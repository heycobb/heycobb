import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import OwnholdKit

@Suite("Endpoint parsing")
struct EndpointTests {
    @Test func defaultsToHTTPSAndPort5001() throws {
        let endpoint = try #require(Endpoint.parse("nas.local"))
        #expect(endpoint.url.absoluteString == "https://nas.local:5001")
        #expect(endpoint.kind == .local)
    }

    @Test func keepsExplicitPort() throws {
        let endpoint = try #require(Endpoint.parse("https://files.example.com:443/some/path"))
        #expect(endpoint.url.absoluteString == "https://files.example.com:443")
        #expect(endpoint.kind == .remote)
    }

    @Test func recognizesPrivateNetworks() throws {
        #expect(Endpoint.parse("100.101.102.103")?.kind == .vpn)
        #expect(Endpoint.parse("nas.tail1234.ts.net")?.kind == .vpn)
        #expect(Endpoint.parse("100.20.1.1")?.kind == .remote) // public 100.x, not Tailscale's range
    }

    @Test func rejectsPlainHTTP() {
        #expect(Endpoint.parse("http://nas.local:5000") == nil)
        #expect(Endpoint.parse("   ") == nil)
    }
}

@Suite("Wire format")
struct WireFormatTests {
    @Test func decodesFolderListing() throws {
        let json = """
        {"data":{"files":[
          {"isdir":true,"name":"Photos","path":"/home/Photos","additional":{"size":0,"time":{"mtime":1700000000}}},
          {"isdir":false,"name":"a.jpg","path":"/home/a.jpg","additional":{"size":12345,"time":{"mtime":1700000100}}}
        ],"offset":0,"total":2},"success":true}
        """
        let envelope = try FileStationClient.decode(Envelope<FileList>.self, from: Data(json.utf8))
        let items = try #require(envelope.data).files.map(\.item)
        #expect(items.count == 2)
        #expect(items[0].isDirectory && items[0].size == nil)
        #expect(items[1].size == 12345)
        #expect(items[1].modified == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(items[1].kind == .image)
    }

    @Test func decodesError() throws {
        let json = #"{"error":{"code":403},"success":false}"#
        let envelope = try FileStationClient.decode(Envelope<LoginData>.self, from: Data(json.utf8))
        #expect(!envelope.success)
        #expect(NASError.from(code: try #require(envelope.error).code, api: "SYNO.API.Auth") == .twoFactorRequired)
    }

    @Test func errorCodesDependOnAPI() {
        #expect(NASError.from(code: 408, api: "SYNO.FileStation.List") == .notFound)
        #expect(NASError.from(code: 408, api: "SYNO.API.Auth") == .passwordExpired)
        #expect(NASError.from(code: 119, api: "SYNO.FileStation.List") == .sessionExpired)
    }

    @Test func formEncodingEscapesReservedCharacters() {
        let body = FormEncoding.encode(["passwd": "a&b=c d+é", "account": "me"])
        #expect(body == "account=me&passwd=a%26b%3Dc%20d%2B%C3%A9")
    }
}

@Suite("Demo library")
struct DemoTests {
    @Test func listsFoldersFirst() async throws {
        let page = try await DemoFileService().list(folder: "/Photos", offset: 0, limit: 100, sort: .name, ascending: true)
        #expect(page.items.first?.isDirectory == true)
        #expect(page.total == 5)
    }

    @Test func rendersThumbnails() async throws {
        let item = RemoteItem(path: "/Photos/x.jpg", name: "x.jpg", isDirectory: false)
        let data = try await DemoFileService().thumbnail(for: item, size: .small)
        #expect(ImageDecoding.downsample(data, maxPixel: 100) != nil)
    }

    @Test func searchFindsNestedFiles() async throws {
        let results = try await DemoFileService().search(in: "/", matching: "lighthouse")
        #expect(results.contains { $0.path.hasPrefix("/Photos/Coast trip/") })
    }

    /// The size shown in the list must match the file you actually get.
    @Test func listedSizesMatchDownloads() async throws {
        let service = DemoFileService()
        for folder in ["/Photos", "/Documents", "/Projects/Website"] {
            let page = try await service.list(folder: folder, offset: 0, limit: 100, sort: .name, ascending: true)
            for item in page.items where !item.isDirectory {
                let url = try await service.download(item)
                defer { try? FileManager.default.removeItem(at: url) }
                let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
                #expect(bytes == item.size, "\(item.path)")
            }
        }
    }

    @Test func nothingIsDatedInTheFuture() async throws {
        let service = DemoFileService()
        for folder in ["/", "/Photos", "/Photos/Coast trip", "/Documents", "/Projects"] {
            let page = try await service.list(folder: folder, offset: 0, limit: 100, sort: .name, ascending: true)
            #expect(page.items.allSatisfy { ($0.modified ?? .distantPast) <= Date() })
        }
    }
}

@Suite("Offline store")
struct OfflineStoreTests {
    /// Saved files keep their real name (Quick Look and the share sheet show
    /// it), and removing one leaves nothing behind.
    @Test func keepsRealNameAndCleansUp() async throws {
        let store = OfflineStore(namespace: "test-\(UUID().uuidString)")
        let service = DemoFileService()
        let item = try await service.list(folder: "/Documents", offset: 0, limit: 10, sort: .name, ascending: true)
            .items.first { $0.name == "Read me.md" }!

        try await store.save(item, using: service)
        let url = try #require(await store.localURL(for: item.path))
        #expect(url.lastPathComponent == "Read me.md")
        #expect(await store.totalBytes() == item.size)

        await store.remove(item.path)
        #expect(await store.localURL(for: item.path) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path(percentEncoded: false)))
        await store.removeAll()
    }
}


