import Foundation

/// Looks up a NAS's current direct addresses from its Synology QuickConnect ID.
///
/// Lookup only: Ownhold then connects straight to the NAS and never sends
/// traffic through Synology's relay servers. The only thing sent to Synology
/// is the QuickConnect ID itself (no account name, password or files).
///
/// The service isn't documented for third-party apps. This follows the
/// request and response shapes Synology's own clients use, parses them
/// defensively, and fails with a clear error if they change.
public struct QuickConnectLookup: Sendable {
    let session: URLSession
    let globalHost: String

    public init(timeout: TimeInterval = 8, globalHost: String = "global.quickconnect.to") {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpAdditionalHeaders = ["User-Agent": "Ownhold"]
        // Synology's lookup servers use publicly trusted certificates, so the
        // system's normal checks apply (no pinning delegate needed).
        self.session = URLSession(configuration: config)
        self.globalHost = globalHost
    }

    /// QuickConnect IDs are letters, digits and hyphens.
    public static func isValidID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard (1 ... 63).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Returns the NAS's current direct addresses, best first.
    public func endpoints(for id: String) async throws -> [Endpoint] {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard Self.isValidID(id) else { throw NASError.quickConnectNotFound }
        var host = globalHost
        // The global server may redirect once to the ID's regional server.
        for _ in 0 ..< 2 {
            let reply = try await request(host: host, id: id)
            switch Self.interpret(reply) {
            case let .found(endpoints):
                guard !endpoints.isEmpty else { throw NASError.quickConnectUnavailable }
                return endpoints
            case let .redirect(site):
                host = site
            case .notFound:
                throw NASError.quickConnectNotFound
            case .failed:
                throw NASError.quickConnectUnavailable
            }
        }
        throw NASError.quickConnectUnavailable
    }

    private func request(host: String, id: String) async throws -> Reply {
        guard let url = URL(string: "https://\(host)/Serv.php") else { throw NASError.quickConnectUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [[String: Any]] = [[
            "version": 1,
            "command": "get_server_info",
            "stop_when_error": false,
            "stop_when_success": false,
            "id": "dsm_portal_https",
            "serverID": id,
            "is_gofile": false,
        ]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await session.data(for: request)
            return try Self.decode(data)
        } catch let error as NASError {
            throw error
        } catch {
            throw NASError.quickConnectUnavailable
        }
    }

    // MARK: Parsing (internal for tests)

    enum Outcome: Equatable {
        case found([Endpoint])
        case redirect(String)
        case notFound
        case failed
    }

    static func decode(_ data: Data) throws -> Reply {
        do {
            let replies = try JSONDecoder().decode([Reply].self, from: data)
            guard let first = replies.first else { throw NASError.quickConnectUnavailable }
            return first
        } catch {
            throw NASError.quickConnectUnavailable
        }
    }

    static func interpret(_ reply: Reply) -> Outcome {
        if reply.errno == 0 { return .found(candidates(from: reply)) }
        if reply.errno == 4 {
            // 4/2: the ID lives on a regional server listed in `sites`.
            if reply.suberrno == 2, let site = reply.sites?.first, isQuickConnectHost(site) {
                return .redirect(site)
            }
            return .notFound
        }
        return .failed
    }

    /// Only follow redirects to Synology's own QuickConnect servers.
    static func isQuickConnectHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h.hasSuffix(".quickconnect.to") && h.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    /// Direct addresses only, best first: LAN addresses, then the NAS's own
    /// DDNS/hostname, then its public address. Relay entries are ignored.
    static func candidates(from reply: Reply) -> [Endpoint] {
        guard let server = reply.server else { return [] }
        let port = reply.service?.port.flatMap { $0 > 0 ? $0 : nil } ?? 5001
        let externalPort = reply.service?.ext_port.flatMap { $0 > 0 ? $0 : nil } ?? port
        var result: [Endpoint] = []
        func add(_ host: String?, _ port: Int, _ kind: Endpoint.Kind) {
            guard let host, isUsableHost(host),
                  let url = URL(string: "https://\(host):\(port)"),
                  !result.contains(where: { $0.url == url })
            else { return }
            result.append(Endpoint(kind: kind, url: url))
        }
        for interface in server.interface ?? [] { add(interface.ip, port, .local) }
        for host in reply.smartdns?.lan ?? [] { add(host, port, .local) }
        add(server.ddns, externalPort, .remote)
        add(server.fqdn, externalPort, .remote)
        add(reply.smartdns?.host, externalPort, .remote)
        add(server.external?.ip, externalPort, .remote)
        return result
    }

    /// IPv4 addresses and DNS names; rejects "NULL", empty, IPv6 and anything odd.
    static func isUsableHost(_ host: String) -> Bool {
        let h = host.lowercased()
        guard !h.isEmpty, h != "null", h != "0.0.0.0", !h.contains(":"), h.count <= 253 else { return false }
        return h.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } && h.contains(".")
    }

    // MARK: Wire types

    struct Reply: Decodable {
        let errno: Int
        let suberrno: Int?
        let sites: [String]?
        let server: Server?
        let service: Service?
        let smartdns: SmartDNS?
    }

    struct Server: Decodable {
        let interface: [Interface]?
        let external: External?
        let ddns: String?
        let fqdn: String?
    }

    struct Interface: Decodable { let ip: String? }
    struct External: Decodable { let ip: String? }

    struct Service: Decodable {
        let port: Int?
        let ext_port: Int?

        enum CodingKeys: String, CodingKey { case port, ext_port }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            port = Self.lenientInt(c, .port)
            ext_port = Self.lenientInt(c, .ext_port)
        }

        /// Accepts 5001 or "5001".
        private static func lenientInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
            if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text) }
            return nil
        }
    }

    struct SmartDNS: Decodable {
        let host: String?
        let lan: [String]?
    }
}
