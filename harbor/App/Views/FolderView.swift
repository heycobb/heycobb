import OwnholdKit
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

enum BrowseLayout: String { case list, grid }

struct FolderView: View {
    let folder: RemoteItem

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("layout") private var layout: BrowseLayout = .list
    @AppStorage("sortField") private var sort: SortField = .name
    @AppStorage("sortAscending") private var ascending = true

    @State private var items: [RemoteItem] = []
    @State private var total = 0
    @State private var loading = false
    /// True once the folder has been listed: until then an empty list means
    /// "not loaded yet", not "Empty Folder".
    @State private var loaded = false
    @State private var retries = 0
    @State private var failed: NASError?
    @State private var query = ""
    @State private var searchResults: [RemoteItem]?
    @State private var previewURL: URL?
    @State private var opening: String?
    @State private var info: RemoteItem?

    // Changes
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var renaming: RemoteItem?
    @State private var creatingFolder = false
    @State private var newName = ""
    @State private var deleting: [RemoteItem] = []
    @State private var confirmingDelete = false
    @State private var moveRequest: MoveRequest?
    @State private var working: String?
    @State private var showingFiles = false
    @State private var showingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    #if os(iOS)
    @State private var scanning = false
    @State private var scannedFile: URL?
    @State private var scanName = ""
    #endif
    @State private var conflictBatch: UploadBatch?
    @State private var dropTargeted = false
    @State private var shareTask: Task<Void, Never>?
    @State private var playing: MediaPlayback?
    @State private var linkItem: RemoteItem?

    typealias MoveRequest = FolderViewMoveRequest
    typealias UploadBatch = FolderViewUploadBatch




    private let pageSize = 300

    private var shown: [RemoteItem] { searchResults ?? items }

