import ArkenalKit
import SwiftUI

enum SidebarItem: Hashable {
    case share(RemoteItem)
    case favorite(RemoteItem)
    case recents
    case offline
    case backup
    /// The Mac's Photo Backup (on iPhone and iPad, `backup` is Photo Backup).
    case photoBackup
    case recentlyDeleted
    case photos
}

extension EnvironmentValues {
    /// A folder a new Mac window or tab opens with (Open in New Tab).
    @Entry var initialFolder: RemoteItem? = nil
    /// Opens a folder in a new tab of this window (Mac tabs; nil elsewhere).
    @Entry var openInNewTab: TabOpener? = nil
}

/// Opens a folder in a new tab. Compared by its window, so views reading it
/// don't redraw on every update.
struct TabOpener: Equatable {
    let window: UUID
    let open: @MainActor (RemoteItem) -> Void

    @MainActor func callAsFunction(_ folder: RemoteItem) { open(folder) }

    static func == (a: TabOpener, b: TabOpener) -> Bool { a.window == b.window }
}

/// What a Browse screen shows: the sidebar item and the folders opened in
/// it. Each Mac tab has its own (see TabHost); elsewhere BrowserView keeps one.
@Observable
final class BrowserState: Identifiable {
    let id = UUID()
    var selection: SidebarItem?
    var path: [RemoteItem] = []
    /// A folder to open first (Open in New Tab).
    var initialFolder: RemoteItem?
    var openedInitialFolder = false

    init(initialFolder: RemoteItem? = nil) {
        self.initialFolder = initialFolder
    }

    /// The tab's name: the folder on top, else the sidebar item.
    var title: String {
        if let folder = path.last { return folder.name }
        switch selection {
        case let .share(item), let .favorite(item): return item.name
        case .photos: return "Photos"
        case .recents: return "Recents"
        case .offline: return "Offline"
        case .backup: return "Folder Backup"
        case .photoBackup: return "Photo Backup"
        case .recentlyDeleted: return "Recently Deleted"
        case nil: return initialFolder?.name ?? "Arkenal"
        }
    }

    var symbol: String {
        switch selection {
        case .share, nil: path.isEmpty ? "externaldrive" : "folder"
        case .favorite: path.isEmpty ? "star" : "folder"
        case .photos: "photo.on.rectangle.angled"
        case .recents: "clock"
        case .offline: "arrow.down.circle"
        case .backup: "clock.arrow.circlepath"
        case .photoBackup: "arrow.triangle.2.circlepath"
        case .recentlyDeleted: "trash"
        }
    }
}

