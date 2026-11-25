import HarborKit
import SwiftUI

/// Dense list row: thumbnail or icon, name, and monospaced metadata.
struct ItemRow: View {
    let item: RemoteItem
    let saved: Bool
    let busy: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ThumbnailView(item: item, size: .small, side: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.meta)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.s)
            if busy {
                ProgressView().controlSize(.small)
            } else if saved {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .imageScale(.small)
                    .accessibilityLabel("Available offline")
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private var meta: String {
        item.isDirectory
            ? Format.date(item.modified)
            : "\(Format.bytes(item.size))  ·  \(Format.date(item.modified))"
    }
}

/// Grid tile: square thumbnail with the name underneath, Photos-style.
struct ItemTile: View {
    let item: RemoteItem
    let saved: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ThumbnailView(item: item, size: .medium, side: nil) }
                .clipShape(.rect(cornerRadius: Theme.thumbnailRadius))
                .overlay(alignment: .bottomTrailing) {
                    if saved {
                        Image(systemName: "arrow.down.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.accent)
                            .padding(Theme.Spacing.xs)
                            .accessibilityLabel("Available offline")
                    }
                }
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
            if !item.isDirectory {
                Text(Format.bytes(item.size))
                    .font(.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

/// Photos-style tile: a square thumbnail, no caption. Files without a
/// thumbnail show their icon with the name inside the square.
struct PhotoTile: View {
    let item: RemoteItem
    let saved: Bool
    let busy: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbnailView(item: item, size: .medium, side: nil) }
            .overlay(alignment: .bottom) {
                if !item.hasThumbnail {
                    Text(item.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(Theme.Spacing.xs)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if saved {
                    Image(systemName: "arrow.down.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .padding(Theme.Spacing.xs)
                }
            }
            .overlay {
                if busy { ProgressView() }
            }
            .clipped()
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(saved ? "Available offline" : "")
            .accessibilityAddTraits(.isButton)
    }
}

/// Loads a NAS-generated thumbnail for photos and videos; falls back to a
/// symbol for everything else.
struct ThumbnailView: View {
    let item: RemoteItem
    let size: ThumbnailSize
    /// Fixed square size, or nil to fill the container.
    let side: CGFloat?

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    @State private var image: CGImageBox?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(.quaternary.opacity(item.isDirectory ? 0 : 0.6))
                Image(systemName: item.kind.symbol)
                    .font(side.map { Font.system(size: $0 * 0.45) } ?? Font.system(size: Platform.isMac ? 60 : 44))
                    .foregroundStyle(item.kind.tint)
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: side == nil ? .infinity : nil, maxHeight: side == nil ? .infinity : nil)
        .clipShape(.rect(cornerRadius: side == nil ? 0 : Theme.thumbnailRadius * 0.75))
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .task(id: item.id) {
            guard item.hasThumbnail, let cache = model.thumbnails, let service = model.service else { return }
            let pixels = Int((side ?? Theme.gridMinimumRegular * 1.4) * scale)
            image = await cache.image(for: item, size: size, maxPixel: pixels, service: service)
        }
    }
}

struct ItemInfoView: View {
    let item: RemoteItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ThumbnailView(item: item, size: .large, side: 160)
                        Spacer()
                    }
                }
                Section {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Kind", value: item.isDirectory ? "Folder" : item.fileExtension.uppercased())
                    if !item.isDirectory {
                        LabeledContent("Size", value: Format.bytes(item.size))
                    }
                    LabeledContent("Modified", value: item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    LabeledContent("Path") {
                        Text(item.path).font(.path).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Info")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}
