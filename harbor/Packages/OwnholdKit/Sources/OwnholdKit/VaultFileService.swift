import CryptoKit
import Foundation

/// Which folders on a NAS are encrypted folders, and the keys of the ones
/// that are unlocked. One per connected NAS, shared by everything using it.
public final class VaultState: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: Set<String>
    private var keys: [String: VaultKeys] = [:]
    /// Called when the list of known encrypted folders changes, to save it.
    public var onRootsChange: (@Sendable (Set<String>) -> Void)?
    /// Called when a folder is locked or unlocked.
    public var onKeysChange: (@Sendable () -> Void)?

    public init(roots: Set<String> = []) {
        self.roots = roots
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var knownRoots: Set<String> { locked { roots } }

    /// The encrypted folder `path` is, or is inside.
    public func root(containing path: String) -> String? {
        locked {
            roots.filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
                .min { $0.count < $1.count }
        }
    }

    public func isRoot(_ path: String) -> Bool { locked { roots.contains(path) } }
    public func isUnlocked(_ root: String) -> Bool { locked { keys[root] != nil } }
    public func keys(for root: String) -> VaultKeys? { locked { keys[root] } }

    public func add(root: String) {
        let changed = locked { roots.insert(root).inserted }
        if changed { onRootsChange?(knownRoots) }
    }

    public func remove(root: String) {
        let changed = locked {
            keys[root] = nil
            return roots.remove(root) != nil
        }
        if changed { onRootsChange?(knownRoots) }
    }

    /// After an encrypted folder (or a folder holding one) is renamed or moved.
    public func move(from old: String, to new: String) {
        let changed = locked {
            var changed = false
            for root in roots where root == old || root.hasPrefix(old + "/") {
                let moved = new + root.dropFirst(old.count)
                roots.remove(root)
                roots.insert(moved)
                if let key = keys.removeValue(forKey: root) { keys[moved] = key }
                changed = true
            }
            return changed
        }
        if changed { onRootsChange?(knownRoots) }
    }

    /// After a folder is deleted: forgets encrypted folders in it.
    public func removeAll(under path: String) {
        let changed = locked {
            let gone = roots.filter { $0 == path || $0.hasPrefix(path + "/") }
            for root in gone {
                roots.remove(root)
                keys[root] = nil
            }
            return !gone.isEmpty
        }
        if changed { onRootsChange?(knownRoots) }
    }

    public func unlock(_ root: String, keys newKeys: VaultKeys) {
        let added = locked {
            keys[root] = newKeys
            return roots.insert(root).inserted
        }
        if added { onRootsChange?(knownRoots) }
        onKeysChange?()
    }

    public func lock(_ root: String) {
        locked { keys[root] = nil }
        onKeysChange?()
    }

    public func lockAll() {
        locked { keys.removeAll() }
        onKeysChange?()
    }
}

/// A FileService that makes encrypted folders look like ordinary ones.
/// Outside encrypted folders every call goes straight to the NAS; inside,
/// names and contents are encrypted on the way out and decrypted on the way
/// back, so the rest of the app (lists, previews, players, uploads, Photo
/// Backup) works unchanged.
public final class VaultFileService: FileService {
    public let base: any FileService
    public let state: VaultState
    private let listings = ListingCache()
    private let headers = HeaderCache()

    public init(base: any FileService, state: VaultState) {
        self.base = base
        self.state = state
    }

    /// The NAS connection itself, for work outside encrypted folders that
    /// needs it directly (such as uploads that continue in the background).
    public func directService(for folder: String) -> (any FileService)? {
        state.root(containing: folder) == nil ? base : nil
    }

    // MARK: Paths

    private struct Location {
        let root: String
        let keys: VaultKeys
    }

    /// Where `path` is: nil outside encrypted folders, throws if locked.
    private func location(of path: String) throws -> Location? {
        guard let root = state.root(containing: path) else { return nil }
        guard let keys = state.keys(for: root) else { throw VaultError.locked(root) }
        return Location(root: root, keys: keys)
    }

    /// Where an item is, for changes to the item itself. An encrypted folder
    /// is an ordinary folder on the NAS (only its contents are encrypted), so
    /// it can be renamed, moved or deleted while locked.
    private func itemLocation(of path: String) throws -> Location? {
        state.isRoot(path) ? nil : try location(of: path)
    }

    private func components(_ path: String, in root: String) -> [String] {
        path.dropFirst(root.count).split(separator: "/").map(String.init)
    }