@Suite("Connection options")
struct ConnectionOptionTests {
    @Test func namesPrivateNetworksOnlyWhenCertain() throws {
        #expect(try #require(Endpoint.parse("nas.tail1234.ts.net", kind: .vpn)).displayName == "Tailscale")
        #expect(try #require(Endpoint.parse("nas.netbird.cloud", kind: .vpn)).displayName == "NetBird")
        // 100.64/10 is shared by Tailscale and NetBird; ZeroTier/WireGuard pick their own ranges.
        #expect(try #require(Endpoint.parse("100.101.102.103", kind: .vpn)).displayName == "Private network")
        #expect(try #require(Endpoint.parse("10.147.17.5", kind: .vpn)).displayName == "Private network")
        #expect(try #require(Endpoint.parse("192.168.1.20", kind: .local)).displayName == "Home network")
    }

    @Test func detectsSynologyDDNSAndPortTypos() throws {
        #expect(try #require(Endpoint.parse("brian.synology.me")).isSynologyDDNS)
        #expect(try #require(Endpoint.parse("home.myds.me:5001")).isSynologyDDNS)
        #expect(try #require(Endpoint.parse("synology.me.example.com")).isSynologyDDNS == false)
        #expect(try #require(Endpoint.parse("nas.example.com")).isSynologyDDNS == false)
        #expect(try #require(Endpoint.parse("nas.local:5000")).usesDSMHTTPPort)
        #expect(try #require(Endpoint.parse("nas.local")).usesDSMHTTPPort == false)
    }

    @Test func mergesEnteredAndDiscoveredAddresses() throws {
        let home = try #require(Endpoint.parse("192.168.1.20", kind: .local))
        let vpn = try #require(Endpoint.parse("nas.tail1234.ts.net", kind: .vpn))
        let found = try #require(Endpoint.parse("brian.synology.me", kind: .remote))
        let profile = ServerProfile(name: "NAS", account: "me", endpoints: [vpn, home], quickConnectID: "brian", discoveredEndpoints: [found, home])
        #expect(profile.allEndpoints == [home, vpn, found])
    }

    @Test func decodesProfilesSavedByEarlierBuilds() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"NAS","account":"me","endpoints":[{"kind":"tailscale","url":"https://nas.tail1234.ts.net:5001"}]}]"#
        let profiles = try JSONDecoder().decode([ServerProfile].self, from: Data(json.utf8))
        #expect(profiles.first?.endpoints.first?.kind == .vpn)
        #expect(profiles.first?.quickConnectID == nil)
        #expect(profiles.first?.discoveredEndpoints.isEmpty == true)
    }
}

@Suite("QuickConnect lookup")
struct QuickConnectTests {
    func reply(_ json: String) throws -> QuickConnectLookup.Reply {
        try QuickConnectLookup.decode(Data(json.utf8))
    }

