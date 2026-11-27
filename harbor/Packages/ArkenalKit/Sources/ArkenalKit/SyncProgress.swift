import Foundation

/// What Arkenal is copying right now, for the Live Activity on iPhone and
/// the Dock and menu bar on the Mac.
public struct SyncProgress: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case photoBackup, folderBackup, uploads
    }

    public var kind: Kind
    /// Items done and the total, or nil while still counting.
    public var done: Int?
    public var total: Int?
    /// 0…1, or nil while still counting.
    public var fraction: Double?

    public init(kind: Kind, done: Int? = nil, total: Int? = nil, fraction: Double? = nil) {
        self.kind = kind
        self.done = done
        self.total = total
        self.fraction = fraction
    }

    public var title: String {
        switch kind {
        case .photoBackup: "Backing Up Photos"
        case .folderBackup: "Backing Up Folders"
        case .uploads: "Uploading"
        }
    }

    /// "12 of 340", or "Checking…" before the count is known.
    public var detail: String {
        guard let done, let total else { return "Checking…" }
        return "\(min(done + 1, total)) of \(total)"
    }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// The Live Activity shown on the Lock Screen and in the Dynamic Island
/// while a backup or a large upload runs.
public struct SyncActivityAttributes: ActivityAttributes {
    public typealias ContentState = SyncProgress
    /// The NAS being copied to.
    public var serverName: String

    public init(serverName: String) { self.serverName = serverName }
}
#endif