    /// The stored path of a plain path inside an encrypted folder.
    private func storedPath(_ path: String, _ location: Location) throws -> String {
        try components(path, in: location.root).reduce(location.root) { stored, name in
            RemoteItem.join(stored, try location.keys.encryptName(name).stored)
        }
    }

    private func storedItem(_ item: RemoteItem, _ location: Location) throws -> RemoteItem {
        let path = try storedPath(item.path, location)
        let stored = item.size.map(Vault.storedSize(plain:))
        return RemoteItem(path: path, name: (path as NSString).lastPathComponent, isDirectory: item.isDirectory,
                          size: item.isDirectory ? nil : stored, modified: item.modified)
    }

    /// The ".n" file next to an item stored under a long-name hash.
    private func sidecar(for storedPath: String) -> RemoteItem? {
        let name = (storedPath as NSString).lastPathComponent
        guard name.hasPrefix(Vault.longNamePrefix) else { return nil }
        let path = storedPath + Vault.longNameSuffix
        return RemoteItem(path: path, name: name + Vault.longNameSuffix, isDirectory: false)
    }

    private func writeSidecar(_ longName: String, stored: String, in storedFolder: String) async throws {
        let file = try SharingProtocols.temporaryFile(named: stored + Vault.longNameSuffix)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data(longName.utf8).write(to: file)
        try await base.upload(file, as: stored + Vault.longNameSuffix, to: storedFolder, replacing: true) { _ in }
    }

    /// Writes ".n" files for any long names in a folder path, so folders an
    /// upload creates can be listed.
    private func ensureSidecars(for folder: String, _ location: Location) async throws {
        var stored = location.root
        for name in components(folder, in: location.root) {
            let encrypted = try location.keys.encryptName(name)
            if let longName = encrypted.longName {
                try await writeSidecar(longName, stored: encrypted.stored, in: stored)
            }
            stored = RemoteItem.join(stored, encrypted.stored)
        }
    }

    // MARK: Listing

