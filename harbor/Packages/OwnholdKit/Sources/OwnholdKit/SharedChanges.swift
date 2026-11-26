import FileProvider
import Foundation

/// Changes the app made on a NAS, passed to the Files app extension so the
/// Files app and Finder show them straight away (the extension doesn't watch
/// the NAS: Ownhold never syncs in the background).
///
/// The app records which folders changed and which paths went away, then
/// asks the system to check the domain's working set; the extension takes
/// the records, lists those folders again and reports what it finds. Only
/// paths are stored, in the app group container, and they're removed as
/// soon as the extension has read them.
public enum SharedChanges {
    public struct Pending: Codable, Equatable, Sendable {
        public var folders: [String] = []
        public var removed: [String] = []
        public var isEmpty: Bool { folders.isEmpty && removed.isEmpty }
        public init(folders: [String] = [], removed: [String] = []) {
            self.folders = folders
            self.removed = removed
        }
    }

    /// Enough for any burst of changes; older entries are dropped (the
    /// folder is listed again whenever it's next opened anyway).
    static let limit = 300

    public static func record(domain: String, folders: [String] = [], removed: [String] = [], in directory: URL? = SharedContainer.directory) {
        guard let url = fileURL(domain: domain, in: directory), !(folders.isEmpty && removed.isEmpty) else { return }
        coordinate(url, writing: true) { url in
            var pending = read(url)
            pending.folders = merged(pending.folders, folders)
            pending.removed = merged(pending.removed, removed)
            write(pending, to: url)
        }
    }

    /// Records a change and asks the system to fetch it from the extension.
    /// Does nothing while Files access is off (or the app lock is on).
    /// `domain` is the server's ID, or "demo" for the demo library.
    public static func announce(domain: String, name: String, folders: [String] = [], removed: [String] = []) {
        guard SharedContainer.isFilesAppEnabled, !SharedConnection.requiresUnlock else { return }
        record(domain: domain, folders: folders, removed: removed)
        let fileProviderDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domain), displayName: name)
        NSFileProviderManager(for: fileProviderDomain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    /// Returns and clears everything recorded for a domain.
    public static func take(domain: String, in directory: URL? = SharedContainer.directory) -> Pending {
        guard let url = fileURL(domain: domain, in: directory) else { return Pending() }
        var taken = Pending()
        coordinate(url, writing: true) { url in
            taken = read(url)
            try? FileManager.default.removeItem(at: url)
        }
        return taken
    }

    // MARK: Storage

    private static func fileURL(domain: String, in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let folder = directory.appending(path: "Changes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = domain.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return folder.appending(path: (safe.isEmpty ? "domain" : safe) + ".json")
    }

    private static func merged(_ old: [String], _ new: [String]) -> [String] {
        var seen = Set<String>()
        // Newest last; keep the most recent `limit`.
        let all = (old + new).reversed().filter { seen.insert($0).inserted }
        return Array(all.prefix(limit).reversed())
    }

    private static func read(_ url: URL) -> Pending {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } ?? Pending()
    }

    private static func write(_ pending: Pending, to url: URL) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The app and the extension are separate processes: coordinate so a
    /// record isn't lost between reading and clearing the file.
    private static func coordinate(_ url: URL, writing: Bool, _ body: (URL) -> Void) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error, byAccessor: body)
        if error != nil { body(url) }
    }
}
