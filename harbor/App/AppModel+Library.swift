import Foundation
import OwnholdKit

/// Favorites, recent files, archives and share links.
extension AppModel {
    // MARK: Favorites and recents

    private static let recentLimit = 20

    func loadLibrary(for profile: ServerProfile) {
        favorites = Self.load(Self.favoritesKey(profile))
        recents = keepRecents ? Self.load(Self.recentsKey(profile)) : []
    }

    func forgetLibrary(for profile: ServerProfile) {
        UserDefaults.standard.removeObject(forKey: Self.favoritesKey(profile))
        UserDefaults.standard.removeObject(forKey: Self.recentsKey(profile))
        if activeServer?.id == profile.id {
            favorites = []
            recents = []
        }
    }

    func isFavorite(_ item: RemoteItem) -> Bool { favorites.contains { $0.path == item.path } }

    func toggleFavorite(_ folder: RemoteItem) {
        guard folder.isDirectory, let profile = activeServer else { return }
        if isFavorite(folder) {
            favorites.removeAll { $0.path == folder.path }
        } else {
            favorites.append(RemoteItem(path: folder.path, name: folder.name, isDirectory: true))
        }
        Self.store(favorites, Self.favoritesKey(profile))
    }

    func noteOpened(_ item: RemoteItem) {
        guard keepRecents, !item.isDirectory, let profile = activeServer else { return }
        recents.removeAll { $0.path == item.path }
        recents.insert(item, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
        Self.store(recents, Self.recentsKey(profile))
    }

    /// Clears the list for every server, not just the active one.
    func clearRecents() {
        recents = []
        for server in servers + [.demo] {
            UserDefaults.standard.removeObject(forKey: Self.recentsKey(server))
        }
    }

    /// Keeps favorites and recents pointing at the right place after a
    /// rename or move, and drops them when an item is deleted.
    func libraryItemsChanged(from old: String, to new: RemoteItem?) {
        guard let profile = activeServer else { return }
        func remap(_ list: [RemoteItem]) -> [RemoteItem] {
            list.compactMap { item in
                guard item.path == old || item.path.hasPrefix(old + "/") else { return item }
                guard let new else { return nil }
                let path = new.path + item.path.dropFirst(old.count)
                return item.with(path: path, name: (path as NSString).lastPathComponent)
            }
        }
        favorites = remap(favorites)
        recents = remap(recents)
        Self.store(favorites, Self.favoritesKey(profile))
        if keepRecents { Self.store(recents, Self.recentsKey(profile)) }
    }

    private static func favoritesKey(_ profile: ServerProfile) -> String { "favorites.\(profile.id.uuidString)" }
    private static func recentsKey(_ profile: ServerProfile) -> String { "recents.\(profile.id.uuidString)" }

    private static func load(_ key: String) -> [RemoteItem] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RemoteItem].self, from: data)) ?? []
    }

    private static func store(_ items: [RemoteItem], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }

    // MARK: Archives

    /// Zips items next to them: "Name.zip" for one item, "Archive.zip" for
    /// several, numbered if the name is taken.
    @discardableResult
    func compress(_ items: [RemoteItem], in folder: String, existing: Set<String>) async -> Bool {
        guard let service, !items.isEmpty else { return false }
        let base = items.count == 1 ? items[0].name : "Archive"
        let name = RemoteItem.uniqueName(for: base + ".zip", avoiding: existing)
        do {
            try await service.compress(items, to: RemoteItem.join(folder, name))
            folderChanged(folder)
            Haptics.success()
            banner = "Compressed to “\(name)”"
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// Like the Finder: an archive holding a single folder (whose name is
    /// free) extracts straight into the current folder. Anything else goes
    /// into a new folder named after the archive, so it never mixes with
    /// (or replaces) what's already there.
    @discardableResult
    func extract(_ archive: RemoteItem, existing: Set<String>) async -> Bool {
        guard let service else { return false }
        let taken = Set(existing.map { $0.lowercased() })
        if let top = try? await service.archiveTopLevel(archive), top.count == 1,
           let only = top.first, !only.contains("/"), !taken.contains(only.lowercased()) {
            do {
                try await service.extract(archive, into: archive.parentPath)
                folderChanged(archive.parentPath)
                Haptics.success()
                banner = "Extracted “\(only)”"
                return true
            } catch {
                folderChanged(archive.parentPath)
                handle(error)
                return false
            }
        }
        var base = archive.name
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        if base == archive.name { base = (base as NSString).deletingPathExtension }
        let name = RemoteItem.uniqueName(for: base.isEmpty ? "Archive" : base, avoiding: existing)
        do {
            let folder = try await service.createFolder(named: name, in: archive.parentPath)
            do {
                try await service.extract(archive, into: folder.path)
            } catch {
                try? await service.delete([folder])
                throw error
            }
            folderChanged(archive.parentPath)
            Haptics.success()
            banner = "Extracted to “\(name)”"
            return true
        } catch {
            folderChanged(archive.parentPath)
            handle(error)
            return false
        }
    }

    // MARK: Share links

    func createShareLink(for item: RemoteItem, password: String?, expires: Date?) async -> SharingLink? {
        guard let service else { return nil }
        do {
            return try await service.createShareLink(for: item, password: password, expires: expires)
        } catch {
            handle(error)
            return nil
        }
    }

    func deleteShareLink(_ link: SharingLink) async -> Bool {
        guard let service else { return false }
        do {
            try await service.deleteShareLink(link)
            return true
        } catch {
            handle(error)
            return false
        }
    }
}

/// Copies a NAS folder to a local folder, file by file, so the share sheet
/// gets a real folder. Returns nil for folders too big to copy this way
/// (the caller then asks the NAS for a zip).
@MainActor
enum FolderCopy {
    static let maxFiles = 2_000
    static let maxBytes: Int64 = 4 * 1024 * 1024 * 1024

    static func make(of folder: RemoteItem, using service: any FileService, progress: @escaping (Int, Int) -> Void) async throws -> URL? {
        // List everything first, so size limits apply before downloading.
        var files: [(RemoteItem, String)] = []
        var folders: [String] = [""]
        var bytes: Int64 = 0
        var pending: [(String, String)] = [(folder.path, "")]
        while let (path, relative) = pending.popLast() {
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await service.list(folder: path, offset: offset, limit: 500, sort: .name, ascending: true)
                for item in page.items {
                    let child = relative.isEmpty ? item.name : relative + "/" + item.name
                    if item.isDirectory {
                        folders.append(child)
                        pending.append((item.path, child))
                    } else {
                        files.append((item, child))
                        bytes += item.size ?? 0
                    }
                }
                if files.count > maxFiles || bytes > maxBytes { return nil }
                offset += page.items.count
                if page.items.isEmpty || offset >= page.total { break }
            }
        }
        let root = PreviewFiles.directory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: folder.name, directoryHint: .isDirectory)
        let fm = FileManager.default
        do {
            for relative in folders {
                try fm.createDirectory(at: relative.isEmpty ? root : root.appending(path: relative, directoryHint: .isDirectory), withIntermediateDirectories: true)
            }
            for (index, (item, relative)) in files.enumerated() {
                try Task.checkCancellation()
                progress(index, files.count)
                let temporary = try await service.download(item)
                try fm.moveItem(at: temporary, to: root.appending(path: relative))
            }
        } catch {
            try? fm.removeItem(at: root.deletingLastPathComponent())
            throw error
        }
        return root
    }
}
