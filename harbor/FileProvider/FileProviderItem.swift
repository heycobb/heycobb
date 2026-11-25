import FileProvider
import OwnholdKit
import UniformTypeIdentifiers

/// A NAS file or folder as the Files app sees it. The identifier is the
/// item's path on the NAS; the root lists the shared folders.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let remote: RemoteItem

    init(_ remote: RemoteItem) {
        self.remote = remote
    }

    static func identifier(for path: String) -> NSFileProviderItemIdentifier {
        path == "/" || path.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(path)
    }

    static func path(for identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? "/" : identifier.rawValue
    }

    var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(for: remote.path) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { Self.identifier(for: remote.parentPath) }
    var filename: String { remote.name }

    var contentType: UTType {
        remote.isDirectory ? .folder : (UTType(filenameExtension: remote.fileExtension) ?? .data)
    }

    var documentSize: NSNumber? { remote.size.map { NSNumber(value: $0) } }
    var contentModificationDate: Date? { remote.modified }

    var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = [.allowsReading]
        if remote.isDirectory { caps.formUnion([.allowsContentEnumerating, .allowsAddingSubItems]) }
        // Shared folders are managed in DSM, like in the app.
        if !remote.isShare { caps.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsWriting]) }
        return caps
    }

    /// Changes when the file does, so the Files app knows to download again.
    var itemVersion: NSFileProviderItemVersion {
        let stamp = "\(remote.modified?.timeIntervalSince1970 ?? 0)-\(remote.size ?? 0)"
        let data = Data(stamp.utf8)
        return NSFileProviderItemVersion(contentVersion: data, metadataVersion: data)
    }
}

/// The root (the list of shared folders).
final class RootItem: NSObject, NSFileProviderItem {
    let name: String
    let readOnly: Bool
    init(name: String, readOnly: Bool = false) {
        self.name = name
        self.readOnly = readOnly
    }
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { name }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { readOnly ? [.allowsContentEnumerating] : [.allowsReading, .allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion { NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8)) }
}