    private func allItems(in folder: String, using service: any FileService) async throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        var offset = 0
        while true {
            let page = try await service.list(folder: folder, offset: offset, limit: 1000, sort: .name, ascending: true)
            items += page.items
            offset += page.items.count
            if !page.hasMore || page.items.isEmpty { return items }
        }
    }

    /// The decrypted contents of a folder inside an encrypted folder.
    private func decryptedItems(in folder: String, _ location: Location) async throws -> [RemoteItem] {
        if let cached = await listings.items(for: folder) { return cached }
        let storedFolder = try storedPath(folder, location)
        let stored = try await allItems(in: storedFolder, using: base)
        var sidecars: [String: RemoteItem] = [:]
        for item in stored where !item.isDirectory && item.name.hasPrefix(Vault.longNamePrefix) && item.name.hasSuffix(Vault.longNameSuffix) {
            sidecars[String(item.name.dropLast(Vault.longNameSuffix.count))] = item
        }
        var items: [RemoteItem] = []
        for item in stored {
            if folder == location.root, Vault.isConfig(item.name) { continue }
            if item.name.hasSuffix(Vault.longNameSuffix), sidecars[String(item.name.dropLast(Vault.longNameSuffix.count))] != nil { continue }
            var encoded = item.name
            if item.name.hasPrefix(Vault.longNamePrefix) {
                guard let sidecar = sidecars[item.name], let text = try? await readSmallFile(sidecar) else { continue }
                encoded = text
            }
            guard let name = try? location.keys.decryptName(encoded) else { continue }
            let size = item.isDirectory ? nil : item.size.flatMap(Vault.plainSize(stored:))
            if !item.isDirectory, item.size != nil, size == nil { continue }
            items.append(RemoteItem(path: RemoteItem.join(folder, name), name: name, isDirectory: item.isDirectory,
                                    size: size, modified: item.modified))
        }
        await listings.store(items, for: folder)
        return items
    }

    private func readSmallFile(_ item: RemoteItem) async throws -> String {
        let url = try await base.download(item)
        defer { Self.discard(url) }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func changed(_ folders: [String]) async {
        await listings.invalidate(folders)
    }

    public func listShares() async throws -> [RemoteItem] {
        try await base.listShares()
    }

    public func list(folder: String, offset: Int, limit: Int, sort: SortField, ascending: Bool) async throws -> FolderPage {
        if let location = try location(of: folder) {
            let items = try await decryptedItems(in: folder, location)
            return SharingProtocols.page(items, offset: offset, limit: limit, sort: sort, ascending: ascending)
        }
        let page = try await base.list(folder: folder, offset: offset, limit: limit, sort: sort, ascending: ascending)
        // A folder holding ownhold-vault.json is an encrypted folder.
        if page.items.contains(where: { !$0.isDirectory && Vault.isConfig($0.name) }) {
            state.add(root: folder)
            return try await list(folder: folder, offset: offset, limit: limit, sort: sort, ascending: ascending)
        }
        return page
    }

    public func search(in folder: String, matching pattern: String) async throws -> [RemoteItem] {
        if let location = try location(of: folder) {
            return try await SharingProtocols.search(in: folder, matching: pattern) { path in
                try await self.decryptedItems(in: path, location)
            }
        }
        // The NAS can't search inside encrypted folders: leave their stored
        // names out of its results.
        return try await base.search(in: folder, matching: pattern).filter {
            state.root(containing: $0.path) == nil && !Vault.isConfig($0.name)
        }
    }

    public func thumbnail(for item: RemoteItem, size: ThumbnailSize) async throws -> Data {
        guard try location(of: item.path) == nil else { throw NASError.notFound }
        return try await base.thumbnail(for: item, size: size)
    }

    // MARK: Reading

    public func download(_ item: RemoteItem) async throws -> URL {
        guard let location = try location(of: item.path) else { return try await base.download(item) }
        if item.isDirectory { return try await downloadFolder(item, location) }
        let stored = try await base.download(try storedItem(item, location))
        defer { Self.discard(stored) }
        let destination = try SharingProtocols.temporaryFile(named: item.name)
        try location.keys.decryptFile(at: stored, to: destination)
        if let modified = item.modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        }
        return destination
    }

    /// A folder inside an encrypted folder comes back as a zip, like folders
    /// elsewhere, made on the device from the decrypted files.
    private func downloadFolder(_ folder: RemoteItem, _ location: Location) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appending(path: "Vault-" + UUID().uuidString, directoryHint: .isDirectory)
        let top = work.appending(path: folder.name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var pending: [(RemoteItem, URL)] = [(folder, top)]
        while let (current, local) = pending.popLast() {
            for child in try await decryptedItems(in: current.path, location) {
                try Task.checkCancellation()
                let target = local.appending(path: child.name, directoryHint: child.isDirectory ? .isDirectory : .notDirectory)
                if child.isDirectory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    pending.append((child, target))
                } else {
                    let file = try await download(child)
                    try FileManager.default.moveItem(at: file, to: target)
                    Self.discard(file)
                }
            }
        }
        return try Self.zip(top, named: folder.name + ".zip")
    }

    /// Removes a downloaded file, and the folder made for it if there was one.
    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if folder.lastPathComponent.hasPrefix("Downloads-") { try? FileManager.default.removeItem(at: folder) }
    }

    /// Zips a local folder with the system's own archiver.
    static func zip(_ folder: URL, named name: String) throws -> URL {
        let destination = try SharingProtocols.temporaryFile(named: name)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
        return destination
    }

    public func read(_ item: RemoteItem, from offset: Int64, length: Int) async throws -> ByteRange {
        guard let location = try location(of: item.path) else { return try await base.read(item, from: offset, length: length) }
        let stored = try storedItem(item, location)
        let header = try await header(for: stored, location)
        guard let range = Vault.storedRange(offset: offset, length: length, plainSize: header.plainSize) else {
            return ByteRange(data: Data(), totalLength: header.plainSize)
        }
        let bytes = try await base.read(stored, from: range.storedOffset, length: range.storedLength)
        let plain = try Vault.openChunks(bytes.data, first: range.firstChunk, plainSize: header.plainSize, key: header.key)
        guard plain.count >= range.skip + range.take else { throw VaultError.damaged }
        return ByteRange(data: plain.subdata(in: range.skip..<(range.skip + range.take)), totalLength: header.plainSize)
    }

    private func header(for stored: RemoteItem, _ location: Location) async throws -> (key: SymmetricKey, plainSize: Int64) {
        let cacheKey = stored.path + "|" + String(stored.modified?.timeIntervalSince1970 ?? 0)
        if let cached = await headers.value(for: cacheKey) { return cached }
        let bytes = try await base.read(stored, from: 0, length: Vault.headerSize)
        guard let plainSize = Vault.plainSize(stored: bytes.totalLength) else { throw VaultError.damaged }
        let value = (try location.keys.fileKey(fromHeader: bytes.data), plainSize)
        await headers.store(value, for: cacheKey)
        return value
    }

    // MARK: Changes

    public func createFolder(named name: String, in parent: String) async throws -> RemoteItem {
        guard let location = try location(of: parent) else { return try await base.createFolder(named: name, in: parent) }
        let encrypted = try location.keys.encryptName(name)
        let storedParent = try storedPath(parent, location)
        let created = try await base.createFolder(named: encrypted.stored, in: storedParent)
        if let longName = encrypted.longName { try await writeSidecar(longName, stored: encrypted.stored, in: storedParent) }
        await changed([parent])
        return RemoteItem(path: RemoteItem.join(parent, name), name: name, isDirectory: true, modified: created.modified)
    }

    public func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem {
        guard let location = try itemLocation(of: item.path) else {
            let renamed = try await base.rename(item, to: name)
            state.move(from: item.path, to: renamed.path)
            return renamed
        }
        let stored = try storedItem(item, location)
        let encrypted = try location.keys.encryptName(name)
        let renamed = try await base.rename(stored, to: encrypted.stored)
        if let old = sidecar(for: stored.path) { try? await base.delete([old]) }
        if let longName = encrypted.longName { try await writeSidecar(longName, stored: encrypted.stored, in: stored.parentPath) }
        await changed([item.parentPath])
        await headers.removeAll()
        return RemoteItem(path: RemoteItem.join(item.parentPath, name), name: name, isDirectory: item.isDirectory,
                          size: item.size, modified: renamed.modified ?? item.modified)
    }

    public func move(_ items: [RemoteItem], to folder: String) async throws {
        let destination = try location(of: folder)
        var direct: [RemoteItem] = []
        var transfers: [RemoteItem] = []
        for item in items {
            let isRoot = state.isRoot(item.path)
            let source = try itemLocation(of: item.path)
            if source == nil || isRoot {
                // Moving a whole encrypted folder (or a plain item) keeps its
                // stored form; it can't go inside another encrypted folder.
                if destination != nil {
                    if isRoot || state.knownRoots.contains(where: { $0.hasPrefix(item.path + "/") }) { throw VaultError.nested }
                    transfers.append(item)
                } else {
                    direct.append(item)
                }
            } else if let source, let destination, source.root == destination.root {
                direct.append(item)
            } else {
                transfers.append(item)
            }
        }
        if !direct.isEmpty {
            if let destination {
                let stored = try direct.map { try storedItem($0, destination) }
                let sidecars = stored.compactMap { sidecar(for: $0.path) }
                try await base.move(stored + sidecars, to: try storedPath(folder, destination))
                try await ensureSidecars(for: folder, destination)
                await headers.removeAll()
            } else {
                try await base.move(direct, to: folder)
                for item in direct { state.move(from: item.path, to: RemoteItem.join(folder, item.name)) }
            }
            await changed([folder] + direct.map(\.parentPath))
        }
        // In or out of an encrypted folder: copy (encrypting or decrypting),
        // then delete the original once the copy is complete.
        for item in transfers {
            try await transfer(item, to: folder)
            try await delete([item])
        }
    }

    private func transfer(_ item: RemoteItem, to folder: String) async throws {
        try Task.checkCancellation()
        if item.isDirectory {
            // Build the path here: a NAS may answer with another form of it.
            let target = RemoteItem.join(folder, item.name)
            do {
                _ = try await createFolder(named: item.name, in: folder)
            } catch NASError.alreadyExists {
                // Left by an earlier attempt that stopped part way: carry on
                // into it. Files that are already there still aren't replaced.
            }
            for child in try await allItems(in: item.path, using: self) {
                try await transfer(child, to: target)
            }
        } else {
            let file = try await download(item)
            defer { Self.discard(file) }
            // Keep the file's date (uploads carry it to the NAS).
            if let modified = item.modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            }
            try await upload(file, as: item.name, to: folder, replacing: false) { _ in }
        }
    }

    public func delete(_ items: [RemoteItem]) async throws {
        var plain: [RemoteItem] = []
        var stored: [RemoteItem] = []
        var folders: [String] = []
        for item in items {
            if let location = try itemLocation(of: item.path) {
                let storedItem = try storedItem(item, location)
                stored.append(storedItem)
                if let sidecar = sidecar(for: storedItem.path) { stored.append(sidecar) }
                folders.append(item.parentPath)
            } else {
                plain.append(item)
            }
        }
        if !stored.isEmpty { try await base.delete(stored) }
        if !plain.isEmpty {
            try await base.delete(plain)
            for item in plain { state.removeAll(under: item.path) }
        }
        await changed(folders)
    }

    public func upload(_ file: URL, as name: String, to folder: String, replacing: Bool,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let location = try location(of: folder) else {
            try await base.upload(file, as: name, to: folder, replacing: replacing, progress: progress)
            return
        }
        let encrypted = try location.keys.encryptName(name)
        let storedFolder = try storedPath(folder, location)
        let sealed = try SharingProtocols.temporaryFile(named: encrypted.stored)
        defer { try? FileManager.default.removeItem(at: sealed.deletingLastPathComponent()) }
        try location.keys.encryptFile(at: file, to: sealed)
        try await ensureSidecars(for: folder, location)
        try await base.upload(sealed, as: encrypted.stored, to: storedFolder, replacing: replacing, progress: progress)
        if let longName = encrypted.longName { try await writeSidecar(longName, stored: encrypted.stored, in: storedFolder) }
        await changed([folder])
        await headers.removeAll()
    }

    public func compress(_ items: [RemoteItem], to destination: String) async throws {
        // Zipping a whole encrypted folder into a plain folder would leave an
        // unencrypted copy of everything in it on the NAS.
        let destinationRoot = state.root(containing: destination)
        for item in items {
            let holdsVault = state.knownRoots.contains { $0 == item.path || $0.hasPrefix(item.path + "/") }
            if holdsVault, destinationRoot == nil || destinationRoot != state.root(containing: item.path) {
                throw VaultError.unavailable
            }
        }
        // The app zips on the device instead when this is unsupported.
        if try items.contains(where: { try location(of: $0.path) != nil }) || (try location(of: destination)) != nil {
            throw NASError.unsupported
        }
        try await base.compress(items, to: destination)
    }

    public func archiveTopLevel(_ archive: RemoteItem) async throws -> [String] {
        guard try location(of: archive.path) == nil else { throw VaultError.unavailable }
        return try await base.archiveTopLevel(archive)
    }

    public func extract(_ archive: RemoteItem, into folder: String) async throws {
        guard try location(of: archive.path) == nil, try location(of: folder) == nil else { throw VaultError.unavailable }
        try await base.extract(archive, into: folder)
    }

    public func createShareLink(for item: RemoteItem, password: String?, expires: Date?) async throws -> SharingLink {
        guard state.root(containing: item.path) == nil else { throw VaultError.unavailable }
        return try await base.createShareLink(for: item, password: password, expires: expires)
    }

    public func deleteShareLink(_ link: SharingLink) async throws {
        try await base.deleteShareLink(link)
    }

    public func signOut() async {
        state.lockAll()
        await base.signOut()
    }

    public func validateSession() async throws {
        try await base.validateSession()
    }

    // MARK: Encrypted folders

    private func configItem(_ root: String) -> RemoteItem {
        RemoteItem(path: RemoteItem.join(root, Vault.configName), name: Vault.configName, isDirectory: false)
    }

    public func config(of root: String) async throws -> VaultConfig {
        let url = try await base.download(configItem(root))
        defer { Self.discard(url) }
        return try VaultConfig.decode(try Data(contentsOf: url))
    }

    /// Makes a new encrypted folder and leaves it unlocked. Returns the
    /// folder and the recovery key to show the user once.
    public func createVault(named name: String, in parent: String, password: String) async throws -> (folder: RemoteItem, recoveryKey: String) {
        guard state.root(containing: parent) == nil else { throw VaultError.nested }
        let made = try VaultConfig.create(password: password)
        let folder = try await base.createFolder(named: name, in: parent)
        let file = try SharingProtocols.temporaryFile(named: Vault.configName)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try made.config.encoded().write(to: file)
        do {
            try await base.upload(file, as: Vault.configName, to: folder.path, replacing: false) { _ in }
        } catch {
            try? await base.delete([folder])
            throw error
        }
        state.unlock(folder.path, keys: made.keys)
        return (folder, made.recoveryKey)
    }

    @discardableResult
    public func unlock(_ root: String, password: String) async throws -> VaultKeys {
        let keys = try await config(of: root).unlock(password: password)
        state.unlock(root, keys: keys)
        await changed([root])
        return keys
    }

    @discardableResult
    public func unlock(_ root: String, recoveryKey: String) async throws -> VaultKeys {
        let keys = try await config(of: root).unlock(recoveryKey: recoveryKey)
        state.unlock(root, keys: keys)
        await changed([root])
        return keys
    }

    /// Sets a new password for an unlocked encrypted folder.
    public func changePassword(of root: String, to password: String) async throws {
        guard let keys = state.keys(for: root) else { throw VaultError.locked(root) }
        let updated = try await config(of: root).changingPassword(to: password, keys: keys)
        let file = try SharingProtocols.temporaryFile(named: Vault.configName)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try updated.encoded().write(to: file)
        try await base.upload(file, as: Vault.configName, to: root, replacing: true) { _ in }
    }
}

