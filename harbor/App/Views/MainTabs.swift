#if os(iOS)
import ArkenalKit
import SwiftUI

/// The tabs on iPhone and iPad. Browse keeps the shared folders and their
/// folder stack (two columns on iPad, with its own sidebar, so the tabs stay
/// a tab bar rather than becoming a second sidebar); the others are places
/// people jump between.
enum AppTab: Hashable {
    case browse, photos, recents, offline, search
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .browse

    var body: some View {
        TabView(selection: $tab) {
            Tab("Browse", systemImage: "externaldrive", value: AppTab.browse) {
                BrowserView()
            }
            Tab("Photos", systemImage: "photo.on.rectangle.angled", value: AppTab.photos) {
                NavigationStack {
                    if ProStore.shared.isUnlocked { PhotoLibraryView() } else { ProLockedView(title: "Photos") }
                }
            }
            if model.keepRecents {
                Tab("Recents", systemImage: "clock", value: AppTab.recents) {
                    NavigationStack { RecentsView() }
                }
            }
            Tab("Offline", systemImage: "arrow.down.circle", value: AppTab.offline) {
                NavigationStack { OfflineView() }
            }
            .badge(model.savedPaths.count)
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.tabBarOnly)
        // Gives photo grids and long folders the whole screen while scrolling.
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: model.keepRecents) {
            if !model.keepRecents, tab == .recents { tab = .browse }
        }
        .onChange(of: model.navigationRequest, initial: true) {
            // Photos, Recents and Offline are tabs here; anything else is in
            // Browse, which handles the request itself.
            switch model.navigationRequest {
            case .photos: tab = .photos
            case .recents: tab = .recents
            case .offline: tab = .offline
            case .some: tab = .browse
                return
            case nil: return
            }
            model.navigationRequest = nil
        }
    }
}

/// Search across every shared folder at once (each folder also has its own
/// search for searching just there).
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [RemoteItem]?
    @State private var searching = false
    @State private var previewURL: URL?
    @State private var playing: MediaPlayback?
    @State private var opening: String?

    var body: some View {
        OwnList {
            ForEach(results ?? []) { item in
                if item.isDirectory {
                    NavigationLink(value: item) { row(item) }
                } else {
                    Button { open(item) } label: { row(item) }
                        .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if searching, results == nil {
                ProgressView()
            } else if query.isEmpty {
                ContentUnavailableView("Search Your NAS", systemImage: "magnifyingglass")
            } else if results?.isEmpty == true {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .navigationDestination(for: RemoteItem.self) { FolderView(folder: $0) }
        .searchable(text: $query, prompt: "Files and folders")
        .task(id: query) {
            guard !query.isEmpty else {
                results = nil
                return
            }
            // Waits for a pause in typing rather than searching every letter.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await search(query)
        }
        .filePreview($previewURL)
        .mediaPlayer($playing)
    }

    private func row(_ item: RemoteItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ItemRow(item: item, saved: model.savedPaths.contains(item.path), busy: opening == item.path)
            // Where it is, since results come from every shared folder.
            Text(item.parentPath)
                .font(.path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.leading, 40 + Theme.Spacing.m)
        }
    }

    private func search(_ text: String) async {
        guard let service = model.service else { return }
        searching = true
        defer { searching = false }
        do {
            let shares = try await service.listShares()
            // Every shared folder at once; one the account can't search is skipped.
            let found = await withTaskGroup(of: [RemoteItem].self) { group in
                for share in shares {
                    group.addTask { (try? await service.search(in: share.path, matching: text)) ?? [] }
                }
                var all: [RemoteItem] = []
                for await items in group { all += items }
                return all
            }
            guard !Task.isCancelled, text == query else { return }
            results = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            model.handle(error)
        }
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
#endif
