import AppIntents
import Foundation
import OwnholdKit

// Shortcuts actions. The app model is registered with AppDependencyManager in
// OwnholdApp.init(), so these work on a cold launch from Siri or Shortcuts.
// Item IDs are "<NAS id>|<d or f>|<path>": saved shortcuts keep them, so the
// format must never change.

// MARK: Item

/// A folder or file on a saved NAS.
struct NASItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "NAS Item"
    static let defaultQuery = NASItemQuery()

    let id: String
    let name: String
    let serverName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(serverName)",
                              image: .init(systemName: isFolder ? "folder" : "doc"))
    }

    init(serverID: UUID, serverName: String, item: RemoteItem) {
        id = "\(serverID.uuidString)|\(item.isDirectory ? "d" : "f")|\(item.path)"
        name = item.name
        self.serverName = serverName
    }

    init?(id: String, serverName: String) {
        let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, UUID(uuidString: parts[0]) != nil, parts[1] == "d" || parts[1] == "f", parts[2].hasPrefix("/") else { return nil }
        self.id = id
        name = (parts[2] as NSString).lastPathComponent
        self.serverName = serverName
    }

    private var parts: [String] { id.split(separator: "|", maxSplits: 2).map(String.init) }
    var serverID: UUID? { UUID(uuidString: parts[0]) }
    var isFolder: Bool { parts[1] == "d" }
    var path: String { parts[2] }
    var remoteItem: RemoteItem { RemoteItem(path: path, name: name, isDirectory: isFolder, modified: nil) }
}

struct NASItemQuery: EntityStringQuery {
    @Dependency private var model: AppModel

    @MainActor
    func entities(for identifiers: [String]) async throws -> [NASItemEntity] {
        identifiers.compactMap { id in
            let serverName = UUID(uuidString: String(id.prefix(36))).flatMap { uuid in model.servers.first { $0.id == uuid }?.name } ?? "NAS"
            return NASItemEntity(id: id, serverName: serverName)
        }
    }

    /// Shared folders and the folders inside them, then Favorites and Recents.
    @MainActor
    func suggestedEntities() async throws -> [NASItemEntity] {
        await model.start()
        guard let profile = model.activeServer, let service = model.service else { return [] }
        let shares = (try? await service.listShares()) ?? []
        var items = shares
        for share in shares {
            let folders = (try? await service.list(folder: share.path, offset: 0, limit: 200, sort: .name, ascending: true).items) ?? []
            items += folders.filter { $0.isDirectory && !RecycleBin.contains($0.path) }
        }
        items += model.favorites + model.recents
        return Self.unique(items).map { NASItemEntity(serverID: profile.id, serverName: profile.name, item: $0) }
    }

    /// What's typed in the Shortcuts picker: a name search across the shared
    /// folders (File Station search), up to 60 results, folders first.
    @MainActor
    func entities(matching string: String) async throws -> [NASItemEntity] {
        let text = string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return try await suggestedEntities() }
        await model.start()
        guard let profile = model.activeServer, let service = model.service else { return [] }
        let shares = (try? await service.listShares()) ?? []
        var found = shares.filter { $0.name.localizedCaseInsensitiveContains(text) }
        for share in shares where found.count < 60 {
            let results = (try? await service.search(in: share.path, matching: text)) ?? []
            found += results.filter { !RecycleBin.contains($0.path) }
        }
        let sorted = Self.unique(found).sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        return sorted.prefix(60).map { NASItemEntity(serverID: profile.id, serverName: profile.name, item: $0) }
    }

    private static func unique(_ items: [RemoteItem]) -> [RemoteItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }
    }
}

// MARK: Errors

enum OwnholdIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConnected
    case notAFolder
    case shareLinkFailed
    case cantWake
    case backupNotSetUp

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "Ownhold can't reach your NAS. Check that you're on your home network or VPN."
        case .notAFolder: "Choose a folder to upload to."
        case .shareLinkFailed: "Ownhold couldn't create a share link."
        case .cantWake: "Wake NAS needs the NAS's MAC address. Add it in Settings › Edit NAS."
        case .backupNotSetUp: "Set up backup in Ownhold first."
        }
    }
}

extension AppModel {
    /// Connects (or switches) to the NAS an action needs.
    func serviceForIntent(serverID: UUID?) async throws -> any FileService {
        await start()
        if let serverID, activeServer?.id != serverID, let profile = servers.first(where: { $0.id == serverID }) {
            await activate(profile)
        }
        guard let service else { throw OwnholdIntentError.notConnected }
        return service
    }
}

