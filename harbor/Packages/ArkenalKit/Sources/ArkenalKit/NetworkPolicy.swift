import Foundation
import Network

/// When Arkenal may use the network for work you didn't just ask for.
///
/// "Expensive" is cellular data or a Personal Hotspot; "constrained" is Low
/// Data Mode. Each kind of work has its own switch for expensive networks
/// (Settings › Cellular Data, or Personal Hotspot on a Mac). Low Data Mode
/// always pauses automatic work; something you start yourself still runs.
public enum NetworkPolicy {
    public enum Use: String, CaseIterable, Sendable {
        /// Automatic Photo Backup (iOS) and Folder Backup (Mac).
        case backups
        /// Uploads of a file over `largeUploadBytes`.
        case largeUploads
        /// Downloading files kept downloaded in Finder (Mac).
        case keptDownloads

        /// Setting key, in the app's own defaults.
        public var key: String { "cellular.\(rawValue)" }

        /// Off unless turned on, except large uploads you start yourself.
        public var allowedByDefault: Bool { self == .largeUploads }
    }

    public static let largeUploadBytes: Int64 = 50_000_000

    /// The rule itself, separate from the device's state so it can be tested.
    public static func allows(expensive: Bool, constrained: Bool, cellularAllowed: Bool, automatic: Bool) -> Bool {
        if constrained, automatic { return false }
        if expensive, !cellularAllowed { return false }
        return true
    }

    public static func isCellularAllowed(_ use: Use, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: use.key) as? Bool ?? use.allowedByDefault
    }

    /// Whether `use` may run right now on this device's connection.
    public static func allows(_ use: Use, automatic: Bool, defaults: UserDefaults = .standard) -> Bool {
        let status = NetworkStatus.shared
        return allows(expensive: status.isExpensive, constrained: status.isConstrained,
                      cellularAllowed: isCellularAllowed(use, defaults: defaults), automatic: automatic)
    }

    /// What to show while work waits for a better network.
    public static var waitingReason: String {
        NetworkStatus.shared.isConstrained ? "Paused in Low Data Mode" : "Waiting for Wi-Fi"
    }
}

/// The current connection: cellular or Personal Hotspot (expensive), and
/// Low Data Mode (constrained). Watched for as long as the app runs.
public final class NetworkStatus: @unchecked Sendable {
    public static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false
    private var constrained = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock {
                self.expensive = path.isExpensive
                self.constrained = path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.snowlightlabs.arkenal.network"))
    }

    public var isExpensive: Bool { lock.withLock { expensive } }
    public var isConstrained: Bool { lock.withLock { constrained } }
}
