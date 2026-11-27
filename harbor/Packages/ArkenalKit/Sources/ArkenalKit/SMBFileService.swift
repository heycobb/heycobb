import Foundation
import OSLog
@preconcurrency import SMBClient

/// A NAS reached over SMB (Windows file sharing), which every NAS offers.
///
/// Uses SMBClient (MIT). Most NAS don't encrypt SMB, so it's meant for the
/// home network or a VPN such as Tailscale (which encrypts everything).
/// The password is used to sign in on each new connection; it isn't stored
/// by this type.
///
/// Paths: "/share/folder/file", like File Station's.
public final class SMBFileService: FileService, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.snowlightlabs.Arkenal", category: "smb")
    public let host: String
    public let port: Int
    private let account: String
    private let password: String
    private let gate = SerialGate()
    private let cache = ListingCache()

    // Used only inside `gate`, one task at a time.
    private var client: SMBClient?
    private var trees: [String: TreeAccessor] = [:]

    public init(host: String, port: Int = 445, account: String, password: String) {
        self.host = host
        self.port = port
        self.account = account
        self.password = password
    }

    /// From an smb:// endpoint.
    public convenience init(endpoint: URL, account: String, password: String) {
        self.init(host: endpoint.host() ?? "", port: endpoint.port ?? 445, account: account, password: password)
    }

    // MARK: Session

    public func validateSession() async throws {
        _ = try await listShares()
    }

    public func signOut() async {
        try? await gate.run {
            if let client { _ = try? await client.logoff() }
            client = nil
            trees = [:]
        }
    }

    // MARK: Browsing

    public func listShares() async throws -> [RemoteItem] {
        try await withClient { client in
            try await client.listShares()
                // Disk shares only: not printers, IPC$ or admin shares (C$).
                .filter { $0.type.rawValue & 0x0FFF_FFFF == 0 && $0.type.rawValue & 0x8000_0000 == 0 && !$0.name.hasSuffix("$") }
                .map { RemoteItem(path: "/" + $0.name, name: $0.name, isDirectory: true) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func list(folder: String, offset: Int, limit: Int, sort: SortField, ascending: Bool) async throws -> FolderPage {
        SharingProtocols.page(try await listAll(folder), offset: offset, limit: limit, sort: sort, ascending: ascending)
    }

    public func search(in folder: String, matching pattern: String) async throws -> [RemoteItem] {
        try await SharingProtocols.search(in: folder, matching: pattern) { try await self.listAll($0) }
    }

    /// SMB has no thumbnails; the device makes them (see ThumbnailCache).
    public func thumbnail(for item: RemoteItem, size: ThumbnailSize) async throws -> Data {
        throw NASError.notFound
    }

    public func download(_ item: RemoteItem) async throws -> URL {
        guard !item.isDirectory else { throw NASError.unsupported }
        let destination = try SharingProtocols.temporaryFile(named: item.name)
        do {
            try await withTree(item.path) { tree, rest in
                let reader = try await tree.fileReader(path: rest)
                do {
                    try await reader.download(to: destination, overwrite: true)
                    try await reader.close()
                } catch {
                    try? await reader.close()
                    throw error
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
        return destination
    }

    public func read(_ item: RemoteItem, from offset: Int64, length: Int) async throws -> ByteRange {
        try await withTree(item.path) { tree, rest in
            let reader = try await tree.fileReader(path: rest)
            do {
                let total = try await reader.fileSize
                let data = offset >= Int64(total) ? Data() : try await reader.read(offset: UInt64(offset), length: UInt32(clamping: max(length, 1)))
                try await reader.close()
                return ByteRange(data: data, totalLength: Int64(total))
            } catch {
                try? await reader.close()
                throw error
            }
        }
    }

    // MARK: Changes

    public func createFolder(named name: String, in parent: String) async throws -> RemoteItem {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        let path = RemoteItem.join(parent, name)
        try await withTree(path) { tree, rest in
            let isFolder = try await tree.existDirectory(path: rest)
            let isFile = try await tree.existFile(path: rest)
            if isFolder || isFile { throw NASError.alreadyExists }
            try await tree.createDirectory(path: rest)
        }
        await cache.invalidate([parent])
        return RemoteItem(path: path, name: name, isDirectory: true, modified: Date())
    }

    public func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        let destination = RemoteItem.join(item.parentPath, name)
        try await move(item.path, to: destination)
        await cache.invalidate([item.parentPath])
        return item.with(path: destination, name: name)
    }

    public func move(_ items: [RemoteItem], to folder: String) async throws {
        for item in items {
            try await move(item.path, to: RemoteItem.join(folder, item.name))
        }
        await cache.invalidate([folder] + items.map(\.parentPath))
    }

    /// Deletes files, and folders with everything in them (SMB only removes
    /// empty folders). A NAS with a Recycle Bin for SMB keeps them there.
    public func delete(_ items: [RemoteItem]) async throws {
        for item in items {
            try await withTree(item.path) { tree, rest in
                if item.isDirectory {
                    try await Self.removeFolder(rest, in: tree)
                } else {
                    try await tree.deleteFile(path: rest)
                }
            }
        }
        await cache.invalidate(items.map(\.parentPath) + items.filter(\.isDirectory).map(\.path))
    }

    public func upload(
        _ file: URL,
        as name: String,
        to folder: String,
        replacing: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard RemoteItem.isValidName(name) else { throw NASError.invalidName }
        let path = RemoteItem.join(folder, name)
        try await withTree(path) { tree, rest in
            // Missing parent folders, from the top.
            let parents = rest.split(separator: "/").dropLast()
            var current = ""
            for part in parents {
                current = current.isEmpty ? String(part) : current + "/" + part
                if try await !tree.existDirectory(path: current) { try await tree.createDirectory(path: current) }
            }
            let exists = try await tree.existFile(path: rest)
            if exists, !replacing { throw NASError.alreadyExists }
            // Written under a temporary name first, so a failed upload never
            // leaves half a file under the real name (or loses the old one).
            let temporary = (rest as NSString).deletingLastPathComponent
            let partial = (temporary.isEmpty ? "" : temporary + "/") + ".arkenal-\(UUID().uuidString.prefix(8)).part"
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            do {
                try await tree.upload(fileHandle: handle, path: partial) { progress(min(0.99, $0)) }
                if exists { try await tree.deleteFile(path: rest) }
                try await tree.rename(from: partial, to: rest)
            } catch {
                try? await tree.deleteFile(path: partial)
                throw error
            }
        }
        await cache.invalidate([folder])
        progress(1)
    }

    /// SMB can't zip on the NAS: Arkenal zips on the device instead.
    public func compress(_ items: [RemoteItem], to destination: String) async throws { throw NASError.unsupported }
    public func archiveTopLevel(_ archive: RemoteItem) async throws -> [String] { throw NASError.unsupported }
    public func extract(_ archive: RemoteItem, into folder: String) async throws { throw NASError.unsupported }
    public func createShareLink(for item: RemoteItem, password: String?, expires: Date?) async throws -> SharingLink { throw NASError.unsupported }
    public func deleteShareLink(_ link: SharingLink) async throws { throw NASError.unsupported }

    // MARK: Private

    private func listAll(_ folder: String) async throws -> [RemoteItem] {
        guard SharingProtocols.split(folder) != nil else { return try await listShares() }
        if let cached = await cache.items(for: folder) { return cached }
        let items = try await withTree(folder) { tree, rest in
            try await tree.listDirectory(path: rest)
                .filter { $0.name != "." && $0.name != ".." && !SharingProtocols.isHidden($0.name) }
                .map { file in
                    RemoteItem(
                        path: RemoteItem.join(Self.normalized(folder), file.name),
                        name: file.name,
                        isDirectory: file.isDirectory,
                        size: file.isDirectory ? nil : Int64(clamping: file.size),
                        modified: file.lastWriteTime
                    )
                }
        }
        await cache.store(items, for: folder)
        return items
    }

    /// Moves within one shared folder, never replacing anything. SMB can't
    /// move between shared folders.
    private func move(_ path: String, to destination: String) async throws {
        guard let from = SharingProtocols.split(path), let to = SharingProtocols.split(destination) else { throw NASError.notFound }
        guard from.share.lowercased() == to.share.lowercased() else { throw NASError.unsupported }
        try await withTree(path) { tree, rest in
            let renamingCase = rest.lowercased() == to.rest.lowercased()
            if !renamingCase {
                let isFile = try await tree.existFile(path: to.rest)
                let isFolder = try await tree.existDirectory(path: to.rest)
                if isFile || isFolder { throw NASError.alreadyExists }
            }
            try await tree.move(from: rest, to: to.rest)
        }
    }

    private static func removeFolder(_ path: String, in tree: TreeAccessor) async throws {
        for file in try await tree.listDirectory(path: path) where file.name != "." && file.name != ".." {
            let child = path + "/" + file.name
            if file.isDirectory {
                try await removeFolder(child, in: tree)
            } else {
                try await tree.deleteFile(path: child)
            }
        }
        try await tree.deleteDirectory(path: path)
    }

    private static func normalized(_ path: String) -> String {
        "/" + path.split(separator: "/").joined(separator: "/")
    }

    /// Runs `work` signed in, one request at a time, reconnecting once if
    /// the connection dropped (the NAS closes idle ones).
    private func withClient<T>(_ work: (SMBClient) async throws -> T) async throws -> T {
        try await gate.run {
            do {
                return try await work(try await connected())
            } catch let error where Self.isDisconnect(error) {
                client = nil
                trees = [:]
                return try await work(try await connected())
            } catch {
                throw Self.translate(error)
            }
        }
    }

    /// Like `withClient`, for a path inside a shared folder: passes the
    /// share's tree and the path within it ("a/b").
    private func withTree<T>(_ path: String, _ work: (TreeAccessor, String) async throws -> T) async throws -> T {
        guard let (share, rest) = SharingProtocols.split(path) else { throw NASError.notFound }
        return try await withClient { client in
            let tree: TreeAccessor
            if let existing = trees[share.lowercased()] {
                tree = existing
            } else {
                tree = client.treeAccessor(share: share)
                trees[share.lowercased()] = tree
            }
            return try await work(tree, rest)
        }
    }

    private func connected() async throws -> SMBClient {
        if let client { return client }
        let client = SMBClient(host: host, port: port)
        do {
            try await client.login(username: account, password: password)
        } catch {
            Self.log.error("SMB sign-in failed: \(String(describing: error), privacy: .public)")
            throw Self.translate(error)
        }
        self.client = client
        return client
    }

    private static func isDisconnect(_ error: Error) -> Bool {
        if error is ConnectionError { return true }
        if let response = error as? ErrorResponse {
            let status = NTStatus(response.header.status)
            return status == .networkSessionExpired || status == .userSessionDeleted || status == .networkNameDeleted
        }
        return false
    }

    static func translate(_ error: Error) -> Error {
        if error is NASError || error is CancellationError { return error }
        if error is ConnectionError { return NASError.unreachable }
        guard let response = error as? ErrorResponse else { return NASError.unreachable }
        let status = NTStatus(response.header.status)
        switch status.rawValue {
        case ErrorCode.logonFailure.rawValue: return NASError.invalidCredentials
        case 0xC000_0072: return NASError.accountDisabled // STATUS_ACCOUNT_DISABLED
        case 0xC000_0071: return NASError.passwordExpired // STATUS_PASSWORD_EXPIRED
        case ErrorCode.accessDenied.rawValue, ErrorCode.badNetworkName.rawValue: return NASError.permissionDenied
        case ErrorCode.objectNameNotFound.rawValue, ErrorCode.objectPathNotFound.rawValue, ErrorCode.noSuchFile.rawValue: return NASError.notFound
        case ErrorCode.objectNameCollision.rawValue: return NASError.alreadyExists
        case ErrorCode.objectNameInvalid.rawValue: return NASError.invalidName
        case 0xC000_007F: return NASError.noSpace // STATUS_DISK_FULL
        default: return NASError.server(code: Int(status.rawValue), api: "SMB")
        }
    }
}
