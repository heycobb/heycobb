import OwnholdKit
import SwiftUI

/// Files opened recently on this NAS, newest first. Kept on this device
/// only; Settings › Show Recents turns it off.
struct RecentsView: View {
    @Environment(AppModel.self) private var model
    @State private var previewURL: URL?
    @State private var playing: MediaPlayback?
    @State private var opening: String?

    var body: some View {
        List {
            ForEach(model.recents) { item in
                Button { open(item) } label: {
                    ItemRow(item: item, saved: model.savedPaths.contains(item.path), busy: opening == item.path)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if model.recents.isEmpty {
                ContentUnavailableView("No Recent Files", systemImage: "clock", description: Text("Files you open appear here."))
            }
        }
        .navigationTitle("Recents")
        .toolbar {
            if !model.recents.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { model.clearRecents() }
                }
            }
        }
        .filePreview($previewURL)
        .mediaPlayer($playing)
    }

    private func open(_ item: RemoteItem) {
        guard opening == nil else { return }
        opening = item.path
        Task {
            defer { opening = nil }
            do {
                switch try await model.openFile(item) {
                case let .play(playback): playing = playback
                case let .preview(url): previewURL = url
                }
            } catch {
                model.handle(error)
            }
        }
    }
}
