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

/// Sidebar of shares + a folder stack. On iPhone this collapses into a single
/// navigation stack; on iPad and Mac it's a two-column layout.
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    /// Compact (iPhone, folded iPhone Duo, narrow iPad window): the sidebar
    /// is the first screen. Regular, or the Mac (no size class): two columns.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: SidebarItem?
    @State private var shares: [RemoteItem] = []
    /// Shared folders with a Recycle Bin this account can open.
    @State private var recycleBins: [AppModel.RecycleBinFolder] = []
    @State private var path: [RemoteItem] = []
    @State private var showingSettings = false
    // Both columns from the start wherever they fit; one column on iPhone either way.
    @State private var visibility: NavigationSplitViewVisibility = .all
    @Environment(\.isBlackout) private var isBlackout

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                detailRoot
                    // A new screen per sidebar item, so a folder's first load
                    // isn't cancelled by swapping it in place of another.
                    .id(selection)
                    .navigationDestination(for: RemoteItem.self) { folder in
                        FolderView(folder: folder)
                    }
            }
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
        .onChange(of: selection) { path = [] }
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
        .onChange(of: model.navigationRequest, initial: true) {
            // From the Mac menu bar: show a share or the Offline list.
            guard let request = model.navigationRequest else { return }
            selection = request
            path = []
            model.navigationRequest = nil
        }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        #endif
    }

    @ViewBuilder private var detailRoot: some View {
        switch selection {
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
                }
            } header: {
                sectionHeader("Shared Folders")
            }
            if !model.favorites.isEmpty {
                Section {
                    ForEach(model.favorites) { folder in
                        macRow(.favorite(folder), title: folder.name, symbol: "star")
                            .contextMenu { unfavoriteButton(folder) }
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
        let selected = selection == item
        return Button { selection = item } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? Theme.onAccent : Theme.accent)
                    .frame(width: 18)
                Text(title)
                    .foregroundStyle(selected ? Theme.onAccent : Theme.Sidebar.text)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.meta)
                        .foregroundStyle(selected ? Theme.onAccent : Theme.Sidebar.secondary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.accent : .clear)
                .padding(.horizontal, 10)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    #else
    /// iPhone and iPad keep the system list (it drives navigation on iPhone);
    /// the tint makes the selection highlight the accent color.
    private var sidebarList: some View {
        List(selection: $selection) {
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
            Section {
                NavigationLink(value: SidebarItem.photos) {
                    sidebarLabel("Photos", symbol: "photo.on.rectangle.angled", item: .photos)
                }
                .listRowBackground(rowBackground(.photos))
                if model.keepRecents {
                    NavigationLink(value: SidebarItem.recents) {
                        sidebarLabel("Recents", symbol: "clock", item: .recents)
                    }
                    .listRowBackground(rowBackground(.recents))
                }
                NavigationLink(value: SidebarItem.offline) {
                    sidebarLabel("Offline", symbol: "arrow.down.circle", item: .offline)
                        .badge(model.savedPaths.count)
                }
                .listRowBackground(rowBackground(.offline))
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
        showsTwoColumns && selection == item
    }

    private func sidebarLabel(_ title: String, symbol: String, item: SidebarItem) -> some View {
        let highlighted = isHighlighted(item)
        return Label {
            Text(title).foregroundStyle(highlighted ? Theme.onAccent : Theme.Sidebar.text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(highlighted ? Theme.onAccent : Theme.accent)
        }
    }

    /// The same solid accent selection as the Mac, instead of the
    /// system's gray (which it uses whenever the file list has focus).
    /// nil keeps the system's row background (the Plain sidebar).
    private func rowBackground(_ item: SidebarItem) -> AnyView? {
        if isHighlighted(item) {
            return AnyView(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent)
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
            if selection == .favorite(folder) { selection = nil }
            model.toggleFavorite(folder)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).foregroundStyle(Theme.Sidebar.secondary)
    }

    #if os(macOS)
    /// The NAS in use, at the top of the Mac sidebar (like the account in
    /// Mail): one line, with a dot for the connection. Clicking it opens
    /// the server menu, which also says how it's connected.
    private var macServerRow: some View {
        Menu {
            Section(ConnectionBadge.title(for: model.connection)) {
                serverMenuItems
            }
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(model.activeServer?.name ?? "Arkenal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Sidebar.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Sidebar.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // The whole row opens the menu, not just the name.
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(ConnectionBadge.title(for: model.connection))
        .accessibilityLabel("\(model.activeServer?.name ?? "Arkenal"), \(ConnectionBadge.title(for: model.connection))")
        .listRowBackground(Color.clear)
        .padding(.vertical, 2)
    }

    private var connectionColor: Color {
        switch model.connection {
        case .online: .green
        case .offline: .orange
        case .idle, .connecting: .secondary
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
        guard selection == nil else { return }
        var initial = shares.first
        #if DEBUG
        // `-share Photos` opens a specific share: used for screenshots.
        if let name = UserDefaults.standard.string(forKey: "share") {
            initial = shares.first { $0.name == name } ?? initial
        }
        #endif
        if let initial { selection = .share(initial) }
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
