import FileProvider
import OwnholdKit

/// Lists a NAS folder for the Files app.
///
/// File Station has no change feed: when asked for changes, a folder is
/// listed again and compared with its last listing.
/// The working set reports changes made in the Ownhold app itself (recorded
/// in `SharedChanges`), and, when the app asks every few minutes while it's
/// open, changes made elsewhere in folders opened recently in Finder and in
/// folders kept downloaded.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let container: NSFileProviderItemIdentifier
    private let context: ProviderContext
    private let snapshots: SnapshotStore
    private let kept: KeptDownloads
    private static let pageSize = 500

    init(container: NSFileProviderItemIdentifier, context: ProviderContext, snapshots: SnapshotStore) {
        self.container = container
        self.context = context
        self.snapshots = snapshots
        self.kept = KeptDownloads(domain: context.domainID)
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let box = ObserverBox(observer)
        let offset = Self.offset(from: page)
        Task {
            do {
                // The working set is everything the system tracks; Ownhold
                // reports folders as they're browsed instead.
                guard container != .workingSet else {
                    box.observer.finishEnumerating(upTo: nil)
                    return
                }
                let path = FileProviderItem.path(for: container)
                let page = try await context.run { service in
                    try await service.list(folder: path, offset: offset, limit: Self.pageSize, sort: .name, ascending: true)
                }
                await snapshots.record(page.items.map(\.path), for: path, replacing: offset == 0)
                if offset == 0 { await snapshots.visited(path) }
                let kept = self.kept
                box.observer.didEnumerate(page.items.map { FileProviderItem($0, kept: kept) })
                box.observer.finishEnumerating(upTo: page.hasMore ? Self.page(offset + page.items.count) : nil)
            } catch {
                box.observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let box = ChangeObserverBox(observer)
        Task {
            guard container != .workingSet else {
                await reportAppChanges(to: box)
                return
            }
            do {
                let path = FileProviderItem.path(for: container)
                let items = try await context.run { service in
                    try await service.list(folder: path, offset: 0, limit: 5000, sort: .name, ascending: true).items
                }
                let previous = await snapshots.paths(for: path)
                await snapshots.record(items.map(\.path), for: path, replacing: true)
                let gone = Set(previous).subtracting(items.map(\.path))
                let kept = self.kept
                box.observer.didUpdate(items.map { FileProviderItem($0, kept: kept) })
                box.observer.didDeleteItems(withIdentifiers: gone.map(FileProviderItem.identifier(for:)))
                box.observer.finishEnumeratingChanges(upTo: Self.anchor(), moreComing: false)
            } catch {
                box.observer.finishEnumeratingWithError(error)
            }
        }
    }

    /// Lists each folder the app changed (and, at most once a minute, the
    /// folders worth checking for changes made elsewhere), then reports
    /// their contents plus whatever went away. A folder the app changed that
    /// can't be listed right now is recorded again for the next check.
    private func reportAppChanges(to box: ChangeObserverBox) async {
        let domain = context.domainID
        let pending = SharedChanges.take(domain: domain)
        let watched = await snapshots.foldersToCheck(kept: kept.paths)
        var updated: [FileProviderItem] = []
        var removed = Set(pending.removed)
        var queue = pending.folders + watched.folders.filter { !pending.folders.contains($0) }
        var listed = Set<String>()
        let fromApp = Set(pending.folders)
        while !queue.isEmpty, listed.count < SnapshotStore.folderLimit {
            let folder = queue.removeFirst()
            guard listed.insert(folder).inserted else { continue }
            do {
                let items = try await context.run { service in
                    try await service.list(folder: folder, offset: 0, limit: 5000, sort: .name, ascending: true).items
                }
                let previous = await snapshots.paths(for: folder)
                await snapshots.record(items.map(\.path), for: folder, replacing: true)
                removed.formUnion(Set(previous).subtracting(items.map(\.path)))
                updated += items.map { FileProviderItem($0, kept: kept) }
                // Walking a kept folder: list everything inside it too, so new
                // files there download without the folder being opened.
                if watched.walkKept, kept.isInsideKept(folder) {
                    queue += items.filter(\.isDirectory).map(\.path)
                }
            } catch let error as NSFileProviderError where error.code == .noSuchItem {
                removed.insert(folder)
            } catch {
                if fromApp.contains(folder) { SharedChanges.record(domain: domain, folders: [folder]) }
            }
        }
        removed.subtract(updated.map { FileProviderItem.path(for: $0.itemIdentifier) })
        if !updated.isEmpty { box.observer.didUpdate(updated) }
        if !removed.isEmpty { box.observer.didDeleteItems(withIdentifiers: removed.map(FileProviderItem.identifier(for:))) }
        box.observer.finishEnumeratingChanges(upTo: Self.anchor(), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor())
    }

    private static func anchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
    }

    private static func page(_ offset: Int) -> NSFileProviderPage {
        NSFileProviderPage(Data(String(offset).utf8))
    }

    private static func offset(from page: NSFileProviderPage) -> Int {
        Int(String(decoding: page.rawValue, as: UTF8.self)) ?? 0
    }
}

