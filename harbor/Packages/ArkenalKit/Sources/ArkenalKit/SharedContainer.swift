import Foundation

/// Storage shared by the app and its Files app extension.
///
/// - The NAS list lives in the app group container (no secrets in it).
/// - Sign-in sessions and trusted certificates live in a shared Keychain
///   access group, device-only, so the extension can reuse your sign-in
///   instead of asking again.
/// - Both identifiers come from Info.plist, set per platform in project.yml.
public enum SharedContainer {
    /// "group.com.snowlightlabs.arkenal" (iOS) or "<team>.com.snowlightlabs.arkenal" (Mac).
    public static var appGroup: String? {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "ArkenalAppGroup") as? String)
    }

    /// "<team>.com.snowlightlabs.arkenal".
    public static var keychainGroup: String? {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "ArkenalKeychainGroup") as? String)
    }

    public static var directory: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// Settings both processes read (the Files app switch).
    public static var defaults: UserDefaults {
        appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public static let filesAppKey = "showInFilesApp"

    /// Settings › Privacy › Show NAS in Files App (off unless turned on).
    public static var isFilesAppEnabled: Bool {
        get { defaults.bool(forKey: filesAppKey) }
        set { defaults.set(newValue, forKey: filesAppKey) }
    }

    /// Whether the Files app / Finder may show the NAS right now: only with
    /// Show NAS in Files App on and the app lock off. The extension checks
    /// this itself on every request, so the lock is enforced there even if
    /// removing the location from Finder ever failed.
    public static var isFilesAccessAllowed: Bool {
        isFilesAppEnabled && !SharedConnection.requiresUnlock
    }

    /// Arkenal Pro, as last confirmed by the App Store in the app; read by
    /// the Finder extension (which can't ask the App Store itself).
    public static var isProUnlocked: Bool {
        get { defaults.bool(forKey: "pro.unlocked") }
        set { defaults.set(newValue, forKey: "pro.unlocked") }
    }

    public static var keychain: Keychain { Keychain(accessGroup: keychainGroup) }

    public static func sessionKey(_ id: UUID) -> String { "session.\(id.uuidString)" }

    // MARK: NAS list

    public static var serversURL: URL {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "servers.json")
    }

    public static func loadServers() -> [ServerProfile] {
        moveLegacyServersFile()
        return (try? Data(contentsOf: serversURL)).flatMap { try? JSONDecoder().decode([ServerProfile].self, from: $0) } ?? []
    }

    public static func saveServers(_ servers: [ServerProfile]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: serversURL, options: .atomic)
    }

    /// Earlier builds kept the list in the app's own Application Support.
    private static func moveLegacyServersFile() {
        guard directory != nil else { return }
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "servers.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path(percentEncoded: false)),
              !fm.fileExists(atPath: serversURL.path(percentEncoded: false)) else { return }
        try? fm.moveItem(at: legacy, to: serversURL)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        // An unset team prefix leaves a leading dot.
        return value.hasPrefix(".") ? String(value.dropFirst()) : value
    }
}
