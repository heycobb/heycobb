import Foundation

/// Decides what Folder Backup (Mac) copies: files that are new or changed
/// since the last backup, by size and modification date. Files are only
/// ever added or replaced on the NAS, never deleted.
public enum FolderBackupPlanner {
    public struct LocalFile: Equatable, Sendable {
        /// Path inside the backed-up folder, "/"-separated, e.g. "Taxes/2025.pdf".
        public let relativePath: String
        public let size: Int64
        public let modified: Date

        public init(relativePath: String, size: Int64, modified: Date) {
            self.relativePath = relativePath
            self.size = size
            self.modified = modified
        }

        /// What the record keeps per file: a change to either means copy it again.
        public var signature: String { "\(size)-\(Int(modified.timeIntervalSince1970))" }
    }

    /// Files to copy: new, or different from what was copied last time.
    public static func changed(_ files: [LocalFile], history: [String: String]) -> [LocalFile] {
        files.filter { history[$0.relativePath] != $0.signature }
    }

    /// System clutter and temporary files that aren't worth copying.
    public static func shouldSkip(name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("~$") || name == "Icon\r" || name == "Thumbs.db"
            || name.hasSuffix(".tmp") || name.hasSuffix(".crdownload") || name.hasSuffix(".download")
    }

    /// Where a file goes: `destination/<folder name>/<relative path>`.
    public static func remoteLocation(of file: LocalFile, folderName: String, destination: String) -> (folder: String, name: String) {
        var parts = file.relativePath.split(separator: "/").map(String.init)
        let name = parts.removeLast()
        var folder = RemoteItem.join(destination, folderName)
        for part in parts { folder = RemoteItem.join(folder, part) }
        return (folder, name)
    }

    /// One NAS folder per backed-up folder; two Mac folders with the same
    /// name get "Documents" and "Documents 2".
    public static func folderNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { name in
            let unique = RemoteItem.uniqueName(for: name, avoiding: used)
            used.insert(unique.lowercased())
            return unique
        }
    }
}
