#if os(macOS)
import FileProvider
import Foundation
import os
import OwnholdKit

/// Makes Finder's Keep Downloaded download right away while Ownhold runs.
///
/// Kept items get macOS's keep-downloaded policy, but macOS downloads them
/// through a background scheduler that can wait a long time. Opening a
/// file downloads it at once, so this opens each kept file that's still a
/// placeholder: when the Finder extension says something was kept, and on
/// each Keep Finder Up to Date check. Without Ownhold running, macOS's own
/// scheduler still downloads them eventually.
enum KeptDownloader {
    /// Posted by the Finder extension after Keep Downloaded.
    static let keptNotification = "app.ownhold.keptDownloadsChanged"
    private static let log = Logger(subsystem: "app.ownhold.Ownhold", category: "kept-downloads")
    private static let limit = 2000

    /// Listens for the extension's notification for as long as the app runs.
    static func observe(_ handler: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), box, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<HandlerBox>.fromOpaque(observer).takeUnretainedValue().handler()
        }, keptNotification as CFString, nil, .deliverImmediately)
    }

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(keptNotification as CFString), nil, nil, true)
    }

    /// Opens every kept file that isn't downloaded yet, in every NAS location.
    static func downloadKeptFiles() async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        for domain in domains {
            let kept = KeptDownloads(domain: domain.identifier.rawValue).paths
            guard !kept.isEmpty, let manager = NSFileProviderManager(for: domain) else { continue }
            var roots: [URL] = []
            for path in kept {
                let identifier = path == "/" ? NSFileProviderItemIdentifier.rootContainer : NSFileProviderItemIdentifier(path)
                if let url = try? await manager.getUserVisibleURL(for: identifier) { roots.append(url) }
            }
            let opened = await Task.detached(priority: .utility) { materialize(roots) }.value
            if opened > 0 { log.info("Downloaded \(opened) kept files") }
        }
    }

    /// Reads each placeholder file through a file coordinator, which makes
    /// the system download it (one at a time, to go easy on the NAS).
    private static func materialize(_ roots: [URL]) -> Int {
        var opened = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey]
        for root in roots {
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            var files = [root]
            if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
                while let url = walker.nextObject() as? URL, files.count < limit { files.append(url) }
            }
            for url in files {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.ubiquitousItemDownloadingStatus != .current else { continue }
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { _ in }
                if error == nil { opened += 1 } else { log.error("Couldn't download a kept file: \(String(describing: error), privacy: .public)") }
            }
        }
        return opened
    }

    private final class HandlerBox: @unchecked Sendable {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }
}
#endif
