import Foundation

/// Client for Synology's File Station Web API (DSM 7.x).
///
/// Reference: "Synology File Station Official API" guide.
/// All requests go over HTTPS. The password is sent once, in a POST body,
/// to obtain a session ID; it is never put in a URL or stored by this type.
public actor FileStationClient: FileService {
    public nonisolated let baseURL: URL
    private let trust: CertificateTrust
    private let session: URLSession
    private var sid: String?
    private var apis: [String: APIInfo] = [:]

    public init(baseURL: URL, trust: CertificateTrust, sid: String? = nil) {
        self.baseURL = baseURL
        self.trust = trust
        self.sid = sid
        let config = URLSessionConfiguration.ephemeral // no on-disk cache or cookies
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60 * 60
        config.httpAdditionalHeaders = ["User-Agent": "Ownhold"]
        self.session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    // MARK: Session

    /// Signs in and returns the session. Pass `deviceToken` from a previous
    /// login to skip the 2-factor prompt on a remembered device.
    public func signIn(
        _ credentials: Credentials,
        deviceName: String,
        deviceToken: String? = nil,
        rememberDevice: Bool = true
    ) async throws -> Session {
        var params: [String: String] = [
            "account": credentials.account,
            "passwd": credentials.password,
            "session": "FileStation",
            "format": "sid",
        ]
        if let otp = credentials.otpCode, !otp.isEmpty {
            params["otp_code"] = otp
            if rememberDevice {
                params["enable_device_token"] = "yes"
                params["device_name"] = deviceName
            }
        }
        if let deviceToken {
            params["device_id"] = deviceToken
            params["device_name"] = deviceName
        }
        let login: LoginData = try await call("SYNO.API.Auth", method: "login", preferredVersion: 6, params: params, authenticated: false)
        sid = login.sid
        return Session(sid: login.sid, deviceToken: login.did ?? deviceToken)
    }

    public func signOut() async {
        guard sid != nil else { return }
        let _: Empty? = try? await call("SYNO.API.Auth", method: "logout", preferredVersion: 6, params: ["session": "FileStation"])
        sid = nil
    }

    /// Cheap request used to check that a stored session is still valid.
    public func validateSession() async throws {
        _ = try await list(folder: "", offset: 0, limit: 1, sort: .name, ascending: true)
    }

    // MARK: Browsing

    public func listShares() async throws -> [RemoteItem] {
        let data: ShareList = try await call("SYNO.FileStation.List", method: "list_share", preferredVersion: 2, params: [
            "additional": #"["size","time"]"#,
            "sort_by": "name",
        ])
        return data.shares.map(\.item)
    }

    public func list(folder: String, offset: Int, limit: Int, sort: SortField, ascending: Bool) async throws -> FolderPage {
        if folder.isEmpty || folder == "/" {
            let shares = try await listShares()
            return FolderPage(items: shares, total: shares.count, offset: 0)
        }
        let data: FileList = try await call("SYNO.FileStation.List", method: "list", preferredVersion: 2, params: [
            "folder_path": folder,
            "offset": String(offset),
            "limit": String(limit),
            "sort_by": sort.apiValue,
            "sort_direction": ascending ? "asc" : "desc",
            "additional": #"["size","time"]"#,
        ])
        return FolderPage(items: data.files.map(\.item), total: data.total, offset: data.offset)
    }

    /// File Station search runs as a background task on the NAS: start it,
    /// poll until it finishes (or ~10s pass), then clean it up.
    public func search(in folder: String, matching pattern: String) async throws -> [RemoteItem] {
        let started: SearchStart = try await call("SYNO.FileStation.Search", method: "start", preferredVersion: 2, params: [
            "folder_path": folder,
            "pattern": pattern,
            "recursive": "true",
        ])
        defer {
            Task { [taskID = started.taskid] in
                let _: Empty? = try? await self.call("SYNO.FileStation.Search", method: "clean", preferredVersion: 2, params: ["taskid": taskID])
            }
        }
        var result: SearchList?
        for _ in 0 ..< 20 {
            let page: SearchList = try await call("SYNO.FileStation.Search", method: "list", preferredVersion: 2, params: [
                "taskid": started.taskid,
                "limit": "500",
                "additional": #"["size","time"]"#,
            ])
            result = page
            if page.finished { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        return result?.files.map(\.item) ?? []
    }

    // MARK: Content

    public func thumbnail(for item: RemoteItem, size: ThumbnailSize) async throws -> Data {
        let request = try await getRequest("SYNO.FileStation.Thumb", method: "get", preferredVersion: 2, params: [
            "path": item.path,
            "size": size.rawValue,
        ])
        let (data, response) = try await perform { try await self.session.data(for: request) }
        try Self.checkBinary(response: response, body: data, api: "SYNO.FileStation.Thumb")
        return data
    }

    public func download(_ item: RemoteItem) async throws -> URL {
        let request = try await getRequest("SYNO.FileStation.Download", method: "download", preferredVersion: 2, params: [
            "path": item.path,
            "mode": "download",
        ])
        let (url, response) = try await perform { try await self.session.download(for: request) }
        // Errors come back as a small JSON body instead of the file. A real
        // .json or .txt file can look similar, so only treat it as an error
        // if it decodes as a failed API envelope.
        if let http = response as? HTTPURLResponse,
           http.mimeType == "application/json" || http.mimeType == "text/plain",
           http.expectedContentLength < 4096,
           let body = try? Data(contentsOf: url),
           let envelope = try? JSONDecoder().decode(Envelope<Empty>.self, from: body),
           !envelope.success {
            try? FileManager.default.removeItem(at: url)
            throw NASError.from(code: envelope.error?.code ?? 100, api: "SYNO.FileStation.Download")
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: url)
            throw http.statusCode == 404 ? NASError.notFound : NASError.server(code: http.statusCode, api: "SYNO.FileStation.Download")
        }
        return url
    }

    /// Ranged GET on the Download API ("open" mode serves the file inline).
    /// If DSM ignores the Range header it would send the whole file, so the
    /// guard cancels any answer that isn't 206 Partial Content.
    public func read(_ item: RemoteItem, from offset: Int64, length: Int) async throws -> ByteRange {
        var request = try await getRequest("SYNO.FileStation.Download", method: "download", preferredVersion: 2, params: [
            "path": item.path,
            "mode": "open",
        ])
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
        if (response as? HTTPURLResponse)?.statusCode != 206 {
            try Self.checkBinary(response: response, body: data, api: "SYNO.FileStation.Download")
            throw NASError.streamingUnsupported
        }
        guard let http = response as? HTTPURLResponse,
              let total = Self.totalLength(contentRange: http.value(forHTTPHeaderField: "Content-Range"))
        else { throw NASError.streamingUnsupported }
        return ByteRange(data: data, totalLength: total)
    }

    /// "bytes 0-1/12345" → 12345.
    static func totalLength(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    // MARK: Changes

    public func createFolder(named name: String, in parent: String) async throws -> RemoteItem {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        let data: FolderList = try await call("SYNO.FileStation.CreateFolder", method: "create", preferredVersion: 2, params: [
            "folder_path": parent,
            "name": name,
            "force_parent": "false",
        ])
        guard let folder = data.folders.first else { throw NASError.malformedResponse }
        return RemoteItem(path: folder.path, name: folder.name, isDirectory: true, modified: .now)
    }

    public func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        let data: FileList = try await call("SYNO.FileStation.Rename", method: "rename", preferredVersion: 2, params: [
            "path": item.path,
            "name": name,
            "additional": #"["size","time"]"#,
        ])
        return data.files.first?.item ?? item.with(path: RemoteItem.join(item.parentPath, name), name: name)
    }

    /// CopyMove runs as a task on the NAS (moving between volumes copies the
    /// data), so start it and poll until it's done. No `overwrite` parameter:
    /// DSM then reports a clash instead of replacing or silently skipping.
    public func move(_ items: [RemoteItem], to folder: String) async throws {
        guard !items.isEmpty else { return }
        let started: TaskStart = try await call("SYNO.FileStation.CopyMove", method: "start", preferredVersion: 3, params: [
            "path": try Self.pathList(items),
            "dest_folder_path": folder,
            "remove_src": "true",
        ])
        try await waitForTask("SYNO.FileStation.CopyMove", taskID: started.taskid, timeout: .seconds(60 * 60))
    }

    public func delete(_ items: [RemoteItem]) async throws {
        guard !items.isEmpty else { return }
        let started: TaskStart = try await call("SYNO.FileStation.Delete", method: "start", preferredVersion: 2, params: [
            "path": try Self.pathList(items),
            "recursive": "true",
            "accurate_progress": "false",
        ])
        try await waitForTask("SYNO.FileStation.Delete", taskID: started.taskid, timeout: .seconds(10 * 60))
    }

    /// Multipart upload, as in the File Station guide. Version 2 is used
    /// explicitly because it's the documented one: `overwrite=true` replaces,
    /// and leaving it out makes DSM refuse a name that's taken.
    public func upload(
        _ file: URL,
        as name: String,
        to folder: String,
        replacing: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        let api = "SYNO.FileStation.Upload"
        let info = try await apiInfo(api)
        guard let sid else { throw NASError.sessionExpired }
        let version = max(info.minVersion, min(2, info.maxVersion))

        var components = URLComponents(url: baseURL.appending(path: "webapi/\(info.path)"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = FormEncoding.encode([
            "api": api, "method": "upload", "version": String(version), "_sid": sid,
        ])
        var fields: [(String, String)] = [
            ("api", api), ("method", "upload"), ("version", String(version)),
            ("path", folder), ("create_parents", "true"),
        ]
        if replacing { fields.append(("overwrite", "true")) }
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fields.append(("mtime", String(Int64(modified.timeIntervalSince1970 * 1000))))
        }
        let boundary = "Ownhold-" + UUID().uuidString
        let body = try Multipart.write(fields: fields, file: file, fileName: name, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120 // DSM may take a while to store a big file after the last byte
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgress(progress)
        let (data, response) = try await perform { [request] in
            try await self.session.upload(for: request, fromFile: body, delegate: delegate)
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw http.statusCode == 413 ? NASError.noSpace : NASError.server(code: http.statusCode, api: api)
        }
        let envelope = try Self.decode(Envelope<Empty>.self, from: data)
        guard envelope.success else {
            let error = NASError.from(code: envelope.error?.code ?? 100, api: api)
            if error == .sessionExpired { self.sid = nil }
            throw error
        }
        progress(1)
    }

    /// Polls a File Station background task until it finishes. A failure
    /// comes back as an error envelope from `status`.
    private func waitForTask(_ api: String, taskID: String, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var delay = Duration.milliseconds(250)
        while clock.now < deadline {
            let status: TaskStatus = try await call(api, method: "status", preferredVersion: api.hasSuffix("CopyMove") ? 3 : 2, params: ["taskid": taskID])
            if status.finished { return }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(2))
        }
        throw NASError.server(code: 599, api: api)
    }

    /// File Station accepts several paths as a JSON array.
    static func pathList(_ items: [RemoteItem]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: items.map(\.path), options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Plumbing

    private func apiInfo(_ api: String) async throws -> APIInfo {
        if let info = apis[api] { return info }
        var components = URLComponents(url: baseURL.appending(path: "webapi/query.cgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Info"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "query"),
            URLQueryItem(name: "query", value: "SYNO.API.Auth,SYNO.FileStation."),
        ]
        let (data, _) = try await perform { [url = components.url!] in try await self.session.data(from: url) }
        let envelope = try Self.decode(Envelope<[String: APIInfo]>.self, from: data)
        guard envelope.success, let infos = envelope.data else { throw NASError.malformedResponse }
        apis = infos
        guard let info = infos[api] else { throw NASError.server(code: 102, api: api) }
        return info
    }

    private func call<T: Decodable>(
        _ api: String,
        method: String,
        preferredVersion: Int,
        params: [String: String],
        authenticated: Bool = true
    ) async throws -> T {
        let info = try await apiInfo(api)
        var form = params
        form["api"] = api
        form["method"] = method
        form["version"] = String(min(preferredVersion, info.maxVersion))
        if authenticated {
            guard let sid else { throw NASError.sessionExpired }
            form["_sid"] = sid
        }
        var request = URLRequest(url: baseURL.appending(path: "webapi/\(info.path)"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(form).utf8)

        let (data, _) = try await perform { [request] in try await self.session.data(for: request) }
        let envelope = try Self.decode(Envelope<T>.self, from: data)
        if envelope.success {
            if let value = envelope.data { return value }
            if let empty = Empty() as? T { return empty }
            throw NASError.malformedResponse
        }
        let error = NASError.from(code: envelope.error?.code ?? 100, api: api)
        if error == .sessionExpired { sid = nil }
        throw error
    }

    /// GET request for binary endpoints. Carries only the session ID, never credentials.
    private func getRequest(_ api: String, method: String, preferredVersion: Int, params: [String: String]) async throws -> URLRequest {
        let info = try await apiInfo(api)
        guard let sid else { throw NASError.sessionExpired }
        var components = URLComponents(url: baseURL.appending(path: "webapi/\(info.path)"), resolvingAgainstBaseURL: false)!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items += [
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "version", value: String(min(preferredVersion, info.maxVersion))),
            URLQueryItem(name: "_sid", value: sid),
        ]
        components.percentEncodedQuery = FormEncoding.encode(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }))
        return URLRequest(url: components.url!)
    }

    /// Runs a request and turns transport failures into `NASError`s.
    private func perform<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as URLError {
            let key = CertificateTrust.hostKey(host: baseURL.host() ?? "", port: baseURL.port ?? 443)
            if let rejection = trust.takeRejection(for: key) { throw rejection }
            switch error.code {
            case .cancelled: throw CancellationError()
            default: throw NASError.unreachable
            }
        }
    }

    private static func checkBinary(response: URLResponse, body: Data, api: String) throws {
        guard let http = response as? HTTPURLResponse else { throw NASError.malformedResponse }
        if http.mimeType == "application/json" || http.mimeType == "text/plain",
           let envelope = try? JSONDecoder().decode(Envelope<Empty>.self, from: body), !envelope.success {
            throw NASError.from(code: envelope.error?.code ?? 100, api: api)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw http.statusCode == 404 ? NASError.notFound : NASError.server(code: http.statusCode, api: api)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NASError.malformedResponse }
    }
}

// MARK: - Wire types

struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIErrorBody?
}