    var body: some View {
        content
            .navigationTitle(selecting ? selectionTitle : folder.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "Search \(folder.name)")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onChange(of: query) { if query.isEmpty { searchResults = nil } }
            .toolbar { toolbar }
            .task(id: ReloadKey(path: folder.path, sort: sort, ascending: ascending, connection: model.connection, revision: model.revision(of: folder.path))) {
                await reload()
            }
            .refreshable { await reload() }
            .filePreview($previewURL)
            .sheet(item: $info) { item in
                ItemInfoView(item: item)
            }
            .sheet(item: $linkItem) { item in
                ShareLinkView(item: item)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ActivityBar(working: working, onCancel: shareTask == nil ? nil : { shareTask?.cancel() })
            }
            .mediaPlayer($playing)
            .modifier(changeSheets)
            #if os(iOS)
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner { url in
                    scanning = false
                    if let url {
                        scanName = DocumentScanner.defaultName
                        scannedFile = url
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Save Scan", isPresented: Binding(get: { scannedFile != nil && !scanning }, set: { _ in })) {
                TextField("Name", text: $scanName)
                Button("Save") { saveScan() }
                Button("Cancel", role: .cancel) { discardScan() }
            } message: {
                Text("In “\(folder.name)”")
            }
            // Scan to NAS from Shortcuts opens this folder, then scans.
            .onChange(of: model.scanRequest, initial: true) {
                guard model.scanRequest == folder.path, DocumentScanner.isAvailable else { return }
                model.scanRequest = nil
                scanning = true
            }
            #endif
            .focusedSceneValue(\.folderCommands, menuCommands)
    }

    // MARK: Change dialogs

    private var changeSheets: ChangeDialogs {
        ChangeDialogs(
            folder: folder,
            renaming: $renaming,
            creatingFolder: $creatingFolder,
            newName: $newName,
            deleting: deleting,
            confirmingDelete: $confirmingDelete,
            moveRequest: $moveRequest,
            showingFiles: $showingFiles,
            showingPhotos: $showingPhotos,
            photoItems: $photoItems,
            conflictBatch: $conflictBatch,
            dropTargeted: $dropTargeted,
            onDelete: { items in Task { await performDelete(items) } },
            onMove: { items, destination in Task { await performMove(items, to: destination) } },
            onUpload: { uploads in Task { await prepare(uploads) } },
            onPhotos: { picked in Task { await importPhotos(picked) } },
            onResolve: { batch, choice in
                model.uploads.add(batch.uploads, to: folder.path, existing: batch.existing, onConflict: choice)
            }
        )
    }

    private var selectionTitle: String {
        selection.isEmpty ? "Select Items" : selection.count == 1 ? "1 Selected" : "\(selection.count) Selected"
    }

    private var selectedItems: [RemoteItem] { shown.filter { selection.contains($0.path) } }

    /// What the Mac menu bar's File, Edit and View commands act on.
    private var menuCommands: FolderCommands {
        let chosen = selectedItems
        let writable = canChange
        return FolderCommands(
            canChange: writable,
            isSelecting: selecting,
            newFolder: {
                newName = ""
                creatingFolder = true
            },
            uploadFiles: { showingFiles = true },
            canRename: writable && chosen.count == 1,
            canDelete: writable && !chosen.isEmpty,
            canExtract: writable && chosen.count == 1 && chosen[0].isArchive,
            canShareLink: model.service != nil && chosen.count == 1,
            rename: {
                guard let item = chosen.first, chosen.count == 1 else { return }
                endSelecting()
                newName = item.name
                renaming = item
            },
            delete: { if !chosen.isEmpty { askToDelete(chosen) } },
            compress: { if !chosen.isEmpty { Task { await compress(chosen) } } },
            extract: { if let archive = chosen.first, chosen.count == 1 { Task { await extract(archive) } } },
            shareLink: {
                guard let item = chosen.first, chosen.count == 1 else { return }
                endSelecting()
                linkItem = item
            },
            toggleSelecting: {
                if selecting { endSelecting() } else { selecting = true }
            }
        )
    }

    private var canChange: Bool {
        guard model.service != nil, case .online = model.connection else { return false }
        return true
    }

    private func toggle(_ item: RemoteItem) {
        Haptics.tap()
        if selection.contains(item.path) { selection.remove(item.path) } else { selection.insert(item.path) }
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    /// Downloads (or zips) the items, then opens the share sheet.
    private func share(_ items: [RemoteItem]) {
        guard shareTask == nil, !items.isEmpty else { return }
        working = items.count == 1 ? "Preparing “\(items[0].name)”…" : "Preparing \(items.count) items…"
        shareTask = Task {
            defer {
                working = nil
                shareTask = nil
            }
            do {
                let urls = try await model.shareableCopies(of: items) { done, total in
                    working = "Copying \(done + 1) of \(total)…"
                }
                try Task.checkCancellation()
                endSelecting()
                SharePresenter.present(urls)
            } catch is CancellationError {
            } catch {
                model.handle(error)
            }
        }
    }

    private func compress(_ items: [RemoteItem]) async {
        working = items.count == 1 ? "Compressing “\(items[0].name)”…" : "Compressing \(items.count) items…"
        defer { working = nil }
        if await model.compress(items, in: folder.path, existing: Set(self.items.map(\.name))) { endSelecting() }
    }

    private func extract(_ archive: RemoteItem) async {
        working = "Extracting “\(archive.name)”…"
        defer { working = nil }
        await model.extract(archive, existing: Set(items.map(\.name)))
    }

    private func askToDelete(_ items: [RemoteItem]) {
        guard !items.isEmpty else { return }
        deleting = items
        confirmingDelete = true
    }

    private func performDelete(_ items: [RemoteItem]) async {
        working = items.count == 1 ? "Deleting “\(items[0].name)”…" : "Deleting \(items.count) items…"
        defer { working = nil }
        if await model.delete(items) { endSelecting() }
    }

    private func performMove(_ items: [RemoteItem], to destination: String) async {
        working = items.count == 1 ? "Moving “\(items[0].name)”…" : "Moving \(items.count) items…"
        defer { working = nil }
        if await model.move(items, to: destination) {
            endSelecting()
            model.banner = items.count == 1 ? "Moved to \((destination as NSString).lastPathComponent)" : "Moved \(items.count) items to \((destination as NSString).lastPathComponent)"
        }
    }

    // MARK: Uploading

    #if os(iOS)
    /// Queues the scanned PDF under the name the user gave it.
    private func saveScan() {
        guard let file = scannedFile else { return }
        scannedFile = nil
        var name = scanName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = DocumentScanner.defaultName }
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        Task { await prepare([PendingUpload(url: file, name: name, ownsFile: true)]) }
    }

    private func discardScan() {
        if let file = scannedFile { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        scannedFile = nil
    }
    #endif

    /// Checks for name clashes, asking Replace / Keep Both / Skip if needed.
    private func prepare(_ uploads: [PendingUpload]) async {
        guard !uploads.isEmpty else { return }
        let existing = await existingNames()
        let conflicts = UploadQueue.conflicts(uploads, existing: existing)
        if conflicts.isEmpty {
            model.uploads.add(uploads, to: folder.path, existing: existing, onConflict: .keepBoth)
        } else {
            conflictBatch = UploadBatch(uploads: uploads, existing: existing, conflicts: conflicts)
        }
    }

    private func existingNames() async -> Set<String> {
        guard items.count < total, let service = model.service,
              let page = try? await service.list(folder: folder.path, offset: 0, limit: max(total, 1000), sort: .name, ascending: true)
        else { return Set(items.map(\.name)) }
        return Set(page.items.map(\.name))
    }

    /// Copies picked photos and videos out of the library (in their original
    /// format, e.g. HEIC), then queues them.
    private func importPhotos(_ picked: [PhotosPickerItem]) async {
        model.uploads.beginPreparing(picked.count)
        defer { model.uploads.endPreparing(picked.count) }
        var staged: [PendingUpload] = []
        var failures = 0
        for item in picked {
            if let media = try? await item.loadTransferable(type: PickedMedia.self) {
                staged.append(PendingUpload(url: media.url, name: media.url.lastPathComponent, ownsFile: true))
            } else {
                failures += 1
            }
        }
        if failures > 0 {
            model.banner = failures == 1 ? "One item couldn't be read from your library." : "\(failures) items couldn't be read from your library."
        }
        await prepare(staged)
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
        } else if items.isEmpty, !loaded, searchResults == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if shown.isEmpty, !loading {
            if searchResults != nil {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "folder")
                } actions: {
                    if canChange {
                        Button("Upload Files…") { showingFiles = true }
                            .buttonStyle(.borderedProminent)
                        Button("New Folder") {
                            newName = ""
                            creatingFolder = true
                        }
                    }
                }
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
        if selecting {
            Button { toggle(item) } label: {
                HStack(spacing: Theme.Spacing.m) {
                    SelectionMark(selected: selection.contains(item.path))
                    ItemRow(item: item, saved: saved, busy: false)
                }
            }
            .buttonStyle(.plain)
        } else {
            normalRow(for: item, saved: saved)
        }
    }

    @ViewBuilder private func normalRow(for item: RemoteItem, saved: Bool) -> some View {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canChange {
                Button { askToDelete([item]) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
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
            if isPhotoFolder {
                folderRows(shown.filter(\.isDirectory))
                photoGrid(shown.filter { !$0.isDirectory })
            } else {
                labeledGrid(shown)
            }
            if loading { ProgressView().padding() }
        }
    }

    /// Mostly photos and videos: show them like Photos does.
    private var isPhotoFolder: Bool {
        let files = shown.filter { !$0.isDirectory }
        guard files.count >= 4 else { return false }
        return Double(files.filter(\.hasThumbnail).count) / Double(files.count) >= 0.7
    }

    private func labeledGrid(_ items: [RemoteItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? Theme.gridMinimumRegular : Theme.gridMinimum), spacing: Theme.Spacing.m, alignment: .top)], spacing: Theme.Spacing.l) {
            ForEach(items) { item in
                tile(for: item)
                    .onAppear { loadMoreIfNeeded(item) }
            }
        }
        .padding(Theme.Spacing.l)
    }

    /// Subfolders above a photo grid: compact rows, so the photos start high.
    private func folderRows(_ folders: [RemoteItem]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(folders) { folder in
                if selecting {
                    Button { toggle(folder) } label: {
                        HStack(spacing: Theme.Spacing.m) {
                            SelectionMark(selected: selection.contains(folder.path))
                            ItemRow(item: folder, saved: model.savedPaths.contains(folder.path), busy: false)
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.s)
                    }
                    .buttonStyle(.plain)
                } else {
                NavigationLink(value: folder) {
                    HStack {
                        ItemRow(item: folder, saved: model.savedPaths.contains(folder.path), busy: false)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.s)
                }
                .buttonStyle(.plain)
                .contextMenu { menu(for: folder) }
                }
                Divider().padding(.leading, Theme.Spacing.l + 40 + Theme.Spacing.m)
            }
        }
    }

    /// Edge-to-edge square thumbnails with hairline gaps and no captions.
    private func photoGrid(_ items: [RemoteItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? Theme.photoMinimumRegular : Theme.photoMinimum), spacing: Theme.photoSpacing)], spacing: Theme.photoSpacing) {
            ForEach(items) { item in
                Button { selecting ? toggle(item) : open(item) } label: {
                    PhotoTile(item: item, saved: model.savedPaths.contains(item.path), busy: opening == item.path)
                        .overlay(alignment: .topTrailing) {
                            if selecting { SelectionMark(selected: selection.contains(item.path), onImage: true) }
                        }
                }
                .buttonStyle(.plain)
                .contextMenu { if !selecting { menu(for: item) } }
                .onAppear { loadMoreIfNeeded(item) }
            }
        }
    }

    @ViewBuilder private func tile(for item: RemoteItem) -> some View {
        let saved = model.savedPaths.contains(item.path)
        Group {
            if selecting {
                Button { toggle(item) } label: {
                    ItemTile(item: item, saved: saved)
                        .overlay(alignment: .topTrailing) {
                            SelectionMark(selected: selection.contains(item.path), onImage: true)
                        }
                }
            } else if item.isDirectory {
                NavigationLink(value: item) { ItemTile(item: item, saved: saved) }
            } else {
                Button { open(item) } label: { ItemTile(item: item, saved: saved) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { if !selecting { menu(for: item) } }
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
            Button(item.isStreamable ? "Play" : "Quick Look", systemImage: item.isStreamable ? "play" : "eye") { open(item) }
        }
        Button("Share…", systemImage: "square.and.arrow.up") { share([item]) }
            .disabled(model.service == nil && !saved)
        if model.service != nil {
            Button("Share Link…", systemImage: "link") { linkItem = item }
        }
        if item.isDirectory {
            Button(model.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: model.isFavorite(item) ? "star.slash" : "star") { model.toggleFavorite(item) }
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
        if canChange {
            Divider()
            Button("Rename…", systemImage: "pencil") {
                newName = item.name
                renaming = item
            }
            Button("Move…", systemImage: "folder") { moveRequest = MoveRequest(items: [item]) }
            Button("Compress", systemImage: "archivebox") { Task { await compress([item]) } }
            if item.isArchive {
                Button("Extract Here", systemImage: "archivebox.circle") { Task { await extract(item) } }
            }
            Button("Delete…", systemImage: "trash", role: .destructive) { askToDelete([item]) }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            selectionToolbar
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Upload Photos and Videos", systemImage: "photo.on.rectangle") { showingPhotos = true }
                    Button("Upload Files…", systemImage: "arrow.up.doc") { showingFiles = true }
                    #if os(iOS)
                    if DocumentScanner.isAvailable {
                        Button("Scan Document", systemImage: "doc.viewfinder") {
                            if ProStore.shared.isUnlocked { scanning = true } else { model.showingPro = true }
                        }
                    }
                    #endif
                    Divider()
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newName = ""
                        creatingFolder = true
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                // The Mac adds a menu arrow beside the icon, which crowds the
                // small glass button; iPhone and iPad already hide it.
                .menuIndicator(.hidden)
                .disabled(!canChange)
            }
            viewOptions
        }
    }

    @ToolbarContentBuilder private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { endSelecting() }
        }
        ToolbarItem(placement: .cancellationAction) {
            if selection.count == shown.count, !shown.isEmpty {
                Button("Deselect All") { selection = [] }
            } else {
                Button("Select All") { selection = Set(shown.map(\.path)) }
            }
        }
        #if os(iOS)
        ToolbarItemGroup(placement: .bottomBar) {
            selectionActions
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            selectionActions
        }
        #endif
    }

    @ViewBuilder private var selectionActions: some View {
        let chosen = selectedItems
        Button("Share", systemImage: "square.and.arrow.up") { share(chosen) }
            .disabled(chosen.isEmpty || model.service == nil || shareTask != nil)
        #if os(iOS)
        Spacer()
        #endif
        Button("Move", systemImage: "folder") { moveRequest = MoveRequest(items: chosen) }
            .disabled(chosen.isEmpty || !canChange)
        #if os(iOS)
        Spacer()
        #endif
        Button("Compress", systemImage: "archivebox") { Task { await compress(chosen) } }
            .disabled(chosen.isEmpty || !canChange || working != nil)
        #if os(iOS)
        Spacer()
        #endif
        Button("Keep Offline", systemImage: "arrow.down.circle") {
            Task {
                for item in chosen where !model.savedPaths.contains(item.path) { await model.toggleOffline(item) }
                endSelecting()
            }
        }
        .disabled(chosen.isEmpty || model.service == nil)
        #if os(iOS)
        Spacer()
        #endif
        Button("Delete", systemImage: "trash", role: .destructive) { askToDelete(chosen) }
            .disabled(chosen.isEmpty || !canChange)
    }

    @ToolbarContentBuilder private var viewOptions: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Select", systemImage: "checkmark.circle") { selecting = true }
                    .disabled(shown.isEmpty)
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
            .menuIndicator(.hidden)
        }
    }

    // MARK: Loading

    private struct ReloadKey: Equatable {
        let path: String
        let sort: SortField
        let ascending: Bool
        let connection: AppModel.Connection
        let revision: Int
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
            loaded = true
            // Something changed here: refresh open search results too, so
            // they don't keep showing deleted or renamed items.
            if searchResults != nil, !query.isEmpty { await runSearch() }
        } catch is CancellationError {
            // On iPhone, pushing a folder can briefly take its screen off and
            // back on, which cancels the first load without starting it
            // again. Retry from outside the cancelled task, a few times.
            if !loaded, retries < 3 {
                retries += 1
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    if !loaded, !loading { await reload() }
                }
            }
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
                switch try await model.openFile(item, siblings: shown) {
                case let .play(playback): playing = playback
                case let .preview(url): previewURL = url
                }
            } catch {
                model.handle(error)
            }
        }
    }
}

