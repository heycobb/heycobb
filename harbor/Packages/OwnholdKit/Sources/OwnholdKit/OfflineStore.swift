import CryptoKit
import Foundation

public struct OfflineEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { item.path }
    public let item: RemoteItem
    public let fileName: String
    public let savedAt: Date
    public let byteCount: Int64
}

/// Files the user chose to keep on this device.
///
/// - Stored in Application Support, not Caches, so iOS won't purge them.
/// - Excluded from iCloud/Finder backups (they're copies of NAS data).
/// - On iPhone/iPad, protected with `.complete` file protection: unreadable
///   while the device is locked.
/// - There is no background sync. `refresh` runs when the app is open.
public actor OfflineStore {
    private let directory: URL
    private let indexURL: URL
    private var entries: [String: OfflineEntry]

    public init(namespace: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appending(path: "Offline/\(namespace)", directoryHint: .isDirectory)
        indexURL = directory.appending(path: "index.json")
        Self.prepare(directory)
        entries = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONDecoder().decode([String: OfflineEntry].self, from: $0) } ?? [:]
    }

    // MARK: Queries

    public func all() -> [OfflineEntry] {
        entries.values.sorted { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
    }

    public func isSaved(_ path: String) -> Bool { entries[path] != nil }

    public func savedPaths() -> Set<String> { Set(entries.keys) }

    public func localURL(for path: String) -> URL? {
        guard let entry = entries[path] else { return nil }
        let url = directory.appending(path: entry.fileName)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    public func totalBytes() -> Int64 {
        entries.values.reduce(0) { $0 + $1.byteCount }
    }

    // MARK: Changes

    /// Downloads a file (or every file under a folder) for offline use.
    /// Returns how many files were saved.
    @discardableResult
    public func save(_ item: RemoteItem, using service: any FileService) async throws -> Int {
        if item.isDirectory {
            var count = 0
            for file in try await Self.files(under: item, using: service) {
                try Task.checkCancellation()
                try await saveFile(file, using: service)
                count += 1
            }
            return count
        }
        try await saveFile(item, using: service)
        return 1
    }

    public func remove(_ path: String) {
        // Removing a folder removes everything saved beneath it.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for key in entries.keys where key == path || key.hasPrefix(prefix) {
            if let entry = entries.removeValue(forKey: key) {
                removeFile(entry.fileName)
            }
        }
        persist()
    }

    /// Follows a rename or move on the NAS, so saved files stay saved under
    /// their new path (and show their new name) without downloading again.
    public func relocate(from old: String, to new: String) {
        let prefix = old + "/"
        let fm = FileManager.default
        for key in Array(entries.keys) where key == old || key.hasPrefix(prefix) {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            let path = new + key.dropFirst(old.count)
            let item = entry.item.with(path: path, name: (path as NSString).lastPathComponent)
            let safeName = item.name.replacingOccurrences(of: "/", with: "-")
            let fileName = Self.hashedName(path) + "/" + safeName
            let from = directory.appending(path: entry.fileName)
            let to = directory.appending(path: fileName)
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                removeFile(entry.fileName) // the old, now empty, per-file folder
                entries[path] = OfflineEntry(item: item, fileName: fileName, savedAt: entry.savedAt, byteCount: entry.byteCount)
            } catch {
                // Keep the copy where it is; it's still readable under the new path.
                entries[path] = OfflineEntry(item: item, fileName: entry.fileName, savedAt: entry.savedAt, byteCount: entry.byteCount)
            }
        }
        persist()
    }

    public func removeAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: directory)
        Self.prepare(directory)
        persist()
    }

    /// Re-downloads saved files that changed on the NAS and drops ones that
    /// were deleted there. Returns the number of files updated.
    @discardableResult
    public func refresh(using service: any FileService) async -> Int {
        let byFolder = Dictionary(grouping: entries.values) { ($0.item.path as NSString).deletingLastPathComponent }
        var updated = 0
        for (folder, saved) in byFolder {
            guard let page = try? await service.list(folder: folder, offset: 0, limit: 5000, sort: .name, ascending: true) else { continue }
            let current = Dictionary(page.items.map { ($0.path, $0) }) { first, _ in first }
            for entry in saved {
                guard let remote = current[entry.item.path] else {
                    remove(entry.item.path)
                    continue
                }
                if remote.modified != entry.item.modified || remote.size != entry.item.size {
                    if (try? await saveFile(remote, using: service)) != nil { updated += 1 }
                }
            }
        }
        return updated
    }

    // MARK: Private

    private func saveFile(_ item: RemoteItem, using service: any FileService) async throws {
        let temporary = try await service.download(item)
        // Stored as <hash of NAS path>/<real name>: the hash keeps same-named
        // files from different folders apart, and the real name is what
        // Quick Look and the share sheet show.
        let safeName = item.name.replacingOccurrences(of: "/", with: "-")
        let fileName = Self.hashedName(item.path) + "/" + safeName
        let destination = directory.appending(path: fileName)
        let fm = FileManager.default
        if let previous = entries[item.path] {
            removeFile(previous.fileName)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: temporary, to: destination)
        Self.protect(destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? item.size ?? 0
        entries[item.path] = OfflineEntry(item: item, fileName: fileName, savedAt: .now, byteCount: size)
        persist()
    }

    /// Deletes a stored file, and its per-file folder if it has one.
    private func removeFile(_ fileName: String) {
        let url = directory.appending(path: fileName)
        try? FileManager.default.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL != directory.standardizedFileURL {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: Self.writeOptions)
    }

    static func files(under folder: RemoteItem, using service: any FileService, limit: Int = 5000) async throws -> [RemoteItem] {
        var result: [RemoteItem] = []
        var queue = [folder.path]
        while let path = queue.popLast(), result.count < limit {
            var offset = 0
            while true {
                let page = try await service.list(folder: path, offset: offset, limit: 1000, sort: .name, ascending: true)
                for item in page.items {
                    if item.isDirectory { queue.append(item.path) } else { result.append(item) }
                }
                guard page.hasMore, !page.items.isEmpty else { break }
                offset += page.items.count
            }
        }
        return Array(result.prefix(limit))
    }

    static func hashedName(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS) || os(visionOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }

    private static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        protect(directory)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private static func protect(_ url: URL) {
        #if os(iOS) || os(visionOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path(percentEncoded: false))
        #endif
    }
}
