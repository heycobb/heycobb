import CryptoKit
import Foundation
import ImageIO

/// Two-level thumbnail cache: decoded images in memory, raw bytes on disk.
///
/// Disk entries live in Caches (the OS may purge them; they're excluded from
/// backups) and file names are hashes, so paths on the NAS aren't visible
/// in the file system.
public actor ThumbnailCache {
    private let directory: URL
    private let memory = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImageBox?, Never>] = [:]

    public init(namespace: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appending(path: "Thumbnails/\(namespace)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    public func image(
        for item: RemoteItem,
        size: ThumbnailSize,
        maxPixel: Int,
        service: any FileService
    ) async -> CGImageBox? {
        let key = Self.key(item: item, size: size)
        if let box = memory.object(forKey: key as NSString) { return box }
        if let task = inFlight[key] { return await task.value }

        let file = directory.appending(path: key)
        // Detached so decoding runs in parallel instead of serializing on the actor.
        let task = Task<CGImageBox?, Never>.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: file), let image = ImageDecoding.downsample(data, maxPixel: maxPixel) {
                return CGImageBox(image)
            }
            guard let data = try? await service.thumbnail(for: item, size: size) else { return nil }
            try? data.write(to: file, options: [.atomic])
            return ImageDecoding.downsample(data, maxPixel: maxPixel).map(CGImageBox.init)
        }
        inFlight[key] = task
        let box = await task.value
        inFlight[key] = nil
        if let box { memory.setObject(box, forKey: key as NSString) }
        return box
    }

    public func removeAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func diskUsage() -> Int64 {
        FileManager.default.allocatedSize(of: directory)
    }

    /// The modification date is part of the key so edited files get fresh thumbnails.
    static func key(item: RemoteItem, size: ThumbnailSize) -> String {
        let stamp = item.modified.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        let digest = SHA256.hash(data: Data("\(item.path)|\(stamp)|\(size.rawValue)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// CGImage is immutable, so sharing it across concurrency domains is safe.
public final class CGImageBox: @unchecked Sendable {
    public let image: CGImage
    public init(_ image: CGImage) { self.image = image }
}

public enum ImageDecoding {
    /// Decodes and downsizes in one step, which uses far less memory than
    /// decoding full-size and scaling afterwards.
    public static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return downsample(source, maxPixel: maxPixel)
    }

    public static func downsample(fileURL: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
        return downsample(source, maxPixel: maxPixel)
    }

    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

extension FileManager {
    func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
