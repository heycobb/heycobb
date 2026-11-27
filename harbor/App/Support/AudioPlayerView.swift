import AVKit
import ImageIO
import MediaPlayer
import Observation
import ArkenalKit
import SwiftUI

/// Plays audio streaming from the NAS: artwork and title from the file's
/// own tags when it has them, a scrubber, 15-second skips, and the rest of
/// the folder after it. Keeps playing in the background, with controls on
/// the Lock Screen and in Control Center, until the player is closed.
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
                    Text(audio.displayTitle)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(audio.displaySubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                scrubber
                controls
                if audio.queueCount > 1 {
                    Text("\(audio.index + 1) of \(audio.queueCount)")
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }
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
        .frame(width: 440, height: 580)
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
        HStack(spacing: audio.queueCount > 1 ? 26 : 44) {
            if audio.queueCount > 1 {
                Button { Task { await audio.previous() } } label: {
                    Image(systemName: "backward.fill").font(.system(size: 22))
                }
                .accessibilityLabel("Previous")
            }
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
            if audio.queueCount > 1 {
                Button { Task { await audio.next() } } label: {
                    Image(systemName: "forward.fill").font(.system(size: 22))
                }
                .disabled(!audio.hasNext)
                .accessibilityLabel("Next")
            }
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
    private(set) var index = 0
    private(set) var queueCount = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loader: StreamingLoader?
    @ObservationIgnored private var queue: [RemoteItem] = []
    @ObservationIgnored private var service: (any FileService)?
    @ObservationIgnored private var current: RemoteItem?
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private var atEnd = false

    var hasNext: Bool { index + 1 < queue.count }
    var displayTitle: String { title ?? current.map { AudioPlayerView.baseName($0.name) } ?? "" }
    var displaySubtitle: String { artist ?? current.map { ($0.parentPath as NSString).lastPathComponent } ?? "" }

    func start(_ playback: MediaPlayback) async {
        #if os(iOS)
        // Keeps playing with the screen locked or in another app (the app
        // declares background audio); stops when the player is closed.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        queue = playback.queue.isEmpty ? [playback.item] : playback.queue
        index = queue.firstIndex { $0.path == playback.item.path } ?? 0
        queueCount = queue.count
        service = playback.service
        let player = playback.makePlayer()
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.position = time.seconds
                let playing = player.timeControlStatus != .paused
                if playing != self.isPlaying {
                    self.isPlaying = playing
                    self.updateNowPlaying()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let finished = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, let current = self.player?.currentItem, ObjectIdentifier(current) == finished else { return }
                self.finishedItem()
            }
        }
        setUpRemoteCommands()
        await begin(playback.item, loader: playback.loader, playerItemReady: true)
    }

    func stop() {
        loadTask?.cancel()
        player?.pause()
        saveCurrentPosition()
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #else
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        observer = nil
        endObserver = nil
        player = nil
        loader = nil
    }

    func toggle() {
        guard let player else { return }
        if atEnd {
            // Play again from the start once the track has finished.
            atEnd = false
            position = 0
            player.seek(to: .zero)
            player.play()
        } else if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
        isPlaying = player.timeControlStatus != .paused
        updateNowPlaying()
    }

    func play() { if player?.timeControlStatus == .paused { toggle() } }
    func pause() { if player?.timeControlStatus != .paused { toggle() } }

    func seek(to seconds: Double) {
        atEnd = seconds >= duration && duration > 0
        position = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlaying()
    }

    func skip(_ seconds: Double) {
        seek(to: min(max(0, position + seconds), duration))
    }

    func next() async {
        guard hasNext else { return }
        await move(to: index + 1)
    }

    /// Back to the start of this track, or to the previous one if it's
    /// only just started, as in Music.
    func previous() async {
        if position > 3 || index == 0 {
            seek(to: 0)
        } else {
            await move(to: index - 1)
        }
    }

    // MARK: Tracks

    private func finishedItem() {
        if let current { PlaybackPositions.save(duration, duration: duration, for: current) }
        if hasNext {
            Task { await move(to: index + 1) }
        } else {
            isPlaying = false
            atEnd = true
            if duration > 0 { position = duration }
            updateNowPlaying()
        }
    }

    private func move(to newIndex: Int) async {
        guard queue.indices.contains(newIndex), let service else { return }
        saveCurrentPosition()
        player?.pause()
        index = newIndex
        let item = queue[newIndex]
        let loader = StreamingLoader(item: item, service: service)
        current = item
        title = nil
        artist = nil
        artwork = nil
        position = 0
        duration = 0
        updateNowPlaying()
        do {
            try await loader.probe()
        } catch {
            // Can't stream this one (or the NAS is unreachable): stop here.
            isPlaying = false
            return
        }
        guard current?.path == item.path else { return } // moved on meanwhile
        player?.replaceCurrentItem(with: AVPlayerItem(asset: loader.makeAsset()))
        await begin(item, loader: loader, playerItemReady: false)
    }

    private func begin(_ item: RemoteItem, loader: StreamingLoader, playerItemReady: Bool) async {
        guard let player else { return }
        self.loader = loader
        current = item
        atEnd = false
        isPlaying = true
        guard let asset = player.currentItem?.asset else { return }
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite { duration = seconds }
        if let saved = PlaybackPositions.position(for: item) { position = saved }
        updateNowPlaying()
        await PlaybackPositions.resumeAndPlay(player, item: item)
        updateNowPlaying()
        await loadTags(asset, for: item)
    }

    private func saveCurrentPosition() {
        guard let current, let player else { return }
        // At the end, forget the position so it starts over next time.
        PlaybackPositions.save(atEnd ? duration : player.currentTime().seconds, duration: duration, for: current)
    }

    /// Title, artist and artwork from the file's tags (ID3 and similar),
    /// read through the same streaming connection.
    private func loadTags(_ asset: AVAsset, for item: RemoteItem) async {
        guard let items = try? await asset.load(.commonMetadata) else { return }
        for tag in items {
            guard current?.path == item.path else { return }
            switch tag.commonKey {
            case .commonKeyTitle: title = Self.nonEmpty(try? await tag.load(.stringValue))
            case .commonKeyArtist: artist = Self.nonEmpty(try? await tag.load(.stringValue))
            case .commonKeyArtwork:
                if let data = try? await tag.load(.dataValue) {
                    artwork = ImageDecoding.downsample(data, maxPixel: 600)
                }
            default: break
            }
        }
        updateNowPlaying()
    }

    /// Tags are sometimes present but blank: fall back to the file's name and folder then.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    // MARK: Lock Screen and Control Center

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
                return .success
            }
            commandTargets.append((command, target))
        }
        on(center.playCommand) { [weak self] _ in self?.play() }
        on(center.pauseCommand) { [weak self] _ in self?.pause() }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        on(center.skipForwardCommand) { [weak self] _ in self?.skip(15) }
        on(center.skipBackwardCommand) { [weak self] _ in self?.skip(-15) }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) }
        }
        if queue.count > 1 {
            on(center.nextTrackCommand) { [weak self] _ in Task { await self?.next() } }
            on(center.previousTrackCommand) { [weak self] _ in Task { await self?.previous() } }
        }
    }

    private func updateNowPlaying() {
        guard player != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: displayTitle,
            MPMediaItemPropertyArtist: displaySubtitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if queue.count > 1 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        if let artwork {
            let image = PlatformImage.from(artwork)
            let size = CGSize(width: artwork.width, height: artwork.height)
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }
}

#if os(iOS)
typealias PlatformImage = UIImage
extension UIImage {
    static func from(_ image: CGImage) -> UIImage { UIImage(cgImage: image) }
}
#else
typealias PlatformImage = NSImage
extension NSImage {
    static func from(_ image: CGImage) -> NSImage { NSImage(cgImage: image, size: .zero) }
}
#endif
