import Foundation
import Observation
import ArkenalKit

/// The Photos view's index: every photo and video in the folders you chose,
/// found by walking them on the NAS. Kept on this device (Caches) so the
/// view opens instantly, and refreshed while it's open, never in the
/// background. Each NAS has its own folders and index.
@MainActor
@Observable
final class PhotoLibrary {
    private(set) var folders: [String] = []
    private(set) var items: [RemoteItem] = []
    private(set) var isRefreshing = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var serverID: UUID?
    @ObservationIgnored private var refresher: Task<Void, Never>?

    /// Enough for a big library, without letting a huge share run away.
    private static let folderLimit = 5000
    private static let itemLimit = 100_000

    init(model: AppModel) { self.model = model }

    func load(for profile: ServerProfile?) {
        refresher?.cancel()
        refresher = nil
        isRefreshing = false
        serverID = profile?.id
        guard let id = profile?.id else {
            folders = []
            items = []
            return
        }
        folders = UserDefaults.standard.stringArray(forKey: Self.foldersKey(id)) ?? []
        items = (try? Data(contentsOf: Self.cacheURL(id))).flatMap { try? JSONDecoder().decode([RemoteItem].self, from: $0) } ?? []
    }

    func forget(_ profile: ServerProfile) {
        UserDefaults.standard.removeObject(forKey: Self.foldersKey(profile.id))
        try? FileManager.default.removeItem(at: Self.cacheURL(profile.id))
    }

    func addFolder(_ path: String) {
        guard let serverID, !folders.contains(path) else { return }
        folders.append(path)
        UserDefaults.standard.set(folders, forKey: Self.foldersKey(serverID))
        refresh()
    }

    func removeFolder(_ path: String) {
        guard let serverID else { return }
        folders.removeAll { $0 == path }
        UserDefaults.standard.set(folders, forKey: Self.foldersKey(serverID))
        items.removeAll { $0.path.hasPrefix(path + "/") }
        save()
    }

    /// Walks the folders again and replaces the index when done.
    func refresh() {
        guard refresher == nil, !folders.isEmpty, let service = model?.service else { return }
        isRefreshing = true
        let roots = folders
        refresher = Task {
            var found: [RemoteItem] = []
            var queue = roots
            var walked = 0
            while !queue.isEmpty, walked < Self.folderLimit, found.count < Self.itemLimit, !Task.isCancelled {
                let folder = queue.removeFirst()
                walked += 1
                var offset = 0
                while !Task.isCancelled {
                    guard let page = try? await service.list(folder: folder, offset: offset, limit: 1000, sort: .name, ascending: true) else { break }
                    for item in page.items {
                        if item.isDirectory {
                            if !PhotoTimeline.shouldSkipFolder(item) { queue.append(item.path) }
                        } else if PhotoTimeline.isPhotoOrVideo(item) {
                            found.append(item)
                        }
                    }
                    offset += page.items.count
                    if page.items.isEmpty || offset >= page.total { break }
                }
            }
            if !Task.isCancelled {
                items = found
                save()
            }
            isRefreshing = false
            refresher = nil
        }
    }

    private func save() {
        guard let serverID else { return }
        try? JSONEncoder().encode(items).write(to: Self.cacheURL(serverID), options: .atomic)
    }

    private static func foldersKey(_ id: UUID) -> String { "photoLibrary.\(id.uuidString)" }

    private static func cacheURL(_ id: UUID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "PhotoLibrary-\(id.uuidString).json")
    }
}