/// Sidebar of shares + a folder stack. On iPhone this collapses into a single
/// navigation stack; on iPad and Mac it's a two-column layout.
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    /// Compact (iPhone, folded iPhone Duo, narrow iPad window): the sidebar
    /// is the first screen. Regular, or the Mac (no size class): two columns.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Mac tabs pass theirs in; otherwise the view keeps its own.
    var externalState: BrowserState?
    @State private var ownState = BrowserState()
    private var state: BrowserState { externalState ?? ownState }
    @State private var shares: [RemoteItem] = []
    /// Shared folders with a Recycle Bin this account can open.
    @State private var recycleBins: [AppModel.RecycleBinFolder] = []
    @State private var showingSettings = false
    // Both columns from the start wherever they fit; one column on iPhone either way.
    @State private var visibility: NavigationSplitViewVisibility = .all
    @Environment(\.isBlackout) private var isBlackout
    @Environment(\.initialFolder) private var initialFolder
    #if os(macOS)
    @Environment(\.openInNewTab) private var openInNewTab
    /// Whether this window is the front one: menu bar requests go there.
    @Environment(\.appearsActive) private var appearsActive
    #endif

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
        } detail: {
            NavigationStack(path: Bindable(state).path) {
                detailRoot
                    // A new screen per sidebar item, so a folder's first load
                    // isn't cancelled by swapping it in place of another.
                    .id(state.selection)
                    .navigationDestination(for: RemoteItem.self) { folder in
                        FolderView(folder: folder)
                    }
            }
            // A fresh stack per Mac tab, so one tab's folder views don't
            // carry over to another.
            .id(state.id)
            #if os(macOS)
            .modifier(GlassCard(on: Theme.Sidebar.isGlass && !isBlackout))
            #endif
        }
        #if os(iOS)
        // Side by side whenever there's room (iPad, an unfolded iPhone Duo),
        // rather than hiding the sidebar until it's asked for.
        .navigationSplitViewStyle(.balanced)
        #endif
        .task(id: model.connection) { await loadShares() }
        .onChange(of: state.selection) {
            // Opening a folder in a new tab sets both at once: keep its stack.
            if state.path.first.map({ !isInside($0, state.selection) }) ?? false { state.path = [] }
        }
        .onChange(of: sizeClass) {
            // Unfolding an iPhone Duo, or widening an iPad window, makes
            // room for the second column: fill it rather than leave it empty.
            guard showsTwoColumns else { return }
            selectInitialShare()
            // Collapsing to one column hides the sidebar inside the split view
            // without updating `visibility`, so setting .all again would be a
            // no-op. Reset it, then ask for both columns once the new width
            // has settled.
            visibility = .automatic
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                visibility = .all
            }
        }
        #if os(macOS)
        .onChange(of: appearsActive) { handleNavigationRequest() }
        #endif
        .onChange(of: model.navigationRequest, initial: true) { handleNavigationRequest() }
        // Another Mac tab: open its folder right away (shares are loaded).
        .onChange(of: state.id) {
            openInitialFolder()
            if showsTwoColumns { selectInitialShare() }
        }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        #endif
    }

    /// From the Mac menu bar (or onboarding): show a share or a list. With
    /// several Mac windows or tabs, only the front one acts on it.
    private func handleNavigationRequest() {
        #if os(macOS)
        guard appearsActive else { return }
        #endif
        guard let request = model.navigationRequest else { return }
        #if os(iOS)
        // Tabs on iPhone and iPad (MainTabs handles these).
        if [.photos, .recents, .offline].contains(request) { return }
        #endif
        state.selection = request
        state.path = []
        model.navigationRequest = nil
    }

    /// Whether a folder belongs to a sidebar item's shared folder or favorite
    /// (so switching to it keeps the folder stack that was just set).
    private func isInside(_ folder: RemoteItem, _ item: SidebarItem?) -> Bool {
        switch item {
        case let .share(root), let .favorite(root): folder.path.hasPrefix(root.path + "/")
        default: false
        }
    }

    /// A new Mac window or tab opened on a folder: its shared folder in the
    /// sidebar, the folder itself on top.
    private func openInitialFolder() {
        guard !state.openedInitialFolder, let folder = state.initialFolder ?? initialFolder,
              let share = shares.first(where: { $0.path == "/" + (folder.path.split(separator: "/").first.map(String.init) ?? "") })
        else { return }
        state.openedInitialFolder = true
        state.path = folder.path == share.path ? [] : [folder]
        state.selection = .share(share)
    }

    #if os(macOS)
    @ViewBuilder private func openInNewTabButton(_ folder: RemoteItem) -> some View {
        if let openInNewTab {
            Button("Open in New Tab", systemImage: "plus.square.on.square") { openInNewTab(folder) }
        }
    }
    #endif

    @ViewBuilder private var detailRoot: some View {
        switch state.selection {
        case let .share(share):
            FolderView(folder: share)
        case let .favorite(folder):
            FolderView(folder: folder)
        case .recents:
            RecentsView()
        case .backup:
            #if os(iOS)
            BackupView()
            #else
            if ProStore.shared.isUnlocked { FolderBackupView() } else { ProLockedView(title: "Folder Backup") }
            #endif
        case .photoBackup:
            BackupView()
        case .offline:
            OfflineView()
        case .recentlyDeleted:
            if ProStore.shared.isUnlocked { RecentlyDeletedView(bins: recycleBins) } else { ProLockedView(title: "Recently Deleted") }
        case .photos:
            if ProStore.shared.isUnlocked { PhotoLibraryView() } else { ProLockedView(title: "Photos") }
        case nil:
            ContentUnavailableView("Choose a folder", systemImage: "sidebar.left")
        }
    }

    private var sidebar: some View {
        sidebarList
            // Tinted: the accent's light tint. Plain: the system's sidebar.
            .scrollContentBackground(Theme.Sidebar.isTinted || Theme.Sidebar.isGlass || isBlackout ? .hidden : .automatic)
            .background(Theme.Sidebar.isTinted ? Theme.Sidebar.background : isBlackout ? Blackout.background : .clear)
        .navigationTitle(model.activeServer?.name ?? "Arkenal")
        #if os(iOS)
        // The NAS name is shown as a heading in the list instead (see
        // `serverHeading`): navigation bar titles stay on one line, so a long
        // name was cut short. The title stays set for VoiceOver and the app
        // switcher; this hides it from the bar.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
        }
        #endif
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        #else
        // Keeps the file list the main column on wide screens (an open
        // iPhone Duo would otherwise split the screen in half).
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        #endif
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ConnectionBadge(connection: model.connection)
            }
            ToolbarItem(placement: .automatic) {
                serverMenu
            }
        }
        #endif
        .refreshable { await loadShares() }
    }

    /// Stands in for the shared folders while connecting or unreachable.
    /// A row in the list (not an overlay), so it never covers the rows below.
    @ViewBuilder private var sharesPlaceholder: some View {
        if shares.isEmpty, model.connection == .connecting {
            HStack(spacing: Theme.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(Theme.Sidebar.secondary)
            }
            .listRowBackground(Color.clear)
        } else if shares.isEmpty, model.connection == .offline {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label {
                    Text("Can't Reach NAS").foregroundStyle(Theme.Sidebar.text)
                } icon: {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                }
                .font(.headline)
                Text("Offline files are still available.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Sidebar.secondary)
                HStack(spacing: Theme.Spacing.l) {
                    Button("Try Again") { Task { await model.reconnect() } }
                    if model.canWake {
                        if model.isWaking {
                            HStack(spacing: Theme.Spacing.xs) {
                                ProgressView().controlSize(.small)
                                Text("Waking…").foregroundStyle(Theme.Sidebar.secondary)
                            }
                        } else {
                            Button("Wake NAS") { Task { await model.wakeNAS() } }
                        }
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, Theme.Spacing.xs)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Sidebar rows

    #if os(macOS)
    /// On the Mac, rows draw their own accent-colored selection: the system list
    /// highlight always uses the user's accent color, which would clash with
    /// the tinted sidebar.
    private var sidebarList: some View {
        List {
            Section { macServerRow }
            Section {
                sharesPlaceholder
                ForEach(shares) { share in
                    macRow(.share(share), title: share.name, symbol: "externaldrive")
                        .contextMenu { openInNewTabButton(share) }
                }
            } header: {
                sectionHeader("Shared Folders")
            }
            if !model.favorites.isEmpty {
                Section {
                    ForEach(model.favorites) { folder in
                        macRow(.favorite(folder), title: folder.name, symbol: "star")
                            .contextMenu {
                                openInNewTabButton(folder)
                                unfavoriteButton(folder)
                            }
                    }
                } header: {
                    sectionHeader("Favorites")
                }
            }
            Section {
                macRow(.photos, title: "Photos", symbol: "photo.on.rectangle.angled")
                if model.keepRecents {
                    macRow(.recents, title: "Recents", symbol: "clock")
                }
                macRow(.offline, title: "Offline", symbol: "arrow.down.circle", badge: model.savedPaths.count)
                macRow(.photoBackup, title: "Photo Backup", symbol: "arrow.triangle.2.circlepath")
                macRow(.backup, title: "Folder Backup", symbol: "clock.arrow.circlepath")
                if !recycleBins.isEmpty {
                    macRow(.recentlyDeleted, title: "Recently Deleted", symbol: "trash")
                }
            }
        }
    }

    private func macRow(_ item: SidebarItem, title: String, symbol: String, badge: Int = 0) -> some View {
        let selected = state.selection == item
        return Button { state.selection = item } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? Theme.Sidebar.onSelection : Theme.accent)
                    .frame(width: 18)
                Text(title)
                    .foregroundStyle(selected ? Theme.Sidebar.onSelection : Theme.Sidebar.text)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.meta)
                        .foregroundStyle(selected ? Theme.Sidebar.onSelection : Theme.Sidebar.secondary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.Sidebar.selection : .clear)
                .padding(.horizontal, 10)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    #else
    /// iPhone and iPad keep the system list (it drives navigation on iPhone);
    /// the tint makes the selection highlight the accent color.
    private var sidebarList: some View {
        List(selection: Bindable(state).selection) {
            Section {} header: { serverHeading }
            Section {
                sharesPlaceholder
                ForEach(shares) { share in
                    NavigationLink(value: SidebarItem.share(share)) {
                        sidebarLabel(share.name, symbol: "externaldrive", item: .share(share))
                    }
                    .listRowBackground(rowBackground(.share(share)))
                }
            } header: {
                sectionHeader("Shared Folders")
            }
            if !model.favorites.isEmpty {
                Section {
                    ForEach(model.favorites) { folder in
                        NavigationLink(value: SidebarItem.favorite(folder)) {
                            sidebarLabel(folder.name, symbol: "star", item: .favorite(folder))
                        }
                        .listRowBackground(rowBackground(.favorite(folder)))
                        .contextMenu { unfavoriteButton(folder) }
                        .swipeActions { unfavoriteButton(folder) }
                    }
                } header: {
                    sectionHeader("Favorites")
                }
            }
            // Photos, Recents and Offline are tabs (see MainTabs).
            Section {
                NavigationLink(value: SidebarItem.backup) {
                    sidebarLabel("Photo Backup", symbol: "arrow.triangle.2.circlepath", item: .backup)
                }
                .listRowBackground(rowBackground(.backup))
                if !recycleBins.isEmpty {
                    NavigationLink(value: SidebarItem.recentlyDeleted) {
                        sidebarLabel("Recently Deleted", symbol: "trash", item: .recentlyDeleted)
                    }
                    .listRowBackground(rowBackground(.recentlyDeleted))
                }
            }
        }
        .listItemTint(.fixed(Theme.accent))
    }

    /// The NAS name, wrapping to two lines (and shrinking a little) rather
    /// than being cut short: "Brian's DS920+ Home Server" fits in a sidebar.
    private var serverHeading: some View {
        Text(model.activeServer?.name ?? "Arkenal")
            .font(showsTwoColumns ? .title.bold() : .largeTitle.bold())
            // Explicit: section headers otherwise draw their text in gray.
            .foregroundStyle(Color.primary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
    }

    /// Whether `item` shows the accent selection. Only with two columns:
    /// in one column, a selected row is the screen you've moved on to.
    private func isHighlighted(_ item: SidebarItem) -> Bool {
        showsTwoColumns && state.selection == item
    }

    private func sidebarLabel(_ title: String, symbol: String, item: SidebarItem) -> some View {
        let highlighted = isHighlighted(item)
        return Label {
            Text(title).foregroundStyle(highlighted ? Theme.Sidebar.onSelection : Theme.Sidebar.text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(highlighted ? Theme.Sidebar.onSelection : Theme.accent)
        }
    }

    /// The same solid accent selection as the Mac, instead of the
    /// system's gray (which it uses whenever the file list has focus).
    /// nil keeps the system's row background (the Plain sidebar).
    private func rowBackground(_ item: SidebarItem) -> AnyView? {
        if isHighlighted(item) {
            return AnyView(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Sidebar.selection)
                .padding(.horizontal, 10))
        }
        if Theme.Sidebar.isTinted { return AnyView(Color.clear) }
        // Blackout: cards on iPhone's list; on the iPad sidebar the rows
        // aren't rounded, so it stays plain black like the Mac's.
        if Blackout.isOn { return AnyView(showsTwoColumns ? Color.clear : Blackout.row) }
        return nil
    }
    #endif

    private func unfavoriteButton(_ folder: RemoteItem) -> some View {
        Button("Remove from Favorites", systemImage: "star.slash") {
            if state.selection == .favorite(folder) { state.selection = nil }
            model.toggleFavorite(folder)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).foregroundStyle(Theme.Sidebar.secondary)
    }

    #if os(macOS)
    /// The NAS in use, at the top of the Mac sidebar: a card with the
    /// device, its connection dot, its kind and how it's reached. Clicking
    /// anywhere on it opens the server menu.
    private var macServerRow: some View {
        Menu {
            Section(ConnectionBadge.title(for: model.connection)) {
                serverMenuItems
            }
        } label: {
            ServerCard(name: model.activeServer?.name ?? "Arkenal",
                       detail: serverDetail,
                       dot: connectionColor)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(ConnectionBadge.title(for: model.connection))
        .accessibilityLabel("\(model.activeServer?.name ?? "Arkenal"), \(serverDetail)")
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
    }

    /// "Synology · Home network" when connected; otherwise the state.
    private var serverDetail: String {
        guard case let .online(endpoint) = model.connection, let endpoint,
              let kind = model.activeServer?.kind else {
            return ConnectionBadge.title(for: model.connection)
        }
        let short = switch kind {
        case .synology: "Synology"
        case .webdav: "WebDAV"
        case .smb: "SMB"
        }
        return "\(short) · \(endpoint.displayName)"
    }

    private var connectionColor: Color {
        switch model.connection {
        case .online: .green
        case .offline: .orange
        case .idle, .connecting: .secondary
        }
    }
    #endif

    #if os(macOS)
    /// The card drawn for the NAS at the top of the Mac sidebar.
    private struct ServerCard: View {
        let name: String
        let detail: String
        let dot: Color
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.Sidebar.text.opacity(0.13))
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Sidebar.text.opacity(0.85))
                }
                .frame(width: 30, height: 30)
                // The dot sits in a cut-out ring, so it reads on any sidebar.
                .mask {
                    Rectangle().overlay(alignment: .bottomTrailing) {
                        Circle().frame(width: 13, height: 13).offset(x: 3, y: 3)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(dot).frame(width: 8, height: 8).offset(x: 0.5, y: 0.5)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Sidebar.text)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Sidebar.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)

                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Sidebar.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(Theme.Sidebar.text.opacity(hovering ? 0.10 : 0.06),
                        in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
            .onHover { hovering = $0 }
        }
    }
    #endif

    private var serverMenu: some View {
        Menu {
            serverMenuItems
        } label: {
            Label("Servers", systemImage: "externaldrive.connected.to.line.below")
        }
    }

    @ViewBuilder private var serverMenuItems: some View {
            ForEach(model.servers) { server in
                Button {
                    Task { await model.activate(server) }
                } label: {
                    if server.id == model.activeServer?.id {
                        Label(server.name, systemImage: "checkmark")
                    } else {
                        Text(server.name)
                    }
                }
            }
            Button("Add a NAS…", systemImage: "plus") { model.isAddingServer = true }
            if model.canWake, model.connection == .offline {
                Button("Wake NAS", systemImage: "power") { Task { await model.wakeNAS() } }
                    .disabled(model.isWaking)
            }
            Divider()
            #if os(iOS)
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
            #else
            SettingsLink { Label("Settings", systemImage: "gearshape") }
            #endif
            Button(model.activeServer?.isDemo == true ? "Leave Demo" : "Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await model.signOut() }
            }
    }

    private func loadShares() async {
        guard let service = model.service else {
            shares = []
            return
        }
        do {
            shares = try await service.listShares()
            openInitialFolder()
            if showsTwoColumns { selectInitialShare() }
            recycleBins = model.activeServer?.kind.hasRecycleBin == false ? [] : await model.recycleBins(in: shares)
        } catch {
            model.handle(error)
        }
    }

    private var showsTwoColumns: Bool { sizeClass != .compact }

    /// With two columns showing, open the first share instead of leaving
    /// the detail column empty. In one column the sidebar is the first screen.
    private func selectInitialShare() {
        guard state.selection == nil else { return }
        var initial = shares.first
        #if DEBUG
        // `-share Photos` opens a specific share: used for screenshots.
        if let name = UserDefaults.standard.string(forKey: "share") {
            initial = shares.first { $0.name == name } ?? initial
        }
        #endif
        #if DEBUG
        // `-select backup` opens a list instead (photos, recents, offline,
        // backup, photoBackup): used for screenshots.
        switch UserDefaults.standard.string(forKey: "select") {
        case "photos": state.selection = .photos; return
        case "recents": state.selection = .recents; return
        case "offline": state.selection = .offline; return
        case "backup": state.selection = .backup; return
        case "photoBackup": state.selection = .photoBackup; return
        default: break
        }
        #endif
        if let initial { state.selection = .share(initial) }
    }
}

/// Shows how the app is connected right now: home network, private network
/// (named when known, e.g. Tailscale),
/// internet, demo or offline.
struct ConnectionBadge: View {
    let connection: AppModel.Connection

    var body: some View {
        Label(title, systemImage: symbol)
            #if os(iOS)
            .labelStyle(.iconOnly)
            #endif
            .foregroundStyle(connection == .offline ? .orange : .secondary)
            .help(title)
            .accessibilityLabel("Connection: \(title)")
    }

    private var title: String { Self.title(for: connection) }

    static func title(for connection: AppModel.Connection) -> String {
        switch connection {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case let .online(endpoint): endpoint?.displayName ?? "Demo library"
        case .offline: "Offline"
        }
    }

    private var symbol: String {
        switch connection {
        case .idle: "circle.dashed"
        case .connecting: "ellipsis"
        case let .online(endpoint): endpoint?.kind.symbol ?? "shippingbox"
        case .offline: "wifi.slash"
        }
    }
}
