import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Built-in sample library. Lets people try the app before connecting a NAS,
/// and gives Apple's App Review team a working account (Guideline 2.1).
/// Images are drawn on the fly, so nothing large ships in the app bundle.
public struct DemoFileService: FileService {
    public init() {}

    private static let now = Date(timeIntervalSince1970: 1_763_000_000)

    private static let tree: [String: [RemoteItem]] = {
        func folder(_ path: String, days: Double) -> RemoteItem {
            RemoteItem(path: path, name: (path as NSString).lastPathComponent, isDirectory: true, modified: now.addingTimeInterval(-days * 86400))
        }
        func file(_ path: String, size: Int64, days: Double) -> RemoteItem {
            RemoteItem(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: size, modified: now.addingTimeInterval(-days * 86400))
        }
        let photoNames = [
            "Harbor at dawn", "Breakwater", "North ridge", "Kitchen window", "Ferry crossing",
            "Low tide", "Lighthouse", "Market street", "Fog bank", "Boatyard", "Dune grass", "Last light",
        ]
        var tree: [String: [RemoteItem]] = [
            "/": [folder("/Photos", days: 2), folder("/Documents", days: 5), folder("/Projects", days: 1)],
            "/Photos": [folder("/Photos/Coast 2026", days: 2)]
                + photoNames.prefix(4).enumerated().map { i, n in file("/Photos/\(n).jpg", size: 2_400_000 + Int64(i) * 310_000, days: 30 + Double(i)) },
            "/Photos/Coast 2026": photoNames.enumerated().map { i, n in
                file("/Photos/Coast 2026/IMG_\(4100 + i) \(n).heic", size: 3_100_000 + Int64(i) * 120_000, days: 2 + Double(i) * 0.1)
            },
            "/Documents": [
                file("/Documents/Read me.md", size: 1_420, days: 5),
                file("/Documents/Packing list.txt", size: 512, days: 12),
                file("/Documents/Home network notes.md", size: 2_048, days: 40),
            ],
            "/Projects": [
                folder("/Projects/Website", days: 1),
                file("/Projects/Ideas.md", size: 880, days: 3),
            ],
            "/Projects/Website": [
                file("/Projects/Website/index.html", size: 4_200, days: 1),
                file("/Projects/Website/hero.png", size: 980_000, days: 1),
            ],
        ]
        tree["/"]?.sort { $0.name < $1.name }
        return tree
    }()

    public func listShares() async throws -> [RemoteItem] { Self.tree["/"] ?? [] }

    public func list(folder: String, offset: Int, limit: Int, sort: SortField, ascending: Bool) async throws -> FolderPage {
        let key = folder.isEmpty ? "/" : folder
        guard let items = Self.tree[key] else { throw NASError.notFound }
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
        return Self.tree.values.flatMap { $0 }
            .filter { $0.path.hasPrefix(prefix) && $0.name.localizedCaseInsensitiveContains(pattern) }
    }

    public func thumbnail(for item: RemoteItem, size: ThumbnailSize) async throws -> Data {
        let px = switch size { case .small: 160; case .medium: 400; case .large: 800 }
        guard let data = Self.renderPhoto(seed: item.path, width: px, height: px * 2 / 3) else { throw NASError.notFound }
        return data
    }

    public func download(_ item: RemoteItem) async throws -> URL {
        let data: Data
        switch item.kind {
        case .image:
            guard let image = Self.renderPhoto(seed: item.path, width: 2400, height: 1600) else { throw NASError.notFound }
            data = image
        default:
            data = Data(Self.text(for: item).utf8)
        }
        let ext = item.kind == .image ? "jpg" : item.fileExtension
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url
    }

    public func signOut() async {}

    // MARK: Content

    private static func text(for item: RemoteItem) -> String {
        switch item.name {
        case "Read me.md":
            """
            # Welcome to the demo library

            This is sample content built into Harbor so you can try the app without a NAS.

            - Browse folders and switch between list and grid.
            - Open photos and documents to preview them.
            - Swipe a file (or right-click on Mac) and choose **Keep Offline**.

            When you're ready, add your own Synology NAS from the server menu.
            """
        case "Packing list.txt":
            "Passport\nCharger\nRain shell\nWool socks ×3\nCamera + spare battery\nPaperback\n"
        default:
            "Sample file: \(item.name)\n"
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
