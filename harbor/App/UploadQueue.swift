import Foundation
import ArkenalKit
import Observation
#if os(iOS)
import UIKit
#endif

/// A file the user picked, dropped or chose from Photos, before it's queued.
struct PendingUpload {
    let url: URL
    let name: String
    /// True for copies Arkenal made (from Photos); deleted when done.
    let ownsFile: Bool

    var isFolder: Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

enum ConflictChoice { case replace, keepBoth, skip, cancel }

/// Uploads, one at a time, in the order the user added them.
///
/// There is no background sync: uploads run while Arkenal is open. On
/// iPhone and iPad the screen stays awake while they run, and iOS gives a
/// little extra time to finish if the user switches apps.
@MainActor
@Observable
final class UploadQueue {
    struct Job: Identifiable {
        enum State: Equatable {
            case waiting
            case uploading(Double)
            case done
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let source: URL
        let ownsFile: Bool
        let name: String
        let folder: String
        let replacing: Bool
        let size: Int64
        var state: State = .waiting

        var isFinished: Bool { state == .done || state == .cancelled }
        var progress: Double {
            switch state {
            case .done: 1
            case let .uploading(p): p
            default: 0
            }
        }
    }

    private(set) var jobs: [Job] = []
    /// Set while a large upload waits for Wi-Fi (Settings › Cellular Data).
    private(set) var networkWait: String?
    /// Items still being copied out of Photos.
    private(set) var preparing = 0

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    #if os(iOS)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(model: AppModel) { self.model = model }

    // MARK: State for the UI

    var isRunning: Bool { runner != nil }
    var isEmpty: Bool { jobs.isEmpty && preparing == 0 }
    var remaining: Int { jobs.count { $0.state == .waiting || $0.isUploading } }
    var completed: Int { jobs.count { $0.state == .done } }
    var failed: Int { jobs.count { if case .failed = $0.state { true } else { false } } }
    var current: Job? { jobs.first { $0.isUploading } }

    /// Overall progress by bytes, over the jobs that haven't been cancelled.
    var fraction: Double {
        let active = jobs.filter { $0.state != .cancelled }
        let total = active.reduce(0.0) { $0 + Double(max($1.size, 1)) }
        guard total > 0 else { return 0 }
        return active.reduce(0.0) { $0 + Double(max($1.size, 1)) * $1.progress } / total
    }

    // MARK: Adding

    func beginPreparing(_ count: Int) { preparing += count }
    func endPreparing(_ count: Int) { preparing = max(0, preparing - count) }

    /// Names in `uploads` that clash with what's already in the folder.
    static func conflicts(_ uploads: [PendingUpload], existing: Set<String>) -> [String] {
        let taken = Set(existing.map { $0.lowercased() })
        return uploads.map(\.name).filter { taken.contains($0.lowercased()) }
    }

    /// Queues files (and everything inside folders) for upload into `folder`.
    func add(_ uploads: [PendingUpload], to folder: String, existing: Set<String>, onConflict choice: ConflictChoice) {
        if choice == .cancel {
            uploads.forEach(discard)
            return
        }
        var assigned = existing
        let taken = Set(existing.map { $0.lowercased() })
        for upload in uploads {
            let clashes = taken.contains(upload.name.lowercased())
            if clashes, choice == .skip {
                discard(upload)
                continue
            }
            // Duplicates within the batch always get a new name; clashes with
            // the folder only when the user chose Keep Both.
            let name = clashes && choice == .replace
                ? upload.name
                : RemoteItem.uniqueName(for: upload.name, avoiding: assigned)
            assigned.insert(name)
            let replacing = clashes && choice == .replace
            if upload.isFolder {
                addFolder(upload.url, as: name, to: folder, replacing: replacing)
            } else {
                append(source: upload.url, ownsFile: upload.ownsFile, name: name, folder: folder, replacing: replacing)
            }
        }
        run()
    }

    private func addFolder(_ url: URL, as name: String, to folder: String, replacing: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let base = url.standardizedFileURL.pathComponents
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let file = enumerator?.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = file.standardizedFileURL.pathComponents.dropFirst(base.count).dropLast()
            let destination = ([RemoteItem.join(folder, name)] + relative).joined(separator: "/")
            append(source: file, ownsFile: false, name: file.lastPathComponent, folder: destination, replacing: replacing)
        }
    }

    private func append(source: URL, ownsFile: Bool, name: String, folder: String, replacing: Bool) {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        jobs.append(Job(source: source, ownsFile: ownsFile, name: name, folder: folder, replacing: replacing, size: size))
    }

    // MARK: Control

    func retryFailed() {
        for index in jobs.indices {
            if case .failed = jobs[index].state { jobs[index].state = .waiting }
        }
        run()
    }

    func cancelAll() {
        runner?.cancel()
        for index in jobs.indices where jobs[index].state == .waiting {
            jobs[index].state = .cancelled
        }
    }