/// File keys and sizes read from headers, so seeking in a video reads each
/// file's header once.
private actor HeaderCache {
    private var entries: [String: (key: SymmetricKey, plainSize: Int64)] = [:]

    func value(for key: String) -> (key: SymmetricKey, plainSize: Int64)? { entries[key] }

    func store(_ value: (key: SymmetricKey, plainSize: Int64), for key: String) {
        if entries.count > 200 { entries.removeAll() }
        entries[key] = value
    }

    func removeAll() { entries.removeAll() }
}

public extension VaultFileService {
    /// Whether `path` is inside an encrypted folder (locked or not).
    func isEncrypted(_ path: String) -> Bool { state.root(containing: path) != nil }
}

/// Where the app and its extensions keep encrypted folders between launches:
/// which folders on each NAS are encrypted (shared app settings), and the
/// keys of folders set to stay unlocked on this device (Keychain, this
/// device only, never synced).
public enum VaultStore {
    private static func rootsKey(_ id: UUID) -> String { "vaultRoots.\(id.uuidString)" }
    private static func keysKey(_ id: UUID) -> String { "vaultKeys.\(id.uuidString)" }

    public static func roots(for id: UUID) -> Set<String> {
        Set(SharedContainer.defaults.stringArray(forKey: rootsKey(id)) ?? [])
    }

