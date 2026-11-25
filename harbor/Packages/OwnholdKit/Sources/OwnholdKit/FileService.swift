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
    func signOut() async
}
