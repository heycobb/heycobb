import Foundation
import OwnholdKit

/// Recently Deleted: DSM's Recycle Bin (see `RecycleBin`).
import os

extension AppModel {
    fileprivate static let recycleLog = Logger(subsystem: "app.ownhold.Ownhold", category: "recycle-bin")

    /// A Recycle Bin to show: a shared folder's, or for "home" the
    /// account's part of the homes shared folder's (DSM keeps deleted home
    /// files in /homes/#recycle/<account>).
    struct RecycleBinFolder: Identifiable, Hashable {
        let title: String
        let path: String
        var id: String { path }
    }

    /// Recycle Bins this account can open. A shared folder without one
    /// (turned off, never used, or admin-only) isn't listed.
    func recycleBins(in shares: [RemoteItem]) async -> [RecycleBinFolder] {
        guard let service, let account = activeServer?.account else { return [] }
        var bins: [RecycleBinFolder] = []
        for share in shares {
            let candidates = share.path == "/home"
                ? [RemoteItem.join(RecycleBin.folder(forShare: "/homes"), account), RecycleBin.folder(forShare: share.path)]
                : [RecycleBin.folder(forShare: share.path)]
            for folder in candidates {
                do {
                    _ = try await service.list(folder: folder, offset: 0, limit: 1, sort: .name, ascending: true)
                    bins.append(RecycleBinFolder(title: share.name, path: folder))
                    break
                } catch {
                    Self.recycleLog.notice("No Recycle Bin at a candidate path: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return bins
    }

    /// Moves an item back where it was deleted from, recreating folders on
    /// the way if they're gone too. Fails, with a message, on a name clash.
    func restore(_ item: RemoteItem) async -> Bool {
        guard let service, var original = RecycleBin.originalPath(of: item.path) else { return false }
        // From the account's part of the homes bin: back into "home".
        if let account = activeServer?.account, original.hasPrefix("/homes/\(account)/") {
            original = "/home/" + original.dropFirst("/homes/\(account)/".count)
        }
        let parent = (original as NSString).deletingLastPathComponent
        do {
            try await ensureFolderExists(parent, service: service)
            let existing = try await service.list(folder: parent, offset: 0, limit: 5000, sort: .name, ascending: true).items
            if existing.contains(where: { $0.name.lowercased() == item.name.lowercased() }) {
                banner = "\((parent as NSString).lastPathComponent) already has an item named \(item.name)."
                return false
            }
            try await service.move([item], to: parent)
            folderChanged(parent, item.parentPath)
            banner = "Restored \(item.name)."
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// Creates each missing folder from the shared folder down to `path`.
    private func ensureFolderExists(_ path: String, service: any FileService) async throws {
        let parts = path.split(separator: "/").map(String.init)
        guard let share = parts.first else { return }
        var current = "/" + share
        for part in parts.dropFirst() {
            let next = RemoteItem.join(current, part)
            do {
                _ = try await service.list(folder: next, offset: 0, limit: 1, sort: .name, ascending: true)
            } catch NASError.notFound {
                _ = try await service.createFolder(named: part, in: current)
            }
            current = next
        }
    }
}
