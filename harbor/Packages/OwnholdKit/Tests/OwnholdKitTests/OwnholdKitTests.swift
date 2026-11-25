import Foundation
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
