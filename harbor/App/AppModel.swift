import FileProvider
import Foundation
import OwnholdKit
import LocalAuthentication
import Observation
import os
import SwiftUI

/// App-wide state: saved servers, the active connection, and settings.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case idle
        case connecting
        /// The address in use; `nil` means the built-in demo library.
        case online(Endpoint?)
        /// Server unreachable: offline files still work.
        case offline
    }

    private(set) var servers: [ServerProfile] = []
    private(set) var activeServer: ServerProfile?
    private(set) var connection: Connection = .idle
    private(set) var service: (any FileService)?
    private(set) var offline: OfflineStore?
    private(set) var thumbnails: ThumbnailCache?
    private(set) var savedPaths: Set<String> = []
    /// Offline files, newest first (the Mac menu bar lists the most recent).
    private(set) var offlineEntries: [OfflineEntry] = []
    /// Set from outside the main window (the Mac menu bar) to show a share
    /// or the Offline list there.
    var navigationRequest: SidebarItem?
    /// Bumped when a folder's contents change, so open folder views reload.
    private(set) var folderRevisions: [String: Int] = [:]
    /// Uploads the user started. Runs only while the app is open.
    @ObservationIgnored private(set) lazy var uploads = UploadQueue(model: self)

    /// Set when the active server needs a password (first use or expired session).
    var signInRequest: ServerProfile?
    /// Shows the Add NAS sheet (from the welcome screen or the server menu).
    var isAddingServer = false
    /// Set when a server presents a certificate the user must review.
    var certificateReview: CertificateReview?
    var banner: String?

    var isLocked = false
    var requireUnlock: Bool {
        didSet {
            defaults.set(requireUnlock, forKey: Keys.requireUnlock)
            SharedConnection.requiresUnlock = requireUnlock
            Task { await syncFilesApp() }
        }
    }
    /// Settings › Privacy › Show NAS in Files App. Off unless turned on, and
    /// off while the app lock is on (the Files app can't ask for Face ID).
    var showInFilesApp: Bool {
        didSet {
            SharedContainer.isFilesAppEnabled = showInFilesApp
            Task { await syncFilesApp() }
        }
    }
    var hideInSwitcher: Bool {
        didSet { defaults.set(hideInSwitcher, forKey: Keys.hideInSwitcher) }
    }

    @ObservationIgnored private var started = false
    private static let log = Logger(subsystem: "app.ownhold.Ownhold", category: "files-app")
    /// Shared with the Files app extension (see SharedContainer).
    private let keychain = SharedContainer.keychain
    let trust = CertificateTrust(keychain: SharedContainer.keychain)
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let lastServer = "lastServerID"
        static let requireUnlock = "requireUnlock"
        static let hideInSwitcher = "hideInSwitcher"
    }

    init() {
        requireUnlock = defaults.bool(forKey: Keys.requireUnlock)
        showInFilesApp = SharedContainer.isFilesAppEnabled
        hideInSwitcher = defaults.object(forKey: Keys.hideInSwitcher) as? Bool ?? true
        isLocked = requireUnlock
        servers = SharedContainer.loadServers()
        PreviewFiles.purge()
        SharedConnection.requiresUnlock = requireUnlock
        UploadQueue.purgeStaging()
    }

    // MARK: Launch

    /// Called by both the main window and the Mac menu bar item; runs once.
    func start() async {
        guard !started, activeServer == nil else { return }
        started = true
        await syncFilesApp()
        #if DEBUG
        // `-demo` opens the demo library directly: used for screenshots.
        if CommandLine.arguments.contains("-demo") {
            await startDemo()
            return
        }
        #endif
        let lastID = defaults.string(forKey: Keys.lastServer).flatMap(UUID.init)
        if let profile = servers.first(where: { $0.id == lastID }) ?? servers.first {
            await activate(profile)
        }
    }

    // MARK: Servers

    func activate(_ profile: ServerProfile) async {
        var profile = profile
        #if DEBUG
        // `-demoName "…"` renames the demo NAS: used to test long names.
        if profile.isDemo, let name = UserDefaults.standard.string(forKey: "demoName") { profile.name = name }
        #endif
        await service?.signOut()
        activeServer = profile
        defaults.set(profile.id.uuidString, forKey: Keys.lastServer)
        offline = OfflineStore(namespace: profile.id.uuidString)
        thumbnails = ThumbnailCache(namespace: profile.id.uuidString)
        await refreshSaved()

        if profile.isDemo {
            service = DemoFileService()
            connection = .online(nil)
            await syncFilesApp()
            return
        }
        guard let session = keychain.codable(Session.self, for: sessionKey(profile)) else {
            service = nil
            connection = .idle
            signInRequest = profile
            return
        }
        await connect(profile, session: session)
    }

    func startDemo() async {
        await activate(.demo)
    }

    /// Signs in with a password, saving the server on success.
    func signIn(to profile: ServerProfile, credentials: Credentials, rememberDevice: Bool) async throws {
        let (endpoint, profile) = try await resolve(profile)
        let client = FileStationClient(baseURL: endpoint.url, trust: trust)
        let previous = keychain.codable(Session.self, for: sessionKey(profile))
        let session = try await client.signIn(
            credentials,
            deviceName: Platform.deviceName,
            deviceToken: previous?.deviceToken,
            rememberDevice: rememberDevice
        )
        keychain.setCodable(session, for: sessionKey(profile))
        save(profile)
        signInRequest = nil
        await activate(profile)
    }

    func signOut() async {
        guard let profile = activeServer else { return }
        await service?.signOut()
        // Keep the device token so 2-factor isn't asked again on this device.
        if let session = keychain.codable(Session.self, for: sessionKey(profile)), let token = session.deviceToken {
            keychain.setCodable(Session(sid: "", deviceToken: token), for: sessionKey(profile))
        } else {
            keychain.remove(sessionKey(profile))
        }
        service = nil
        connection = .idle
        if profile.isDemo {
            activeServer = nil
            await syncFilesApp()
        } else {
            signInRequest = profile
        }
    }

    func remove(_ profile: ServerProfile) async {
        if activeServer?.id == profile.id {
            await service?.signOut()
            activeServer = nil
            service = nil
            connection = .idle
        }
        await OfflineStore(namespace: profile.id.uuidString).removeAll()
        await ThumbnailCache(namespace: profile.id.uuidString).removeAll()
        keychain.remove(sessionKey(profile))
        for endpoint in profile.allEndpoints {
            trust.forget(host: CertificateTrustKey.make(endpoint.url))
        }
        servers.removeAll { $0.id == profile.id }
        persistServers()
        await syncFilesApp()
    }

    /// Saves edits to a server's name or addresses.
    func update(_ profile: ServerProfile) async {
        var profile = profile
        guard let old = servers.first(where: { $0.id == profile.id }) else { return }
        // A different QuickConnect ID means the old lookup results don't apply.
        if old.quickConnectID != profile.quickConnectID { profile.discoveredEndpoints = [] }
        let oldKeys = old.endpoints.map { CertificateTrustKey.make($0.url) }
        let newKeys = profile.endpoints.map { CertificateTrustKey.make($0.url) }
        trust.extendPin(from: oldKeys, to: newKeys)
        for key in Set(oldKeys).subtracting(newKeys) { trust.forget(host: key) }
        save(profile)
        if activeServer?.id == profile.id {
            activeServer = profile
            if old.endpoints != profile.endpoints || old.quickConnectID != profile.quickConnectID { await reconnect() }
        }
    }

    func reconnect() async {
        guard let profile = activeServer else { return }
        await activate(profile)
    }

    // MARK: Offline

    func toggleOffline(_ item: RemoteItem) async {
        guard let offline, let service else { return }
        if savedPaths.contains(item.path) {
            await offline.remove(item.path)
        } else {
            do {
                let count = try await offline.save(item, using: service)
                Haptics.success()
                banner = count == 1 ? "Saved for offline use" : "Saved \(count) files for offline use"
            } catch {
                banner = (error as? LocalizedError)?.errorDescription ?? "Couldn't save for offline use."
            }
        }
        await refreshSaved()
    }

    func refreshOffline() async {
        guard let offline, let service, case .online = connection else { return }
        await offline.refresh(using: service)
        await refreshSaved()
    }

    /// A local copy for previewing: the offline file if saved, otherwise a
    /// temporary download that's deleted on next launch.
    func localCopy(of item: RemoteItem) async throws -> URL {
        if let url = await offline?.localURL(for: item.path) { return url }
        guard let service else { throw NASError.unreachable }
        let temporary = try await service.download(item)
        return try PreviewFiles.adopt(temporary, named: item.name)
    }

    /// Local copies ready for the share sheet: files as they are (offline
    /// copies if saved), folders as zips made by the NAS.
    func shareableCopies(of items: [RemoteItem]) async throws -> [URL] {
        var urls: [URL] = []
        for item in items {
            try Task.checkCancellation()
            if item.isDirectory {
                guard let service else { throw NASError.unreachable }
                let zip = try await service.download(item)
                urls.append(try PreviewFiles.adopt(zip, named: item.name + ".zip"))
            } else {
                urls.append(try await localCopy(of: item))
            }
        }
        return urls
    }

    private func refreshSaved() async {
        let entries = await offline?.all() ?? []
        savedPaths = Set(entries.map(\.item.path))
        offlineEntries = entries.sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: Changes

    func revision(of folder: String) -> Int { folderRevisions[folder] ?? 0 }

    func folderChanged(_ folders: String...) {
        for folder in Set(folders) { folderRevisions[folder, default: 0] += 1 }
    }

    @discardableResult
    func createFolder(named name: String, in parent: String) async -> RemoteItem? {
        guard let service else { return nil }
        do {
            let folder = try await service.createFolder(named: name.trimmingCharacters(in: .whitespaces), in: parent)
            folderChanged(parent)
            return folder
        } catch {
            handle(error)
            return nil
        }
    }

    func rename(_ item: RemoteItem, to name: String) async {
        guard let service, name != item.name else { return }
        do {
            let renamed = try await service.rename(item, to: name.trimmingCharacters(in: .whitespaces))
            await offline?.relocate(from: item.path, to: renamed.path)
            await refreshSaved()
            folderChanged(item.parentPath)
        } catch {
            handle(error)
        }
    }

    /// Returns false if nothing moved, so the caller can keep its selection.
    @discardableResult
    func move(_ items: [RemoteItem], to folder: String) async -> Bool {
        let items = items.filter { $0.parentPath != folder }
        guard let service, !items.isEmpty else { return false }
        do {
            try await service.move(items, to: folder)
            for item in items {
                await offline?.relocate(from: item.path, to: RemoteItem.join(folder, item.name))
            }
            await refreshSaved()
            for parent in Set(items.map(\.parentPath)) { folderChanged(parent) }
            folderChanged(folder)
            Haptics.success()
            return true
        } catch {
            // Some items may have moved before the error.
            for parent in Set(items.map(\.parentPath)) { folderChanged(parent) }
            folderChanged(folder)
            handle(error)
            return false
        }
    }

    @discardableResult
    func delete(_ items: [RemoteItem]) async -> Bool {
        guard let service, !items.isEmpty else { return false }
        defer { for parent in Set(items.map(\.parentPath)) { folderChanged(parent) } }
        do {
            try await service.delete(items)
            // The offline copies would be dropped at the next refresh anyway.
            for item in items { await offline?.remove(item.path) }
            await refreshSaved()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: Errors

    /// Central handling for errors from any screen.
    func handle(_ error: Error) {
        guard let error = error as? NASError else { return }
        switch error {
        case .sessionExpired:
            if let profile = activeServer { signInRequest = profile }
        case let .untrustedCertificate(info):
            certificateReview = CertificateReview(info: info, changed: false)
        case let .certificateChanged(info):
            certificateReview = CertificateReview(info: info, changed: true)
        case .unreachable:
            if activeServer?.isDemo == false { connection = .offline }
        default:
            banner = error.errorDescription
        }
    }

    func trustCertificate(_ review: CertificateReview) async {
        let addresses = activeServer?.allEndpoints.map { CertificateTrustKey.make($0.url) } ?? []
        trust.trust(review.info, alsoFor: addresses)
        certificateReview = nil
        await reconnect()
    }

    // MARK: Lock

    func unlock() async {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        do {
            // Falls back to the device passcode if Face ID / Touch ID fails.
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Ownhold") {
                isLocked = false
            }
        } catch {
            isLocked = true
        }
    }

    func lockIfNeeded() {
        if requireUnlock { isLocked = true }
    }

    // MARK: Private

    private func connect(_ profile: ServerProfile, session: Session) async {
        connection = .connecting
        do {
            let (endpoint, updated) = try await resolve(profile)
            if updated != profile {
                save(updated)
                if activeServer?.id == updated.id { activeServer = updated }
            }
            guard !session.sid.isEmpty else { throw NASError.sessionExpired }
            let client = FileStationClient(baseURL: endpoint.url, trust: trust, sid: session.sid)
            try await client.validateSession()
            service = client
            connection = .online(endpoint)
            await refreshOffline()
        } catch {
            service = nil
            connection = .offline
            handle(error)
        }
    }

    /// Refreshes the NAS's QuickConnect addresses (if it has an ID), then
    /// picks the best address that answers. Returns the profile with any
    /// newly discovered addresses, for saving.
    private func resolve(_ profile: ServerProfile) async throws -> (Endpoint, ServerProfile) {
        var profile = profile
        if let id = profile.quickConnectID, !id.isEmpty {
            do {
                profile.discoveredEndpoints = try await QuickConnectLookup().endpoints(for: id)
            } catch {
                // Lookup failed: carry on with saved and last-known addresses,
                // unless there's nothing else to try.
                if profile.allEndpoints.isEmpty { throw error }
            }
        }
        // A certificate trusted at any of this NAS's addresses covers the
        // others too. Pinning only narrows what each address may present, so
        // a wrong lookup answer can't redirect the app to another server.
        let keys = profile.allEndpoints.map { CertificateTrustKey.make($0.url) }
        trust.extendPin(from: keys, to: keys)
        let endpoint = try await ConnectionResolver(trust: trust).resolve(profile.allEndpoints)
        return (endpoint, profile)
    }

    private func save(_ profile: ServerProfile) {
        if let index = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[index] = profile
        } else {
            servers.append(profile)
        }
        persistServers()
        Task { await syncFilesApp() }
    }

    // MARK: Files app

    /// Adds a Files app location for each NAS (and the demo library while
    /// it's open) when the switch is on, and removes them when it's off.
    /// Removing one also makes the system delete every file it cached for it.
    func syncFilesApp() async {
        let enabled = showInFilesApp && !requireUnlock
        var wanted: [NSFileProviderDomain] = []
        if enabled {
            wanted = servers.map { NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier($0.id.uuidString), displayName: $0.name) }
            if activeServer?.isDemo == true {
                wanted.append(NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("demo"), displayName: "Ownhold Demo"))
            }
        }
        guard enabled else {
            // Off: remove every Ownhold location, including any the system
            // made on its own, along with everything it cached.
            do { try await NSFileProviderManager.removeAllDomains() } catch { Self.log.error("Files app: remove all failed: \(error)") }
            return
        }
        let existing = (try? await NSFileProviderManager.domains()) ?? []
        let wantedIDs = Set(wanted.map(\.identifier))
        for domain in existing where !wantedIDs.contains(domain.identifier) {
            do { try await NSFileProviderManager.remove(domain) } catch { Self.log.error("Files app: remove failed: \(error)") }
        }
        for domain in wanted {
            // Adding again updates the name if the NAS was renamed.
            do { try await NSFileProviderManager.add(domain) } catch { Self.log.error("Files app: add failed: \(error)") }
        }
    }

    private func sessionKey(_ profile: ServerProfile) -> String { SharedContainer.sessionKey(profile.id) }

    private func persistServers() {
        SharedContainer.saveServers(servers)
    }
}

struct CertificateReview: Identifiable, Equatable {
    var id: String { info.fingerprint }
    let info: CertificateInfo
    let changed: Bool
}

enum CertificateTrustKey {
    static func make(_ url: URL) -> String {
        "\(url.host() ?? ""):\(url.port ?? 443)"
    }
}

/// Temporary downloads used for previews. Cleared at every launch.
enum PreviewFiles {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Previews", directoryHint: .isDirectory)
    }

    static func purge() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Moves a download into a per-file folder so it keeps its real name
    /// (QuickLook and the share sheet use it).
    static func adopt(_ temporary: URL, named name: String) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
