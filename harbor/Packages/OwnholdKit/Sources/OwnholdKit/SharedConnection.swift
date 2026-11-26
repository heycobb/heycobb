import Foundation

/// Connects to a NAS from an extension (Files app, Save to Ownhold), reusing
/// the app's sign-in and trusted certificates from the shared Keychain group.
/// Extensions never ask for a password: if there's no valid session, they
/// say to open Ownhold.
public enum SharedConnection {
    /// The NAS list, as the app saved it.
    public static func servers() -> [ServerProfile] {
        SharedContainer.loadServers()
    }

    public static func hasSession(for profile: ServerProfile) -> Bool {
        guard let session = SharedContainer.keychain.codable(Session.self, for: SharedContainer.sessionKey(profile.id)) else { return false }
        return !session.sid.isEmpty
    }

    /// Picks the best address and returns a signed-in client.
    public static func connect(to profile: ServerProfile) async throws -> any FileService {
        if profile.isDemo { return DemoFileService() }
        let keychain = SharedContainer.keychain
        guard let session = keychain.codable(Session.self, for: SharedContainer.sessionKey(profile.id)),
              !session.sid.isEmpty
        else { throw NASError.sessionExpired }
        let trust = CertificateTrust(keychain: keychain)
        let endpoint = try await ConnectionResolver(trust: trust).resolve(profile.allEndpoints, server: profile.kind)
        return Connector.service(for: profile, at: endpoint, session: session, trust: trust)
    }

    /// Whether the app lock (Settings › Privacy) is on, so extensions ask
    /// for Face ID / Touch ID too.
    public static var requiresUnlock: Bool {
        get { SharedContainer.defaults.bool(forKey: "requireUnlock") }
        set { SharedContainer.defaults.set(newValue, forKey: "requireUnlock") }
    }

    /// The folder last saved to, per NAS ("<id>|/path").
    public static func lastFolder(for profile: ServerProfile) -> String? {
        SharedContainer.defaults.string(forKey: "lastSaveFolder.\(profile.id.uuidString)")
    }

    public static func setLastFolder(_ path: String, for profile: ServerProfile) {
        SharedContainer.defaults.set(path, forKey: "lastSaveFolder.\(profile.id.uuidString)")
    }
}