    @Test func readsDirectAddressesAndIgnoresTheRelay() throws {
        let r = try reply(#"""
        [{"command":"get_server_info","errno":0,"version":1,
          "server":{"interface":[{"ip":"192.168.1.20","name":"eth0"},{"ip":"0.0.0.0"}],
                    "external":{"ip":"203.0.113.7","ipv6":"::"},"ddns":"brian.synology.me","fqdn":"NULL"},
          "service":{"port":5001,"ext_port":"0","relay_ip":"198.51.100.9","relay_port":443},
          "smartdns":{"host":"brian.direct.quickconnect.to","lan":["192-168-1-20.brian.direct.quickconnect.to"]}}]
        """#)
        guard case let .found(endpoints) = QuickConnectLookup.interpret(r) else { Issue.record("not found"); return }
        #expect(endpoints.map(\.url.absoluteString) == [
            "https://192.168.1.20:5001",
            "https://192-168-1-20.brian.direct.quickconnect.to:5001",
            "https://brian.synology.me:5001",
            "https://brian.direct.quickconnect.to:5001",
            "https://203.0.113.7:5001",
        ])
        #expect(endpoints.prefix(2).allSatisfy { $0.kind == .local })
        #expect(!endpoints.contains { $0.url.host() == "198.51.100.9" })
    }

    @Test func usesTheExternalPortForInternetAddresses() throws {
        let r = try reply(#"[{"errno":0,"server":{"interface":[{"ip":"10.0.0.5"}],"external":{"ip":"203.0.113.7"}},"service":{"port":5001,"ext_port":15001}}]"#)
        guard case let .found(endpoints) = QuickConnectLookup.interpret(r) else { Issue.record("not found"); return }
        #expect(endpoints.map(\.url.absoluteString) == ["https://10.0.0.5:5001", "https://203.0.113.7:15001"])
    }

    @Test func followsRegionalRedirectsOnlyToSynology() throws {
        let ok = try reply(#"[{"errno":4,"suberrno":2,"sites":["dec.quickconnect.to"]}]"#)
        #expect(QuickConnectLookup.interpret(ok) == .redirect("dec.quickconnect.to"))
        let hostile = try reply(#"[{"errno":4,"suberrno":2,"sites":["quickconnect.to.attacker.example"]}]"#)
        #expect(QuickConnectLookup.interpret(hostile) == .notFound)
    }

    @Test func reportsUnknownIDsAndBadReplies() throws {
        #expect(QuickConnectLookup.interpret(try reply(#"[{"errno":4,"suberrno":1}]"#)) == .notFound)
        #expect(QuickConnectLookup.interpret(try reply(#"[{"errno":9}]"#)) == .failed)
        #expect(throws: NASError.quickConnectUnavailable) { try QuickConnectLookup.decode(Data("<html>".utf8)) }
    }

    @Test func validatesIDs() {
        #expect(QuickConnectLookup.isValidID("brian-nas"))
        #expect(!QuickConnectLookup.isValidID("brian nas"))
        #expect(!QuickConnectLookup.isValidID("../etc"))
        #expect(!QuickConnectLookup.isValidID(""))
    }
}

@Suite("File changes")
struct FileChangeTests {
    @Test func validatesNames() {
        #expect(RemoteItem.isValidName("Holiday 2026"))
        #expect(RemoteItem.isValidName("Café.jpg"))
        #expect(!RemoteItem.isValidName(""))
        #expect(!RemoteItem.isValidName("   "))
        #expect(!RemoteItem.isValidName("a/b"))
        #expect(!RemoteItem.isValidName(".."))
        #expect(!RemoteItem.isValidName("line\nbreak"))
        #expect(!RemoteItem.isValidName(String(repeating: "é", count: 200)))
    }

    @Test func makesUniqueNames() {
        #expect(RemoteItem.uniqueName(for: "IMG.jpg", avoiding: ["Other.jpg"]) == "IMG.jpg")
        #expect(RemoteItem.uniqueName(for: "IMG.jpg", avoiding: ["img.JPG"]) == "IMG 2.jpg")
        #expect(RemoteItem.uniqueName(for: "IMG.jpg", avoiding: ["IMG.jpg", "IMG 2.jpg"]) == "IMG 3.jpg")
        #expect(RemoteItem.uniqueName(for: "Folder", avoiding: ["Folder"]) == "Folder 2")
    }

    @Test func mapsFileStationErrors() {
        #expect(NASError.from(code: 1805, api: "SYNO.FileStation.Upload") == .alreadyExists)
        #expect(NASError.from(code: 414, api: "SYNO.FileStation.CreateFolder") == .alreadyExists)
        #expect(NASError.from(code: 416, api: "SYNO.FileStation.Upload") == .noSpace)
        #expect(NASError.from(code: 419, api: "SYNO.FileStation.Rename") == .invalidName)
        #expect(NASError.from(code: 407, api: "SYNO.FileStation.Delete") == .permissionDenied)
    }

    @Test func encodesPathLists() throws {
        let items = [RemoteItem(path: "/Photos/a \"b\".jpg", name: "a", isDirectory: false), RemoteItem(path: "/Photos/Ç", name: "Ç", isDirectory: true)]
        let json = try FileStationClient.pathList(items)
        #expect(try JSONDecoder().decode([String].self, from: Data(json.utf8)) == items.map(\.path))
        #expect(!json.contains("\\/"))
    }

    @Test func writesMultipartBodies() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let body = try Multipart.write(fields: [("path", "/Photos")], file: source, fileName: "a\"b.txt", boundary: "XX")
        defer { try? FileManager.default.removeItem(at: body) }
        let text = try String(contentsOf: body, encoding: .utf8)
        #expect(text == "--XX\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/Photos\r\n--XX\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a%22b.txt\"\r\nContent-Type: application/octet-stream\r\n\r\nhello\r\n--XX--\r\n")
    }

    @Test func demoCreatesRenamesMovesAndDeletes() async throws {
        let demo = DemoFileService()
        let folder = try await demo.createFolder(named: "Trip", in: "/Photos")
        await #expect(throws: NASError.alreadyExists) { try await demo.createFolder(named: "trip", in: "/Photos") }

        let photo = try await demo.list(folder: "/Photos", offset: 0, limit: 100, sort: .name, ascending: true).items.first { !$0.isDirectory }!
        let before = try await demo.thumbnail(for: photo, size: .small)
        try await demo.move([photo], to: folder.path)
        let moved = try await demo.list(folder: folder.path, offset: 0, limit: 100, sort: .name, ascending: true).items
        #expect(moved.map(\.name) == [photo.name])
        #expect(try await demo.thumbnail(for: moved[0], size: .small) == before)

        let renamed = try await demo.rename(folder, to: "Coast 2")
        let inside = try await demo.list(folder: renamed.path, offset: 0, limit: 100, sort: .name, ascending: true).items
        #expect(inside.first?.path == "/Photos/Coast 2/\(photo.name)")

        await #expect(throws: NASError.permissionDenied) { try await demo.move([renamed], to: renamed.path) }
        try await demo.delete([renamed])
        let photos = try await demo.list(folder: "/Photos", offset: 0, limit: 100, sort: .name, ascending: true).items
        #expect(!photos.contains { $0.name == "Coast 2" })
        await #expect(throws: NASError.notFound) { try await demo.list(folder: renamed.path, offset: 0, limit: 10, sort: .name, ascending: true) }
    }

    @Test func demoUploadsAndReplaces() async throws {
        let demo = DemoFileService()
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("first".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        try await demo.upload(source, as: "Note.txt", to: "/Documents/New/Deep", replacing: false) { _ in }
        await #expect(throws: NASError.alreadyExists) {
            try await demo.upload(source, as: "note.TXT", to: "/Documents/New/Deep", replacing: false) { _ in }
        }
        try Data("second".utf8).write(to: source)
        try await demo.upload(source, as: "Note.txt", to: "/Documents/New/Deep", replacing: true) { _ in }
        let items = try await demo.list(folder: "/Documents/New/Deep", offset: 0, limit: 10, sort: .name, ascending: true).items
        #expect(items.count == 1)
        let copy = try await demo.download(items[0])
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(try String(contentsOf: copy, encoding: .utf8) == "second")
        #expect(items[0].size == 6)
    }

    @Test func demoCompressesExtractsAndShares() async throws {
        let demo = DemoFileService()
        let folder = try await demo.list(folder: "/Projects", offset: 0, limit: 10, sort: .name, ascending: true).items.first { $0.name == "Website" }!
        try await demo.compress([folder], to: "/Projects/Website.zip")
        await #expect(throws: NASError.alreadyExists) { try await demo.compress([folder], to: "/Projects/Website.zip") }
        let zip = try await demo.list(folder: "/Projects", offset: 0, limit: 10, sort: .name, ascending: true).items.first { $0.name == "Website.zip" }!
        #expect(zip.isArchive)
        #expect((zip.size ?? 0) > 0)
        #expect(try await demo.archiveTopLevel(zip) == ["Website"])
        // Extracting where "Website" exists would clash; into a new folder it doesn't.
        await #expect(throws: NASError.alreadyExists) { try await demo.extract(zip, into: "/Projects") }
        let target = try await demo.createFolder(named: "Unzipped", in: "/Projects")
        try await demo.extract(zip, into: target.path)
        let copied = try await demo.list(folder: "/Projects/Unzipped/Website", offset: 0, limit: 10, sort: .name, ascending: true).items
        #expect(Set(copied.map(\.name)) == ["index.html", "hero.jpg"])
        let link = try await demo.createShareLink(for: zip, password: "pw", expires: nil)
        #expect(link.hasPassword)
        #expect(link.url.host() == "nas.example.com")
    }

    @Test func backupFoldersByMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = ISO8601DateFormatter().date(from: "2026-03-05T12:00:00Z")!
        #expect(BackupPlanner.folder(for: date, in: "/home/Backup", calendar: calendar) == "/home/Backup/2026/03")
        #expect(BackupPlanner.folder(for: nil, in: "/home/Backup", calendar: calendar) == "/home/Backup/Undated")
    }

    @Test func backupSkipsWhatsDoneAndAvoidsClashes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!
        let live = BackupPlanner.Asset(id: "A", created: date, resources: [
            .init(name: "IMG_0001.HEIC", size: 100), .init(name: "IMG_0001.MOV", size: 900),
        ])
        let photo = BackupPlanner.Asset(id: "B", created: date, resources: [.init(name: "IMG_0002.HEIC", size: 200)])
        let clash = BackupPlanner.Asset(id: "C", created: date, resources: [.init(name: "IMG_0003.HEIC", size: 300)])
        let done = BackupPlanner.Asset(id: "D", created: date, resources: [.init(name: "IMG_0004.HEIC", size: 400)])
        let plan = BackupPlanner.plan(
            [live, photo, clash, done],
            destination: "/home/Backup",
            history: [BackupPlanner.historyKey(assetID: "D", resource: "IMG_0004.HEIC")],
            existing: ["/home/Backup/2026/11": ["img_0002.heic": 200, "img_0003.heic": 999]],
            calendar: calendar
        )
        // B is already on the NAS (same name and size); D was backed up before.
        #expect(plan.alreadyThere == [BackupPlanner.historyKey(assetID: "B", resource: "IMG_0002.HEIC")])
        #expect(plan.jobs.map(\.name) == ["IMG_0001.HEIC", "IMG_0001.MOV", "IMG_0003 2.HEIC"])
        #expect(Set(plan.jobs.map(\.folder)) == ["/home/Backup/2026/11"])
        #expect(plan.bytes == 1300)
    }

    @Test func backupChecksUnknownSizesLater() {
        let asset = BackupPlanner.Asset(id: "A", created: nil, resources: [.init(name: "IMG_1.HEIC", size: nil), .init(name: "IMG_2.HEIC", size: nil)])
        let plan = BackupPlanner.plan([asset], destination: "/b", history: [], existing: ["/b/Undated": ["img_1.heic": 10]])
        #expect(plan.jobs.map(\.checkExisting) == [true, false])
        #expect(plan.jobs.map(\.name) == ["IMG_1.HEIC", "IMG_2.HEIC"])
    }

    @Test func sharedChangesMergeAndClear() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        SharedChanges.record(domain: "abc", folders: ["/home/a"], in: directory)
        SharedChanges.record(domain: "abc", folders: ["/home/a", "/home/b"], removed: ["/home/a/x"], in: directory)
        SharedChanges.record(domain: "other", folders: ["/z"], in: directory)
        let taken = SharedChanges.take(domain: "abc", in: directory)
        #expect(taken.folders == ["/home/a", "/home/b"])
        #expect(taken.removed == ["/home/a/x"])
        #expect(SharedChanges.take(domain: "abc", in: directory).isEmpty)
        #expect(SharedChanges.take(domain: "other", in: directory).folders == ["/z"])
    }

    @Test func searchPatterns() {
        #expect(FileStationClient.searchPattern("tax") == "*tax*")
        #expect(FileStationClient.searchPattern(" Ownhold Extract ") == "*Ownhold Extract*")
        #expect(FileStationClient.searchPattern("*.pdf") == "*.pdf")
        #expect(FileStationClient.searchPattern("IMG_00??") == "IMG_00??")
    }

    @Test func archiveNames() {
        #expect(RemoteItem(path: "/a/b.tar.gz", name: "b.tar.gz", isDirectory: false).isArchive)
        #expect(RemoteItem(path: "/a/b.7Z", name: "b.7Z", isDirectory: false).isArchive)
        #expect(!RemoteItem(path: "/a/b.txt", name: "b.txt", isDirectory: false).isArchive)
        #expect(!RemoteItem(path: "/a/b.zip", name: "b.zip", isDirectory: true).isArchive)
    }

    @Test func offlineFilesFollowRenames() async throws {
        let store = OfflineStore(namespace: "test-\(UUID().uuidString)")
        let demo = DemoFileService()
        let item = try await demo.list(folder: "/Documents", offset: 0, limit: 10, sort: .name, ascending: true).items.first { $0.name == "Read me.md" }!
        try await store.save(item, using: demo)
        await store.relocate(from: "/Documents", to: "/Docs")
        #expect(await store.localURL(for: item.path) == nil)
        let url = try #require(await store.localURL(for: "/Docs/Read me.md"))
        #expect(url.lastPathComponent == "Read me.md")
        await store.relocate(from: "/Docs/Read me.md", to: "/Docs/Welcome.md")
        #expect(try #require(await store.localURL(for: "/Docs/Welcome.md")).lastPathComponent == "Welcome.md")
        await store.removeAll()
    }
}

@Suite("Sharing and streaming")
struct StreamingTests {
    @Test func parsesContentRange() {
        #expect(FileStationClient.totalLength(contentRange: "bytes 0-1/12345") == 12345)
        #expect(FileStationClient.totalLength(contentRange: "bytes 100-199/*") == nil)
        #expect(FileStationClient.totalLength(contentRange: nil) == nil)
    }

    @Test func knowsWhatCanStream() {
        #expect(RemoteItem(path: "/a.MOV", name: "a.MOV", isDirectory: false).isStreamable)
        #expect(RemoteItem(path: "/a.m4a", name: "a.m4a", isDirectory: false).isStreamable)
        #expect(!RemoteItem(path: "/a.mkv", name: "a.mkv", isDirectory: false).isStreamable)
        #expect(!RemoteItem(path: "/a.mp4", name: "a.mp4", isDirectory: true).isStreamable)
    }

    @Test func demoVideoStreamsInRanges() async throws {
        let demo = DemoFileService()
        let video = try #require(try await demo.list(folder: "/Photos/Coast trip", offset: 0, limit: 100, sort: .name, ascending: true)
            .items.first { $0.isStreamable })
        let first = try await demo.read(video, from: 0, length: 2)
        #expect(first.data.count == 2)
        #expect(first.totalLength == video.size)
        let tail = try await demo.read(video, from: first.totalLength - 10, length: 100)
        #expect(tail.data.count == 10)
        // A real, playable movie.
        let asset = AVURLAsset(url: try await demo.download(video))
        #expect(try await asset.load(.duration).seconds > 5)
    }

    @Test func loaderServesThePlayer() async throws {
        let demo = DemoFileService()
        let video = try #require(try await demo.list(folder: "/Photos/Coast trip", offset: 0, limit: 100, sort: .name, ascending: true)
            .items.first { $0.isStreamable })
        let loader = StreamingLoader(item: video, service: demo)
        try await loader.probe()
        let asset = loader.makeAsset()
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds > 5)
        withExtendedLifetime(loader) {}
    }

    @Test func demoFolderDownloadsAsZip() async throws {
        let demo = DemoFileService()
        let folder = RemoteItem(path: "/Documents", name: "Documents", isDirectory: true)
        let zip = try await demo.download(folder)
        defer { try? FileManager.default.removeItem(at: zip) }
        let head = try FileHandle(forReadingFrom: zip).read(upToCount: 4)
        #expect(head == Data([0x50, 0x4B, 0x03, 0x04])) // "PK\u{3}\u{4}"
    }
}

@Suite("Device thumbnails")
struct LocalThumbnailTests {
    /// A camera-style JPEG with an embedded preview: the first 64 KB are
    /// enough, without decoding (or downloading) the whole photo.
    @Test func readsEmbeddedPreviewFromPartialFile() throws {
        // A detailed image, so the file is much larger than its preview.
        let ctx = try #require(CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0 ..< 200 {
            ctx.setFillColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1)
            ctx.fill(CGRect(x: i * 12, y: (i * 37) % 1600, width: 300, height: 200))
        }
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let head = (out as Data).prefix(64 * 1024)
        #expect(head.count < (out as Data).count)
        let preview = try #require(LocalThumbnailer.embeddedPreview(Data(head), maxPixel: 400))
        #expect(max(preview.width, preview.height) <= 400)
    }

    @Test func noPreviewMeansNil() throws {
        // A plain JPEG without an embedded thumbnail, cut short: nothing to use.
        let full = try #require(DemoFileService.renderPhoto(seed: "y", width: 2400, height: 1600))
        #expect(LocalThumbnailer.embeddedPreview(Data(full.prefix(4096)), maxPixel: 400) == nil)
    }

    @Test func videoFrameFromRanges() async throws {
        let demo = DemoFileService()
        let video = try #require(try await demo.list(folder: "/Photos/Coast trip", offset: 0, limit: 100, sort: .name, ascending: true)
            .items.first { $0.isStreamable })
        let data = try #require(await LocalThumbnailer.shared.thumbnail(for: video, maxPixel: 300, service: demo))
        let image = try #require(ImageDecoding.downsample(data, maxPixel: 300))
        #expect(max(image.width, image.height) <= 300)
    }
}

@Suite("DSM replies")
struct DSMReplyTests {
    /// The shape DSM 7 returns for Rename: files only, no total/offset.
    @Test func decodesRenameReply() throws {
        let json = #"{"data":{"files":[{"additional":{"size":50,"time":{"mtime":1795651740}},"isdir":false,"name":"renamed-test.txt","path":"/home/TEST FOLDER/Ownhold Test/renamed-test.txt"}]},"success":true}"#
        let envelope = try FileStationClient.decode(Envelope<RenamedFiles>.self, from: Data(json.utf8))
        #expect(envelope.data?.files.first?.item.name == "renamed-test.txt")
        #expect(envelope.data?.files.first?.item.size == 50)
    }
}

@Suite("Kept downloads")
struct KeptDownloadsTests {
    private func store() -> KeptDownloads {
        let defaults = UserDefaults(suiteName: "kept-\(UUID().uuidString)")!
        return KeptDownloads(domain: "test", defaults: defaults)
    }

    @Test func insideAKeptFolderCountsAsKept() {
        let kept = store()
        kept.keep(["/home/Photos"])
        #expect(kept.isKept("/home/Photos"))
        #expect(!kept.isKept("/home/Photos/2024"))
        #expect(kept.isInsideKept("/home/Photos/2024/a.jpg"))
        #expect(!kept.isInsideKept("/home/Photos 2"))
    }

    @Test func keepingAFolderDropsEntriesInsideIt() {
        let kept = store()
        kept.keep(["/home/Photos/2024", "/home/Docs/a.pdf"])
        kept.keep(["/home/Photos"])
        #expect(kept.paths.sorted() == ["/home/Docs/a.pdf", "/home/Photos"])
    }

    @Test func stopAndMove() {
        let kept = store()
        kept.keep(["/home/Photos", "/home/Docs"])
        kept.stop(["/home/Docs"])
        kept.move(from: "/home/Photos", to: "/home/Pictures")
        #expect(kept.paths == ["/home/Pictures"])
    }
}

@Suite("Folder backup planner")
struct FolderBackupPlannerTests {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func copiesOnlyNewAndChangedFiles() {
        let same = FolderBackupPlanner.LocalFile(relativePath: "a.txt", size: 10, modified: date)
        let edited = FolderBackupPlanner.LocalFile(relativePath: "b.txt", size: 12, modified: date)
        let new = FolderBackupPlanner.LocalFile(relativePath: "Sub/c.txt", size: 1, modified: date)
        let history = ["a.txt": same.signature, "b.txt": "10-1700000000"]
        #expect(FolderBackupPlanner.changed([same, edited, new], history: history) == [edited, new])
    }

    @Test func placesFilesUnderTheFolderName() {
        let file = FolderBackupPlanner.LocalFile(relativePath: "Taxes/2025/return.pdf", size: 1, modified: date)
        let location = FolderBackupPlanner.remoteLocation(of: file, folderName: "Documents", destination: "/home/Mac Backup")
        #expect(location.folder == "/home/Mac Backup/Documents/Taxes/2025")
        #expect(location.name == "return.pdf")
    }

    @Test func skipsClutterAndKeepsNamesUnique() {
        #expect(FolderBackupPlanner.shouldSkip(name: ".DS_Store"))
        #expect(FolderBackupPlanner.shouldSkip(name: "~$Report.docx"))
        #expect(!FolderBackupPlanner.shouldSkip(name: "Report.docx"))
        #expect(FolderBackupPlanner.folderNames(["Documents", "documents", "Desktop"]) == ["Documents", "documents 2", "Desktop"])
    }
}

@Suite("Network policy")
struct NetworkPolicyTests {
    @Test func wifiAllowsEverything() {
        #expect(NetworkPolicy.allows(expensive: false, constrained: false, cellularAllowed: false, automatic: true))
    }

    @Test func cellularFollowsTheSwitch() {
        #expect(!NetworkPolicy.allows(expensive: true, constrained: false, cellularAllowed: false, automatic: false))
        #expect(NetworkPolicy.allows(expensive: true, constrained: false, cellularAllowed: true, automatic: true))
    }

    @Test func lowDataModePausesOnlyAutomaticWork() {
        #expect(!NetworkPolicy.allows(expensive: false, constrained: true, cellularAllowed: true, automatic: true))
        #expect(NetworkPolicy.allows(expensive: false, constrained: true, cellularAllowed: true, automatic: false))
    }

    @Test func defaults() {
        let defaults = UserDefaults(suiteName: "policy-\(UUID().uuidString)")!
        #expect(!NetworkPolicy.isCellularAllowed(.backups, defaults: defaults))
        #expect(NetworkPolicy.isCellularAllowed(.largeUploads, defaults: defaults))
        #expect(!NetworkPolicy.isCellularAllowed(.keptDownloads, defaults: defaults))
    }
}

@Suite("Wake on LAN")
struct WakeOnLANTests {
    @Test func parsesCommonMACFormats() {
        let expected: [UInt8] = [0x00, 0x11, 0x32, 0xAA, 0xBB, 0xCC]
        #expect(WakeOnLAN.parseMAC("00:11:32:aa:bb:cc") == expected)
        #expect(WakeOnLAN.parseMAC("00-11-32-AA-BB-CC") == expected)
        #expect(WakeOnLAN.parseMAC("001132AABBCC") == expected)
        #expect(WakeOnLAN.parseMAC("00:11:32:aa:bb") == nil)
        #expect(WakeOnLAN.parseMAC("not a mac addr") == nil)
        #expect(WakeOnLAN.format(expected) == "00:11:32:AA:BB:CC")
    }

    @Test func magicPacketLayout() {
        let mac: [UInt8] = [1, 2, 3, 4, 5, 6]
        let packet = WakeOnLAN.packet(for: mac)
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))
        #expect(Array(packet.suffix(6)) == mac)
    }

    @Test func oldSavedProfilesDecodeWithoutMAC() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"NAS","account":"a","endpoints":[]}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.macAddress == nil)
    }
}

@Suite("Recycle Bin")
struct RecycleBinTests {
    @Test func originalPaths() {
        #expect(RecycleBin.folder(forShare: "/home") == "/home/#recycle")
        #expect(RecycleBin.originalPath(of: "/home/#recycle/TEST FOLDER/a.txt") == "/home/TEST FOLDER/a.txt")
        #expect(RecycleBin.originalPath(of: "/home/#recycle/a.txt") == "/home/a.txt")
        #expect(RecycleBin.originalPath(of: "/home/#recycle") == nil)
        #expect(RecycleBin.originalPath(of: "/home/Photos/a.jpg") == nil)
        #expect(RecycleBin.contains("/home/#recycle/x"))
        #expect(!RecycleBin.contains("/home/x/#recycle"))
    }
}

@Suite("Photo timeline")
struct PhotoTimelineTests {
    private func photo(_ name: String, _ date: String?) -> RemoteItem {
        let formatter = ISO8601DateFormatter()
        return RemoteItem(path: "/p/\(name)", name: name, isDirectory: false, modified: date.flatMap(formatter.date))
    }

    @Test func groupsByMonthNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let items = [
            photo("a.jpg", "2025-03-02T10:00:00Z"),
            photo("b.heic", "2026-11-20T10:00:00Z"),
            photo("c.mov", "2026-11-01T10:00:00Z"),
            photo("notes.pdf", "2026-11-05T10:00:00Z"),
            photo("d.jpg", nil),
        ]
        let months = PhotoTimeline.months(items, calendar: calendar)
        #expect(months.map(\.id) == ["2026-11", "2025-03", "undated"])
        #expect(months[0].items.map(\.name) == ["b.heic", "c.mov"])
    }

    @Test func skipsRecycleAndSystemFolders() {
        #expect(PhotoTimeline.shouldSkipFolder(RemoteItem(path: "/home/#recycle", name: "#recycle", isDirectory: true)))
        #expect(PhotoTimeline.shouldSkipFolder(RemoteItem(path: "/home/x/@eaDir", name: "@eaDir", isDirectory: true)))
        #expect(!PhotoTimeline.shouldSkipFolder(RemoteItem(path: "/home/2024", name: "2024", isDirectory: true)))
    }
}

@Suite struct CertificateKeyTests {
    /// URLSession reports hosts in lowercase; a NAS found on the network
    /// keeps its name's case ("FirelandsDS25.local").
    @Test func hostKeyIgnoresCase() {
        #expect(CertificateTrust.hostKey(host: "FirelandsDS25.local", port: 5001) == "firelandsds25.local:5001")
        #expect(CertificateTrust.hostKey(host: "FirelandsDS25.local", port: 5001) == CertificateTrust.hostKey(host: "firelandsds25.local", port: 5001))
    }
}

@Suite("Other NAS: SMB and WebDAV")
struct SharingProtocolTests {
    @Test func parsesAddressesPerKind() throws {
        #expect(Endpoint.parse("nas.local", server: .smb)?.url.absoluteString == "smb://nas.local")
        #expect(Endpoint.parse("smb://192.168.1.5", server: .smb)?.url.absoluteString == "smb://192.168.1.5")
        #expect(Endpoint.parse("smb://nas.local:1445", server: .smb)?.url.absoluteString == "smb://nas.local:1445")
        #expect(Endpoint.parse("ftp://nas.local", server: .smb) == nil)
        #expect(Endpoint.parse("nas.local:5006", server: .webdav)?.url.absoluteString == "https://nas.local:5006/")
        #expect(Endpoint.parse("https://cloud.example.com/remote.php/dav/files/me", server: .webdav)?.url.absoluteString
            == "https://cloud.example.com/remote.php/dav/files/me/")
        #expect(Endpoint.parse("http://nas.local:5005", server: .webdav) == nil)
        #expect(Endpoint.parse("nas.local", server: .synology)?.url.absoluteString == "https://nas.local:5001")
    }

    @Test func kindFromTypedText() {
        #expect(ServerDetector.kind(fromText: "smb://nas.local") == .smb)
        #expect(ServerDetector.kind(fromText: "https://cloud.example.com/remote.php/dav/") == .webdav)
        #expect(ServerDetector.kind(fromText: "https://nas.local:5006/") == nil)
        #expect(ServerDetector.kind(fromText: "nas.local") == nil)
    }

    @Test func savedProfilesWithoutKindAreSynology() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"NAS","account":"me","endpoints":[]}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.kind == .synology)
        let smb = ServerProfile(name: "Q", account: "me", endpoints: [], kind: .smb)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(smb))
        #expect(decoded.kind == .smb)
    }

    @Test func parsesMultistatus() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/dav/files/me/Photos/</D:href><D:propstat><D:prop>
            <D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>https://nas.local/dav/files/me/Photos/Beach%20Day.jpg</D:href><D:propstat><D:prop>
            <D:resourcetype/><D:getcontentlength>12345</D:getcontentlength>
            <D:getlastmodified>Tue, 03 Jun 2025 14:02:11 GMT</D:getlastmodified></D:prop></D:propstat></D:response>
          <D:response><D:href>/dav/files/me/Photos/2024/</D:href><D:propstat><D:prop>
            <D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
        </D:multistatus>
        """
        let items = try WebDAVMultistatus.parse(Data(xml.utf8), base: URL(string: "https://nas.local/dav/files/me/")!)
        #expect(items.map(\.path) == ["/Photos", "/Photos/Beach Day.jpg", "/Photos/2024"])
        #expect(items[1].name == "Beach Day.jpg")
        #expect(items[1].size == 12345)
        #expect(!items[1].isDirectory && items[2].isDirectory)
        #expect(items[1].modified == Date(timeIntervalSince1970: 1_748_959_331))
    }

    @Test func encodesPaths() {
        let base = URL(string: "https://nas.local:5006/")!
        #expect(WebDAVClient.url(base: base, path: "/home/A #1 & 50%.txt", isDirectory: false).absoluteString
            == "https://nas.local:5006/home/A%20%231%20&%2050%25.txt")
        #expect(WebDAVClient.url(base: base, path: "/home/TEST FOLDER", isDirectory: true).absoluteString
            == "https://nas.local:5006/home/TEST%20FOLDER/")
    }

    @Test func sortsFoldersFirstAndPages() {
        let items = [
            RemoteItem(path: "/s/b.txt", name: "b.txt", isDirectory: false, size: 1),
            RemoteItem(path: "/s/Z", name: "Z", isDirectory: true),
            RemoteItem(path: "/s/a10.txt", name: "a10.txt", isDirectory: false, size: 3),
            RemoteItem(path: "/s/a2.txt", name: "a2.txt", isDirectory: false, size: 2),
        ]
        let page = SharingProtocols.page(items, offset: 0, limit: 10, sort: .name, ascending: true)
        #expect(page.items.map(\.name) == ["Z", "a2.txt", "a10.txt", "b.txt"])
        let second = SharingProtocols.page(items, offset: 2, limit: 1, sort: .size, ascending: false)
        #expect(second.items.map(\.name) == ["a2.txt"] && second.total == 4 && second.hasMore)
    }

    @Test func hidesHousekeepingFolders() {
        for name in ["@eaDir", "#recycle", ".DS_Store", "@Recycle", ".@__thumb", "desktop.ini", "$RECYCLE.BIN"] {
            #expect(SharingProtocols.isHidden(name), "\(name)")
        }
        #expect(!SharingProtocols.isHidden("Photos"))
    }

    @Test func searchesBelowAFolder() async throws {
        let tree: [String: [RemoteItem]] = [
            "/s": [RemoteItem(path: "/s/Trip", name: "Trip", isDirectory: true), RemoteItem(path: "/s/trip.pdf", name: "trip.pdf", isDirectory: false)],
            "/s/Trip": [RemoteItem(path: "/s/Trip/map.png", name: "map.png", isDirectory: false)],
        ]
        let found = try await SharingProtocols.search(in: "/s", matching: "trip") { tree[$0] ?? [] }
        #expect(Set(found.map(\.path)) == ["/s/Trip", "/s/trip.pdf"])
    }

    @Test func splitsPaths() {
        #expect(SharingProtocols.split("/home/TEST FOLDER/docs")! == ("home", "TEST FOLDER/docs"))
        #expect(SharingProtocols.split("/home")! == ("home", ""))
        #expect(SharingProtocols.split("/") == nil)
        #expect(SharingProtocols.ancestors(of: "/a/b") == ["/a", "/a/b"])
    }
}

