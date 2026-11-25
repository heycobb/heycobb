import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Built-in sample library. Lets people try the app before connecting a NAS,
/// and gives Apple's App Review team a working account (Guideline 2.1).
/// Images are drawn on the fly, so nothing large ships in the app bundle.
///
/// Changes (uploads, new folders, renames, moves, deletes) work too, but only
/// in memory: the library is back to its original state next time.
public actor DemoFileService: FileService {
    /// Folder path → its items. Starts as the built-in library.
    private var tree: [String: [RemoteItem]] = DemoFileService.initialTree
    /// Where a file's bytes come from, by its current path.
    private var sources: [String: Source] = [:]
    private let uploads = FileManager.default.temporaryDirectory.appending(path: "DemoUploads", directoryHint: .isDirectory)

    private enum Source {
        /// Built-in content, keyed by the file's original path and name.
        case builtIn(path: String, name: String)
        /// A file the user uploaded during this session.
        case uploaded(URL)
    }

    public init() {}

    /// Dates count back from this morning, so the library always looks
    /// recently used and nothing is ever dated in the future.
    private static let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)

    private static let initialTree: [String: [RemoteItem]] = {
        func folder(_ path: String, days: Double) -> RemoteItem {
            RemoteItem(path: path, name: (path as NSString).lastPathComponent, isDirectory: true, modified: now.addingTimeInterval(-days * 86400))
        }
        // Sizes are the real byte counts of what `download` returns, so the
        // size in the list matches the file you get (App Review may check).
        func file(_ path: String, days: Double) -> RemoteItem {
            let name = (path as NSString).lastPathComponent
            let size = Int64(content(path: path, name: name)?.count ?? 0)
            return RemoteItem(path: path, name: name, isDirectory: false, size: size, modified: now.addingTimeInterval(-days * 86400))
        }
        let photoNames = [
            "Harbor at dawn", "Breakwater", "North ridge", "Kitchen window", "Ferry crossing",
            "Low tide", "Lighthouse", "Market street", "Fog bank", "Boatyard", "Dune grass", "Last light",
        ]
        var tree: [String: [RemoteItem]] = [
            "/": [folder("/Photos", days: 2), folder("/Documents", days: 5), folder("/Projects", days: 1)],
            // A folder's date is its newest item's date, as on a real NAS.
            "/Photos": [folder("/Photos/Coast trip", days: 2.1)]
                + photoNames.prefix(4).enumerated().map { i, n in file("/Photos/\(n).jpg", days: 30 + Double(i) * 3) },
            "/Photos/Coast trip": photoNames.enumerated().map { i, n in
                file("/Photos/Coast trip/IMG_\(4100 + i) \(n).jpg", days: 3.2 - Double(i) * 0.1)
            },
            "/Documents": [
                file("/Documents/Read me.md", days: 5),
                file("/Documents/Packing list.txt", days: 12),
                file("/Documents/Home network notes.md", days: 40),
            ],
            "/Projects": [
                folder("/Projects/Website", days: 1),
                file("/Projects/Ideas.md", days: 3),
            ],
            "/Projects/Website": [
                file("/Projects/Website/index.html", days: 1),
                file("/Projects/Website/hero.jpg", days: 1),
            ],
        ]
        tree["/"]?.sort { $0.name < $1.name }
        return tree
    }()

    public func listShares() async throws -> [RemoteItem] { tree["/"] ?? [] }

    public func list(folder: String, offset: Int, limit: Int, sort: SortField, ascending: Bool) async throws -> FolderPage {
        let key = folder.isEmpty ? "/" : folder
        guard let items = tree[key] else { throw NASError.notFound }
        let sorted = items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let ordered: Bool
            switch sort {
            case .name: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: ordered = (a.size ?? 0) < (b.size ?? 0)
            case .modified: ordered = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            }
            return ascending ? ordered : !ordered
        }
        let page = Array(sorted.dropFirst(offset).prefix(limit))
        return FolderPage(items: page, total: sorted.count, offset: offset)
    }

    public func search(in folder: String, matching pattern: String) async throws -> [RemoteItem] {
        let prefix = folder == "/" ? "/" : folder + "/"
        return tree.values.flatMap { $0 }
            .filter { $0.path.hasPrefix(prefix) && $0.name.localizedCaseInsensitiveContains(pattern) }
    }

    public func thumbnail(for item: RemoteItem, size: ThumbnailSize) async throws -> Data {
        let px = switch size { case .small: 160; case .medium: 400; case .large: 800 }
        switch source(for: item.path) {
        case let .uploaded(url):
            guard let data = Self.thumbnail(of: url, maxPixel: px) else { throw NASError.notFound }
            return data
        case let .builtIn(path, _):
            guard let data = Self.renderPhoto(seed: path, width: px, height: px * 2 / 3) else { throw NASError.notFound }
            return data
        }
    }

    public func download(_ item: RemoteItem) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + item.fileExtension)
        switch source(for: item.path) {
        case let .uploaded(file):
            try FileManager.default.copyItem(at: file, to: url)
        case let .builtIn(path, name):
            guard let data = Self.content(path: path, name: name) else { throw NASError.notFound }
            try data.write(to: url)
        }
        return url
    }

    public func signOut() async {}

    // MARK: Changes (in memory only)

    public func createFolder(named name: String, in parent: String) async throws -> RemoteItem {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        try checkFree(name, in: parent)
        let folder = RemoteItem(path: RemoteItem.join(parent, name), name: name, isDirectory: true, modified: .now)
        tree[parent, default: []].append(folder)
        tree[folder.path] = []
        return folder
    }

    public func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        guard !item.isShare else { throw NASError.permissionDenied }
        if name.lowercased() != item.name.lowercased() { try checkFree(name, in: item.parentPath) }
        let renamed = item.with(path: RemoteItem.join(item.parentPath, name), name: name)
        relocate(item, to: renamed)
        return renamed
    }

    public func move(_ items: [RemoteItem], to folder: String) async throws {
        guard tree[folder] != nil else { throw NASError.notFound }
        for item in items {
            guard !item.isShare, folder != item.path, !folder.hasPrefix(item.path + "/") else { throw NASError.permissionDenied }
            guard item.parentPath != folder else { continue }
            try checkFree(item.name, in: folder)
        }
        for item in items where item.parentPath != folder {
            relocate(item, to: item.with(path: RemoteItem.join(folder, item.name), name: item.name))
        }
    }

    public func delete(_ items: [RemoteItem]) async throws {
        for item in items {
            guard !item.isShare else { throw NASError.permissionDenied }
            tree[item.parentPath]?.removeAll { $0.path == item.path }
            let prefix = item.path + "/"
            for key in tree.keys where key == item.path || key.hasPrefix(prefix) { tree[key] = nil }
            for key in sources.keys where key == item.path || key.hasPrefix(prefix) {
                if case let .uploaded(url) = sources[key] { try? FileManager.default.removeItem(at: url) }
                sources[key] = nil
            }
        }
    }

    public func upload(
        _ file: URL,
        as name: String,
        to folder: String,
        replacing: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        // Create missing parents, as the NAS does with create_parents.
        var parent = "/"
        for component in folder.split(separator: "/").map(String.init) {
            let path = RemoteItem.join(parent, component)
            if tree[path] == nil {
                guard tree[parent] != nil else { throw NASError.notFound }
                _ = try await createFolder(named: component, in: parent)
            }
            parent = path
        }
        let path = RemoteItem.join(folder, name)
        if let existing = tree[folder]?.first(where: { $0.name.lowercased() == name.lowercased() }) {
            guard replacing, !existing.isDirectory else { throw NASError.alreadyExists }
            try await delete([existing])
        }
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let stored = uploads.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: stored)
        // A short pause so progress is visible, as it would be on a real NAS.
        for step in 1 ... 4 {
            try await Task.sleep(for: .milliseconds(120))
            progress(Double(step) / 4)
        }
        let size = (try? stored.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        sources[path] = .uploaded(stored)
        tree[folder, default: []].append(RemoteItem(path: path, name: name, isDirectory: false, size: size, modified: .now))
    }

    private func checkFree(_ name: String, in folder: String) throws {
        if tree[folder]?.contains(where: { $0.name.lowercased() == name.lowercased() }) == true {
            throw NASError.alreadyExists
        }
    }

    private func source(for path: String) -> Source {
        sources[path] ?? .builtIn(path: path, name: (path as NSString).lastPathComponent)
    }

    /// Moves or renames an item, carrying its children and content along.
    private func relocate(_ item: RemoteItem, to moved: RemoteItem) {
        let old = item.path, new = moved.path
        func remap(_ path: String) -> String? {
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
            return nil
        }
        // Built-in files keep their original identity, so photos still draw the same.
        var movedSources: [String: Source] = [:]
        for child in tree.values.joined() where !child.isDirectory && remap(child.path) != nil {
            movedSources[child.path] = source(for: child.path)
        }
        tree[item.parentPath]?.removeAll { $0.path == old }
        var newTree: [String: [RemoteItem]] = [:]
        for (key, items) in tree {
            newTree[remap(key) ?? key] = items.map { child in
                remap(child.path).map { child.with(path: $0, name: ($0 as NSString).lastPathComponent) } ?? child
            }
        }
        newTree[moved.parentPath, default: []].append(moved)
        tree = newTree
        for (path, source) in movedSources {
            sources[path] = nil
            if let target = remap(path) { sources[target] = source }
        }
    }

    /// A JPEG thumbnail of an uploaded image (or nil for other files).
    private static func thumbnail(of url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: Content

    /// The bytes behind a demo file. Photos are drawn on the fly.
    private static func content(path: String, name: String) -> Data? {
        if FileKind(extension: (name as NSString).pathExtension.lowercased()) == .image {
            return renderPhoto(seed: path, width: 2400, height: 1600)
        }
        return Data(text(named: name).utf8)
    }

    private static func text(named name: String) -> String {
        switch name {
        case "Read me.md":
            """
            # Welcome to the demo library

            This is sample content built into Ownhold so you can try the app without a NAS.

            - Browse folders and switch between list and grid.
            - Open photos and documents to preview them.
            - Swipe a file (or right-click on Mac) and choose **Keep Offline**.
            - Tap **+** to upload photos and files or make a folder. Rename, move
              and delete from the same menus. Demo changes are undone when you leave.

            When you're ready, choose Add a NAS from the server menu.
            """
        case "Home network notes.md":
            """
            # Home network

            | Device | Address | Notes |
            |---|---|---|
            | Router | 192.168.1.1 | Firmware updated in spring |
            | NAS | 192.168.1.20 | HTTPS on 5001, nightly snapshots |
            | Printer | 192.168.1.42 | Reserved address |

            ## Away from home
            - Tailscale on the NAS and every phone and laptop.
            - MagicDNS name: nas.example-tailnet.ts.net
            - No ports forwarded on the router.

            ## Backups
            - Photos and Documents: nightly snapshots, kept 30 days.
            - Offsite copy every Sunday at 2:00.
            """
        case "Ideas.md":
            """
            # Ideas

            - Print a photo book from the coast trip
            - Move old scans into Documents/Archive
            - Rename camera files by date
            - Try a justified grid for photo folders
            """
        case "index.html":
            """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <title>Coast trip</title>
              <link rel="stylesheet" href="style.css">
            </head>
            <body>
              <header><h1>Coast trip</h1></header>
              <main>
                <img src="hero.jpg" alt="Hills above the harbor at first light">
                <p>Five days along the coast, mostly on foot.</p>
              </main>
            </body>
            </html>
            """
        case "Packing list.txt":
            "Passport\nCharger\nRain shell\nWool socks ×3\nCamera + spare battery\nPaperback\n"
        default:
            "Sample file: \(name)\n"
        }
    }

    /// Draws a simple, flat landscape whose colors come from the file path,
    /// so each demo photo looks distinct but stable.
    static func renderPhoto(seed: String, width: Int, height: Int) -> Data? {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        func unit(_ shift: UInt64) -> CGFloat { CGFloat((hash >> shift) & 0xFF) / 255 }

        let palettes: [[(CGFloat, CGFloat, CGFloat)]] = [
            [(0.86, 0.83, 0.76), (0.55, 0.62, 0.60), (0.24, 0.31, 0.33), (0.93, 0.62, 0.38)],
            [(0.74, 0.80, 0.84), (0.42, 0.50, 0.56), (0.18, 0.22, 0.27), (0.96, 0.90, 0.78)],
            [(0.93, 0.80, 0.66), (0.71, 0.45, 0.33), (0.30, 0.22, 0.20), (0.99, 0.93, 0.80)],
            [(0.80, 0.84, 0.76), (0.47, 0.56, 0.42), (0.20, 0.26, 0.20), (0.97, 0.85, 0.55)],
        ]
        let palette = palettes[Int(hash % UInt64(palettes.count))]
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        func fill(_ c: (CGFloat, CGFloat, CGFloat)) { ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
        let w = CGFloat(width), h = CGFloat(height)

        fill(palette[0]); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        fill(palette[3])
        let sun = w * (0.08 + 0.06 * unit(8))
        ctx.fillEllipse(in: CGRect(x: w * (0.15 + 0.6 * unit(16)), y: h * (0.55 + 0.2 * unit(24)), width: sun, height: sun))

        for (layer, color) in [(0, palette[1]), (1, palette[2])] {
            fill(color)
            let base = h * (layer == 0 ? 0.42 : 0.24) + h * 0.08 * unit(UInt64(32 + layer * 8))
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: 0, y: base))
            let peaks = 3 + Int(unit(UInt64(40 + layer * 4)) * 3)
            for i in 1 ... peaks {
                let x = w * CGFloat(i) / CGFloat(peaks)
                let lift = h * 0.12 * unit(UInt64((i * 7 + layer * 13) % 56))
                ctx.addLine(to: CGPoint(x: x - w / CGFloat(peaks * 2), y: base + lift))
                ctx.addLine(to: CGPoint(x: x, y: base))
            }
            ctx.addLine(to: CGPoint(x: w, y: 0))
            ctx.closePath()
            ctx.fillPath()
        }

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
