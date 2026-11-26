#if os(macOS)
import CoreServices
import Foundation
import Observation
import os
import OwnholdKit

/// Folder Backup (Mac): copies chosen Mac folders to a folder on the NAS,
/// keeping their structure. New and changed files are copied; nothing is
/// ever deleted on the NAS, so a file removed here stays backed up there.
///
/// It runs when asked (Back Up Now) and, with Back Up When Files Change on,
/// a minute after files in those folders change while Ownhold is running
/// (the menu bar keeps it running with the window closed). Never in Low
/// Power Mode. Each NAS has its own folders and destination.
@MainActor
@Observable
final class FolderBackup {
    struct Source: Codable, Identifiable, Equatable {
        var id = UUID()
        /// Security-scoped bookmark: the sandbox's permission to read the folder.
        var bookmark: Data
        var name: String
        var path: String
    }

    struct Settings: Codable, Equatable {
        var sources: [Source] = []
        var destination: String?
        var automatic = false
        var lastBackup: Date?
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case uploading(done: Int, total: Int, current: String)
        case finished(uploaded: Int)
        case failed(String)
    }

    private static let log = Logger(subsystem: "app.ownhold.Ownhold", category: "folder-backup")
    /// Wait this long after the last change before copying, so a burst of
    /// saves becomes one backup.
    private static let settleDelay: Duration = .seconds(60)

