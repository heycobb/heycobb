import Foundation

/// A saved NAS. Contains nothing secret: the session ID and device token
/// live in the Keychain, keyed by `id`.
public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var account: String
    /// Addresses the user entered, in priority order.
    public var endpoints: [Endpoint]
    /// Optional Synology QuickConnect ID. Used only to look up the NAS's
    /// current direct addresses; traffic never goes through Synology's relay.
    public var quickConnectID: String?
    /// Addresses found by the last QuickConnect lookup, kept so the app can
    /// still connect if the lookup service is unavailable.
    public var discoveredEndpoints: [Endpoint]
    /// For Wake NAS: "00:11:32:AA:BB:CC". Read from DSM when the account may
    /// see it (admins), or typed in Edit NAS.
    public var macAddress: String?

    public init(
        id: UUID = UUID(),
        name: String,
        account: String,
        endpoints: [Endpoint],
        quickConnectID: String? = nil,
        discoveredEndpoints: [Endpoint] = [],
        macAddress: String? = nil
    ) {
        self.id = id
        self.name = name
        self.account = account
        self.endpoints = endpoints
        self.quickConnectID = quickConnectID
        self.discoveredEndpoints = discoveredEndpoints
        self.macAddress = macAddress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        account = try c.decode(String.self, forKey: .account)
        endpoints = try c.decode([Endpoint].self, forKey: .endpoints)
        quickConnectID = try c.decodeIfPresent(String.self, forKey: .quickConnectID)
        discoveredEndpoints = try c.decodeIfPresent([Endpoint].self, forKey: .discoveredEndpoints) ?? []
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
    }

    public static let demo = ServerProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000DE70")!,
        name: "Demo NAS",
        account: "demo",
        endpoints: []
    )

    public var isDemo: Bool { id == Self.demo.id }

    /// Entered addresses first, then any discovered ones not already listed,
    /// ordered home network → private network → internet.
    public var allEndpoints: [Endpoint] {
        var seen = Set<URL>()
        let merged = (endpoints + discoveredEndpoints).filter { seen.insert($0.url).inserted }
        return merged.enumerated()
            .sorted { ($0.element.kind.priority, $0.offset) < ($1.element.kind.priority, $1.offset) }
            .map(\.element)
    }
}

public struct Endpoint: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case local
        /// Any private network that runs as a VPN on the device: Tailscale,
        /// ZeroTier, NetBird, WireGuard, Headscale… Stored as "tailscale"
        /// for compatibility with earlier builds.
        case vpn = "tailscale"
        case remote

        public var label: String {
            switch self {
            case .local: "Home network"
            case .vpn: "Private network"
            case .remote: "Internet"
            }
        }

        var priority: Int {
            switch self {
            case .local: 0
            case .vpn: 1
            case .remote: 2
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

    /// What to call this connection in the UI: the private network's name
    /// when it can be told from the address, otherwise the kind's label.
    public var displayName: String {
        if kind == .vpn, let network = privateNetwork { return network }
        return kind.label
    }

    /// Recognizes private networks from their DNS names. IP ranges aren't
    /// used: Tailscale and NetBird both use 100.64.0.0/10, and ZeroTier and
    /// WireGuard use whatever range the user picks.
    public var privateNetwork: String? {
        let h = (url.host() ?? "").lowercased()
        if h.hasSuffix(".ts.net") { return "Tailscale" }
        if h.hasSuffix(".netbird.cloud") || h.hasSuffix(".netbird.selfhosted") { return "NetBird" }
        return nil
    }

    /// Synology's free DDNS service hostnames (set up in DSM under
    /// Control Panel › External Access › DDNS).
    public static let synologyDDNSDomains = [
        "synology.me", "myds.me", "diskstation.me", "i234.me", "myddns.me",
        "dscloud.biz", "dscloud.me", "dscloud.mobi",
        "dsmynas.com", "dsmynas.net", "dsmynas.org",
        "familyds.com", "familyds.net", "familyds.org",
    ]

    public var isSynologyDDNS: Bool {
        let h = (url.host() ?? "").lowercased()
        return Self.synologyDDNSDomains.contains { h.hasSuffix("." + $0) }
    }

    /// DSM serves plain HTTP on 5000 and HTTPS on 5001. An HTTPS address on
    /// 5000 is almost always a typo, and fails with a confusing error.
    public var usesDSMHTTPPort: Bool { url.port == 5000 }

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
        if h.hasSuffix(".ts.net") || h.hasSuffix(".netbird.cloud") || h.hasPrefix("100.") && isCGNAT(h) { return .vpn }
        if h.hasSuffix(".local") || h.hasPrefix("192.168.") || h.hasPrefix("10.") || isPrivate172(h) || !h.contains(".") {
            return .local
        }
        return .remote
    }

    /// 100.64.0.0/10 (carrier-grade NAT space), used by Tailscale and NetBird.
    private static func isCGNAT(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64 ... 127).contains(parts[1])
    }

    private static func isPrivate172(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 172 && (16 ... 31).contains(parts[1])
    }
}
