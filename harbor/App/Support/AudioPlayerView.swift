import AVKit
import ImageIO
import Observation
import OwnholdKit
import SwiftUI

/// Plays an audio file streaming from the NAS: artwork and title from the
/// file's own tags when it has them, a scrubber, and 15-second skips.
struct AudioPlayerView: View {
    let playback: MediaPlayback
    @Environment(\.dismiss) private var dismiss
    @State private var audio = AudioController()

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.l) {
                Spacer(minLength: 0)
                artwork
                VStack(spacing: Theme.Spacing.xs) {
                    Text(audio.title ?? Self.baseName(playback.item.name))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(audio.artist ?? (playback.item.parentPath as NSString).lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                scrubber
                controls
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .tint(Theme.accent)
        #if os(macOS)
        .frame(width: 420, height: 560)
        #endif
        .task { await audio.start(playback) }
        .onDisappear { audio.stop() }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
            if let image = audio.artwork {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 240, height: 240)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { audio.position }, set: { audio.position = $0 }),
                   in: 0 ... max(audio.duration, 1)) { editing in
                audio.scrubbing = editing
                if !editing { audio.seek(to: audio.position) }
            }
            .disabled(audio.duration == 0)
            .accessibilityLabel("Position")
            HStack {
                Text(Self.time(audio.position))
                Spacer()
                Text("-" + Self.time(max(0, audio.duration - audio.position)))
            }
            .font(.meta)
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { audio.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 26))
            }
            .accessibilityLabel("Back 15 seconds")
            Button { audio.toggle() } label: {
                Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
            Button { audio.skip(15) } label: {
                Image(systemName: "goforward.15").font(.system(size: 26))
            }
            .accessibilityLabel("Forward 15 seconds")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }

    static func baseName(_ name: String) -> String { (name as NSString).deletingPathExtension }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The player and its state, so the time observer updates the view.
@MainActor
@Observable
final class AudioController {
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var scrubbing = false
    var title: String?
    var artist: String?
    var artwork: CGImage?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var loader: StreamingLoader?

    func start(_ playback: MediaPlayback) async {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        #endif
        loader = playback.loader
        let player = playback.makePlayer()
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.position = time.seconds
                self.isPlaying = player.timeControlStatus != .paused
            }
        }
        player.play()
        isPlaying = true
        guard let asset = player.currentItem?.asset else { return }
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite { duration = seconds }
        await loadTags(asset)
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        loader = nil
    }

    func toggle() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        isPlaying = player.timeControlStatus != .paused
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func skip(_ seconds: Double) {
        let target = min(max(0, position + seconds), duration)
        position = target
        seek(to: target)
    }

    /// Title, artist and artwork from the file's tags (ID3 and similar),
    /// read through the same streaming connection.
    private func loadTags(_ asset: AVAsset) async {
        guard let items = try? await asset.load(.commonMetadata) else { return }
        for item in items {
            switch item.commonKey {
            case .commonKeyTitle: title = try? await item.load(.stringValue)
            case .commonKeyArtist: artist = try? await item.load(.stringValue)
            case .commonKeyArtwork:
                if let data = try? await item.load(.dataValue) {
                    artwork = ImageDecoding.downsample(data, maxPixel: 600)
                }
            default: break
            }
        }
    }
}
