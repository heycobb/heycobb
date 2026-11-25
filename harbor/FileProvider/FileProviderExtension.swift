import FileProvider
import OwnholdKit
import UniformTypeIdentifiers

/// Shows a NAS in the Files app (and in Finder on a Mac), when the user turns
/// on Settings › Privacy › Show NAS in Files App.
///
/// Files are downloaded only when opened, and changes made in the Files app
/// (new folders, uploads, renames, moves, deletes) go straight to the NAS,
/// through the same File Station calls and certificate checks as the app.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let context: ProviderContext
    private let snapshots = SnapshotStore()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.context = ProviderContext(domainID: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {}

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let reply = Reply(completionHandler)
        if identifier == .rootContainer {
            reply.handler(RootItem(name: domain.displayName), nil)
            return Progress()
        }
        return task { [self] in
            do {
                reply.handler(FileProviderItem(try await lookup(identifier)), nil)
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
                reply.handler(url, FileProviderItem(remote), nil)
            } catch {
                reply.handler(nil, nil, error)
            }
        }
    }

    // MARK: Changes from the Files app

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let reply = ChangeReply(completionHandler)
        let parent = FileProviderItem.path(for: itemTemplate.parentItemIdentifier)
        let name = itemTemplate.filename
        let isFolder = itemTemplate.contentType?.conforms(to: .folder) == true
        let source = url.map(SendableURL.init)
        return task { [self] in
            do {
                if isFolder {
                    let folder = try await context.run { try await $0.createFolder(named: name, in: parent) }
                    reply.handler(FileProviderItem(folder), [], false, nil)
                } else {
                    guard let source else { throw NSFileProviderError(.cannotSynchronize) }
                    try await context.run { try await $0.upload(source.url, as: name, to: parent, replacing: false) { _ in } }
                    reply.handler(FileProviderItem(try await lookup(path: RemoteItem.join(parent, name))), [], false, nil)
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
                reply.handler(FileProviderItem(remote), [], false, nil)
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
                reply.handler(nil)
            } catch {
                reply.handler(error)
            }
        }
    }

    // MARK: Listing

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier != .trashContainer else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderEnumerator(container: containerItemIdentifier, context: context, snapshots: snapshots)
    }

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
