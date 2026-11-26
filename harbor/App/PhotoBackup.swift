#if os(iOS)
import BackgroundTasks
import Network
import Observation
import os
import OwnholdKit
import Photos
import UIKit

/// Backs up the photo library to a folder on the NAS: originals in their
/// own format, in Year/Month folders, without duplicates.
///
/// It runs when asked (Back Up Now), and, only with Back Up Automatically
/// on, when the app opens and in the background when iOS allows it (by
/// default only on Wi-Fi and while charging, never in Low Power Mode).
/// Photo library access is requested only when backup is turned on.
@MainActor
@Observable
final class PhotoBackup {
    struct Settings: Codable, Equatable {
        var destination: String?
        var includeVideos = true
        var includeLivePhotoVideos = true
        /// nil: the whole library. Otherwise only items taken from then on.
        var since: Date?
        var automatic = false
        var wifiOnly = true
        var chargingOnly = true
        var lastBackup: Date?
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case uploading(done: Int, total: Int, current: String)
        case finished(uploaded: Int)
        case failed(String)
    }

    static let taskID = "app.ownhold.Ownhold.backup"
    private static let log = Logger(subsystem: "app.ownhold.Ownhold", category: "backup")

    var settings = Settings() { didSet { if settings != oldValue { saveSettings() } } }
    private(set) var phase: Phase = .idle
    private(set) var access: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// Items not backed up yet, from the last check (nil before one).
    private(set) var waiting: Int?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var serverID: UUID?

    init(model: AppModel) { self.model = model }

    var isRunning: Bool { runner != nil }
    var isReady: Bool { settings.destination != nil && (access == .authorized || access == .limited) }

    // MARK: Server

    /// Loads the settings for the NAS now in use (each NAS has its own).
    func load(for profile: ServerProfile?) {
        cancel()
        serverID = profile?.id
        phase = .idle
        waiting = nil
        guard let id = profile?.id, let data = UserDefaults.standard.data(forKey: Self.settingsKey(id)),
              let saved = try? JSONDecoder().decode(Settings.self, from: data) else {
            settings = Settings()
            return
        }
        settings = saved
    }

    func forget(_ profile: ServerProfile) {
        UserDefaults.standard.removeObject(forKey: Self.settingsKey(profile.id))
        try? FileManager.default.removeItem(at: Self.historyURL(profile.id))
    }