// MARK: - Change dialogs

/// The alerts, sheets and pickers for changing files, kept out of the main
/// view body so the type checker stays fast.
private struct ChangeDialogs: ViewModifier {
    let folder: RemoteItem
    @Binding var renaming: RemoteItem?
    @Binding var creatingFolder: Bool
    @Binding var newName: String
    let deleting: [RemoteItem]
    @Binding var confirmingDelete: Bool
    @Binding var moveRequest: FolderViewMoveRequest?
    @Binding var showingFiles: Bool
    @Binding var showingPhotos: Bool
    @Binding var photoItems: [PhotosPickerItem]
    @Binding var conflictBatch: FolderViewUploadBatch?
    @Binding var dropTargeted: Bool
    let onDelete: ([RemoteItem]) -> Void
    let onMove: ([RemoteItem], String) -> Void
    let onUpload: ([PendingUpload]) -> Void
    let onPhotos: ([PhotosPickerItem]) -> Void
    let onResolve: (FolderViewUploadBatch, ConflictChoice) -> Void

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            // Buttons check the name when tapped: an alert doesn't refresh a
            // button's disabled state while you type, so `.disabled` would
            // leave Create stuck off (or on).
            .alert("New Folder", isPresented: $creatingFolder) {
                TextField("Name", text: $newName)
                    .onSubmit { create() }
                Button("Create") { create() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("In “\(folder.name)”")
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { item in
                TextField("Name", text: $newName)
                    .onSubmit { rename(item) }
                Button("Rename") { rename(item) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("Enter a new name for “\(item.name)”.")
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete(deleting) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes \(deleting.count == 1 ? "it" : "them") from your NAS. If the Recycle Bin is on for this shared folder, you can restore \(deleting.count == 1 ? "it" : "them") from there in DSM.")
            }
            .sheet(item: $moveRequest) { request in
                FolderPicker(items: request.items) { destination in onMove(request.items, destination) }
            }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                onUpload(urls.map { PendingUpload(url: $0, name: $0.lastPathComponent, ownsFile: false) })
            }
            .photosPicker(isPresented: $showingPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
            .onChange(of: photoItems) {
                guard !photoItems.isEmpty else { return }
                let picked = photoItems
                photoItems = []
                onPhotos(picked)
            }
            .confirmationDialog(conflictTitle, isPresented: Binding(get: { conflictBatch != nil }, set: { if !$0 { conflictBatch = nil } }), titleVisibility: .visible, presenting: conflictBatch) { batch in
                Button("Keep Both") { onResolve(batch, .keepBoth) }
                Button("Replace", role: .destructive) { onResolve(batch, .replace) }
                Button("Skip") { onResolve(batch, .skip) }
                Button("Cancel", role: .cancel) { onResolve(batch, .cancel) }
            } message: { _ in
                Text("Keep Both adds a number to the new name. Replace overwrites what's on the NAS.")
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, model.service != nil else { return false }
                onUpload(files.map { PendingUpload(url: $0, name: $0.lastPathComponent, ownsFile: false) })
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    Rectangle()
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .background(Theme.accent.opacity(0.06))
                        .overlay {
                            Label("Upload to \(folder.name)", systemImage: "arrow.up.circle")
                                .font(.headline)
                                .foregroundStyle(Theme.accent)
                        }
                        .allowsHitTesting(false)
                }
            }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard RemoteItem.isValidName(name) else {
            model.banner = NASError.invalidName.errorDescription
            return
        }
        Task { await model.createFolder(named: name, in: folder.path) }
    }

    private func rename(_ item: RemoteItem) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != item.name else { return }
        guard RemoteItem.isValidName(name) else {
            model.banner = NASError.invalidName.errorDescription
            return
        }
        Task { await model.rename(item, to: name) }
    }

