import AVKit
import ArkenalKit
import SwiftUI

/// A video or audio file streaming from the NAS.
struct MediaPlayback: Identifiable {
    let id = UUID()
    let item: RemoteItem
    /// Must live as long as the player: the asset holds it weakly.
    let loader: StreamingLoader
    /// For audio: the folder's audio files in order (including `item`), so
    /// the player can go on to the next one. Empty for a single file.
    var queue: [RemoteItem] = []
    var service: (any FileService)?

    @MainActor func makePlayer() -> AVPlayer {
        let player = AVPlayer(playerItem: AVPlayerItem(asset: loader.makeAsset()))
        player.allowsExternalPlayback = true // AirPlay
        return player
    }
}

/// What opening a file leads to: streaming it, or a local copy for Quick Look.
enum OpenedFile {
    case play(MediaPlayback)
    case preview(URL)
}

extension AppModel {
    /// Streams video and audio straight from the NAS (unless saved offline),
    /// and downloads everything else for Quick Look. `siblings` are the
    /// other files in the folder, so audio can play on through them.
    func openFile(_ item: RemoteItem, siblings: [RemoteItem] = []) async throws -> OpenedFile {
        noteOpened(item)
        if item.isStreamable, !savedPaths.contains(item.path), let service {
            let loader = StreamingLoader(item: item, service: service)
            do {
                try await loader.probe()
                var playback = MediaPlayback(item: item, loader: loader, service: service)
                if item.kind == .audio {
                    let audio = siblings.filter { $0.kind == .audio && $0.isStreamable }
                    if audio.count > 1, audio.contains(where: { $0.path == item.path }) { playback.queue = audio }
                }
                return .play(playback)
            } catch NASError.streamingUnsupported {
                // Fall back to downloading it for Quick Look.
            }
        }
        return .preview(try await localCopy(of: item))
    }
}

extension View {
    /// Plays `playback` in the system player: full screen on iPhone and iPad,
    /// a sheet on the Mac.
    func mediaPlayer(_ playback: Binding<MediaPlayback?>) -> some View {
        // Audio gets its own player (title, artwork, scrubber); the system
        // video player only shows a QuickTime logo for audio.
        let video = Binding<MediaPlayback?>(
            get: { playback.wrappedValue?.item.kind == .audio ? nil : playback.wrappedValue },
            set: { playback.wrappedValue = $0 }
        )
        let audio = Binding<MediaPlayback?>(
            get: { playback.wrappedValue?.item.kind == .audio ? playback.wrappedValue : nil },
            set: { playback.wrappedValue = $0 }
        )
        #if os(iOS)
        return background(PlayerPresenter(playback: video))
            .sheet(item: audio) { AudioPlayerView(playback: $0) }
        #else
        return sheet(item: video) { MacPlayerSheet(playback: $0) }
            .background(Color.clear.sheet(item: audio) { AudioPlayerView(playback: $0) })
        #endif
    }
}

#if os(iOS)
/// Presents `AVPlayerViewController` modally, which gives the standard
/// close button, swipe to dismiss, AirPlay and playback speed.
private struct PlayerPresenter: UIViewControllerRepresentable {
    @Binding var playback: MediaPlayback?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.isHidden = true
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onDismiss = { playback = nil }
        guard let playback, coordinator.current != playback.id,
              host.presentedViewController == nil, host.view.window != nil else { return }
        coordinator.current = playback.id
        coordinator.loader = playback.loader
        // Sound even with the ring/silent switch on, like other video apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let controller = AVPlayerViewController()
        controller.player = playback.makePlayer()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = coordinator
        coordinator.host = host
        controller.modalPresentationStyle = .fullScreen
        coordinator.item = playback.item
        host.present(controller, animated: true) {
            guard let player = controller.player else { return }
            Task { await PlaybackPositions.resumeAndPlay(player, item: playback.item) }
        }
    }

    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        var current: UUID?
        var loader: StreamingLoader?
        var item: RemoteItem?
        weak var host: UIViewController?
        var onDismiss: () -> Void = {}
        /// While Picture in Picture is showing, the full-screen player is
        /// dismissed but playback carries on.
        private var inPictureInPicture = false

        // Called when the user closes a modally presented player.
        @MainActor
        func playerViewController(_ controller: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard !context.isCancelled, let self, !self.inPictureInPicture else { return }
                self.finish(controller)
            }
        }

        @MainActor
        func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
            inPictureInPicture = true
        }

        @MainActor
        func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
            inPictureInPicture = false
            // Closed from the floating window (rather than returned to full screen).
            if controller.presentingViewController == nil { finish(controller) }
        }

        // Back to full screen from the floating window.
        @MainActor
        func playerViewController(_ controller: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            guard let host, host.view.window != nil, host.presentedViewController == nil else {
                completionHandler(false)
                return
            }
            host.present(controller, animated: true) { completionHandler(true) }
        }

        @MainActor
        private func finish(_ controller: AVPlayerViewController) {
            controller.player?.pause()
            if let item { PlaybackPositions.save(controller.player, item: item) }
            controller.player = nil
            current = nil
            loader = nil
            onDismiss()
        }
    }
}
#else
private struct MacPlayerSheet: View {
    let playback: MediaPlayback
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            if let player {
                MacPlayerView(player: player)
            } else {
                Color.black
            }
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 405, idealHeight: 540)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .navigationTitle(playback.item.name)
        .onAppear {
            let player = playback.makePlayer()
            self.player = player
            Task { await PlaybackPositions.resumeAndPlay(player, item: playback.item) }
        }
        .onDisappear {
            player?.pause()
            PlaybackPositions.save(player, item: playback.item)
            player = nil
        }
    }
}

private struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif
