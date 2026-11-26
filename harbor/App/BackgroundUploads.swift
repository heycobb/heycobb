#if os(iOS)
import Foundation
import os
import OwnholdKit
import UIKit

/// Uploads that keep going after you leave Ownhold (iPhone and iPad).
///
/// Large files (`threshold` and up) are handed to a background URLSession:
/// iOS sends them even while Ownhold is suspended, and relaunches it to
/// report the result. The NAS's certificate is checked exactly as for every
/// other request (`CertificateTrust`). Small files go the quick direct way.
final class BackgroundUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploads()
    static let identifier = "app.ownhold.Ownhold.uploads"
    static let threshold: Int64 = 10_000_000

    /// Set at launch: the same certificate pins as the rest of the app.
    var trust: CertificateTrust?
    /// From `application(_:handleEventsForBackgroundURLSession:…)`; called
    /// once iOS has delivered every finished upload.
    var finishEvents: (() -> Void)?

    private static let log = Logger(subsystem: "app.ownhold.Ownhold", category: "background-uploads")
    private let lock = NSLock()
    private var running: [Int: Running] = [:]

    private struct Running {
        let body: URL
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<Void, Error>
        var data = Data()
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Whether cellular is allowed is decided before an upload starts
        // (Settings › Cellular Data), so don't second-guess it here.
        config.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Recreates the session at launch so iOS can deliver results of uploads
    /// that finished while Ownhold wasn't running.
    func reconnect() { _ = session }

    /// Uploads `file` to the NAS through the background session.
    func upload(_ file: URL, as name: String, to folder: String, replacing: Bool,
                with client: FileStationClient, progress: @escaping @Sendable (Double) -> Void) async throws {
        let prepared = try await client.prepareUpload(file, as: name, to: folder, replacing: replacing)
        let task = session.uploadTask(with: prepared.request, fromFile: prepared.body)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { running[task.taskIdentifier] = Running(body: prepared.body, progress: progress, continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        progress(1)
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let box = ChallengeBox(challenge)
        Task {
            let (disposition, credential) = await trust.urlSession(session, didReceive: box.challenge)
            completionHandler(disposition, credential)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        lock.withLock { running[task.taskIdentifier] }?.progress(fraction)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { running[dataTask.taskIdentifier]?.data.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finished = lock.withLock { running.removeValue(forKey: task.taskIdentifier) }
        guard let finished else {
            // Finished after Ownhold was relaunched: nothing is waiting for it.
            Self.log.notice("A background upload finished after a relaunch")
            return
        }
        try? FileManager.default.removeItem(at: finished.body)
        if let error {
            finished.continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : NASError.unreachable)
            return
        }
        do {
            try FileStationClient.checkUploadResponse(data: finished.data, response: task.response)
            finished.continuation.resume()
        } catch {
            finished.continuation.resume(throwing: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            finishEvents?()
            finishEvents = nil
        }
    }
}

/// The challenge isn't Sendable, but it's only read on the way to the trust check.
private struct ChallengeBox: @unchecked Sendable {
    let challenge: URLAuthenticationChallenge
    init(_ challenge: URLAuthenticationChallenge) { self.challenge = challenge }
}

/// Hands iOS's "your background uploads finished" wake-up to `BackgroundUploads`.
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploads.identifier else { return completionHandler() }
        BackgroundUploads.shared.finishEvents = completionHandler
        BackgroundUploads.shared.reconnect()
    }
}

extension FileService {
    /// Uploads, through the background session for large files on iPhone
    /// and iPad (so they finish after you leave Ownhold), directly otherwise.
    func uploadAllowingBackground(_ file: URL, as name: String, to folder: String, replacing: Bool,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if size >= BackgroundUploads.threshold, ProStore.unlocked, let client = self as? FileStationClient {
            try await BackgroundUploads.shared.upload(file, as: name, to: folder, replacing: replacing, with: client, progress: progress)
        } else {
            try await upload(file, as: name, to: folder, replacing: replacing, progress: progress)
        }
    }
}
#endif