/// The last listing of each folder, to work out what was deleted, and when
/// each folder was last opened in Finder. Kept in the extension's own
/// container (paths and dates only), so it survives the system stopping and
/// restarting the extension.
actor SnapshotStore {
    private struct Saved: Codable {
        var children: [String: [String]] = [:]
        var visits: [String: Date] = [:]
    }

    private var saved: Saved
    private let file: URL?
    private var lastCheck = Date.distantPast
    private var lastWalk = Date.distantPast
    private var walkSoon = false

    /// Most folders listed in one check, so a huge kept tree can't run away.
    static let folderLimit = 400
    /// Folders opened in Finder within this long are checked for changes.
    static let recentWindow: TimeInterval = 2 * 60 * 60
    static let recentLimit = 12
    /// How often the folders are checked, and kept folders walked in full.
    static let checkInterval: TimeInterval = 60
    static let walkInterval: TimeInterval = 15 * 60

    init(domainID: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let safe = domainID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        file = base?.appending(path: "Listings-\(safe).json")
        let data = file.flatMap { try? Data(contentsOf: $0) }
        if let data, let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
        } else if let data, let old = try? JSONDecoder().decode([String: [String]].self, from: data) {
            saved = Saved(children: old) // listings saved by an earlier version
        } else {
            saved = Saved()
        }
    }

    func paths(for folder: String) -> [String] { saved.children[folder] ?? [] }

    func record(_ paths: [String], for folder: String, replacing: Bool) {
        saved.children[folder] = replacing ? paths : (saved.children[folder] ?? []) + paths
        save()
    }

    func visited(_ folder: String) {
        saved.visits[folder] = .now
        saved.visits = saved.visits.filter { $0.value > .now.addingTimeInterval(-Self.recentWindow) }
        save()
    }

    /// Right after Keep Downloaded: walk kept folders at the next check.
    func walkKeptSoon() {
        walkSoon = true
        lastCheck = .distantPast
    }

    /// The folders to check for changes made outside Ownhold: those opened
    /// recently, and kept ones. Nothing if the last check was under a minute ago.
    func foldersToCheck(kept: [String]) -> (folders: [String], walkKept: Bool) {
        guard Date.now.timeIntervalSince(lastCheck) >= Self.checkInterval else { return ([], false) }
        lastCheck = .now
        let walk = walkSoon || Date.now.timeIntervalSince(lastWalk) >= Self.walkInterval
        if walk {
            lastWalk = .now
            walkSoon = false
        }
        let recent = saved.visits
            .filter { $0.value > .now.addingTimeInterval(-Self.recentWindow) }
            .sorted { $0.value > $1.value }
            .prefix(Self.recentLimit)
            .map(\.key)
        // A kept folder is checked itself; a kept file through its folder.
        let keptFolders = kept.map { saved.children[$0] != nil ? $0 : ($0 as NSString).deletingLastPathComponent }
        var seen = Set<String>()
        return ((keptFolders + recent).filter { seen.insert($0).inserted }, walk)
    }

    private func save() {
        if let file, let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

// The observers aren't Sendable, but the system allows calling them from any thread.
struct ObserverBox: @unchecked Sendable {
    let observer: NSFileProviderEnumerationObserver
    init(_ observer: NSFileProviderEnumerationObserver) { self.observer = observer }
}

struct ChangeObserverBox: @unchecked Sendable {
    let observer: NSFileProviderChangeObserver
    init(_ observer: NSFileProviderChangeObserver) { self.observer = observer }
}

/// Lists nothing (the placeholder location while Files access is off).
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}