    static func save(_ roots: Set<String>, for id: UUID) {
        SharedContainer.defaults.set(roots.sorted(), forKey: rootsKey(id))
    }

    private static func storedKeys(for id: UUID) -> [String: Data] {
        SharedContainer.keychain.codable([String: Data].self, for: keysKey(id)) ?? [:]
    }

    private static func saveKeys(_ keys: [String: Data], for id: UUID) {
        if keys.isEmpty {
            SharedContainer.keychain.remove(keysKey(id))
        } else {
            _ = SharedContainer.keychain.setCodable(keys, for: keysKey(id))
        }
    }

    /// Whether a folder is set to stay unlocked on this device.
    public static func isRemembered(_ root: String, for id: UUID) -> Bool { storedKeys(for: id)[root] != nil }

    public static func remember(_ keys: VaultKeys, for root: String, server id: UUID) {
        var all = storedKeys(for: id)
        all[root] = keys.masterData
        saveKeys(all, for: id)
    }

    public static func forget(_ root: String, server id: UUID) {
        var all = storedKeys(for: id)
        guard all.removeValue(forKey: root) != nil else { return }
        saveKeys(all, for: id)
    }

    /// When a NAS is removed.
    public static func forgetAll(server id: UUID) {
        SharedContainer.defaults.removeObject(forKey: rootsKey(id))
        SharedContainer.keychain.remove(keysKey(id))
        forgetAllBiometric(server: id)
    }

    /// The state for a NAS, with folders set to stay unlocked already
    /// unlocked, saving changes as they happen.
    public static func makeState(for id: UUID) -> VaultState {
        let state = VaultState(roots: roots(for: id))
        for (root, data) in storedKeys(for: id) {
            if let keys = VaultKeys(masterData: data) { state.unlock(root, keys: keys) }
        }
        state.onRootsChange = { roots in
            save(roots, for: id)
            pruneBiometric(keeping: roots, server: id)
            // Keys of folders that were renamed, moved or deleted.
            var all = storedKeys(for: id)
            let stale = all.keys.filter { !roots.contains($0) }
            guard !stale.isEmpty else { return }
            for root in stale { all[root] = nil }
            saveKeys(all, for: id)
        }
        return state
    }
}
