import ArkenalKit
import SwiftUI

/// Photos: every photo and video in the chosen folders, newest first,
/// grouped by month, like the Photos app.
struct PhotoLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var choosingFolder = false
    @State private var opening: String?
    @State private var playing: MediaPlayback?
    @State private var previewURL: URL?

    private var library: PhotoLibrary { model.photoLibrary }

    var body: some View {
        let months = PhotoTimeline.months(library.items)
        Group {
            if library.folders.isEmpty {
                ContentUnavailableView {
                    Label("No Photo Folders", systemImage: "photo.on.rectangle.angled")
                } actions: {
                    Button("Choose Folder…") { choosingFolder = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if months.isEmpty {
                if library.isRefreshing {
                    ProgressView("Finding photos…")
                } else {
                    ContentUnavailableView("No Photos", systemImage: "photo")
                }
            } else {
                grid(months)
            }
        }
        .navigationTitle("Photos")
        .toolbar { toolbar }
        .sheet(isPresented: $choosingFolder) {
            FolderPicker(items: [], title: "Show Photos From", actionTitle: "Add") { path in library.addFolder(path) }
        }
        .filePreview($previewURL)
        .mediaPlayer($playing)
        .task(id: model.connection) {
            #if os(iOS)
            // Start with the Photo Backup folder, if there is one.
            if library.folders.isEmpty, let destination = model.backup.settings.destination { library.addFolder(destination) }
            #endif
            library.refresh()
        }
    }

    private func grid(_ months: [PhotoTimeline.Month]) -> some View {
        let all = months.flatMap(\.items)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.l, pinnedViews: [.sectionHeaders]) {
                ForEach(months) { month in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? Theme.photoMinimumRegular : Theme.photoMinimum), spacing: Theme.photoSpacing)], spacing: Theme.photoSpacing) {
                            ForEach(month.items) { item in
                                Button { open(item, in: all) } label: {
                                    PhotoTile(item: item, saved: model.savedPaths.contains(item.path), busy: opening == item.path)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text(title(for: month))
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, Theme.Spacing.m)
                            .padding(.vertical, Theme.Spacing.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if library.isRefreshing, !library.items.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Add Folder…", systemImage: "folder.badge.plus") { choosingFolder = true }
                    if !library.folders.isEmpty {
                        Section("Showing Photos From") {
                            ForEach(library.folders, id: \.self) { path in
                                Button("Remove \((path as NSString).lastPathComponent)", systemImage: "minus.circle") { library.removeFolder(path) }
                            }
                        }
                        Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
                    }
                } label: {
                    Label("Folders", systemImage: "folder")
                }
            }
        }
    }

    private func title(for month: PhotoTimeline.Month) -> String {
        guard let start = month.start else { return "Undated" }
        return start.formatted(.dateTime.month(.wide).year())
    }

    private func open(_ item: RemoteItem, in all: [RemoteItem]) {
        guard opening == nil else { return }
        opening = item.path
        Task {
            defer { opening = nil }
            do {
                switch try await model.openFile(item, siblings: all) {
                case let .play(playback): playing = playback
                case let .preview(url): previewURL = url
                }
            } catch {
                model.handle(error)
            }
        }
    }
}
