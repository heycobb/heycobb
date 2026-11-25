import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Streams a video or audio file from the NAS into AVPlayer.
///
/// AVPlayer does its own networking, which wouldn't apply Ownhold's
/// certificate pinning (and would reject DSM's self-signed certificate).
/// So the asset uses a private URL scheme, and this loader answers
/// AVPlayer's byte-range requests through `FileService.read`, over the
/// same pinned connection as everything else. Nothing is written to disk.
///
/// Keep a strong reference for as long as the asset plays: the asset's
/// resource loader holds its delegate weakly.
public final class StreamingLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let scheme = "ownhold-stream"
    /// Bytes per request. Big enough to keep throughput up over a VPN,
    /// small enough that seeking feels immediate.
    static let chunkSize = 2 << 20

    private let item: RemoteItem
    private let service: any FileService
    private let queue = DispatchQueue(label: "app.ownhold.streaming")
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var knownLength: Int64?

    public init(item: RemoteItem, service: any FileService) {
        self.item = item
        self.service = service
        self.knownLength = nil
    }

    public func makeAsset() -> AVURLAsset {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "nas"
        components.path = "/" + item.name
        let asset = AVURLAsset(url: components.url ?? URL(string: "\(Self.scheme)://nas/media")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Checks that the NAS serves byte ranges for this file. Throws
    /// `.streamingUnsupported` if not, so the caller can download instead.
    public func probe() async throws {
        _ = try await length()
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    // MARK: AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let box = RequestBox(loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(box)
            self?.lock.withLock { _ = self?.tasks.removeValue(forKey: key) }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }

    // MARK: Serving

    private func serve(_ box: RequestBox) async {
        let request = box.request
        do {
            let total = try await length()
            if let info = request.contentInformationRequest {
                info.contentType = UTType(filenameExtension: item.fileExtension)?.identifier ?? UTType.movie.identifier
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            if let dataRequest = request.dataRequest {
                var offset = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
                let end = dataRequest.requestsAllDataToEndOfResource
                    ? total
                    : min(total, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
                while offset < end {
                    try Task.checkCancellation()
                    let length = Int(min(Int64(Self.chunkSize), end - offset))
                    let part = try await service.read(item, from: offset, length: length)
                    guard !part.data.isEmpty else { break }
                    try Task.checkCancellation()
                    dataRequest.respond(with: part.data)
                    offset += Int64(part.data.count)
                }
            }
            request.finishLoading()
        } catch is CancellationError {
            // AVPlayer cancelled this request (seeking, or closed).
        } catch {
            request.finishLoading(with: error)
        }
    }

    private func length() async throws -> Int64 {
        if let known = lock.withLock({ knownLength }) { return known }
        let first = try await service.read(item, from: 0, length: 2)
        lock.withLock { knownLength = first.totalLength }
        return first.totalLength
    }
}

/// AVFoundation's loading requests aren't Sendable, but they may be answered
/// from any thread, one task per request.
private struct RequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
}