/// Runs against a real WebDAV server when OWNHOLD_WEBDAV_URL, _USER and
/// _PASS are set (for example a local Apache with mod_dav); skipped otherwise.
@Suite("WebDAV against a server", .enabled(if: ProcessInfo.processInfo.environment["OWNHOLD_WEBDAV_URL"] != nil))
struct WebDAVIntegrationTests {
    @Test func fullRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(env["OWNHOLD_WEBDAV_URL"])
        let account = try #require(env["OWNHOLD_WEBDAV_USER"])
        let password = try #require(env["OWNHOLD_WEBDAV_PASS"])
        #expect(await ServerDetector.detect(address) == .webdav)

        let endpoint = try #require(Endpoint.parse(address, server: .webdav))
        let profile = ServerProfile(name: "Test", account: account, endpoints: [endpoint], kind: .webdav)
        let trust = CertificateTrust(keychain: Keychain(service: "app.ownhold.tests"))
        defer { trust.forget(host: CertificateTrust.hostKey(host: endpoint.url.host() ?? "", port: endpoint.url.port ?? 443)) }

        // First contact: the self-signed certificate must be reviewed.
        do {
            _ = try await ConnectionResolver(trust: trust).resolve([endpoint], server: .webdav)
            Issue.record("expected an untrusted certificate")
        } catch let NASError.untrustedCertificate(info) {
            trust.trust(info)
        }
        #expect(try await ConnectionResolver(trust: trust).resolve([endpoint], server: .webdav) == endpoint)

