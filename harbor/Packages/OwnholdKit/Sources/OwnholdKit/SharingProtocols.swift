import Foundation

/// Pieces shared by the SMB and WebDAV clients. Both protocols list a whole
/// folder at once, with no paging, sorting or search on the server, so
/// Ownhold does those itself.
enum SharingProtocols {
    /// Names hidden from listings: dot files, and the housekeeping folders
    /// NAS systems keep in every share (Synology's @eaDir and #recycle,
    /// QNAP's @Recycle and .@__thumb, Windows' desktop.ini).
    static func isHidden(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("@") || name.hasPrefix("#") { return true }
        let lower = name.lowercased()
        return lower == "desktop.ini" || lower == "thumbs.db" || lower == "$recycle.bin"
    }

    /// Sorts like File Station: folders first, then by the chosen field.
    static func page(_ items: [RemoteItem], offset: Int, limit: Int, sort: SortField, ascending: Bool) -> FolderPage {
        let sorted = items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let byName = a.name.localizedStandardCompare(b.name)
            let ordered: Bool
            switch sort {
            case .name: ordered = byName == .orderedAscending
            case .size:
                let (x, y) = (a.size ?? 0, b.size ?? 0)
                ordered = x == y ? byName == .orderedAscending : x < y
            case .modified:
                let (x, y) = (a.modified ?? .distantPast, b.modified ?? .distantPast)
                ordered = x == y ? byName == .orderedAscending : x < y
            }
            return ascending ? ordered : !ordered
        }
        let start = min(max(offset, 0), sorted.count)
        return FolderPage(items: Array(sorted[start...].prefix(max(limit, 0))), total: sorted.count, offset: start)
    }

    /// Search by name, by listing folders below `folder`. Stops after a few
    /// hundred folders or results, so a huge share can't keep the NAS busy.
    static func search(
        in folder: String,
        matching pattern: String,
        list: (String) async throws -> [RemoteItem]
    ) async throws -> [RemoteItem] {
        let needle = pattern.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
        guard !needle.isEmpty else { return [] }
        var found: [RemoteItem] = []
        var pending = [folder]
        var visited = 0
        while !pending.isEmpty, visited < 400, found.count < 300 {
            try Task.checkCancellation()
            let path = pending.removeFirst()
            visited += 1
            guard let items = try? await list(path) else { continue }
            for item in items {
                if item.name.localizedCaseInsensitiveContains(needle) { found.append(item) }
                if item.isDirectory { pending.append(item.path) }
            }
        }
        return found
    }

    /// Splits "/share/a/b" into ("share", "a/b").
    static func split(_ path: String) -> (share: String, rest: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        return (String(first), parts.dropFirst().joined(separator: "/"))
    }

    /// Parent folders of `folder` from the top, for creating missing ones:
    /// "/a/b/c" → ["/a", "/a/b", "/a/b/c"].
    static func ancestors(of folder: String) -> [String] {
        var paths: [String] = []
        var current = ""
        for part in folder.split(separator: "/") {
            current += "/" + part
            paths.append(current)
        }
        return paths
    }

    /// A temporary file location for a download.
    static func temporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Downloads-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }
}

/// Keeps a folder's listing for a few seconds, so loading a long folder in
/// pages lists it on the NAS once. Any change made in a folder drops it.
actor ListingCache {
    private var entries: [String: (items: [RemoteItem], at: Date)] = [:]
    private let lifetime: TimeInterval = 10

    func items(for folder: String) -> [RemoteItem]? {
        guard let entry = entries[folder.lowercased()], Date().timeIntervalSince(entry.at) < lifetime else { return nil }
        return entry.items
    }

    func store(_ items: [RemoteItem], for folder: String) {
        if entries.count > 50 { entries.removeAll() }
        entries[folder.lowercased()] = (items, Date())
    }

    func invalidate(_ folders: [String]) {
        for folder in folders { entries[folder.lowercased()] = nil }
    }
}

/// Runs one piece of work at a time, in order. SMB sends requests over a
/// single connection that isn't safe to use from two tasks at once.
final class SerialGate: Sendable {
    private let lock = Lock()

    func run<T>(_ body: () async throws -> T) async throws -> T {
        await lock.acquire()
        do {
            let result = try await body()
            await lock.release()
            return result
        } catch {
            await lock.release()
            throw error
        }
    }

    private actor Lock {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
    }
}