struct APIErrorBody: Decodable { let code: Int }

struct Empty: Decodable, Sendable { init() {} }

struct APIInfo: Decodable, Sendable {
    let path: String
    let minVersion: Int
    let maxVersion: Int
}

struct LoginData: Decodable, Sendable {
    let sid: String
    let did: String?
}

struct WireFile: Decodable, Sendable {
    let path: String
    let name: String
    let isdir: Bool
    let additional: Additional?

    struct Additional: Decodable, Sendable {
        let size: Int64?
        let time: Times?
    }

    struct Times: Decodable, Sendable {
        let mtime: TimeInterval?
    }

    var item: RemoteItem {
        RemoteItem(
            path: path,
            name: name,
            isDirectory: isdir,
            size: isdir ? nil : additional?.size,
            modified: additional?.time?.mtime.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

struct ShareList: Decodable, Sendable {
    let shares: [WireFile]
}

struct FileList: Decodable, Sendable {
    let files: [WireFile]
    let total: Int
    let offset: Int
}

struct SearchStart: Decodable, Sendable { let taskid: String }

struct TaskStart: Decodable, Sendable { let taskid: String }

struct TaskStatus: Decodable, Sendable { let finished: Bool }

struct FolderList: Decodable, Sendable {
    let folders: [Folder]
    struct Folder: Decodable, Sendable {
        let path: String
        let name: String
    }
}

/// Lets a ranged read continue only if the server answered 206.
final class RangeGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _rejected = false
    var rejected: Bool { lock.withLock { _rejected } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let partial = (response as? HTTPURLResponse)?.statusCode == 206
        // A small JSON error body is fine to read; a whole file is not.
        let small = response.expectedContentLength >= 0 && response.expectedContentLength < 4096
        if partial || small { return .allow }
        lock.withLock { _rejected = true }
        return .cancel
    }
}

/// Reports upload progress; everything else (including the certificate
/// check) is left to the session's delegate.
final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        // Hold back the last percent until DSM confirms it stored the file.
        report(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// Writes a multipart/form-data body to a temporary file, streaming the
/// source in chunks so large videos don't have to fit in memory.
enum Multipart {
    static func write(fields: [(String, String)], file: URL, fileName: String, boundary: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Uploads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = directory.appending(path: UUID().uuidString)
        FileManager.default.createFile(atPath: body.path(percentEncoded: false), contents: nil)
        let out = try FileHandle(forWritingTo: body)
        defer { try? out.close() }
        do {
            var head = ""
            for (name, value) in fields {
                head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            }
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(quoted(fileName))\"\r\n"
            head += "Content-Type: application/octet-stream\r\n\r\n"
            try out.write(contentsOf: Data(head.utf8))
            let source = try FileHandle(forReadingFrom: file)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: body)
            throw error
        }
        return body
    }

    /// Quotes and line breaks would end the header early.
    static func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

struct SearchList: Decodable, Sendable {
    let files: [WireFile]
    let finished: Bool
}

enum FormEncoding {
    private static let allowed: CharacterSet = {
        // ASCII only: CharacterSet.alphanumerics would let "é" through unescaped.
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }()

    static func encode(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
