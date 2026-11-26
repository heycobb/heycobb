import Foundation

/// How Ownhold talks to a NAS.
///
/// Synology gets DSM's own API (thumbnails, share links, archives, Recycle
/// Bin, QuickConnect). Any other NAS (QNAP, UGREEN, UniFi, TrueNAS, a Mac
/// or PC) is reached over the file-sharing standards every one of them
/// offers: SMB, or WebDAV over HTTPS.
public enum ServerKind: String, Codable, Sendable, CaseIterable {
    case synology
    case webdav
    case smb

    public var label: String {
        switch self {
        case .synology: "Synology"
        case .webdav: "WebDAV"
        case .smb: "File Sharing (SMB)"
        }
    }

    // MARK: What each kind can do (the UI shows features by these)

    /// DSM's Sharing Links.
    public var hasShareLinks: Bool { self == .synology }
    /// Compressing on the NAS and extracting archives. Elsewhere, Compress
    /// zips on the device and uploads the archive.
    public var hasArchives: Bool { self == .synology }
    /// DSM's Recycle Bin (Recently Deleted).
    public var hasRecycleBin: Bool { self == .synology }
    /// Synology's QuickConnect address lookup.
    public var hasQuickConnect: Bool { self == .synology }
    /// 2-factor sign-in codes.
    public var hasTwoFactor: Bool { self == .synology }
    /// Thumbnails made by the NAS. Elsewhere they're made on the device.
    public var hasServerThumbnails: Bool { self == .synology }
    /// SMB isn't encrypted by most NAS, so it's for the home network or a
    /// VPN only. Ownhold says so when it's used.
    public var isUnencrypted: Bool { self == .smb }

    /// The usual port for the kind (as typed addresses default to it).
    public var defaultPort: Int {
        switch self {
        case .synology: 5001
        case .webdav: 443
        case .smb: 445
        }
    }
}

public extension Endpoint {
    /// Parses a typed address for a kind of server:
    /// - Synology: "nas.local" → https://nas.local:5001
    /// - WebDAV: "https://nas.local:5006/" or a server path such as
    ///   "https://cloud.example.com/remote.php/dav/files/me/". HTTPS only.
    /// - SMB: "nas.local" or "smb://nas.local" → smb://nas.local
    static func parse(_ text: String, kind: Kind? = nil, server: ServerKind) -> Endpoint? {
        switch server {
        case .synology:
            return parse(text, kind: kind)
        case .webdav:
            var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.lowercased().hasPrefix("http://") else { return nil }
            if !raw.lowercased().hasPrefix("https://") { raw = "https://" + raw }
            guard var components = URLComponents(string: raw), let host = components.host, !host.isEmpty else { return nil }
            components.query = nil
            components.fragment = nil
            if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
            guard let url = components.url else { return nil }
            return Endpoint(kind: kind ?? guessKind(host: host), url: url)
        case .smb:
            var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if let scheme = raw.range(of: "://") {
                guard raw[..<scheme.lowerBound].lowercased() == "smb" else { return nil }
                raw = String(raw[scheme.upperBound...])
            }
            guard let components = URLComponents(string: "smb://" + raw), let host = components.host, !host.isEmpty else { return nil }
            var clean = URLComponents()
            clean.scheme = "smb"
            clean.host = host
            if let port = components.port, port != 445 { clean.port = port }
            guard let url = clean.url else { return nil }
            return Endpoint(kind: kind ?? guessKind(host: host), url: url)
        }
    }
}

public extension Endpoint {
    /// The address as it's shown for editing: what parsing it gives back.
    func editableText(server: ServerKind) -> String {
        guard let host = url.host() else { return "" }
        switch server {
        case .webdav:
            return url.absoluteString
        case .synology, .smb:
            return url.port == nil || url.port == server.defaultPort ? host : "\(host):\(url.port!)"
        }
    }
}
