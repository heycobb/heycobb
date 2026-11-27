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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab: AppTab = .browse

    /// iPhone (compact width): a tab bar docked to the bottom edge. iPad and
    /// an open iPhone Duo keep the system's tab bar (top or side).
    private var embedded: Bool { sizeClass == .compact }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Browse", systemImage: "externaldrive", value: AppTab.browse) {
                BrowserView().modifier(SystemTabBar(hidden: embedded))
            }
            Tab("Photos", systemImage: "photo.on.rectangle.angled", value: AppTab.photos) {
                NavigationStack {
                    if ProStore.shared.isUnlocked { PhotoLibraryView() } else { ProLockedView(title: "Photos") }
                }
                .modifier(SystemTabBar(hidden: embedded))
            }
            if model.keepRecents {
                Tab("Recents", systemImage: "clock", value: AppTab.recents) {
                    NavigationStack { RecentsView() }.modifier(SystemTabBar(hidden: embedded))
                }
            }
            Tab("Offline", systemImage: "arrow.down.circle", value: AppTab.offline) {
                NavigationStack { OfflineView() }.modifier(SystemTabBar(hidden: embedded))
            }
            .badge(model.savedPaths.count)
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }.modifier(SystemTabBar(hidden: embedded))
            }
        }
        .tabViewStyle(.tabBarOnly)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if embedded { EmbeddedTabBar(tab: $tab, items: items) }
        }
        // The keyboard covers the docked bar rather than lifting it.
        .ignoresSafeArea(.keyboard, edges: .bottom)
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

    private var items: [EmbeddedTabBar.Item] {
        var list: [EmbeddedTabBar.Item] = [
            .init(tab: .browse, title: "Browse", symbol: "externaldrive"),
            .init(tab: .photos, title: "Photos", symbol: "photo.on.rectangle.angled"),
        ]
        if model.keepRecents { list.append(.init(tab: .recents, title: "Recents", symbol: "clock")) }
        list.append(.init(tab: .offline, title: "Offline", symbol: "arrow.down.circle", badge: model.savedPaths.count))
        list.append(.init(tab: .search, title: "Search", symbol: "magnifyingglass"))
        return list
    }
}

/// Hides the system's floating tab bar where the docked one is used.
private struct SystemTabBar: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content.toolbarVisibility(hidden ? .hidden : .automatic, for: .tabBar)
    }
}

/// A tab bar docked to the bottom edge, full width, like the classic iOS
/// tab bar: the screen's own background, a hairline on top.
struct EmbeddedTabBar: View {
    struct Item: Identifiable {
        let tab: AppTab
        let title: String
        let symbol: String
        var badge = 0
        var id: AppTab { tab }
    }

    @Binding var tab: AppTab
    let items: [Item]
    @Environment(\.isBlackout) private var isBlackout

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let selected = tab == item.tab
                Button {
                    if tab != item.tab { Haptics.tap() }
                    tab = item.tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .symbolVariant(selected ? .fill : .none)
                            .font(.system(size: 21, weight: .regular))
                            .frame(height: 26)
                            .overlay(alignment: .topTrailing) {
                                if item.badge > 0 {
                                    Text("\(item.badge)")
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .background(Capsule().fill(.red))
                                        .offset(x: 12, y: -4)
                                }
                            }
                        Text(item.title)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.badge > 0 ? "\(item.title), \(item.badge)" : item.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 1)
        .background {
            Rectangle()
                .fill(isBlackout ? AnyShapeStyle(Blackout.background) : AnyShapeStyle(.bar))
                .overlay(alignment: .top) { Divider() }
                .ignoresSafeArea(edges: .bottom)
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
