import Foundation

/// A saved NAS. Contains nothing secret: the session ID and device token
/// live in the Keychain, keyed by `id`.
public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var account: String
    /// Addresses to try, in priority order.
    public var endpoints: [Endpoint]

    public init(id: UUID = UUID(), name: String, account: String, endpoints: [Endpoint]) {
        self.id = id
        self.name = name
        self.account = account
        self.endpoints = endpoints
    }

    public static let demo = ServerProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000DE70")!,
        name: "Demo NAS",
        account: "demo",
        endpoints: []
    )

    public var isDemo: Bool { id == Self.demo.id }
}

public struct Endpoint: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case local, tailscale, remote

        public var label: String {
            switch self {
            case .local: "Home network"
            case .tailscale: "Tailscale"
            case .remote: "Internet"
            }
        }
    }

    public var id: URL { url }
    public var kind: Kind
    public var url: URL

    public init(kind: Kind, url: URL) {
        self.kind = kind
        self.url = url
    }

    /// Accepts "nas.local", "100.64.1.2:5001", "https://nas.tail1234.ts.net"…
    /// and normalizes to an HTTPS URL, defaulting to DSM's HTTPS port 5001.
    /// Plain HTTP is deliberately not supported.
    public static func parse(_ text: String, kind: Kind? = nil) -> Endpoint? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("http://") { return nil }
        if !raw.lowercased().hasPrefix("https://") { raw = "https://" + raw }
        guard var components = URLComponents(string: raw), let host = components.host, !host.isEmpty else { return nil }
        if components.port == nil { components.port = 5001 }
        components.path = ""
        components.query = nil
        guard let url = components.url else { return nil }
        return Endpoint(kind: kind ?? guessKind(host: host), url: url)
    }

    static func guessKind(host: String) -> Kind {
        let h = host.lowercased()
        if h.hasSuffix(".ts.net") || h.hasPrefix("100.") && isCGNAT(h) { return .tailscale }
        if h.hasSuffix(".local") || h.hasPrefix("192.168.") || h.hasPrefix("10.") || isPrivate172(h) || !h.contains(".") {
            return .local
        }
        return .remote
    }

    /// Tailscale assigns addresses from 100.64.0.0/10.
    private static func isCGNAT(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64 ... 127).contains(parts[1])
    }

    private static func isPrivate172(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 172 && (16 ... 31).contains(parts[1])
    }
}