// MARK: Actions

struct UploadFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Upload Files to NAS"
    static let description = IntentDescription("Uploads files to a folder on your NAS. Files with the same name are kept as copies.")

    @Parameter(title: "Files", supportedContentTypes: [.item]) var files: [IntentFile]
    @Parameter(title: "Folder") var folder: NASItemEntity
    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Upload \(\.$files) to \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard folder.isFolder else { throw OwnholdIntentError.notAFolder }
        let service = try await model.serviceForIntent(serverID: folder.serverID)
        let staging = FileManager.default.temporaryDirectory.appending(path: "Shortcuts-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var taken = Set(((try? await service.list(folder: folder.path, offset: 0, limit: 5000, sort: .name, ascending: true).items) ?? []).map { $0.name.lowercased() })
        for file in files {
            let name = RemoteItem.uniqueName(for: file.filename, avoiding: taken)
            let local = staging.appending(path: name)
            try file.data.write(to: local)
            try await service.upload(local, as: name, to: folder.path, replacing: false) { _ in }
            taken.insert(name.lowercased())
        }
        model.folderChanged(folder.path)
        return .result(dialog: files.count == 1 ? "Uploaded 1 file to \(folder.name)." : "Uploaded \(files.count) files to \(folder.name).")
    }
}

struct GetShareLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Share Link"
    static let description = IntentDescription("Creates a share link for a file or folder on your NAS.")

    @Parameter(title: "Item") var item: NASItemEntity
    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Get a share link for \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<URL> {
        _ = try await model.serviceForIntent(serverID: item.serverID)
        guard let link = await model.createShareLink(for: item.remoteItem, password: nil, expires: nil) else {
            throw OwnholdIntentError.shareLinkFailed
        }
        return .result(value: link.url)
    }
}

struct OpenInOwnholdIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open in Ownhold"
    static let description = IntentDescription("Opens a folder in Ownhold (for a file, the folder it's in).")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Item") var target: NASItemEntity
    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await model.serviceForIntent(serverID: target.serverID)
        let folder = target.isFolder ? target.remoteItem
            : RemoteItem(path: (target.path as NSString).deletingLastPathComponent,
                         name: ((target.path as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                         isDirectory: true, modified: nil)
        model.navigationRequest = .favorite(folder)
        return .result()
    }
}

struct WakeNASIntent: AppIntent {
    static let title: LocalizedStringResource = "Wake NAS"
    static let description = IntentDescription("Wakes the NAS you use in Ownhold. Works on your home network.")

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.start()
        guard model.canWake else { throw OwnholdIntentError.cantWake }
        await model.wakeNAS()
        if case .online = model.connection { return .result(dialog: "Your NAS is awake.") }
        return .result(dialog: "Ownhold woke your NAS but it hasn't answered yet.")
    }
}

struct BackUpNowIntent: AppIntent {
    #if os(iOS)
    static let title: LocalizedStringResource = "Back Up Photos Now"
    static let description = IntentDescription("Starts Photo Backup in Ownhold.")
    // Photo Backup runs in the app, so bring it forward.
    static var supportedModes: IntentModes { .foreground }
    #else
    static let title: LocalizedStringResource = "Back Up Folders Now"
    static let description = IntentDescription("Starts Folder Backup in Ownhold.")
    #endif

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await model.serviceForIntent(serverID: nil)
        #if os(iOS)
        guard model.backup.isReady else { throw OwnholdIntentError.backupNotSetUp }
        model.backup.backUpNow()
        #else
        guard model.folderBackup.isReady else { throw OwnholdIntentError.backupNotSetUp }
        model.folderBackup.backUpNow()
        #endif
        return .result(dialog: "Backup started.")
    }
}

// MARK: Siri and Spotlight

struct OwnholdShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WakeNASIntent(), phrases: [
            "Wake my NAS with \(.applicationName)",
            "\(.applicationName) wake NAS",
        ], shortTitle: "Wake NAS", systemImageName: "power")
        AppShortcut(intent: BackUpNowIntent(), phrases: [
            "Back up now with \(.applicationName)",
            "\(.applicationName) back up",
        ], shortTitle: "Back Up Now", systemImageName: "clock.arrow.circlepath")
        AppShortcut(intent: UploadFilesIntent(), phrases: [
            "Upload to my NAS with \(.applicationName)",
        ], shortTitle: "Upload to NAS", systemImageName: "square.and.arrow.up")
    }
}
