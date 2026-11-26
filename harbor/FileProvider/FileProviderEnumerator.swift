import FileProvider
import OwnholdKit

/// Lists a NAS folder for the Files app.
///
/// Ownhold doesn't sync in the background, so there's no change feed: when
/// asked for changes, the folder is listed again and compared with the last
/// listing, which is kept in memory for as long as the extension runs.
/// The working set reports changes made in the Ownhold app itself, which it
/// records in `SharedChanges` before asking the system to check.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let container: NSFileProviderItemIdentifier
    private let context: ProviderContext
    private let snapshots: SnapshotStore
    private static let pageSize = 500

    init(container: NSFileProviderItemIdentifier, context: ProviderContext, snapshots: SnapshotStore) {
        self.container = container
        self.context = context
        self.snapshots = snapshots
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
                box.observer.didEnumerate(page.items.map(FileProviderItem.init))
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
                box.observer.didUpdate(items.map(FileProviderItem.init))
                box.observer.didDeleteItems(withIdentifiers: gone.map(FileProviderItem.identifier(for:)))
                box.observer.finishEnumeratingChanges(upTo: Self.anchor(), moreComing: false)
            } catch {
                box.observer.finishEnumeratingWithError(error)
            }
        }
    }

    /// Lists each folder the app changed and reports its contents, plus
    /// whatever the app removed or moved away. A folder that can't be
    /// listed right now is recorded again for the next check.
    private func reportAppChanges(to box: ChangeObserverBox) async {
        let domain = context.domainID
        let pending = SharedChanges.take(domain: domain)
        var updated: [FileProviderItem] = []
        var removed = Set(pending.removed)
        var unknown: [String] = []
        for folder in pending.folders {
            do {
                let items = try await context.run { service in
                    try await service.list(folder: folder, offset: 0, limit: 5000, sort: .name, ascending: true).items
                }
                let previous = await snapshots.paths(for: folder)
                if previous.isEmpty { unknown.append(folder) }
                await snapshots.record(items.map(\.path), for: folder, replacing: true)
                removed.formUnion(Set(previous).subtracting(items.map(\.path)))
                updated += items.map(FileProviderItem.init)
            } catch let error as NSFileProviderError where error.code == .noSuchItem {
                removed.insert(folder)
            } catch {
                SharedChanges.record(domain: domain, folders: [folder])
            }
        }
        removed.subtract(updated.map { FileProviderItem.path(for: $0.itemIdentifier) })
        if !updated.isEmpty { box.observer.didUpdate(updated) }
        if !removed.isEmpty { box.observer.didDeleteItems(withIdentifiers: removed.map(FileProviderItem.identifier(for:))) }
        box.observer.finishEnumeratingChanges(upTo: Self.anchor(), moreComing: false)
        // With no earlier listing to compare against (the extension was
        // restarted), deletions made before can't be worked out here: have
        // the system import those folders again, which drops anything that
        // is no longer on the NAS.
        if !unknown.isEmpty {
            let manager = NSFileProviderManager(for: NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domain), displayName: ""))
            for folder in unknown {
                manager?.reimportItems(below: FileProviderItem.identifier(for: folder)) { _ in }
            }
        }
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

/// The last listing of each folder, to work out what was deleted.
actor SnapshotStore {
    private var children: [String: [String]] = [:]

    func paths(for folder: String) -> [String] { children[folder] ?? [] }

    func record(_ paths: [String], for folder: String, replacing: Bool) {
        children[folder] = replacing ? paths : (children[folder] ?? []) + paths
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
