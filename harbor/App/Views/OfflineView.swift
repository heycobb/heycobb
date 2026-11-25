import HarborKit
import QuickLook
import SwiftUI

/// Everything kept on this device. Works with no connection at all.
struct OfflineView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [OfflineEntry] = []
    @State private var totalBytes: Int64 = 0
    @State private var previewURL: URL?

    var body: some View {
        List {
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        Button {
                            Task { previewURL = await model.offline?.localURL(for: entry.item.path) }
                        } label: {
                            OfflineRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from Offline", systemImage: "minus.circle", role: .destructive) {
                                remove(entry)
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { entries[$0] }.forEach(remove) }
                } footer: {
                    Text("\(entries.count) files · \(Format.bytes(totalBytes)) on this device")
                        .font(.meta)
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing Offline Yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Swipe a file or folder, or use its menu, and choose Keep Offline.")
                )
            }
        }
        .navigationTitle("Offline")
        .quickLookPreview($previewURL)
        .task(id: model.savedPaths) { await load() }
        .refreshable {
            await model.refreshOffline()
            await load()
        }
    }

    private func load() async {
        guard let offline = model.offline else { return }
        entries = await offline.all()
        totalBytes = await offline.totalBytes()
    }

    private func remove(_ entry: OfflineEntry) {
        Task { await model.toggleOffline(entry.item) }
    }
}

private struct OfflineRow: View {
    let entry: OfflineEntry

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ThumbnailView(item: entry.item, size: .small, side: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.name).lineLimit(1).truncationMode(.middle)
                Text((entry.item.path as NSString).deletingLastPathComponent)
                    .font(.path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(Format.bytes(entry.byteCount))
                .font(.meta)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}