        await #expect(throws: NASError.invalidCredentials) {
            _ = try await Connector.signIn(profile, at: endpoint, credentials: Credentials(account: account, password: "wrong"),
                                           trust: trust, deviceName: "Test", previous: nil, rememberDevice: false)
        }
        let session = try await Connector.signIn(profile, at: endpoint, credentials: Credentials(account: account, password: password),
                                                 trust: trust, deviceName: "Test", previous: nil, rememberDevice: false)
        let service = try await Connector.connect(profile, at: endpoint, session: session, trust: trust)

        #expect(try await service.listShares().map(\.name).contains("share"))
        let top = try await service.list(folder: "/share", offset: 0, limit: 50, sort: .name, ascending: true)
        #expect(top.items.map(\.name) == ["Sub", "Hello World.txt"])

        // Upload into a folder that doesn't exist yet; no replacing.
        let local = FileManager.default.temporaryDirectory.appending(path: "ownhold-dav-\(UUID().uuidString).txt")
        try Data("0123456789".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try await service.upload(local, as: "Ten #1.txt", to: "/share/New/Deep", replacing: false) { _ in }
        await #expect(throws: NASError.alreadyExists) {
            try await service.upload(local, as: "Ten #1.txt", to: "/share/New/Deep", replacing: false) { _ in }
        }
        try await service.upload(local, as: "Ten #1.txt", to: "/share/New/Deep", replacing: true) { _ in }
        let file = try #require(try await service.list(folder: "/share/New/Deep", offset: 0, limit: 10, sort: .name, ascending: true).items.first)
        #expect(file.name == "Ten #1.txt" && file.size == 10)

        let range = try await service.read(file, from: 2, length: 3)
        #expect(String(decoding: range.data, as: UTF8.self) == "234" && range.totalLength == 10)
        let downloaded = try await service.download(file)
        #expect(try String(contentsOf: downloaded, encoding: .utf8) == "0123456789")

        let renamed = try await service.rename(file, to: "Renamed.txt")
        await #expect(throws: NASError.alreadyExists) { _ = try await service.createFolder(named: "Deep", in: "/share/New") }
        try await service.move([renamed], to: "/share/Sub")
        #expect(try await service.search(in: "/share", matching: "renamed").map(\.path) == ["/share/Sub/Renamed.txt"])

        try await service.delete([RemoteItem(path: "/share/New", name: "New", isDirectory: true),
                                  RemoteItem(path: "/share/Sub/Renamed.txt", name: "Renamed.txt", isDirectory: false)])
        let after = try await service.list(folder: "/share", offset: 0, limit: 50, sort: .name, ascending: true)
        #expect(after.items.map(\.name) == ["Sub", "Hello World.txt"])
    }
}
