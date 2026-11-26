import AVKit
import OwnholdKit
import SwiftUI

/// A video or audio file streaming from the NAS.
struct MediaPlayback: Identifiable {
    let id = UUID()
    let item: RemoteItem
    /// Must live as long as the player: the asset holds it weakly.
    let loader: StreamingLoader

    @MainActor func makePlayer() -> AVPlayer {
        let player = AVPlayer(playerItem: AVPlayerItem(asset: loader.makeAsset()))
        player.allowsExternalPlayback = true // AirPlay
        return player
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
        controller.allowsPictureInPicturePlayback = false
        controller.delegate = coordinator
        controller.modalPresentationStyle = .fullScreen
        host.present(controller, animated: true) { controller.player?.play() }
    }

    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        var current: UUID?
        var loader: StreamingLoader?
        var onDismiss: () -> Void = {}

        // Called when the user closes a modally presented player.
        @MainActor
        func playerViewController(_ controller: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard !context.isCancelled, let self else { return }
                controller.player?.pause()
                controller.player = nil
                self.current = nil
                self.loader = nil
                self.onDismiss()
            }
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
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = false
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif
