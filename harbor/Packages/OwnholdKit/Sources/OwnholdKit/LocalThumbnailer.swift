import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Makes thumbnails on the device when the NAS doesn't have one.
///
/// DSM only creates HEIC and video thumbnails for folders indexed by
/// Synology Photos or the indexing service; elsewhere File Station answers
/// "not found". To keep battery and data use low:
/// - Photos: read only the start of the file and use the small preview most
///   cameras embed (HEIC from iPhones, most JPEG/RAW). Downloading the whole
///   photo is a last resort, skipped in Low Power Mode and for large files.
/// - Videos: fetch only the byte ranges needed to decode one keyframe.
///   Skipped in Low Power Mode.
/// - At most two at a time; results are cached on disk by ThumbnailCache, so
///   each file is done once.
actor LocalThumbnailer {
    static let shared = LocalThumbnailer()

    /// Bytes read from the start of a photo to find its embedded preview.
    static let headBytes = 256 * 1024
    /// Largest photo downloaded whole when it has no embedded preview.
    static let maxFullDownload: Int64 = 12 * 1024 * 1024

    private static let log = Logger(subsystem: "app.ownhold.Ownhold", category: "thumbnails")
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// JPEG data for a thumbnail, or nil.
    func thumbnail(for item: RemoteItem, maxPixel: Int, service: any FileService) async -> Data? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch item.kind {
        case .image:
            return await photo(item, maxPixel: maxPixel, service: service, lowPower: lowPower)
        case .video:
            guard !lowPower, item.isStreamable else { return nil }
            return await videoFrame(item, maxPixel: maxPixel, service: service)
        default:
            return nil
        }
    }

    // MARK: Photos

    private func photo(_ item: RemoteItem, maxPixel: Int, service: any FileService, lowPower: Bool) async -> Data? {
        // 1. The embedded preview, from the first part of the file.
        if let head = try? await service.read(item, from: 0, length: Self.headBytes),
           let image = Self.embeddedPreview(head.data, maxPixel: maxPixel) {
            Self.log.info("photo: embedded preview (\(item.fileExtension, privacy: .public))")
            return Self.jpeg(image)
        }
        // 2. The whole photo, once, if it's not too big.
        guard !lowPower, (item.size ?? .max) <= Self.maxFullDownload,
              let file = try? await service.download(item) else { return nil }
        Self.log.info("photo: full download (\(item.fileExtension, privacy: .public), \(item.size ?? 0) bytes)")
        defer { try? FileManager.default.removeItem(at: file) }
        return ImageDecoding.downsample(fileURL: file, maxPixel: maxPixel).flatMap(Self.jpeg)
    }

    /// Uses only a preview stored in the file (never decodes the full image),
    /// so it works on a partial download.
    static func embeddedPreview(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    // MARK: Videos

    private func videoFrame(_ item: RemoteItem, maxPixel: Int, service: any FileService) async -> Data? {
        let loader = StreamingLoader(item: item, service: service)
        let asset = loader.makeAsset()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // The nearest keyframe: no decoding of the frames in between.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        withExtendedLifetime(loader) {}
        Self.log.info("video: keyframe \(image == nil ? "failed" : "ok", privacy: .public) (\(item.fileExtension, privacy: .public))")
        return image.flatMap(Self.jpeg)
    }

    // MARK: Helpers

    static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private func acquire() async {
        if running < 2 {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
