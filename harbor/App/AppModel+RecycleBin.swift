import Foundation
import OwnholdKit

/// Recently Deleted: DSM's Recycle Bin (see `RecycleBin`).
extension AppModel {
    /// Shared folders whose Recycle Bin this account can open. A share
    /// without one (turned off, never used, or admin-only) isn't listed.
    func recycleBins(in shares: [RemoteItem]) async -> [RemoteItem] {
        guard let service else { return [] }
        var bins: [RemoteItem] = []
        for share in shares {
            let folder = RecycleBin.folder(forShare: share.path)
            if (try? await service.list(folder: folder, offset: 0, limit: 1, sort: .name, ascending: true)) != nil {
                bins.append(share)
            }
        }
        return bins
    }

    /// Moves an item back where it was deleted from, recreating folders on
    /// the way if they're gone too. Fails, with a message, on a name clash.
    func restore(_ item: RemoteItem) async -> Bool {
        guard let service, let original = RecycleBin.originalPath(of: item.path) else { return false }
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