    private var deleteTitle: String {
        deleting.count == 1 ? "Delete “\(deleting[0].name)”?" : "Delete \(deleting.count) Items?"
    }

    private var conflictTitle: String {
        guard let batch = conflictBatch else { return "" }
        return batch.conflicts.count == 1
            ? "“\(batch.conflicts[0])” already exists in \(folder.name)"
            : "\(batch.conflicts.count) items already exist in \(folder.name)"
    }
}

/// A checkmark circle for selection mode.
struct SelectionMark: View {
    let selected: Bool
    var onImage = false

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(selected ? Color.white : (onImage ? Color.white : Color.secondary), selected ? Theme.accent : .clear)
            .shadow(color: onImage ? .black.opacity(0.35) : .clear, radius: 2)
            .padding(onImage ? Theme.Spacing.xs : 0)
            .accessibilityLabel(selected ? "Selected" : "Not selected")
    }
}

/// A photo or video from the Photos picker, copied to a private folder in
/// its original format.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMedia(url: try UploadQueue.stage(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            PickedMedia(url: try UploadQueue.stage(received.file))
        }
    }
}

struct FolderViewMoveRequest: Identifiable {
    let id = UUID()
    let items: [RemoteItem]
}

struct FolderViewUploadBatch {
    let uploads: [PendingUpload]
    let existing: Set<String>
    let conflicts: [String]
}

/// Folder actions published to the Mac menu bar (see `FolderMenuCommands`).
/// The Bools decide which items are available: SwiftUI can't compare
/// closures, so a change carried only by a closure never reaches the menu.
struct FolderCommands {
    var canChange: Bool
    var isSelecting: Bool
    var newFolder: () -> Void
    var uploadFiles: () -> Void
    var canRename: Bool
    var canDelete: Bool
    var canExtract: Bool
    var canShareLink: Bool
    var rename: () -> Void
    var delete: () -> Void
    var compress: () -> Void
    var extract: () -> Void
    var shareLink: () -> Void
    var toggleSelecting: () -> Void
}

extension FocusedValues {
    @Entry var folderCommands: FolderCommands?
}
