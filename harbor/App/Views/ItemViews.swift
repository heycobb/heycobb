import ArkenalKit
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
        // Centered, like Finder's icon view and the Files app.
        VStack(alignment: .center, spacing: Theme.Spacing.xs) {
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
                .font(.tileName)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            // Folders show their date: their size isn't known without
            // listing everything inside.
            Text(item.isDirectory ? Format.date(item.modified) : Format.bytes(item.size))
                .font(.tileMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
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
            .overlay(alignment: .bottomLeading) {
                // Videos look like photos once they have a frame: mark them.
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
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
            .accessibilityValue([item.kind == .video ? "Video" : nil, saved ? "Available offline" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(.isButton)
    }
}

/// Loads a thumbnail (from the NAS for photos and videos, made on the device
/// for documents); falls back to a symbol.
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
                symbol
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: side == nil ? .infinity : nil, maxHeight: side == nil ? .infinity : nil)
        .clipShape(.rect(cornerRadius: side == nil ? 0 : Theme.thumbnailRadius * 0.75))
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .task(id: item.id) {
            guard item.canShowThumbnail, let cache = model.thumbnails, let service = model.service else { return }
            let pixels = Int((side ?? Theme.gridMinimumRegular * 1.4) * scale)
            image = await cache.image(for: item, size: size, maxPixel: pixels, service: service)
        }
    }
}

extension ThumbnailView {
    /// The item's symbol when there's no thumbnail. In grid tiles (no fixed
    /// side) it scales with the tile, as in Finder: folders fill most of it.
    @ViewBuilder var symbol: some View {
        if let side {
            Image(systemName: item.kind.symbol)
                .font(.system(size: side * 0.45))
                .foregroundStyle(item.kind.tint)
                .overlay { lock(size: side * 0.17, drop: side * 0.03) }
        } else {
            GeometryReader { proxy in
                let width = proxy.size.width * (item.isDirectory ? 0.62 : 0.4)
                Image(systemName: item.kind.symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(item.kind.tint)
                    .frame(width: width)
                    .overlay { lock(size: width * 0.26, drop: width * 0.06) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Encrypted folders: a lock on the folder.
    @ViewBuilder private func lock(size: CGFloat, drop: CGFloat) -> some View {
        if item.isDirectory, model.isEncryptedFolder(item.path) {
            Image(systemName: "lock.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.background)
                .offset(y: drop)
                .accessibilityLabel("Encrypted")
        }
    }
}

struct ItemInfoView: View {
    let item: RemoteItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OwnForm {
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
