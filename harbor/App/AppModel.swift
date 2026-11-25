import Foundation
import OwnholdKit
import LocalAuthentication
import Observation
import SwiftUI

/// App-wide state: saved servers, the active connection, and settings.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case idle
        case connecting
        /// `nil` kind means the built-in demo library.
        case online(Endpoint.Kind?)
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

    /// Set when the active server needs a password (first use or expired session).
    var signInRequest: ServerProfile?
    /// Shows the Add NAS sheet (from the welcome screen or the server menu).
    var isAddingServer = false
    /// Set when a server presents a certificate the user must review.
    var certificateReview: CertificateReview?
    var banner: String?

    var isLocked = false
    var requireUnlock: Bool {
        didSet { defaults.set(requireUnlock, forKey: Keys.requireUnlock) }
    }
    var hideInSwitcher: Bool {
        didSet { defaults.set(hideInSwitcher, forKey: Keys.hideInSwitcher) }
    }

    let trust = CertificateTrust()
    private let keychain = Keychain()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let lastServer = "lastServerID"
        static let requireUnlock = "requireUnlock"
        static let hideInSwitcher = "hideInSwitcher"
    }

    init() {
        requireUnlock = defaults.bool(forKey: Keys.requireUnlock)
        hideInSwitcher = defaults.object(forKey: Keys.hideInSwitcher) as? Bool ?? true
        isLocked = requireUnlock
        servers = Self.loadServers()
        PreviewFiles.purge()
    }

    // MARK: Launch

    func start() async {
        guard activeServer == nil else { return }
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
        await service?.signOut()
        activeServer = profile
        defaults.set(profile.id.uuidString, forKey: Keys.lastServer)
        offline = OfflineStore(namespace: profile.id.uuidString)
        thumbnails = ThumbnailCache(namespace: profile.id.uuidString)
        savedPaths = await offline?.savedPaths() ?? []

        if profile.isDemo {
            service = DemoFileService()
            connection = .online(nil)
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
        let endpoint = try await resolve(profile)
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
        if profile.isDemo { activeServer = nil } else { signInRequest = profile }
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
        for endpoint in profile.endpoints {
            trust.forget(host: CertificateTrustKey.make(endpoint.url))
        }
        servers.removeAll { $0.id == profile.id }
        persistServers()
    }

    /// Saves edits to a server's name or addresses.
    func update(_ profile: ServerProfile) async {
        guard let old = servers.first(where: { $0.id == profile.id }) else { return }
        let oldKeys = old.endpoints.map { CertificateTrustKey.make($0.url) }
        let newKeys = profile.endpoints.map { CertificateTrustKey.make($0.url) }
        trust.extendPin(from: oldKeys, to: newKeys)
        for key in Set(oldKeys).subtracting(newKeys) { trust.forget(host: key) }
        save(profile)
        if activeServer?.id == profile.id {
            activeServer = profile
            if old.endpoints != profile.endpoints { await reconnect() }
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
        savedPaths = await offline.savedPaths()
    }

    func refreshOffline() async {
        guard let offline, let service, case .online = connection else { return }
        await offline.refresh(using: service)
        savedPaths = await offline.savedPaths()
    }

    /// A local copy for previewing: the offline file if saved, otherwise a
    /// temporary download that's deleted on next launch.
    func localCopy(of item: RemoteItem) async throws -> URL {
        if let url = await offline?.localURL(for: item.path) { return url }
        guard let service else { throw NASError.unreachable }
        let temporary = try await service.download(item)
        return try PreviewFiles.adopt(temporary, named: item.name)
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
        let addresses = activeServer?.endpoints.map { CertificateTrustKey.make($0.url) } ?? []
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
            let endpoint = try await resolve(profile)
            guard !session.sid.isEmpty else { throw NASError.sessionExpired }
            let client = FileStationClient(baseURL: endpoint.url, trust: trust, sid: session.sid)
            try await client.validateSession()
            service = client
            connection = .online(endpoint.kind)
            await refreshOffline()
        } catch {
            service = nil
            connection = .offline
            handle(error)
        }
    }

    private func resolve(_ profile: ServerProfile) async throws -> Endpoint {
        try await ConnectionResolver(trust: trust).resolve(profile.endpoints)
    }

    private func save(_ profile: ServerProfile) {
        if let index = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[index] = profile
        } else {
            servers.append(profile)
        }
        persistServers()
    }

    private func sessionKey(_ profile: ServerProfile) -> String { "session.\(profile.id.uuidString)" }

    private static var serversURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appending(path: "servers.json")
    }

    private static func loadServers() -> [ServerProfile] {
        (try? Data(contentsOf: serversURL)).flatMap { try? JSONDecoder().decode([ServerProfile].self, from: $0) } ?? []
    }

    private func persistServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: Self.serversURL, options: .atomic)
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
