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
