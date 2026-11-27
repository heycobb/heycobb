import Foundation
import OSLog

/// A NAS reached over WebDAV (RFC 4918), on HTTPS only.
///
/// QNAP, UGREEN, TrueNAS, Nextcloud and Synology (with its WebDAV Server
/// package) all offer it. The account and password go with every request
/// (HTTP Basic, inside the encrypted connection), since WebDAV has no
/// sessions; the certificate is checked and pinned like DSM's.
///
/// Paths: "/" is the address the user entered (for example
/// https://nas.local:5006/), its folders act as the shared folders, and
/// "/Photos/2024" is a folder below it.
public final class WebDAVClient: FileService {
    private static let log = Logger(subsystem: "com.snowlightlabs.Arkenal", category: "webdav")
    public let baseURL: URL
    private let session: URLSession
    private let trust: CertificateTrust
    private let authorization: String
    private let cache = ListingCache()

    public init(baseURL: URL, account: String, password: String, trust: CertificateTrust) {
        self.baseURL = baseURL
        self.trust = trust
        authorization = "Basic " + Data("\(account):\(password)".utf8).base64EncodedString()
        let config = URLSessionConfiguration.ephemeral // no on-disk cache or cookies
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60 * 60
        config.httpAdditionalHeaders = ["User-Agent": "Arkenal"]
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: Session

    public func validateSession() async throws {
        _ = try await propfind("/", depth: "0")
    }

    public func signOut() async {}

    // MARK: Browsing

    public func listShares() async throws -> [RemoteItem] {
        try await listAll("/").filter(\.isDirectory)
    }

    public func list(folder: String, offset: Int, limit: Int, sort: SortField, ascending: Bool) async throws -> FolderPage {
        SharingProtocols.page(try await listAll(folder), offset: offset, limit: limit, sort: sort, ascending: ascending)
    }

    public func search(in folder: String, matching pattern: String) async throws -> [RemoteItem] {
        try await SharingProtocols.search(in: folder, matching: pattern) { try await self.listAll($0) }
    }

    /// WebDAV servers don't make thumbnails; the device does (see
    /// ThumbnailCache, which falls back to LocalThumbnailer on notFound).
    public func thumbnail(for item: RemoteItem, size: ThumbnailSize) async throws -> Data {
        throw NASError.notFound
    }

    public func download(_ item: RemoteItem) async throws -> URL {
        guard !item.isDirectory else { throw NASError.unsupported }
        let request = request("GET", item.path)
        let (url, response) = try await perform { [request] in try await self.session.download(for: request) }
        do {
            try Self.check(response)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    public func read(_ item: RemoteItem, from offset: Int64, length: Int) async throws -> ByteRange {
        var request = request("GET", item.path)
        request.setValue("bytes=\(offset)-\(offset + Int64(max(length, 1)) - 1)", forHTTPHeaderField: "Range")
        let guardian = RangeGuard()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: guardian)
        } catch {
            if guardian.rejected { throw NASError.streamingUnsupported }
            return try await perform { throw error }
        }
        try Self.check(response)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let total = FileStationClient.totalLength(contentRange: http.value(forHTTPHeaderField: "Content-Range"))
        else { throw NASError.streamingUnsupported }
        return ByteRange(data: data, totalLength: total)
    }

    // MARK: Changes

    public func createFolder(named name: String, in parent: String) async throws -> RemoteItem {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        let path = RemoteItem.join(parent, name)
        try await send(request("MKCOL", path), conflict: .alreadyExists)
        await cache.invalidate([parent])
        return RemoteItem(path: path, name: name, isDirectory: true, modified: Date())
    }

    public func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        let destination = RemoteItem.join(item.parentPath, name)
        try await move(item.path, to: destination, isDirectory: item.isDirectory)
        await cache.invalidate([item.parentPath])
        return item.with(path: destination, name: name)
    }

    public func move(_ items: [RemoteItem], to folder: String) async throws {
        for item in items {
            try await move(item.path, to: RemoteItem.join(folder, item.name), isDirectory: item.isDirectory)
        }
        await cache.invalidate([folder] + items.map(\.parentPath))
    }

    public func delete(_ items: [RemoteItem]) async throws {
        for item in items {
            try await send(request("DELETE", item.path, isDirectory: item.isDirectory))
        }
        await cache.invalidate(items.map(\.parentPath))
    }

