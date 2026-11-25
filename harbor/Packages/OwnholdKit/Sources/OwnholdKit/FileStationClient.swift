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
