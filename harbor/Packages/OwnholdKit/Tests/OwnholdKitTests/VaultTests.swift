import Foundation
import Testing
@testable import OwnholdKit

/// Fewer rounds than real folders, so tests run quickly.
private let fastIterations = 1_000

struct VaultFormatTests {
    let keys = VaultKeys(master: .init(size: .bits256))

    @Test func roundTripsEverySizeAroundChunkEdges() throws {
        let sizes = [0, 1, 15, 16, Vault.chunkSize - 1, Vault.chunkSize, Vault.chunkSize + 1, 3 * Vault.chunkSize + 17]
        for size in sizes {
            let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let sealed = try keys.encrypt(plain)
            #expect(Int64(sealed.count) == Vault.storedSize(plain: Int64(size)))
            #expect(Vault.plainSize(stored: Int64(sealed.count)) == Int64(size))
            #expect(try keys.decrypt(sealed) == plain)
            #expect(sealed.range(of: Data("OHV1".utf8)) == 0..<4)
        }
    }

    @Test func sameContentEncryptsDifferentlyEachTime() throws {
        let plain = Data(repeating: 7, count: 100)
        #expect(try keys.encrypt(plain) != keys.encrypt(plain))
    }

    @Test func detectsTamperingTruncationAndTheWrongKey() throws {
        let plain = Data((0..<(2 * Vault.chunkSize + 5)).map { UInt8(truncatingIfNeeded: $0) })
        let sealed = try keys.encrypt(plain)
        var flipped = sealed
        flipped[Vault.headerSize + 10] ^= 1
        #expect(throws: VaultError.damaged) { try keys.decrypt(flipped) }
        // Cutting off the last chunk leaves a file whose last chunk isn't marked last.
        let cut = sealed.prefix(Vault.headerSize + 2 * Vault.storedChunk)
        #expect(throws: VaultError.damaged) { try keys.decrypt(cut) }
        let other = VaultKeys(master: .init(size: .bits256))
        #expect(throws: VaultError.damaged) { try other.decrypt(sealed) }
    }

    @Test func filesEncryptAndDecryptOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "in.bin")
        let plain = Data((0..<(Vault.chunkSize * 2 + 100)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try plain.write(to: source)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let sealed = folder.appending(path: "sealed")
        let opened = folder.appending(path: "out.bin")
        try keys.encryptFile(at: source, to: sealed)
        try keys.decryptFile(at: sealed, to: opened)
        #expect(try Data(contentsOf: opened) == plain)
        let sealedDate = try sealed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(sealedDate == date)
    }

    @Test func rangesMapToTheRightChunks() throws {
        let size = Int64(3 * Vault.chunkSize + 10)
        let plain = Data((0..<Int(size)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let sealed = try keys.encrypt(plain)
        let key = try keys.fileKey(fromHeader: sealed.prefix(Vault.headerSize))
        for (offset, length) in [(0, 10), (Int64(Vault.chunkSize) - 3, 6), (Int64(Vault.chunkSize) * 3, 100), (5, Int(size)), (size - 1, 1)] {
            let range = try #require(Vault.storedRange(offset: offset, length: length, plainSize: size))
            let bytes = sealed.subdata(in: Int(range.storedOffset)..<Int(range.storedOffset) + range.storedLength)
            let opened = try Vault.openChunks(bytes, first: range.firstChunk, plainSize: size, key: key)
            let slice = opened.subdata(in: range.skip..<(range.skip + range.take))
            let end = min(Int(offset) + length, Int(size))
            #expect(slice == plain.subdata(in: Int(offset)..<end))
        }
        #expect(Vault.storedRange(offset: size, length: 1, plainSize: size) == nil)
    }

    @Test func namesAreStableSafeAndPrivate() throws {
        let name = "Tax Return 2026.pdf"
        let a = try keys.encryptName(name)
        #expect(a.stored == (try keys.encryptName(name)).stored)
        #expect(a.longName == nil)
        #expect(!a.stored.contains("Tax"))
        #expect(a.stored == a.stored.lowercased())
        #expect(a.stored.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
        #expect(try keys.decryptName(a.stored) == name)
        #expect(try keys.encryptName("tax return 2026.pdf").stored != a.stored)
        // The same characters typed differently (é as one or two code points) match.
        #expect(try keys.encryptName("Caf\u{E9}").stored == (try keys.encryptName("Cafe\u{301}")).stored)
        #expect(throws: VaultError.damaged) { try keys.decryptName("notastoredname") }
    }

    @Test func longNamesAreStoredUnderAHash() throws {
        let name = String(repeating: "写真", count: 40) + ".jpg"
        let encrypted = try keys.encryptName(name)
        #expect(encrypted.stored.hasPrefix("_"))
        #expect(encrypted.stored.count <= Vault.maxStoredName)
        let full = try #require(encrypted.longName)
        #expect(try keys.decryptName(full) == name)
    }
}

struct VaultKeyTests {
    @Test func unlocksWithThePasswordOrRecoveryKey() throws {
        let made = try VaultConfig.create(password: "correct horse", iterations: fastIterations)
        let config = try VaultConfig.decode(try made.config.encoded())
        #expect(try config.unlock(password: "correct horse") == made.keys)
        #expect(throws: VaultError.wrongPassword) { try config.unlock(password: "Correct horse") }
        #expect(try config.unlock(recoveryKey: made.recoveryKey) == made.keys)
        // Written down by hand: lowercase, spaces, O for 0 and l for 1.
        let handwritten = made.recoveryKey.lowercased().replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
        #expect(try config.unlock(recoveryKey: handwritten) == made.keys)
        #expect(throws: VaultError.wrongRecoveryKey) { try config.unlock(recoveryKey: "ABCD-EFGH") }
    }

    @Test func recoveryKeysLookRight() throws {
        let made = try VaultConfig.create(password: "x", iterations: fastIterations)
        let groups = made.recoveryKey.split(separator: "-")
        #expect(groups.count == 13)
        #expect(groups.allSatisfy { $0.count == 4 })
        #expect(!made.recoveryKey.contains { "ILOU".contains($0) })
    }

    @Test func changingThePasswordKeepsTheKeysAndRecovery() throws {
        let made = try VaultConfig.create(password: "old", iterations: fastIterations)
        let changed = try made.config.changingPassword(to: "new", keys: made.keys, iterations: fastIterations)
        #expect(try changed.unlock(password: "new") == made.keys)
        #expect(throws: VaultError.wrongPassword) { try changed.unlock(password: "old") }
        #expect(try changed.unlock(recoveryKey: made.recoveryKey) == made.keys)
    }

    @Test func settingsFileHoldsNoSecrets() throws {
        let made = try VaultConfig.create(password: "hunter2", iterations: fastIterations)
        let text = String(decoding: try made.config.encoded(), as: UTF8.self)
        #expect(!text.contains("hunter2"))
        #expect(text.contains("PBKDF2-HMAC-SHA256"))
        #expect(throws: VaultError.notAVault) { try VaultConfig.decode(Data("{}".utf8)) }
    }

    @Test func passwordKeyMatchesAKnownAnswer() throws {
        // RFC 7914 section 11's PBKDF2-HMAC-SHA256 vector ("passwd", "salt", 1 round).
        let key = try VaultConfig.passwordKey("passwd", salt: Data("salt".utf8), iterations: 1)
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }
}

// MARK: - Encrypted folders over a NAS

/// A NAS made of a local folder, for testing VaultFileService end to end.
final class LocalNAS: FileService, @unchecked Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "LocalNAS-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "share"), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appending(path: String(path.dropFirst())) }

    func item(_ path: String) -> RemoteItem {
        let values = try? url(path).resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory ?? false
        return RemoteItem(path: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory,
                          size: isDirectory ? nil : values?.fileSize.map(Int64.init), modified: values?.contentModificationDate)
    }

    /// Every stored name under a folder, at any depth.
    func storedNames(under path: String) -> [String] {
        (FileManager.default.subpaths(atPath: url(path).path) ?? []).map { ($0 as NSString).lastPathComponent }
    }

    func listShares() async throws -> [RemoteItem] { [item("/share")] }

    func list(folder: String, offset: Int, limit: Int, sort: SortField, ascending: Bool) async throws -> FolderPage {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url(folder).path) else { throw NASError.notFound }
        let items = names.filter { !$0.hasPrefix(".") }.map { item(RemoteItem.join(folder, $0)) }
        return SharingProtocols.page(items, offset: offset, limit: limit, sort: sort, ascending: ascending)
    }

    func search(in folder: String, matching pattern: String) async throws -> [RemoteItem] {
        try await SharingProtocols.search(in: folder, matching: pattern) { path in
            try await self.list(folder: path, offset: 0, limit: 10_000, sort: .name, ascending: true).items
        }
    }

    func thumbnail(for item: RemoteItem, size: ThumbnailSize) async throws -> Data { throw NASError.notFound }

    func download(_ item: RemoteItem) async throws -> URL {
        let destination = try SharingProtocols.temporaryFile(named: item.name)
        try FileManager.default.copyItem(at: url(item.path), to: destination)
        return destination
    }

    func read(_ item: RemoteItem, from offset: Int64, length: Int) async throws -> ByteRange {
        let data = try Data(contentsOf: url(item.path))
        let start = Int(min(offset, Int64(data.count)))
        return ByteRange(data: data.subdata(in: start..<min(start + length, data.count)), totalLength: Int64(data.count))
    }

    func createFolder(named name: String, in parent: String) async throws -> RemoteItem {
        let path = RemoteItem.join(parent, name)
        guard !FileManager.default.fileExists(atPath: url(path).path) else { throw NASError.alreadyExists }
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
        return item(path)
    }

    func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem {
        let path = RemoteItem.join(item.parentPath, name)
        try FileManager.default.moveItem(at: url(item.path), to: url(path))
        return self.item(path)
    }

    func move(_ items: [RemoteItem], to folder: String) async throws {
        for item in items {
            let target = url(RemoteItem.join(folder, item.name))
            guard !FileManager.default.fileExists(atPath: target.path) else { throw NASError.alreadyExists }
            try FileManager.default.moveItem(at: url(item.path), to: target)
        }
    }

    func delete(_ items: [RemoteItem]) async throws {
        for item in items { try FileManager.default.removeItem(at: url(item.path)) }
    }

    func upload(_ file: URL, as name: String, to folder: String, replacing: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: url(folder), withIntermediateDirectories: true)
        let target = url(RemoteItem.join(folder, name))
        if FileManager.default.fileExists(atPath: target.path) {
            guard replacing else { throw NASError.alreadyExists }
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: file, to: target)
        progress(1)
    }

    func compress(_ items: [RemoteItem], to destination: String) async throws { throw NASError.unsupported }
    func archiveTopLevel(_ archive: RemoteItem) async throws -> [String] { throw NASError.unsupported }
    func extract(_ archive: RemoteItem, into folder: String) async throws { throw NASError.unsupported }
    func createShareLink(for item: RemoteItem, password: String?, expires: Date?) async throws -> SharingLink { throw NASError.unsupported }
    func deleteShareLink(_ link: SharingLink) async throws {}
    func signOut() async {}
}

