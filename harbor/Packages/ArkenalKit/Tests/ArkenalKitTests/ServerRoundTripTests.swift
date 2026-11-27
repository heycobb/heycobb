import Foundation
import Security
import Testing
@testable import ArkenalKit

/// Runs the whole file workflow against a real server: Nextcloud or any
/// other WebDAV server, or SMB (Samba, as inside most NAS systems). Skipped
/// unless ARKENAL_IT_URL is set. Tools/test-servers starts local servers
/// and runs this for each.
///
/// - ARKENAL_IT_URL: the address as typed in the app ("smb://host:1445",
///   "https://host:8443/remote.php/dav/files/user/")
/// - ARKENAL_IT_USER, ARKENAL_IT_PASS: the account
/// - ARKENAL_IT_SHARE: an existing top-level folder (share) to work in
///
/// Everything happens in a new folder inside the share, removed at the end.
@Suite("Round trip against a server", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ARKENAL_IT_URL"] != nil))
struct ServerRoundTripTests {
    struct Setup {
        let service: any FileService
        let kind: ServerKind
        let root: String
    }

    private func connect() async throws -> Setup {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(env["ARKENAL_IT_URL"])
        let account = try #require(env["ARKENAL_IT_USER"])
        let password = try #require(env["ARKENAL_IT_PASS"])
        let share = try #require(env["ARKENAL_IT_SHARE"])
        let kind = try #require(ServerDetector.kind(fromText: address), "address must say smb:// or be an https URL with a path")
        let endpoint = try #require(Endpoint.parse(address, server: kind))
        let profile = ServerProfile(name: "Test", account: account, endpoints: [endpoint], kind: kind)
        let trust = CertificateTrust(keychain: Keychain(service: "com.snowlightlabs.arkenal.tests"))

        if kind == .webdav {
            // A fresh server's self-signed certificate is shown once, then trusted.
            do {
                _ = try await ConnectionResolver(trust: trust).resolve([endpoint], server: kind)
            } catch let NASError.untrustedCertificate(info) {
                trust.trust(info)
            }
        }
        step("wrong password")
        await #expect(throws: NASError.invalidCredentials) {
            _ = try await Connector.signIn(profile, at: endpoint, credentials: Credentials(account: account, password: password + "x"),
                                           trust: trust, deviceName: "Test", previous: nil, rememberDevice: false)
        }
        step("sign in")
        let session = try await Connector.signIn(profile, at: endpoint, credentials: Credentials(account: account, password: password),
                                                 trust: trust, deviceName: "Test", previous: nil, rememberDevice: false)
        step("connect")
        let service = try await Connector.connect(profile, at: endpoint, session: session, trust: trust)
        step("list shares")
        let shares = try await service.listShares().map(\.name)
        #expect(shares.contains(share), "shares: \(shares)")
        step("create test folder")
        let folder = try await service.createFolder(named: "Arkenal Test \(UUID().uuidString.prefix(8))", in: "/" + share)
        return Setup(service: service, kind: kind, root: folder.path)
    }

    /// Prints progress when ARKENAL_IT_VERBOSE is set (to find a step that hangs).
    private func step(_ label: String) {
        if ProcessInfo.processInfo.environment["ARKENAL_IT_VERBOSE"] != nil {
            FileHandle.standardError.write(Data("STEP \(Date().timeIntervalSince1970) \(label)\n".utf8))
        }
    }

    private func local(_ data: Data, _ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "arkenal-it-\(name)")
        try data.write(to: url)
        return url
    }

    private func names(_ service: any FileService, _ folder: String) async throws -> [String] {
        try await service.list(folder: folder, offset: 0, limit: 200, sort: .name, ascending: true).items.map(\.name)
    }

    @Test func filesFoldersAndNames() async throws {
        let setup = try await connect()
        let service = setup.service, root = setup.root
        defer { Task { try? await service.delete([RemoteItem(path: root, name: "", isDirectory: true)]) } }

        step("upload new/deep")
        // Upload into folders that don't exist yet; refuse to replace unless asked.
        let ten = try local(Data("0123456789".utf8))
        try await service.upload(ten, as: "Ten #1.txt", to: root + "/New/Deep", replacing: false) { _ in }
        await #expect(throws: NASError.alreadyExists) {
            try await service.upload(ten, as: "Ten #1.txt", to: root + "/New/Deep", replacing: false) { _ in }
        }
        try await service.upload(ten, as: "Ten #1.txt", to: root + "/New/Deep", replacing: true) { _ in }
        let file = try #require(try await service.list(folder: root + "/New/Deep", offset: 0, limit: 10, sort: .name, ascending: true).items.first)
        #expect(file.name == "Ten #1.txt")
        #expect(file.size == 10)
        #expect(file.modified != nil)

        step("read range")
        let range = try await service.read(file, from: 2, length: 3)
        #expect(String(decoding: range.data, as: UTF8.self) == "234")
        #expect(range.totalLength == 10)
        #expect(try Data(contentsOf: try await service.download(file)) == Data("0123456789".utf8))

        step("odd names")
        // Names people actually use: accents (both Unicode forms), emoji, symbols.
        let odd = ["Café menu.txt", "Cafe\u{301} decomposed.txt", "Fjord 🌲 notes.txt", "50% off & more (1).txt", "spaces  twice.txt"]
        for name in odd {
            try await service.upload(ten, as: name, to: root, replacing: false) { _ in }
        }
        let listed = try await names(service, root)
        for name in odd {
            #expect(listed.contains { $0.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping }, "missing \(name): \(listed)")
        }

        step("rename")
        // Rename, refuse a clashing folder, move, search.
        let renamed = try await service.rename(file, to: "Renamed.txt")
        #expect(renamed.name == "Renamed.txt")
        await #expect(throws: NASError.alreadyExists) { _ = try await service.createFolder(named: "Deep", in: root + "/New") }
        step("create Sub")
        _ = try await service.createFolder(named: "Sub", in: root)
        step("move")
        try await service.move([renamed], to: root + "/Sub")
        #expect(try await names(service, root + "/Sub") == ["Renamed.txt"])
        step("search")
        #expect(try await service.search(in: root, matching: "renamed").map(\.path) == [root + "/Sub/Renamed.txt"])

        step("big file")
        // A bigger file, so uploads and downloads go through more than one chunk.
        var big = Data(count: 20 * 1024 * 1024 + 123)
        big.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let bigURL = try local(big)
        defer { try? FileManager.default.removeItem(at: bigURL) }
        try await service.upload(bigURL, as: "Big.bin", to: root, replacing: false) { _ in }
        let bigItem = try #require(try await service.list(folder: root, offset: 0, limit: 200, sort: .name, ascending: true).items.first { $0.name == "Big.bin" })
        #expect(bigItem.size == Int64(big.count))
        step("big tail")
        let tail = try await service.read(bigItem, from: Int64(big.count - 50), length: 50)
        #expect(tail.data == big.suffix(50))
        #expect(try Data(contentsOf: try await service.download(bigItem)) == big)

        step("delete")
        // Delete several at once.
        try await service.delete([RemoteItem(path: root + "/New", name: "New", isDirectory: true), bigItem])
        let after = try await names(service, root)
        #expect(!after.contains("New") && !after.contains("Big.bin"))
    }

    @Test func encryptedFolder() async throws {
        let setup = try await connect()
        let root = setup.root
        defer { Task { try? await setup.service.delete([RemoteItem(path: root, name: "", isDirectory: true)]) } }
        let state = VaultState()
        let vault = VaultFileService(base: setup.service, state: state)

        step("create vault")
        let (folder, recovery) = try await vault.createVault(named: "Private", in: root, password: "pw")
        let secret = Data(repeating: 0x5A, count: 300_000) + Data("the end".utf8)
        try await vault.upload(try local(secret), as: "Tax return 2026.pdf", to: folder.path + "/Taxes", replacing: false) { _ in }
        step("vault list")
        #expect(try await names(vault, folder.path) == ["Taxes"])
        let item = try #require(try await vault.list(folder: folder.path + "/Taxes", offset: 0, limit: 10, sort: .name, ascending: true).items.first)
        #expect(item.name == "Tax return 2026.pdf")
        #expect(item.size == Int64(secret.count))
        #expect(try Data(contentsOf: try await vault.download(item)) == secret)
        #expect(try await vault.read(item, from: Int64(secret.count - 7), length: 7).data == Data("the end".utf8))

        // On the server: only the settings file and scrambled names.
        let stored = try await names(setup.service, folder.path)
        #expect(stored.contains(Vault.configName))
        #expect(!stored.contains("Taxes"))

        step("vault rename")
        _ = try await vault.rename(item, to: "Renamed.pdf")
        state.lock(folder.path)
        await #expect(throws: VaultError.locked(folder.path)) {
            _ = try await vault.list(folder: folder.path, offset: 0, limit: 10, sort: .name, ascending: true)
        }
        try await vault.unlock(folder.path, recoveryKey: recovery)
        #expect(try await names(vault, folder.path + "/Taxes") == ["Renamed.pdf"])
    }

    /// Typing just a Nextcloud server's address (ARKENAL_IT_NEXTCLOUD, e.g.
    /// "localhost:8443") finds its WebDAV address.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARKENAL_IT_NEXTCLOUD"]?.isEmpty == false))
    func findsNextcloudFromItsAddress() async throws {
        let typed = try #require(ProcessInfo.processInfo.environment["ARKENAL_IT_NEXTCLOUD"])
        #expect(await ServerDetector.detect(typed) == .webdav)
        let address = try #require(await ServerDetector.nextcloudAddress(typed))
        #expect(address.hasSuffix("/remote.php/webdav/"))
        #expect(await ServerDetector.nextcloudAddress(address) == nil)
        #expect(await ServerDetector.nextcloudAddress("smb://" + typed) == nil)
    }
}
