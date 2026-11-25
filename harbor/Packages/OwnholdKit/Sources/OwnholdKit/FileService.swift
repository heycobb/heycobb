import Foundation

/// Everything the UI needs from a NAS. `FileStationClient` talks to a real
/// Synology; `DemoFileService` serves built-in sample content so the app can
/// be tried (and reviewed by Apple) without a NAS.
public protocol FileService: Sendable {
    func listShares() async throws -> [RemoteItem]
    func list(folder: String, offset: Int, limit: Int, sort: SortField, ascending: Bool) async throws -> FolderPage
    func search(in folder: String, matching pattern: String) async throws -> [RemoteItem]
    func thumbnail(for item: RemoteItem, size: ThumbnailSize) async throws -> Data
    /// Downloads a file and returns a temporary local URL the caller must move.
    func download(_ item: RemoteItem) async throws -> URL

    // MARK: Changes (each one is started by the user; nothing syncs in the background)

    func createFolder(named name: String, in parent: String) async throws -> RemoteItem
    func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem
    /// Moves items into `folder`. Fails rather than replacing anything already there.
    func move(_ items: [RemoteItem], to folder: String) async throws
    /// Deletes items. If the shared folder's Recycle Bin is on, DSM keeps them there.
    func delete(_ items: [RemoteItem]) async throws
    /// Uploads a local file as `folder/name`, creating missing parent folders.
    /// With `replacing` false, fails with `.alreadyExists` if the name is taken.
    func upload(
        _ file: URL,
        as name: String,
        to folder: String,
        replacing: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func signOut() async
}
