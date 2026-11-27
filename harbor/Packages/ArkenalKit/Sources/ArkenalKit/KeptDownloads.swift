import Foundation

/// Folders and files kept downloaded in Finder (right-click › Keep
/// Downloaded). Shared by the app and the Finder extension; paths only.
/// Everything inside a kept folder is kept too.
public struct KeptDownloads: @unchecked Sendable { // UserDefaults is thread-safe
    public let domain: String
    private let defaults: UserDefaults

    public init(domain: String, defaults: UserDefaults = SharedContainer.defaults) {
        self.domain = domain
        self.defaults = defaults
    }

    private var key: String { "keptDownloads.\(domain)" }

    public var paths: [String] { defaults.stringArray(forKey: key) ?? [] }

    /// Kept by itself (shows "Stop Keeping Downloaded").
    public func isKept(_ path: String) -> Bool { paths.contains(path) }

    /// Kept by itself or because a folder around it is.
    public func isInsideKept(_ path: String) -> Bool {
        paths.contains { Self.path(path, isWithin: $0) }
    }

    public func keep(_ new: [String]) {
        var all = paths
        for path in new where !all.contains(path) { all.append(path) }
        // Anything inside a newly kept folder no longer needs its own entry.
        let snapshot = all
        all.removeAll { path in snapshot.contains { $0 != path && Self.path(path, isWithin: $0) } }
        defaults.set(all, forKey: key)
    }

    public func stop(_ removed: [String]) {
        defaults.set(paths.filter { !removed.contains($0) }, forKey: key)
    }

    /// Renamed or moved on the NAS: the kept entry follows.
    public func move(from old: String, to new: String) {
        let updated = paths.map { path -> String in
            guard Self.path(path, isWithin: old) else { return path }
            return new + path.dropFirst(old.count)
        }
        defaults.set(updated, forKey: key)
    }

    public func removeAll() { defaults.removeObject(forKey: key) }

    /// "/home/Photos/2024" is within "/home/Photos" (and within itself).
    public static func path(_ path: String, isWithin folder: String) -> Bool {
        path == folder || folder == "/" || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
