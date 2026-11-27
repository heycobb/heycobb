import AVFoundation
import Foundation
import Testing
@testable import ArkenalKit

@Suite("Demo video")
struct DemoVideoTests {
    @Test func rendersSixSecondsAt960x540() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "demo-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DemoVideo.render(to: url))
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 6) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 960, height: 540))
        #expect(try await track.load(.nominalFrameRate).rounded() == 24)
    }
}
