import Foundation

/// DSM's Recycle Bin: a `#recycle` folder at the top of each shared folder
/// that has it turned on, keeping deleted items' folder structure.
/// "/home/TEST FOLDER/a.txt" is kept as "/home/#recycle/TEST FOLDER/a.txt".
public enum RecycleBin {
    public static let folderName = "#recycle"

    /// "/home" → "/home/#recycle".
    public static func folder(forShare share: String) -> String {
        RemoteItem.join(share, folderName)
    }

    /// Where an item in a Recycle Bin came from, or nil if it isn't in one.
    public static func originalPath(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[1] == folderName else { return nil }
        return "/" + ([parts[0]] + parts.dropFirst(2)).joined(separator: "/")
    }

    /// True for "/home/#recycle" and anything inside it.
    public static func contains(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count >= 2 && parts[1] == folderName
    }
}
