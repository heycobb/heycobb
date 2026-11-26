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
    /// A folder comes back as a zip archive of its contents.
    func download(_ item: RemoteItem) async throws -> URL
    /// Reads part of a file, for streaming video and audio. Throws
    /// `.streamingUnsupported` if the server won't serve byte ranges.
    func read(_ item: RemoteItem, from offset: Int64, length: Int) async throws -> ByteRange

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
    /// Compresses items into a zip at `destination` (a full path). Fails
    /// rather than replacing an existing file.
    func compress(_ items: [RemoteItem], to destination: String) async throws
    /// The names at the top level of an archive (at most a few), so the
    /// caller can tell whether it holds a single folder.
    func archiveTopLevel(_ archive: RemoteItem) async throws -> [String]
    /// Extracts an archive into `folder`, without replacing anything there.
    func extract(_ archive: RemoteItem, into folder: String) async throws
    /// Creates a link anyone can open (DSM's Sharing Links).
    func createShareLink(for item: RemoteItem, password: String?, expires: Date?) async throws -> SharingLink
    /// Removes a link so it stops working.
    func deleteShareLink(_ link: SharingLink) async throws
    func signOut() async
}