    var settings = Settings() {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            if settings.sources != oldValue.sources || settings.automatic != oldValue.automatic { updateWatcher() }
        }
    }
    private(set) var phase: Phase = .idle
    /// Files not backed up yet, from the last check (nil before one).
    private(set) var waiting: Int?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var serverID: UUID?
    @ObservationIgnored private var watcher: FolderWatcher?

    init(model: AppModel) { self.model = model }

    var isRunning: Bool { runner != nil }
    var isReady: Bool { settings.destination != nil && !settings.sources.isEmpty }

    /// Why automatic backups are waiting (on a Personal Hotspot, or in Low
    /// Data Mode), if they are.
    var networkWait: String? {
        guard settings.automatic, !NetworkPolicy.allows(.backups, automatic: true) else { return nil }
        return NetworkPolicy.waitingReason
    }

    /// The NAS folder each source goes into, in order.
    var folderNames: [String] { FolderBackupPlanner.folderNames(settings.sources.map(\.name)) }

    // MARK: Server

    func load(for profile: ServerProfile?) {
        cancel()
        serverID = profile?.id
        phase = .idle
        waiting = nil
        if let id = profile?.id, let data = UserDefaults.standard.data(forKey: Self.settingsKey(id)),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
        updateWatcher()
    }

    func forget(_ profile: ServerProfile) {
        UserDefaults.standard.removeObject(forKey: Self.settingsKey(profile.id))
        try? FileManager.default.removeItem(at: Self.historyFolder(profile.id))
    }

    private func saveSettings() {
        guard let serverID else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey(serverID))
    }

    // MARK: Folders

    /// Adds Mac folders the user picked (an Open panel grants the access).
    func add(_ urls: [URL]) {
        for url in urls where !settings.sources.contains(where: { $0.path == url.path(percentEncoded: false) }) {
            guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            settings.sources.append(Source(bookmark: bookmark, name: url.lastPathComponent, path: url.path(percentEncoded: false)))
        }
        waiting = nil
    }

    func remove(_ source: Source) {
        guard let serverID else { return }
        settings.sources.removeAll { $0.id == source.id }
        try? FileManager.default.removeItem(at: Self.historyURL(serverID, source.id))
        waiting = nil
    }

    /// A new destination starts a fresh record, so everything is copied there.
    func setDestination(_ path: String) {
        guard path != settings.destination, let serverID else { return }
        try? FileManager.default.removeItem(at: Self.historyFolder(serverID))
        settings.destination = path
        settings.lastBackup = nil
        waiting = nil
    }

    // MARK: Running

    func backUpNow() {
        guard runner == nil else { return }
        pending?.cancel()
        runner = Task {
            await run()
            runner = nil
        }
    }

    func cancel() {
        pending?.cancel()
        runner?.cancel()
    }

    /// With Back Up When Files Change on: catch up after connecting.
    func runIfAutomatic() {
        guard settings.automatic, ProStore.unlocked, isReady, runner == nil, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              NetworkPolicy.allows(.backups, automatic: true) else { return }
        backUpNow()
    }

    /// Counts what's left to copy, without copying anything.
    func check() async {
        guard isReady, runner == nil, let serverID else { return }
        var count = 0
        for source in settings.sources {
            guard let url = Self.resolve(source) else { continue }
            let files = await Self.scan(url)
            count += FolderBackupPlanner.changed(files, history: Self.loadHistory(serverID, source.id)).count
        }
        waiting = count
    }

    private func run() async {
        guard isReady, let service = model?.service, let destination = settings.destination, let serverID else { return }
        phase = .scanning
        do {
            // Plan every folder first, so progress counts all files.
            var jobs: [(source: Source, folderName: String, root: URL, file: FolderBackupPlanner.LocalFile)] = []
            var roots: [URL] = []
            defer { roots.forEach { $0.stopAccessingSecurityScopedResource() } }
            for (source, folderName) in zip(settings.sources, folderNames) {
                guard let url = Self.resolve(source) else {
                    throw BackupError.folderUnavailable(source.name)
                }
                if url.startAccessingSecurityScopedResource() { roots.append(url) }
                let files = await Self.scan(url)
                let changed = FolderBackupPlanner.changed(files, history: Self.loadHistory(serverID, source.id))
                jobs += changed.map { (source, folderName, url, $0) }
            }
            var histories: [UUID: [String: String]] = [:]
            var uploaded = 0
            for (index, job) in jobs.enumerated() {
                try Task.checkCancellation()
                let location = FolderBackupPlanner.remoteLocation(of: job.file, folderName: job.folderName, destination: destination)
                phase = .uploading(done: index, total: jobs.count, current: location.name)
                let local = job.root.appending(path: job.file.relativePath)
                guard RemoteItem.isValidName(location.name) else { continue }
                do {
                    // The NAS creates missing folders on the way.
                    try await service.upload(local, as: location.name, to: location.folder, replacing: true) { _ in }
                } catch let error as NASError where error == .notFound {
                    continue // removed while backing up
                }
                if histories[job.source.id] == nil { histories[job.source.id] = Self.loadHistory(serverID, job.source.id) }
                histories[job.source.id]?[job.file.relativePath] = job.file.signature
                uploaded += 1
                if uploaded % 20 == 0 { Self.save(histories, serverID) }
            }
            Self.save(histories, serverID)
            settings.lastBackup = .now
            waiting = 0
            phase = .finished(uploaded: uploaded)
            if uploaded > 0 { model?.folderChanged(destination) }
        } catch is CancellationError {
            phase = .idle
        } catch {
            Self.log.error("Folder backup failed: \(String(describing: error), privacy: .public)")
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "The backup stopped. Try again.")
        }
    }

    enum BackupError: LocalizedError {
        case folderUnavailable(String)
        var errorDescription: String? {
            switch self {
            case let .folderUnavailable(name): "Can't open “\(name)” on this Mac. Remove it and add it again."
            }
        }
    }

    // MARK: Watching for changes

    private func updateWatcher() {
        watcher?.stop()
        watcher = nil
        guard settings.automatic, !settings.sources.isEmpty else { return }
        let urls = settings.sources.compactMap(Self.resolve)
        watcher = FolderWatcher(urls: urls) { [weak self] in self?.filesChanged() }
    }

    private func filesChanged() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, model?.service != nil else { return }
            runIfAutomatic()
        }
    }

    // MARK: Files on this Mac

    private static func resolve(_ source: Source) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: source.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Every file in a folder, skipping clutter, hidden files and anything
    /// that isn't a regular file (aliases, symbolic links).
    private static func scan(_ root: URL) async -> [FolderBackupPlanner.LocalFile] {
        await Task.detached(priority: .utility) {
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
            let base = root.standardizedFileURL.path(percentEncoded: false)
            var files: [FolderBackupPlanner.LocalFile] = []
            while let url = walker.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if FolderBackupPlanner.shouldSkip(name: values.name ?? url.lastPathComponent) {
                    if values.isRegularFile != true { walker.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                var relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))
                while relative.hasPrefix("/") { relative.removeFirst() }
                files.append(.init(relativePath: relative, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            }
            return files
        }.value
    }

    // MARK: Record of what's backed up (on this Mac only)

    private static func settingsKey(_ id: UUID) -> String { "folderBackup.\(id.uuidString)" }

    private static func historyFolder(_ server: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FolderBackup", directoryHint: .isDirectory)
            .appending(path: server.uuidString, directoryHint: .isDirectory)
    }

    private static func historyURL(_ server: UUID, _ source: UUID) -> URL {
        historyFolder(server).appending(path: source.uuidString + ".json")
    }

    private static func loadHistory(_ server: UUID, _ source: UUID) -> [String: String] {
        (try? Data(contentsOf: historyURL(server, source))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private static func save(_ histories: [UUID: [String: String]], _ server: UUID) {
        try? FileManager.default.createDirectory(at: historyFolder(server), withIntermediateDirectories: true)
        for (source, history) in histories {
            try? JSONEncoder().encode(history).write(to: historyURL(server, source), options: .atomic)
        }
    }
}

/// Calls back on the main thread when anything inside the folders changes
/// (FSEvents, batched by the system every 30 seconds).
@MainActor
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let urls: [URL]
    private let onChange: @MainActor () -> Void

    init(urls: [URL], onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        // Watching needs the folders' sandbox access for as long as it runs.
        self.urls = urls.filter { $0.startAccessingSecurityScopedResource() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        let paths = self.urls.map { $0.path(percentEncoded: false) } as CFArray
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 30,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
#endif
