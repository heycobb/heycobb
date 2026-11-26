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
        identifiers.compactMap { NASItemEntity(id: $0, serverName: model.serverName(forItemID: $0)) }
    }

    @MainActor
    func suggestedEntities() async throws -> [NASItemEntity] {
        await NASItemSearch.suggested(model: model, foldersOnly: false)
    }

    @MainActor
    func entities(matching string: String) async throws -> [NASItemEntity] {
        await NASItemSearch.matching(string, model: model, foldersOnly: false)
    }
}

/// A folder on a saved NAS: what Upload Files to NAS needs, so its picker
/// lists folders only. Same ID format as `NASItemEntity`.
struct NASFolderEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "NAS Folder"
    static let defaultQuery = NASFolderQuery()

    let item: NASItemEntity
    var id: String { item.id }

    var displayRepresentation: DisplayRepresentation { item.displayRepresentation }

    init(_ item: NASItemEntity) { self.item = item }
}

struct NASFolderQuery: EntityStringQuery {
    @Dependency private var model: AppModel

    @MainActor
    func entities(for identifiers: [String]) async throws -> [NASFolderEntity] {
        identifiers.compactMap { NASItemEntity(id: $0, serverName: model.serverName(forItemID: $0)) }
            .filter(\.isFolder).map(NASFolderEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [NASFolderEntity] {
        await NASItemSearch.suggested(model: model, foldersOnly: true).map(NASFolderEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [NASFolderEntity] {
        await NASItemSearch.matching(string, model: model, foldersOnly: true).map(NASFolderEntity.init)
    }
}

/// Suggestions and name search for both pickers.
@MainActor
enum NASItemSearch {
    /// Shared folders and the folders inside them, then Favorites and Recents.
    static func suggested(model: AppModel, foldersOnly: Bool) async -> [NASItemEntity] {
        await model.start()
        guard let profile = model.activeServer, let service = model.service else { return [] }
        let shares = (try? await service.listShares()) ?? []
        var items = shares
        for share in shares {
            let folders = (try? await service.list(folder: share.path, offset: 0, limit: 200, sort: .name, ascending: true).items) ?? []
            items += folders.filter { $0.isDirectory && !RecycleBin.contains($0.path) }
        }
        items += model.favorites + model.recents
        return entities(unique(items), foldersOnly: foldersOnly, profile: profile)
    }

    /// A File Station name search across the shared folders, up to 60
    /// results, folders first, without Recycle Bins.
    static func matching(_ string: String, model: AppModel, foldersOnly: Bool) async -> [NASItemEntity] {
        let text = string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return await suggested(model: model, foldersOnly: foldersOnly) }
        await model.start()
        guard let profile = model.activeServer, let service = model.service else { return [] }
        let shares = (try? await service.listShares()) ?? []
        var found = shares.filter { $0.name.localizedCaseInsensitiveContains(text) }
        for share in shares where found.count < 60 {
            let results = (try? await service.search(in: share.path, matching: text)) ?? []
            found += results.filter { !RecycleBin.contains($0.path) && (!foldersOnly || $0.isDirectory) }
        }
        let sorted = unique(found).sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        return entities(Array(sorted.prefix(60)), foldersOnly: foldersOnly, profile: profile)
    }

    private static func entities(_ items: [RemoteItem], foldersOnly: Bool, profile: ServerProfile) -> [NASItemEntity] {
        items.filter { !foldersOnly || $0.isDirectory }
            .map { NASItemEntity(serverID: profile.id, serverName: profile.name, item: $0) }
    }

    private static func unique(_ items: [RemoteItem]) -> [RemoteItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }
    }
}

extension AppModel {
    /// The saved NAS's name for an item ID ("<NAS id>|…").
    func serverName(forItemID id: String) -> String {
        UUID(uuidString: String(id.prefix(36))).flatMap { uuid in servers.first { $0.id == uuid }?.name } ?? "NAS"
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
    @Parameter(title: "Folder") var destination: NASFolderEntity
    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Upload \(\.$files) to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let folder = destination.item
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

#if os(iOS)
struct ScanToNASIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan to NAS"
    static let description = IntentDescription("Scans a document with the camera and saves it as a PDF in a folder on your NAS.")
    // The scanner is on screen, so open the app.
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Folder") var destination: NASFolderEntity
    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Scan a document to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await model.serviceForIntent(serverID: destination.item.serverID)
        let folder = destination.item.remoteItem
        model.scanRequest = folder.path
        model.navigationRequest = .favorite(folder)
        return .result()
    }
}
#endif

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
