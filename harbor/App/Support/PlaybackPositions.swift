import AVFoundation
import CryptoKit
import Foundation
import OwnholdKit
import OSLog

/// Where playback stopped in each video or audio file, so it can continue
/// there next time (Settings › Playback › Remember Playback Position).
///
/// Kept on this device only. Files are identified by a hash of their path,
/// size and date rather than their names, so the list says nothing about
/// what was played. A changed file starts from the beginning.
enum PlaybackPositions {
    private static let log = Logger(subsystem: "app.ownhold.Ownhold", category: "playback")
    static let settingKey = "rememberPlaybackPosition"
    private static let storeKey = "playbackPositions"
    /// The most recent files kept; older ones are forgotten.
    private static let limit = 300
    /// Too early to be worth resuming: 5 seconds, less for short files.
    private static func minimum(_ duration: Double) -> Double { min(5, duration * 0.1) }
    /// Close enough to the end to count as finished: the last 10 seconds,
    /// less for short files.
    private static func endMargin(_ duration: Double) -> Double { min(10, duration * 0.1) }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    static func position(for item: RemoteItem) -> Double? {
        guard isEnabled, let entry = store[key(item)], entry.count == 2 else { return nil }
        return entry[0]
    }

    /// Saves where `seconds` falls in a file of `duration`, or forgets the
    /// file when playback barely started or reached the end.
    static func save(_ seconds: Double, duration: Double, for item: RemoteItem) {
        guard isEnabled, seconds.isFinite, duration.isFinite, duration > 0 else { return }
        var entries = store
        let key = key(item)
        if seconds < minimum(duration) || duration - seconds < endMargin(duration) {
            log.debug("Forgetting position (\(seconds, format: .fixed(precision: 1)) of \(duration, format: .fixed(precision: 1)))")
            entries[key] = nil
        } else {
            log.debug("Saving position \(seconds, format: .fixed(precision: 1)) of \(duration, format: .fixed(precision: 1))")
            entries[key] = [seconds, Date().timeIntervalSince1970]
            if entries.count > limit {
                let oldest = entries.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(entries.count - limit)
                for (old, _) in oldest { entries[old] = nil }
            }
        }
        store = entries
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    // MARK: Players

    /// Moves to the saved position (once the file is ready), then plays.
    @MainActor
    static func resumeAndPlay(_ player: AVPlayer, item: RemoteItem) async {
        if let seconds = position(for: item), let playerItem = player.currentItem {
            // Wait (up to 5 seconds) for the file to be ready to seek.
            for _ in 0 ..< 100 where playerItem.status == .unknown {
                try? await Task.sleep(for: .milliseconds(50))
            }
            log.debug("Resuming at \(seconds, format: .fixed(precision: 1)), item status \(playerItem.status.rawValue)")
            if playerItem.status == .readyToPlay {
                await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        player.play()
    }

    /// Saves where `player` is now. Call when the player closes.
    @MainActor
    static func save(_ player: AVPlayer?, item: RemoteItem) {
        guard let player, let playerItem = player.currentItem else { return }
        save(player.currentTime().seconds, duration: playerItem.duration.seconds, for: item)
    }

    // MARK: Storage

    private static var store: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storeKey) }
    }

    private static func key(_ item: RemoteItem) -> String {
        let identity = "\(item.path)\n\(item.size ?? -1)\n\(item.modified?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
