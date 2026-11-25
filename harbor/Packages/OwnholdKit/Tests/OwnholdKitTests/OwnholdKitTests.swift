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

    @Test func recognizesTailscale() throws {
        #expect(Endpoint.parse("100.101.102.103")?.kind == .tailscale)
        #expect(Endpoint.parse("nas.tail1234.ts.net")?.kind == .tailscale)
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
