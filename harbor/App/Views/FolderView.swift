import HarborKit
import QuickLook
import SwiftUI

enum BrowseLayout: String { case list, grid }

struct FolderView: View {
    let folder: RemoteItem

    @Environment(AppModel.self) private var model
    @AppStorage("layout") private var layout: BrowseLayout = .list
    @AppStorage("sortField") private var sort: SortField = .name
    @AppStorage("sortAscending") private var ascending = true

    @State private var items: [RemoteItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var failed: NASError?
    @State private var query = ""
    @State private var searchResults: [RemoteItem]?
    @State private var previewURL: URL?
    @State private var opening: String?
    @State private var info: RemoteItem?

    private let pageSize = 300

    private var shown: [RemoteItem] { searchResults ?? items }

    var body: some View {
        content
            .navigationTitle(folder.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "Search \(folder.name)")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onChange(of: query) { if query.isEmpty { searchResults = nil } }
            .toolbar { toolbar }
            .task(id: ReloadKey(path: folder.path, sort: sort, ascending: ascending, connection: model.connection)) {
                await reload()
            }
            .refreshable { await reload() }
            .quickLookPreview($previewURL)
            .sheet(item: $info) { item in
                ItemInfoView(item: item)
            }
    }

    @ViewBuilder private var content: some View {
        if let failed, items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Open Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failed.errorDescription ?? "")
            } actions: {
                Button("Try Again") { Task { await reload() } }
            }
        } else if shown.isEmpty, !loading {
            if searchResults != nil {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        } else if layout == .grid {
            grid
        } else {
            list
        }
    }

    // MARK: List

    private var list: some View {
        List {
            ForEach(shown) { item in
                row(for: item)
                    .onAppear { loadMoreIfNeeded(item) }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
    }

    @ViewBuilder private func row(for item: RemoteItem) -> some View {
        let saved = model.savedPaths.contains(item.path)
        Group {
            if item.isDirectory {
                NavigationLink(value: item) {
                    ItemRow(item: item, saved: saved, busy: false)
                }
            } else {
                Button { open(item) } label: {
                    ItemRow(item: item, saved: saved, busy: opening == item.path)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu { menu(for: item) }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button {
                Task { await model.toggleOffline(item) }
            } label: {
                Label(saved ? "Remove" : "Offline", systemImage: saved ? "arrow.down.circle.dotted" : "arrow.down.circle")
            }
            .tint(saved ? .gray : Theme.accent)
        }
        #endif
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.Spacing.m)], spacing: Theme.Spacing.l) {
                ForEach(shown) { item in
                    tile(for: item)
                        .onAppear { loadMoreIfNeeded(item) }
                }
            }
            .padding(Theme.Spacing.l)
            if loading { ProgressView().padding() }
        }
    }

    @ViewBuilder private func tile(for item: RemoteItem) -> some View {
        let saved = model.savedPaths.contains(item.path)
        Group {
            if item.isDirectory {
                NavigationLink(value: item) { ItemTile(item: item, saved: saved) }
            } else {
                Button { open(item) } label: { ItemTile(item: item, saved: saved) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menu(for: item) }
    }

    // MARK: Menus

    @ViewBuilder private func menu(for item: RemoteItem) -> some View {
        let saved = model.savedPaths.contains(item.path)
        Button {
            Task { await model.toggleOffline(item) }
        } label: {
            Label(saved ? "Remove from Offline" : "Keep Offline", systemImage: saved ? "minus.circle" : "arrow.down.circle")
        }
        if !item.isDirectory {
            Button("Quick Look", systemImage: "eye") { open(item) }
        }
        Button("Get Info", systemImage: "info.circle") { info = item }
        Button("Copy Path", systemImage: "doc.on.doc") {
            #if os(iOS)
            UIPasteboard.general.string = item.path
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
            #endif
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("View", selection: $layout) {
                    Label("List", systemImage: "list.bullet").tag(BrowseLayout.list)
                    Label("Grid", systemImage: "square.grid.2x2").tag(BrowseLayout.grid)
                }
                .pickerStyle(.inline)
                Picker("Sort By", selection: $sort) {
                    Text("Name").tag(SortField.name)
                    Text("Date Modified").tag(SortField.modified)
                    Text("Size").tag(SortField.size)
                }
                .pickerStyle(.inline)
                Toggle("Ascending", isOn: $ascending)
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease")
            }
        }
    }

    // MARK: Loading

    private struct ReloadKey: Equatable {
        let path: String
        let sort: SortField
        let ascending: Bool
        let connection: AppModel.Connection
    }

    private func reload() async {
        guard let service = model.service else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await service.list(folder: folder.path, offset: 0, limit: pageSize, sort: sort, ascending: ascending)
            items = page.items
            total = page.total
            failed = nil
        } catch is CancellationError {
        } catch {
            failed = error as? NASError ?? .malformedResponse
            model.handle(error)
        }
    }

    private func loadMoreIfNeeded(_ item: RemoteItem) {
        guard searchResults == nil, !loading, items.count < total, item.id == items.last?.id, let service = model.service else { return }
        loading = true
        Task {
            defer { loading = false }
            if let page = try? await service.list(folder: folder.path, offset: items.count, limit: pageSize, sort: sort, ascending: ascending) {
                items += page.items
                total = page.total
            }
        }
    }

    private func runSearch() async {
        guard !query.isEmpty, let service = model.service else { return }
        loading = true
        defer { loading = false }
        do {
            searchResults = try await service.search(in: folder.path, matching: query)
        } catch {
            model.handle(error)
        }
    }

    private func open(_ item: RemoteItem) {
        guard opening == nil else { return }
        Haptics.tap()
        opening = item.path
        Task {
            defer { opening = nil }
            do {
                previewURL = try await model.localCopy(of: item)
            } catch {
                model.handle(error)
            }
        }
    }
}
