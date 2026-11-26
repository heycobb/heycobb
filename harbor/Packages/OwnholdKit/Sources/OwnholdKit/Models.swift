import Foundation

/// A file or folder on the NAS.
public struct RemoteItem: Identifiable, Hashable, Sendable, Codable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?

    public init(path: String, name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    public var kind: FileKind { isDirectory ? .folder : FileKind(extension: fileExtension) }

    /// Whether the NAS can generate a thumbnail for this item.
    public var hasThumbnail: Bool { kind == .image || kind == .video }

    /// Formats Apple's player plays natively, so they can stream from the
    /// NAS instead of downloading first. (MKV, AVI, WMV and WebM can't.)
    public var isStreamable: Bool {
        !isDirectory && ["mov", "mp4", "m4v", "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"].contains(fileExtension)
    }

    /// Archives the NAS can extract.
    public var isArchive: Bool {
        guard !isDirectory else { return false }
        let lower = name.lowercased()
        return ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz"].contains(fileExtension) || lower.hasSuffix(".tar.gz")
    }

    /// The folder this item is in.
    public var parentPath: String { (path as NSString).deletingLastPathComponent }

    /// Shared folders (top level) can't be renamed, moved or deleted from
    /// File Station; that's done in DSM's Control Panel.
    public var isShare: Bool { path.split(separator: "/").count == 1 }

    public func with(path: String, name: String) -> RemoteItem {
        RemoteItem(path: path, name: name, isDirectory: isDirectory, size: size, modified: modified)
    }

    // MARK: Names

    public static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// File and folder names: not empty, no "/", not "." or "..", no control
    /// characters, and at most 255 bytes (the limit on DSM's file systems).
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", name.utf8.count <= 255 else { return false }
        return !name.contains("/") && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// "Photo.jpg" → "Photo 2.jpg" (then 3, 4…) until it doesn't clash.
    /// Comparison ignores case, as SMB clients and macOS do.
    public static func uniqueName(for name: String, avoiding existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for n in 2... {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return name
    }
}

public enum FileKind: String, Sendable, Codable {
    case folder, image, video, audio, pdf, document, spreadsheet, presentation, archive, code, text, other

    public init(extension ext: String) {
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "raw", "dng", "cr2", "cr3", "nef", "arw":
            self = .image
        case "mov", "mp4", "m4v", "avi", "mkv", "wmv", "webm", "3gp":
            self = .video
        case "mp3", "m4a", "aac", "flac", "wav", "aiff", "ogg", "alac":
            self = .audio
        case "pdf": self = .pdf
        case "doc", "docx", "pages", "rtf", "odt": self = .document
        case "xls", "xlsx", "numbers", "csv", "ods": self = .spreadsheet
        case "ppt", "pptx", "key", "odp": self = .presentation
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg": self = .archive
        case "swift", "py", "js", "ts", "json", "yml", "yaml", "sh", "html", "css", "xml", "c", "h", "go", "rs", "java", "kt":
            self = .code
        case "txt", "md", "markdown", "log": self = .text
        default: self = .other
        }
    }
}

/// Part of a file, plus the whole file's length.
public struct ByteRange: Sendable {
    public let data: Data
    public let totalLength: Int64

    public init(data: Data, totalLength: Int64) {
        self.data = data
        self.totalLength = totalLength
    }
}

public struct FolderPage: Sendable {
    public let items: [RemoteItem]
    public let total: Int
    public let offset: Int

    public init(items: [RemoteItem], total: Int, offset: Int) {
        self.items = items
        self.total = total
        self.offset = offset
    }

    public var hasMore: Bool { offset + items.count < total }
}

public enum SortField: String, Sendable, CaseIterable, Codable {
    case name, size, modified

    /// The value File Station expects for `sort_by`.
    var apiValue: String {
        switch self {
        case .name: "name"
        case .size: "size"
        case .modified: "mtime"
        }
    }
}

public enum ThumbnailSize: String, Sendable {
    /// ~120px; list rows.
    case small
    /// ~320px; grid cells.
    case medium
    /// ~640px; quick previews.
    case large
}

/// Credentials entered by the user. The password is only held in memory
/// during login; afterwards the app keeps the session ID and device token.
public struct Credentials: Sendable {
    public var account: String
    public var password: String
    public var otpCode: String?

    public init(account: String, password: String, otpCode: String? = nil) {
        self.account = account
        self.password = password
        self.otpCode = otpCode
    }
}

/// What a successful login returns.
public struct Session: Sendable, Codable, Equatable {
    public let sid: String
    /// Returned when "remember this device" is used, so the next login
    /// can skip the 2-factor code.
    public let deviceToken: String?

    public init(sid: String, deviceToken: String?) {
        self.sid = sid
        self.deviceToken = deviceToken
    }
}

/// A link to a file or folder that anyone with the URL can open, created by
/// the NAS (DSM's Sharing Links). It works until it expires or is removed.
public struct SharingLink: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let expires: Date?
    public let hasPassword: Bool

    public init(id: String, url: URL, expires: Date?, hasPassword: Bool) {
        self.id = id
        self.url = url
        self.expires = expires
        self.hasPassword = hasPassword
    }
}