    private func saveSettings() {
        guard let serverID else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey(serverID))
        if settings.automatic { Self.scheduleBackground(settings) } else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID) }
    }

    /// A new destination starts a fresh record: files are checked against
    /// what's in the new folder instead.
    func setDestination(_ path: String) {
        guard path != settings.destination, let serverID else { return }
        try? FileManager.default.removeItem(at: Self.historyURL(serverID))
        settings.destination = path
        settings.lastBackup = nil
        waiting = nil
    }

    // MARK: Access

    func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func refreshAccess() {
        access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: Running

    func backUpNow() {
        guard runner == nil else { return }
        runner = Task {
            await run(background: false)
            runner = nil
        }
    }

    func cancel() {
        runner?.cancel()
    }

    /// With Back Up Automatically on: catch up when the app opens.
    func runIfAutomatic() {
        guard settings.automatic, isReady, runner == nil, Self.conditionsAllow(settings, foreground: true) else { return }
        backUpNow()
    }

    /// Counts what's left to back up, without uploading anything.
    func check() async {
        guard isReady, runner == nil, let service = model?.service, let destination = settings.destination, let serverID else { return }
        if let plan = try? await makePlan(service: service, destination: destination, history: Self.loadHistory(serverID)) {
            waiting = Set(plan.jobs.map(\.assetID)).count
        }
    }

    func run(background: Bool) async {
        guard isReady, let service = model?.service, let destination = settings.destination, let serverID else { return }
        let keepAwake = !background
        if keepAwake { UIApplication.shared.isIdleTimerDisabled = true }
        let grace = background ? .invalid : UIApplication.shared.beginBackgroundTask(withName: "Photo Backup") { }
        defer {
            if keepAwake { UIApplication.shared.isIdleTimerDisabled = false }
            if grace != .invalid { UIApplication.shared.endBackgroundTask(grace) }
        }
        phase = .scanning
        var history = Self.loadHistory(serverID)
        do {
            let plan = try await makePlan(service: service, destination: destination, history: history)
            history.formUnion(plan.alreadyThere)
            var uploaded = 0
            var existingByFolder: [String: [String: Int64?]] = [:]
            for (index, job) in plan.jobs.enumerated() {
                try Task.checkCancellation()
                phase = .uploading(done: index, total: plan.jobs.count, current: job.name)
                let file = try await Self.export(job)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                var name = job.name
                if job.checkExisting {
                    if existingByFolder[job.folder] == nil {
                        existingByFolder[job.folder] = (try? await Self.listing(job.folder, service: service)) ?? [:]
                    }
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) }
                    let existing = existingByFolder[job.folder] ?? [:]
                    if let there = existing[name.lowercased()], there != nil, there == size {
                        history.insert(job.historyKey)
                        continue
                    }
                    name = RemoteItem.uniqueName(for: name, avoiding: Set(existing.keys))
                }
                do {
                    try await service.upload(file, as: name, to: job.folder, replacing: false) { _ in }
                } catch NASError.alreadyExists {
                    // Uploaded by another device meanwhile: leave it.
                }
                history.insert(job.historyKey)
                uploaded += 1
                if uploaded % 10 == 0 { Self.saveHistory(history, serverID) }
            }
            Self.saveHistory(history, serverID)
            settings.lastBackup = .now
            waiting = 0
            phase = .finished(uploaded: uploaded)
            if uploaded > 0 { model?.folderChanged(destination) }
        } catch is CancellationError {
            Self.saveHistory(history, serverID)
            phase = .idle
        } catch {
            Self.saveHistory(history, serverID)
            Self.log.error("Backup failed: \(String(describing: error), privacy: .public)")
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "The backup stopped. Try again.")
        }
    }

    // MARK: Planning

    private func makePlan(service: any FileService, destination: String, history: Set<String>) async throws -> BackupPlanner.Plan {
        let assets = Self.libraryAssets(settings)
        // List each month folder once, to spot files already there.
        let folders = Set(assets.map { BackupPlanner.folder(for: $0.created, in: destination) })
        var existing: [String: [String: Int64?]] = [:]
        for folder in folders {
            try Task.checkCancellation()
            existing[folder] = try await Self.listing(folder, service: service)
        }
        return BackupPlanner.plan(assets, destination: destination, history: history, existing: existing)
    }

    private static func listing(_ folder: String, service: any FileService) async throws -> [String: Int64?] {
        do {
            var result: [String: Int64?] = [:]
            var offset = 0
            while true {
                let page = try await service.list(folder: folder, offset: offset, limit: 1000, sort: .name, ascending: true)
                for item in page.items where !item.isDirectory { result[item.name.lowercased()] = item.size }
                offset += page.items.count
                if page.items.isEmpty || offset >= page.total { break }
            }
            return result
        } catch NASError.notFound {
            return [:]
        }
    }

    /// The library's photos (and videos), oldest first, with their
    /// original files: the photo or video itself, a RAW's paired JPEG,
    /// and a Live Photo's video when wanted. Edits aren't included.
    private static func libraryAssets(_ settings: Settings) -> [BackupPlanner.Asset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var predicates = [NSPredicate(format: settings.includeVideos ? "mediaType == %d || mediaType == %d" : "mediaType == %d",
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)]
        if let since = settings.since { predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let fetched = PHAsset.fetchAssets(with: options)
        var assets: [BackupPlanner.Asset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            let wanted: Set<PHAssetResourceType> = settings.includeLivePhotoVideos
                ? [.photo, .video, .alternatePhoto, .pairedVideo]
                : [.photo, .video, .alternatePhoto]
            let resources = PHAssetResource.assetResources(for: asset)
                .filter { wanted.contains($0.type) }
                .map { BackupPlanner.Resource(name: $0.originalFilename, size: nil) }
            guard !resources.isEmpty else { return }
            assets.append(.init(id: asset.localIdentifier, created: asset.creationDate, resources: resources))
        }
        return assets
    }

    /// Writes one original file to a temporary folder (downloading it from
    /// iCloud first if the device keeps only a smaller copy).
    private static func export(_ job: BackupPlanner.Job) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.originalFilename == job.resource.name })
        else { throw NASError.notFound }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Backup-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: job.resource.name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        // The upload carries the file's date: make it when the photo was taken.
        if let taken = asset.creationDate {
            try? FileManager.default.setAttributes([.modificationDate: taken], ofItemAtPath: file.path(percentEncoded: false))
        }
        return file
    }

    // MARK: Record of what's backed up (on this device only)

    private static func settingsKey(_ id: UUID) -> String { "backup.\(id.uuidString)" }

    private static func historyURL(_ id: UUID) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Backup", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: id.uuidString + ".json")
    }

    private static func loadHistory(_ id: UUID) -> Set<String> {
        (try? Data(contentsOf: historyURL(id))).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    private static func saveHistory(_ history: Set<String>, _ id: UUID) {
        try? JSONEncoder().encode(history).write(to: historyURL(id), options: [.atomic, .completeFileProtection])
    }

    // MARK: Automatic backup

    /// Wi-Fi and power conditions for an automatic run. Never in Low Power Mode.
    private static func conditionsAllow(_ settings: Settings, foreground: Bool) -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if settings.chargingOnly, !foreground {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            if state != .charging, state != .full { return false }
        }
        if settings.wifiOnly, NetworkStatus.shared.isExpensive { return false }
        return true
    }

    static func scheduleBackground(_ settings: Settings) {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = settings.chargingOnly
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("Couldn't schedule backup: \(String(describing: error), privacy: .public)")
        }
    }

    /// Called once at launch: what to do when iOS starts the background task.
    static func registerBackgroundTask(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
            MainActor.assumeIsolated {
                let backup = model.backup
                guard backup.settings.automatic else {
                    task.setTaskCompleted(success: true)
                    return
                }
                Self.scheduleBackground(backup.settings)
                let work = Task {
                    await model.start()
                    guard backup.isReady, conditionsAllow(backup.settings, foreground: false) else { return }
                    await backup.run(background: true)
                }
                task.expirationHandler = { work.cancel() }
                Task {
                    await work.value
                    task.setTaskCompleted(success: !work.isCancelled)
                }
            }
        }
    }
}

/// Whether the current connection is cellular or a personal hotspot.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { self.expensive = path.isExpensive }
        }
        monitor.start(queue: DispatchQueue(label: "app.ownhold.network"))
    }

    var isExpensive: Bool { lock.withLock { expensive } }
}
#endif