    /// Removes finished and failed uploads from the list.
    func clearFinished() {
        for job in jobs where job.state != .waiting && !job.isUploading { discard(job) }
        jobs.removeAll { $0.state != .waiting && !$0.isUploading }
    }

    // MARK: Running

    private func run() {
        guard runner == nil, jobs.contains(where: { $0.state == .waiting }) else { return }
        keepAwake(true)
        runner = Task {
            while let index = jobs.firstIndex(where: { $0.state == .waiting }), !Task.isCancelled {
                guard await waitForNetwork(size: jobs[index].size), !Task.isCancelled else { break }
                guard let index = jobs.firstIndex(where: { $0.state == .waiting }) else { break }
                guard await upload(at: index) else { break }
            }
            networkWait = nil
            runner = nil
            keepAwake(false)
            refreshFolders(force: true)
            // Anything left waiting (after a connection error) can be retried.
            for index in jobs.indices where jobs[index].state == .waiting {
                jobs[index].state = .failed("Not uploaded")
            }
            // All went well: the summary clears itself. Failures stay until dismissed.
            if failed == 0 {
                try? await Task.sleep(for: .seconds(4))
                if runner == nil, failed == 0, !jobs.contains(where: { $0.state == .waiting }) { clearFinished() }
            }
        }
    }

    /// Large files wait for Wi-Fi when Settings › Cellular Data › Large
    /// Uploads is off. Checks every few seconds; false if cancelled.
    private func waitForNetwork(size: Int64) async -> Bool {
        guard size >= NetworkPolicy.largeUploadBytes else { return true }
        while !NetworkPolicy.allows(.largeUploads, automatic: false) {
            networkWait = NetworkPolicy.waitingReason
            do { try await Task.sleep(for: .seconds(5)) } catch { return false }
        }
        networkWait = nil
        return true
    }

    /// Returns false when the rest of the queue can't continue (signed out,
    /// NAS unreachable, or cancelled).
    private func upload(at index: Int) async -> Bool {
        let job = jobs[index]
        guard let service = model?.service else {
            jobs[index].state = .failed(NASError.unreachable.errorDescription ?? "")
            return false
        }
        jobs[index].state = .uploading(0)
        let id = job.id
        let scoped = job.source.startAccessingSecurityScopedResource()
        defer { if scoped { job.source.stopAccessingSecurityScopedResource() } }
        do {
            let progress: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in self?.setProgress(fraction, for: id) }
            }
            #if os(iOS)
            // Large files keep uploading after you leave Arkenal.
            try await service.uploadAllowingBackground(job.source, as: job.name, to: job.folder, replacing: job.replacing, progress: progress)
            #else
            try await service.upload(job.source, as: job.name, to: job.folder, replacing: job.replacing, progress: progress)
            #endif
            setState(.done, for: id)
            discard(job)
            refreshFolders(force: false)
            return true
        } catch is CancellationError {
            setState(.cancelled, for: id)
            return false
        } catch {
            let nasError = error as? NASError
            setState(.failed(nasError?.errorDescription ?? error.localizedDescription), for: id)
            switch nasError {
            case .sessionExpired?, .unreachable?, .untrustedCertificate?, .certificateChanged?:
                model?.handle(error)
                return false
            default:
                return true
            }
        }
    }

    private func setProgress(_ fraction: Double, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isUploading else { return }
        jobs[index].state = .uploading(fraction)
    }

    private func setState(_ state: Job.State, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    /// Reloads the folders being uploaded into, at most every few seconds
    /// while uploads run, so the list fills in without constant reloading.
    private func refreshFolders(force: Bool) {
        guard force || Date().timeIntervalSince(lastRefresh) > 3 else { return }
        lastRefresh = Date()
        for folder in Set(jobs.filter { $0.state == .done }.map(\.folder)) {
            model?.folderChanged(folder)
            // A new subfolder appears in its parent too.
            model?.folderChanged((folder as NSString).deletingLastPathComponent)
        }
    }

    private func discard(_ job: Job) {
        if job.ownsFile { Self.removeStaged(job.source) }
    }

    private func discard(_ upload: PendingUpload) {
        if upload.ownsFile { Self.removeStaged(upload.url) }
    }

    // MARK: Staging (copies from Photos)

    nonisolated static var stagingDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "UploadStaging", directoryHint: .isDirectory)
    }

    /// Copies a file into a private folder, keeping its name.
    nonisolated static func stage(_ file: URL) throws -> URL {
        let folder = stagingDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    nonisolated private static func removeStaged(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Leftovers from a previous run (the app was closed mid-upload).
    nonisolated static func purgeStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    private func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        if on, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Uploads") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        } else if !on {
            endBackgroundTask()
        }
        #endif
    }

    #if os(iOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}

extension UploadQueue.Job {
    var isUploading: Bool { if case .uploading = state { true } else { false } }
}