    public func upload(
        _ file: URL,
        as name: String,
        to folder: String,
        replacing: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        try await createMissingFolders(folder)
        let path = RemoteItem.join(folder, name)
        var request = request("PUT", path)
        // The server refuses rather than replacing, unless asked to replace.
        if !replacing { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let delegate = UploadProgress(progress)
        let (_, response) = try await perform { [request] in try await self.session.upload(for: request, fromFile: file, delegate: delegate) }
        if (response as? HTTPURLResponse)?.statusCode == 412 { throw NASError.alreadyExists }
        try Self.check(response, conflict: .notFound)
        await cache.invalidate([folder])
        progress(1)
    }

    /// The NAS can't zip over WebDAV: Arkenal zips on the device instead.
    public func compress(_ items: [RemoteItem], to destination: String) async throws { throw NASError.unsupported }
    public func archiveTopLevel(_ archive: RemoteItem) async throws -> [String] { throw NASError.unsupported }
    public func extract(_ archive: RemoteItem, into folder: String) async throws { throw NASError.unsupported }
    public func createShareLink(for item: RemoteItem, password: String?, expires: Date?) async throws -> SharingLink { throw NASError.unsupported }
    public func deleteShareLink(_ link: SharingLink) async throws { throw NASError.unsupported }

    // MARK: Requests

    private func listAll(_ folder: String) async throws -> [RemoteItem] {
        if let cached = await cache.items(for: folder) { return cached }
        let entries = try await propfind(folder, depth: "1")
        let items = entries.filter { $0.path != Self.normalized(folder) && !SharingProtocols.isHidden($0.name) }
        await cache.store(items, for: folder)
        return items
    }

    private func propfind(_ path: String, depth: String) async throws -> [RemoteItem] {
        var request = request("PROPFIND", path, isDirectory: true)
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await perform { [request] in try await self.session.data(for: request) }
        try Self.check(response)
        return try WebDAVMultistatus.parse(data, base: baseURL)
    }

    /// MOVE without replacing anything at the destination.
    private func move(_ path: String, to destination: String, isDirectory: Bool) async throws {
        var request = request("MOVE", path, isDirectory: isDirectory)
        request.setValue(url(for: destination, isDirectory: isDirectory).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        try await send(request, conflict: .notFound)
    }

    private func createMissingFolders(_ folder: String) async throws {
        if (try? await propfind(folder, depth: "0")) != nil { return }
        for path in SharingProtocols.ancestors(of: folder) {
            var request = request("MKCOL", path)
            request.timeoutInterval = 20
            let (_, response) = try await perform { [request] in try await self.session.data(for: request) }
            // 405: it's there already.
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 405 { try Self.check(response) }
        }
        await cache.invalidate(SharingProtocols.ancestors(of: folder).map { ($0 as NSString).deletingLastPathComponent })
    }

    private func send(_ request: URLRequest, conflict: NASError = .notFound) async throws {
        let (_, response) = try await perform { [request] in try await self.session.data(for: request) }
        try Self.check(response, conflict: conflict)
    }

    private func request(_ method: String, _ path: String, isDirectory: Bool = false) -> URLRequest {
        var request = URLRequest(url: url(for: path, isDirectory: isDirectory))
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    /// The address of "/a/b c": the base URL plus each name percent-encoded.
    func url(for path: String, isDirectory: Bool) -> URL {
        Self.url(base: baseURL, path: path, isDirectory: isDirectory)
    }

    static func url(base: URL, path: String, isDirectory: Bool) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%")
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
        var text = base.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        text += encoded.joined(separator: "/")
        if isDirectory, !encoded.isEmpty { text += "/" }
        return URL(string: text) ?? base
    }

    static func normalized(_ path: String) -> String {
        "/" + path.split(separator: "/").joined(separator: "/")
    }

    /// Runs a request and turns transport failures into `NASError`s.
    private func perform<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as URLError {
            let key = CertificateTrust.hostKey(host: baseURL.host() ?? "", port: baseURL.port ?? 443)
            if let rejection = trust.takeRejection(for: key) { throw rejection }
            Self.log.error("WebDAV request failed: \(error.code.rawValue)")
            switch error.code {
            case .cancelled: throw CancellationError()
            default: throw NASError.unreachable
            }
        }
    }

    static func check(_ response: URLResponse, conflict: NASError = .notFound) throws {
        guard let http = response as? HTTPURLResponse else { throw NASError.malformedResponse }
        switch http.statusCode {
        case 200 ..< 300: return
        // The password stopped working (changed on the NAS): sign in again.
        case 401: throw NASError.sessionExpired
        case 403: throw NASError.permissionDenied
        case 404: throw NASError.notFound
        case 405, 412: throw NASError.alreadyExists
        case 409: throw conflict
        case 413, 507: throw NASError.noSpace
        default: throw NASError.server(code: http.statusCode, api: "WebDAV")
        }
    }
}

/// Reads a PROPFIND answer (a DAV:multistatus document).
enum WebDAVMultistatus {
    static func parse(_ data: Data, base: URL) throws -> [RemoteItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { throw NASError.malformedResponse }
        let basePath = decodedPath(base)
        return delegate.responses.compactMap { response in
            guard let href = response.href, let url = URL(string: href, relativeTo: base) else { return nil }
            var path = decodedPath(url)
            guard path.lowercased().hasPrefix(basePath.lowercased()) else { return nil }
            path = String(path.dropFirst(basePath.count))
            let parts = path.split(separator: "/")
            let name = parts.last.map(String.init) ?? ""
            return RemoteItem(
                path: "/" + parts.joined(separator: "/"),
                name: name,
                isDirectory: response.isCollection,
                size: response.isCollection ? nil : response.length,
                modified: response.modified.flatMap(httpDate)
            )
        }
    }

    /// The URL's path, decoded, ending in "/".
    private static func decodedPath(_ url: URL) -> String {
        let path = url.absoluteURL.path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }

    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    struct Response {
        var href: String?
        var isCollection = false
        var length: Int64?
        var modified: String?
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var responses: [Response] = []
        private var current: Response?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "response": current = Response()
            case "collection": current?.isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href": if current?.href == nil { current?.href = value }
            case "getcontentlength": current?.length = Int64(value)
            case "getlastmodified": current?.modified = value
            case "response":
                if let current { responses.append(current) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
