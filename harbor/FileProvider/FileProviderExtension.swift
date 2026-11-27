import FileProvider
import os
import ArkenalKit
import UniformTypeIdentifiers

/// Shows a NAS in the Files app (and in Finder on a Mac), when the user turns
/// on Settings › Privacy › Show NAS in Files App.
///
/// Files are downloaded only when opened, and changes made in the Files app
/// (new folders, uploads, renames, moves, deletes) go straight to the NAS,
/// through the same File Station calls and certificate checks as the app.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing, NSFileProviderCustomAction, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let context: ProviderContext
    private let snapshots: SnapshotStore
    private let kept: KeptDownloads

    /// iOS keeps a default "Arkenal" location whenever Arkenal has none of
    /// its own (Settings › Privacy › Show NAS in Files App is off), and apps
    /// can't remove it. It stays empty: no NAS names, no files, no network.
    /// The same applies whenever the app lock is on: the Files app and Finder
    /// can't ask for Face ID or Touch ID, so they get nothing.
    private var isPlaceholder: Bool {
        domain.identifier.rawValue == "NSFileProviderDomainDefaultIdentifier" || !SharedContainer.isFilesAccessAllowed
    }

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.context = ProviderContext(domainID: domain.identifier.rawValue)
        self.snapshots = SnapshotStore(domainID: domain.identifier.rawValue)
        self.kept = KeptDownloads(domain: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {}

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let reply = Reply(completionHandler)
        if identifier == .rootContainer {
            reply.handler(RootItem(name: domain.displayName, readOnly: isPlaceholder), nil)
            return Progress()
        }
        if identifier == .trashContainer {
            reply.handler(TrashItem(), nil)
            return Progress()
        }
        if isPlaceholder {
            reply.handler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        return task { [self] in
            do {
                reply.handler(FileProviderItem(try await lookup(identifier), kept: kept), nil)
            } catch {
                reply.handler(nil, error)
            }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let reply = Reply3(completionHandler)
        return task { [self] in
            do {
                let remote = try await lookup(itemIdentifier)
                let url = try await context.run { try await $0.download(remote) }
                reply.handler(url, FileProviderItem(remote, kept: kept), nil)
            } catch {
                reply.handler(nil, nil, error)
            }
        }
    }

    // MARK: Changes from the Files app

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let reply = ChangeReply(completionHandler)
        // Anything put in Finder's Trash for this location (items that were
        // never uploaded) stays on this Mac: the NAS has no such folder.
        if itemTemplate.parentItemIdentifier == .trashContainer {
            reply.handler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return Progress()
        }
        let parent = FileProviderItem.path(for: itemTemplate.parentItemIdentifier)
        let name = itemTemplate.filename
        let isFolder = itemTemplate.contentType?.conforms(to: .folder) == true
        let source = url.map(SendableURL.init)
        return task { [self] in
            do {
                if isFolder {
                    let folder = try await context.run { try await $0.createFolder(named: name, in: parent) }
                    reply.handler(FileProviderItem(folder, kept: kept), [], false, nil)
                } else {
                    guard let source else { throw NSFileProviderError(.cannotSynchronize) }
                    try await context.run { try await $0.upload(source.url, as: name, to: parent, replacing: false) { _ in } }
                    reply.handler(FileProviderItem(try await lookup(path: RemoteItem.join(parent, name)), kept: kept), [], false, nil)
                }
            } catch {
                reply.handler(nil, [], false, error)
            }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let reply = ChangeReply(completionHandler)
        let identifier = item.itemIdentifier
        let newName = item.filename
        let newParent = FileProviderItem.path(for: item.parentItemIdentifier)
        let source = newContents.map(SendableURL.init)
        return task { [self] in
            do {
                var remote = try await lookup(identifier)
                let originalPath = remote.path
                if changedFields.contains(.parentItemIdentifier), remote.parentPath != newParent {
                    let moving = remote
                    try await context.run { try await $0.move([moving], to: newParent) }
                    remote = remote.with(path: RemoteItem.join(newParent, remote.name), name: remote.name)
                }
                if changedFields.contains(.filename), remote.name != newName {
                    let renaming = remote
                    remote = try await context.run { try await $0.rename(renaming, to: newName) }
                }
                if changedFields.contains(.contents), let source {
                    let target = remote
                    try await context.run { try await $0.upload(source.url, as: target.name, to: target.parentPath, replacing: true) { _ in } }
                    remote = try await lookup(path: target.path)
                }
                if remote.path != originalPath { kept.move(from: originalPath, to: remote.path) }
                reply.handler(FileProviderItem(remote, kept: kept), [], false, nil)
            } catch {
                reply.handler(nil, [], false, error)
            }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let reply = Reply1(completionHandler)
        return task { [self] in
            do {
                let remote = try await lookup(identifier)
                try await context.run { try await $0.delete([remote]) }
                kept.stop([remote.path])
                reply.handler(nil)
            } catch {
                reply.handler(error)
            }
        }
    }

    // MARK: Listing

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // Items deleted from the NAS are deleted there (or go to DSM's
        // Recycle Bin), so Finder's Trash for this location is always empty.
        // It must still answer: refusing made Finder report that the Trash
        // "needs to be downloaded", and nothing could be moved to it.
        if containerItemIdentifier == .trashContainer || isPlaceholder { return EmptyEnumerator() }
        return FileProviderEnumerator(container: containerItemIdentifier, context: context, snapshots: snapshots)
    }

    // MARK: Keep Downloaded (Finder's right-click menu, see Info.plist)

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier, onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier], completionHandler: @escaping (Error?) -> Void) -> Progress {
        let reply = Reply1(completionHandler)
        let paths = itemIdentifiers.map(FileProviderItem.path(for:))
        let keep = actionIdentifier.rawValue == Self.keepAction
        // Keep Downloaded is part of Arkenal Pro (Stop Keeping always works).
        if keep, !SharedContainer.isProUnlocked {
            reply.handler(NSError(domain: "com.snowlightlabs.Arkenal", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Keep Downloaded is part of Arkenal Pro.",
                NSLocalizedRecoverySuggestionErrorKey: "Open Arkenal to unlock it.",
            ]))
            return Progress()
        }
        let domainID = domain.identifier.rawValue
        return task { [self] in
            if keep {
                kept.keep(paths)
                await snapshots.walkKeptSoon()
            } else {
                kept.stop(paths)
            }
            // Report the items again (from their folders) with the new policy.
            let parents = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
            SharedChanges.record(domain: domainID, folders: Array(parents))
            let manager = NSFileProviderManager(for: domain)
            try? await manager?.signalEnumerator(for: .workingSet)
            // The keep policy alone leaves downloads to a background scheduler
            // that can wait a long time; ask for each file now instead. Done
            // before replying: the system may stop the extension once it has.
            if keep, let manager {
                let files = await filesInside(paths)
                Self.log.info("Keep Downloaded: requesting \(files.count) files")
                for path in files {
                    do {
                        try await manager.requestDownloadForItem(withIdentifier: FileProviderItem.identifier(for: path), requestedRange: NSRange(location: NSNotFound, length: 0))
                    } catch {
                        Self.log.error("Keep Downloaded: request failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            reply.handler(nil)
            // Arkenal, if it's running, downloads them straight away.
            if keep {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.snowlightlabs.arkenal.keptDownloadsChanged" as CFString), nil, nil, true)
            }
        }
    }

    private static let log = Logger(subsystem: "com.snowlightlabs.Arkenal", category: "files-extension")

    /// Every file in (or among) the kept items, listing folders on the way
    /// so Finder learns about them too. Capped, so a huge folder can't run away.
    private func filesInside(_ paths: [String]) async -> [String] {
        var files: [String] = []
        var queue = paths
        var listed = 0
        while !queue.isEmpty, listed < SnapshotStore.folderLimit, files.count < 2000 {
            let path = queue.removeFirst()
            guard let items = try? await context.run({ try await $0.list(folder: path, offset: 0, limit: 5000, sort: .name, ascending: true).items }) else {
                files.append(path) // not a folder: a kept file
                continue
            }
            listed += 1
            await snapshots.record(items.map(\.path), for: path, replacing: true)
            files += items.filter { !$0.isDirectory }.map(\.path)
            queue += items.filter(\.isDirectory).map(\.path)
        }
        return Array(files.prefix(2000))
    }

    static let keepAction = "com.snowlightlabs.arkenal.keepDownloaded"

    // MARK: Thumbnails

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let each = ThumbReply(perThumbnailCompletionHandler)
        let done = Reply1(completionHandler)
        let large = max(size.width, size.height) > 300
        return task { [self] in
            for identifier in itemIdentifiers {
                do {
                    let remote = try await lookup(identifier)
                    guard remote.hasThumbnail else {
                        each.handler(identifier, nil, nil)
                        continue
                    }
                    let data = try await context.run { try await $0.thumbnail(for: remote, size: large ? .large : .medium) }
                    each.handler(identifier, data, nil)
                } catch {
                    each.handler(identifier, nil, error)
                }
            }
            done.handler(nil)
        }
    }

    // MARK: Helpers

    /// Finds an item's details by listing its folder (File Station has no
    /// "get info" call for a single path that works across DSM versions).
    private func lookup(_ identifier: NSFileProviderItemIdentifier) async throws -> RemoteItem {
        try await lookup(path: FileProviderItem.path(for: identifier))
    }

    private func lookup(path: String) async throws -> RemoteItem {
        let parent = (path as NSString).deletingLastPathComponent
        let items = try await context.run { service in
            parent == "/" ? try await service.listShares()
                : try await service.list(folder: parent, offset: 0, limit: 5000, sort: .name, ascending: true).items
        }
        guard let item = items.first(where: { $0.path == path }) else { throw NSFileProviderError(.noSuchItem) }
        return item
    }

    /// Runs async work, cancelled if the system cancels the request.
    private func task(_ work: @escaping @Sendable () async -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let running = Task {
            await work()
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { running.cancel() }
        return progress
    }
}

// The system's completion handlers aren't marked Sendable, but may be called from any thread.
private struct Reply: @unchecked Sendable { let handler: (NSFileProviderItem?, Error?) -> Void; init(_ h: @escaping (NSFileProviderItem?, Error?) -> Void) { handler = h } }
private struct Reply1: @unchecked Sendable { let handler: (Error?) -> Void; init(_ h: @escaping (Error?) -> Void) { handler = h } }
private struct Reply3: @unchecked Sendable { let handler: (URL?, NSFileProviderItem?, Error?) -> Void; init(_ h: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) { handler = h } }
private struct ChangeReply: @unchecked Sendable { let handler: (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void; init(_ h: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) { handler = h } }
private struct ThumbReply: @unchecked Sendable { let handler: (NSFileProviderItemIdentifier, Data?, Error?) -> Void; init(_ h: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void) { handler = h } }
private struct SendableURL: @unchecked Sendable { let url: URL; init(_ url: URL) { self.url = url } }