struct VaultServiceTests {
    func localFile(_ name: String, _ data: Data) throws -> URL {
        let file = try SharingProtocols.temporaryFile(named: name)
        try data.write(to: file)
        return file
    }

    func names(_ service: VaultFileService, _ folder: String) async throws -> [String] {
        try await service.list(folder: folder, offset: 0, limit: 100, sort: .name, ascending: true).items.map(\.name)
    }

    @Test func worksLikeAnOrdinaryFolderAndStoresNothingReadable() async throws {
        let nas = try LocalNAS()
        let service = VaultFileService(base: nas, state: VaultState())
        let saved = SavedRoots()
        service.state.onRootsChange = { saved.value = $0 }
        let (folder, recovery) = try await service.createVault(named: "Private", in: "/share", password: "pw")
        // A new folder is remembered as encrypted (for the lock icon after relaunch).
        #expect(saved.value == ["/share/Private"])
        #expect(folder.path == "/share/Private")
        #expect(!recovery.isEmpty)

        let contents = Data("my secret notes".utf8)
        try await service.upload(try localFile("Notes.txt", contents), as: "Notes.txt", to: "/share/Private/Taxes/2026", replacing: false) { _ in }
        _ = try await service.createFolder(named: "Scans", in: "/share/Private")

        #expect(try await names(service, "/share/Private") == ["Scans", "Taxes"])
        #expect(try await names(service, "/share/Private/Taxes") == ["2026"])
        let listed = try await service.list(folder: "/share/Private/Taxes/2026", offset: 0, limit: 10, sort: .name, ascending: true).items
        #expect(listed.map(\.name) == ["Notes.txt"])
        #expect(listed.first?.size == Int64(contents.count))

        let downloaded = try await service.download(listed[0])
        #expect(try Data(contentsOf: downloaded) == contents)
        let part = try await service.read(listed[0], from: 3, length: 6)
        #expect(part.data == Data("secret".utf8))
        #expect(part.totalLength == Int64(contents.count))

        // On the NAS: only the settings file and scrambled names.
        let stored = nas.storedNames(under: "/share/Private")
        #expect(stored.contains(Vault.configName))
        for name in ["Notes.txt", "Taxes", "2026", "Scans"] { #expect(!stored.contains(name)) }
        let all = FileManager.default.subpaths(atPath: nas.url("/share/Private").path) ?? []
        for path in all {
            let data = (try? Data(contentsOf: nas.url("/share/Private/" + path))) ?? Data()
            #expect(data.range(of: contents) == nil)
        }

        let found = try await service.search(in: "/share/Private", matching: "notes")
        #expect(found.map(\.path) == ["/share/Private/Taxes/2026/Notes.txt"])
    }

    @Test func locksUnlocksAndIsFoundByListing() async throws {
        let nas = try LocalNAS()
        let first = VaultFileService(base: nas, state: VaultState())
        let (_, recovery) = try await first.createVault(named: "Vault", in: "/share", password: "pw")
        try await first.upload(try localFile("a.txt", Data("a".utf8)), as: "a.txt", to: "/share/Vault", replacing: false) { _ in }

        // Another device knows nothing about it until it lists the folder.
        let state = VaultState()
        let second = VaultFileService(base: nas, state: state)
        #expect(try await names(second, "/share") == ["Vault"])
        await #expect(throws: VaultError.locked("/share/Vault")) {
            _ = try await second.list(folder: "/share/Vault", offset: 0, limit: 10, sort: .name, ascending: true)
        }
        #expect(state.knownRoots == ["/share/Vault"])
        await #expect(throws: VaultError.wrongPassword) { try await second.unlock("/share/Vault", password: "nope") }
        try await second.unlock("/share/Vault", password: "pw")
        #expect(try await names(second, "/share/Vault") == ["a.txt"])

        state.lock("/share/Vault")
        await #expect(throws: VaultError.locked("/share/Vault")) {
            _ = try await second.download(RemoteItem(path: "/share/Vault/a.txt", name: "a.txt", isDirectory: false, size: 1))
        }
        try await second.unlock("/share/Vault", recoveryKey: recovery)
        try await second.changePassword(of: "/share/Vault", to: "new")
        state.lock("/share/Vault")
        try await second.unlock("/share/Vault", password: "new")
        await #expect(throws: VaultError.nested) { _ = try await second.createVault(named: "Inner", in: "/share/Vault", password: "x") }
    }

    @Test func renamesMovesAndDeletesInsideAndAcross() async throws {
        let nas = try LocalNAS()
        let service = VaultFileService(base: nas, state: VaultState())
        _ = try await service.createVault(named: "V", in: "/share", password: "pw")
        try await service.upload(try localFile("one.txt", Data("1".utf8)), as: "one.txt", to: "/share/V/A", replacing: false) { _ in }
        _ = try await service.createFolder(named: "B", in: "/share/V")

        let one = RemoteItem(path: "/share/V/A/one.txt", name: "one.txt", isDirectory: false, size: 1)
        let renamed = try await service.rename(one, to: "uno.txt")
        #expect(try await names(service, "/share/V/A") == ["uno.txt"])
        try await service.move([renamed], to: "/share/V/B")
        #expect(try await names(service, "/share/V/B") == ["uno.txt"])
        await #expect(throws: NASError.alreadyExists) {
            try await service.upload(try localFile("uno.txt", Data("x".utf8)), as: "uno.txt", to: "/share/V/B", replacing: false) { _ in }
        }

        // Moving out decrypts; moving in encrypts. Originals go only after the copy.
        let inside = RemoteItem(path: "/share/V/B/uno.txt", name: "uno.txt", isDirectory: false, size: 1)
        try await service.move([inside], to: "/share")
        #expect(try Data(contentsOf: nas.url("/share/uno.txt")) == Data("1".utf8))
        #expect(try await names(service, "/share/V/B").isEmpty)
        try FileManager.default.createDirectory(at: nas.url("/share/Plain/Sub"), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: nas.url("/share/Plain/Sub/deep.txt"))
        let taken = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: taken], ofItemAtPath: nas.url("/share/Plain/Sub/deep.txt").path)
        try await service.move([nas.item("/share/Plain")], to: "/share/V")
        let moved = try await service.list(folder: "/share/V/Plain/Sub", offset: 0, limit: 10, sort: .name, ascending: true).items
        #expect(moved.first?.modified == taken)
        #expect(!FileManager.default.fileExists(atPath: nas.url("/share/Plain").path))
        #expect(try await names(service, "/share/V/Plain/Sub") == ["deep.txt"])
        #expect(!nas.storedNames(under: "/share/V").contains("deep.txt"))

        // A move that stopped part way can be run again: it carries on into
        // the folder the first attempt made.
        try FileManager.default.createDirectory(at: nas.url("/share/V2/Sub"), withIntermediateDirectories: true)
        try Data("again".utf8).write(to: nas.url("/share/V2/Sub/again.txt"))
        _ = try await service.createFolder(named: "V2", in: "/share/V")
        try await service.move([nas.item("/share/V2")], to: "/share/V")
        #expect(try await names(service, "/share/V/V2/Sub") == ["again.txt"])

        // A whole encrypted folder can be renamed, but not put in another.
        let renamedVault = try await service.rename(nas.item("/share/V"), to: "W")
        #expect(service.state.knownRoots == ["/share/W"])
        #expect(try await names(service, renamedVault.path) == ["A", "B", "Plain", "V2"])
        _ = try await service.createVault(named: "Other", in: "/share", password: "pw")
        await #expect(throws: VaultError.nested) { try await service.move([nas.item("/share/Other")], to: "/share/W") }

        try await service.delete([RemoteItem(path: "/share/W/Plain", name: "Plain", isDirectory: true),
                                  RemoteItem(path: "/share/W/V2", name: "V2", isDirectory: true)])
        #expect(try await names(service, "/share/W") == ["A", "B"])
        // A locked encrypted folder can still be renamed, moved and deleted.
        service.state.lock("/share/W")
        let renamedLocked = try await service.rename(nas.item("/share/W"), to: "W2")
        #expect(service.state.knownRoots.contains(renamedLocked.path))
        try FileManager.default.createDirectory(at: nas.url("/share/Box"), withIntermediateDirectories: true)
        try await service.move([nas.item("/share/W2")], to: "/share/Box")
        try await service.delete([nas.item("/share/Box/W2")])
        #expect(service.state.knownRoots == ["/share/Other"])
    }

    @Test func longNamesAndFolderDownloads() async throws {
        let nas = try LocalNAS()
        let service = VaultFileService(base: nas, state: VaultState())
        _ = try await service.createVault(named: "V", in: "/share", password: "pw")
        let long = String(repeating: "長い名前", count: 20)
        try await service.upload(try localFile("x", Data("long".utf8)), as: long + ".txt", to: "/share/V/" + long, replacing: false) { _ in }
        #expect(try await names(service, "/share/V") == [long])
        #expect(try await names(service, "/share/V/" + long) == [long + ".txt"])
        #expect(nas.storedNames(under: "/share/V").allSatisfy { $0.utf8.count <= 255 })

        let renamed = try await service.rename(RemoteItem(path: "/share/V/\(long)/\(long).txt", name: long + ".txt", isDirectory: false), to: "short.txt")
        #expect(try await names(service, "/share/V/" + long) == ["short.txt"])
        #expect(renamed.name == "short.txt")

        let zip = try await service.download(RemoteItem(path: "/share/V/" + long, name: long, isDirectory: true))
        #expect(zip.pathExtension == "zip")
        #expect(((try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0)
    }

    @Test func refusesWhatTheNASCantDoOnEncryptedFiles() async throws {
        let nas = try LocalNAS()
        let service = VaultFileService(base: nas, state: VaultState())
        _ = try await service.createVault(named: "V", in: "/share", password: "pw")
        let item = RemoteItem(path: "/share/V/a.zip", name: "a.zip", isDirectory: false)
        await #expect(throws: VaultError.unavailable) { _ = try await service.createShareLink(for: item, password: nil, expires: nil) }
        await #expect(throws: VaultError.unavailable) { try await service.extract(item, into: "/share/V") }
        await #expect(throws: NASError.unsupported) { try await service.compress([item], to: "/share/V/b.zip") }
        // A whole encrypted folder can't be zipped into a plain folder.
        await #expect(throws: VaultError.unavailable) { try await service.compress([nas.item("/share/V")], to: "/share/V.zip") }
        await #expect(throws: VaultError.unavailable) { _ = try await service.createShareLink(for: nas.item("/share/V"), password: nil, expires: nil) }
        await #expect(throws: NASError.notFound) { _ = try await service.thumbnail(for: item, size: .small) }
        #expect(service.directService(for: "/share/V/x") == nil)
        #expect(service.directService(for: "/share/other") != nil)
    }
}

private final class SavedRoots: @unchecked Sendable {
    var value: Set<String> = []
}
