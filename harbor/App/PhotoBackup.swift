import Network
import Observation
import os
import ArkenalKit
import Photos
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Backs up the photo library to a folder on the NAS: originals in their
/// own format, in Year/Month folders, without duplicates, on iPhone, iPad
/// and Mac.
///
/// It runs when asked (Back Up Now), and, only with Back Up Automatically
/// on: on iPhone and iPad when the app opens and in the background when iOS
/// allows it (by default only while charging); on a Mac when the app opens
/// and when new photos arrive in the library. Never in Low Power Mode.
/// Photo library access is requested only when backup is turned on.
///
/// An iPhone and a Mac using the same iCloud Photos library don't upload
/// the same photo twice: see BackupPlanner and BackupManifest.
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

    static let taskID = "com.snowlightlabs.Arkenal.backup"
    private static let log = Logger(subsystem: "com.snowlightlabs.Arkenal", category: "backup")

    var settings = Settings() { didSet { if settings != oldValue { saveSettings() } } }
    private(set) var phase: Phase = .idle
    private(set) var access: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// Items not backed up yet, from the last check (nil before one).
    private(set) var waiting: Int?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var serverID: UUID?
    #if os(macOS)
    @ObservationIgnored private var libraryWatcher: LibraryWatcher?
    #endif

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
        defer {
            #if os(macOS)
            updateWatcher()
            #endif
        }
        guard let id = profile?.id, let data = UserDefaults.standard.data(forKey: Self.settingsKey(id)),
              let saved = try? JSONDecoder().decode(Settings.self, from: data) else {
            settings = Settings()
            return
        }
        Self.migrateWiFiOnly(data)
        settings = saved
    }

    func forget(_ profile: ServerProfile) {
        UserDefaults.standard.removeObject(forKey: Self.settingsKey(profile.id))
        try? FileManager.default.removeItem(at: Self.historyURL(profile.id))
    }

    private func saveSettings() {
        guard let serverID else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey(serverID))
        #if os(iOS)
        if settings.automatic { Self.scheduleBackground(settings) } else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID) }
        #else
        updateWatcher()
        #endif
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
        #if os(macOS)
        updateWatcher()
        #endif
    }

    func refreshAccess() {
        access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    #if os(macOS)
    /// With Back Up Automatically on, new photos in the library (taken on
    /// this Mac, imported, or arriving from iCloud) start a backup a minute
    /// after the last change. Nothing watches while it's off.
    private func updateWatcher() {
        let wanted = settings.automatic && serverID != nil && (access == .authorized || access == .limited)
        if wanted, libraryWatcher == nil {
            libraryWatcher = LibraryWatcher { [weak self] in self?.runIfAutomatic() }
        } else if !wanted {
            libraryWatcher = nil
        }
    }
    #endif

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
        guard settings.automatic, ProStore.unlocked, isReady, runner == nil, Self.conditionsAllow(settings, foreground: true) else { return }
        backUpNow()
    }

    /// Counts what's left to back up, without uploading anything.
    func check() async {
        guard isReady, runner == nil, let service = model?.service, let destination = settings.destination, let serverID else { return }
        if let plan = try? await makePlan(service: service, destination: destination, history: Self.loadHistory(serverID), shared: Self.loadManifest(destination, service: service).items) {
            waiting = Set(plan.jobs.map(\.assetID)).count
        }
    }

    func run(background: Bool) async {
        guard isReady, let service = model?.service, let destination = settings.destination, let serverID else { return }
        #if os(iOS)
        let keepAwake = !background
        if keepAwake { UIApplication.shared.isIdleTimerDisabled = true }
        let grace = background ? .invalid : UIApplication.shared.beginBackgroundTask(withName: "Photo Backup") { }
        defer {
            if keepAwake { UIApplication.shared.isIdleTimerDisabled = false }
            if grace != .invalid { UIApplication.shared.endBackgroundTask(grace) }
        }
        #else
        // Keeps the Mac from sleeping while you wait for Back Up Now; an
        // automatic run only asks not to be put in App Nap.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: background ? [.background] : [.userInitiated, .idleSystemSleepDisabled],
            reason: "Photo Backup"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        #endif
        phase = .scanning
        var history = Self.loadHistory(serverID)
        // iCloud items now on the NAS, for its shared list.
        var newShared: [String] = []
        do {
            let manifest = try await Self.loadManifest(destination, service: service)
            let plan = try await makePlan(service: service, destination: destination, history: history, shared: manifest.items)
            Self.log.notice("Backup plan: \(plan.jobs.count) to upload (\(plan.jobs.count { $0.checkExisting }) to compare), \(plan.alreadyThere.count) already there")
            history.formUnion(plan.alreadyThere)
            newShared += plan.sharedFound
            var uploaded = 0
            var existingByFolder: [String: [String: BackupPlanner.ExistingFile]] = [:]
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
                    if let there = existing[name.lowercased()]?.size, there == size {
                        history.insert(job.historyKey)
                        if let key = job.cloudKey { newShared.append(key) }
                        continue
                    }
                    name = RemoteItem.uniqueName(for: name, avoiding: Set(existing.keys))
                }
                do {
                    #if os(iOS)
                    try await service.uploadAllowingBackground(file, as: name, to: job.folder, replacing: false) { _ in }
                    #else
                    try await service.upload(file, as: name, to: job.folder, replacing: false) { _ in }
                    #endif
                } catch NASError.alreadyExists {
                    // Uploaded by another device meanwhile: leave it.
                }
                history.insert(job.historyKey)
                if let key = job.cloudKey { newShared.append(key) }
                uploaded += 1
                if uploaded % 10 == 0 { Self.saveHistory(history, serverID) }
                if newShared.count >= 200 {
                    await Self.addToManifest(newShared, destination, service: service)
                    newShared = []
                }
            }
            Self.saveHistory(history, serverID)
            await Self.addToManifest(newShared, destination, service: service)
            settings.lastBackup = .now
            waiting = 0
            phase = .finished(uploaded: uploaded)
            if uploaded > 0 { model?.folderChanged(destination) }
        } catch is CancellationError {
            Self.saveHistory(history, serverID)
            await Self.addToManifest(newShared, destination, service: service)
            phase = .idle
        } catch {
            Self.saveHistory(history, serverID)
            await Self.addToManifest(newShared, destination, service: service)
            Self.log.error("Backup failed: \(String(describing: error), privacy: .public)")
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "The backup stopped. Try again.")
        }
    }

    /// Why an automatic backup is waiting for the network, if it is.
    var networkWait: String? {
        guard settings.automatic, !NetworkPolicy.allows(.backups, automatic: true) else { return nil }
        return NetworkPolicy.waitingReason
    }

    /// Photo Backup used to have its own Only on Wi-Fi switch. Turned off, it
    /// becomes Settings › Cellular Data › Photo Backup on (once).
    private static func migrateWiFiOnly(_ data: Data) {
        let key = NetworkPolicy.Use.backups.key
        guard UserDefaults.standard.object(forKey: key) == nil,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["wifiOnly"] as? Bool == false else { return }
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: Planning

    private func makePlan(service: any FileService, destination: String, history: Set<String>, shared: Set<String>) async throws -> BackupPlanner.Plan {
        let assets = Self.libraryAssets(settings)
        // List each month folder once, to spot files already there.
        let folders = Set(assets.map { BackupPlanner.folder(for: $0.created, in: destination) })
        var existing: [String: [String: BackupPlanner.ExistingFile]] = [:]
        for folder in folders {
            try Task.checkCancellation()
            existing[folder] = try await Self.listing(folder, service: service)
        }
        return BackupPlanner.plan(assets, destination: destination, history: history, shared: shared, files: existing)
    }

    // MARK: The NAS's list of backed-up iCloud items

    /// Read at the start of each run. Missing (first backup, or a NAS
    /// backed up before this list existed) means empty.
    private static func loadManifest(_ destination: String, service: any FileService) async throws -> BackupManifest {
        try await storedManifest(destination, service: service).manifest
    }

    /// The list and the name it's stored under: it may still have its name
    /// from before the app was renamed, until it next changes.
    private static func storedManifest(_ destination: String, service: any FileService) async throws -> (manifest: BackupManifest, name: String?) {
        for name in [BackupManifest.fileName, BackupManifest.legacyFileName] {
            let item = RemoteItem(path: RemoteItem.join(destination, name), name: name, isDirectory: false)
            do {
                let file = try await service.download(item)
                defer { try? FileManager.default.removeItem(at: file) }
                return (BackupManifest.decode(try Data(contentsOf: file)), name)
            } catch NASError.notFound {
                continue
            }
        }
        return (BackupManifest(), nil)
    }

    /// Adds keys to the list, re-reading it first so another device's
    /// additions since this run started are kept. Failing here only means
    /// the next run compares names and dates instead.
    private static func addToManifest(_ keys: [String], _ destination: String, service: any FileService) async {
        guard !keys.isEmpty else { return }
        do {
            let stored = try await storedManifest(destination, service: service)
            var manifest = stored.manifest
            let before = manifest.items.count
            manifest.items.formUnion(keys)
            guard manifest.items.count != before else { return }
            let folder = FileManager.default.temporaryDirectory.appending(path: "Manifest-" + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: BackupManifest.fileName)
            try manifest.encoded().write(to: file)
            try await service.upload(file, as: BackupManifest.fileName, to: destination, replacing: true) { _ in }
            if stored.name == BackupManifest.legacyFileName {
                let name = BackupManifest.legacyFileName
                let legacy = RemoteItem(path: RemoteItem.join(destination, name), name: name, isDirectory: false)
                try? await service.delete([legacy])
            }
        } catch {
            log.error("Couldn't update the backup list: \(String(describing: error), privacy: .public)")
        }
    }

    private static func listing(_ folder: String, service: any FileService) async throws -> [String: BackupPlanner.ExistingFile] {
        do {
            var result: [String: BackupPlanner.ExistingFile] = [:]
            var offset = 0
            while true {
                let page = try await service.list(folder: folder, offset: offset, limit: 1000, sort: .name, ascending: true)
                for item in page.items where !item.isDirectory {
                    result[item.name.lowercased()] = BackupPlanner.ExistingFile(size: item.size, modified: item.modified)
                }
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
        // iCloud Photos identifiers, the same on every device using the
        // library. Items not in iCloud (or with iCloud Photos off) get none.
        var cloudIDs: [String: String] = [:]
        var localIDs: [String] = []
        localIDs.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in localIDs.append(asset.localIdentifier) }
        for start in stride(from: 0, to: localIDs.count, by: 500) {
            let batch = Array(localIDs[start..<min(start + 500, localIDs.count)])
            for (local, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: batch) {
                if case let .success(cloud) = result { cloudIDs[local] = cloud.archivalStringValue }
            }
        }
        fetched.enumerateObjects { asset, _, _ in
            let wanted: Set<PHAssetResourceType> = settings.includeLivePhotoVideos
                ? [.photo, .video, .alternatePhoto, .pairedVideo]
                : [.photo, .video, .alternatePhoto]
            let resources = PHAssetResource.assetResources(for: asset)
                .filter { wanted.contains($0.type) }
                .compactMap { $0.filename.map { BackupPlanner.Resource(name: $0, size: nil) } }
            guard !resources.isEmpty else { return }
            assets.append(.init(id: asset.localIdentifier, cloudID: cloudIDs[asset.localIdentifier], created: asset.creationDate, resources: resources))
        }
        return assets
    }

    /// Writes one original file to a temporary folder (downloading it from
    /// iCloud first if the device keeps only a smaller copy).
    private static func export(_ job: BackupPlanner.Job) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.filename == job.resource.name })
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
        #if os(iOS)
        if settings.chargingOnly, !foreground {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            if state != .charging, state != .full { return false }
        }
        #endif
        // Settings › Cellular Data › Photo Backup, and Low Data Mode.
        if !NetworkPolicy.allows(.backups, automatic: true) { return false }
        return true
    }

    #if os(iOS)
    static func scheduleBackground(_ settings: Settings) {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = settings.chargingOnly
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        let log = log
        BGTaskScheduler.shared.submitTaskRequest(request) { error in
            if let error {
                log.error("Couldn't schedule backup: \(String(describing: error), privacy: .public)")
            }
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
    #endif
}

#if os(macOS)
/// Tells Photo Backup when the Mac's photo library changes, a minute after
/// the last change (an import or an iCloud sync arrives in bursts).
@MainActor
private final class LibraryWatcher: NSObject, PHPhotoLibraryChangeObserver {
    private let changed: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.schedule() }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            changed()
        }
    }
}
#endif
