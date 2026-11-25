import OwnholdKit
import SwiftUI

enum SidebarItem: Hashable {
    case share(RemoteItem)
    case offline
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
    @State private var path: [RemoteItem] = []
    @State private var showingSettings = false
    // Both columns from the start wherever they fit; one column on iPhone either way.
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                detailRoot
                    .navigationDestination(for: RemoteItem.self) { folder in
                        FolderView(folder: folder)
                    }
            }
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
        case .offline:
            OfflineView()
        case nil:
            ContentUnavailableView("Choose a folder", systemImage: "sidebar.left")
        }
    }

    private var sidebar: some View {
        sidebarList
            // Tinted: the accent's light tint. Plain: the system's sidebar.
            .scrollContentBackground(Theme.Sidebar.isTinted ? .hidden : .automatic)
            .background(Theme.Sidebar.isTinted ? Theme.Sidebar.background : .clear)
        .navigationTitle(model.activeServer?.name ?? "Ownhold")
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
        #if os(macOS)
        // The Mac sidebar is too narrow for toolbar items next to the window
        // controls, so connection status and the server menu live in a footer,
        // like the account switcher at the bottom of Mail's sidebar.
        .safeAreaInset(edge: .bottom) { macFooter }
        #else
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
        .overlay {
            if shares.isEmpty, model.connection == .connecting {
                ProgressView()
            } else if shares.isEmpty, model.connection == .offline {
                ContentUnavailableView {
                    Label("Can't Reach NAS", systemImage: "wifi.slash")
                } description: {
                    Text("Offline files are still available.")
                } actions: {
                    Button("Try Again") { Task { await model.reconnect() } }
                }
            }
        }
    }

    // MARK: Sidebar rows

    #if os(macOS)
    /// On the Mac, rows draw their own evergreen selection: the system list
    /// highlight always uses the user's accent color, which would clash with
    /// the tinted sidebar.
    private var sidebarList: some View {
        List {
            Section {
                ForEach(shares) { share in
                    macRow(.share(share), title: share.name, symbol: "externaldrive")
                }
            } header: {
                sectionHeader("Shared Folders")
            }
            Section {
                macRow(.offline, title: "Offline", symbol: "arrow.down.circle", badge: model.savedPaths.count)
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
    /// the tint makes the selection highlight evergreen.
    private var sidebarList: some View {
        List(selection: $selection) {
            Section {} header: { serverHeading }
            Section {
                ForEach(shares) { share in
                    NavigationLink(value: SidebarItem.share(share)) {
                        sidebarLabel(share.name, symbol: "externaldrive", item: .share(share))
                    }
                    .listRowBackground(rowBackground(.share(share)))
                }
            } header: {
                sectionHeader("Shared Folders")
            }
            Section {
                NavigationLink(value: SidebarItem.offline) {
                    sidebarLabel("Offline", symbol: "arrow.down.circle", item: .offline)
                        .badge(model.savedPaths.count)
                }
                .listRowBackground(rowBackground(.offline))
            }
        }
        .listItemTint(.fixed(Theme.accent))
    }

    /// The NAS name, wrapping to two lines (and shrinking a little) rather
    /// than being cut short: "Brian's DS920+ Home Server" fits in a sidebar.
    private var serverHeading: some View {
        Text(model.activeServer?.name ?? "Ownhold")
            .font(showsTwoColumns ? .title.bold() : .largeTitle.bold())
            // Explicit: section headers otherwise draw their text in gray.
            .foregroundStyle(Color.primary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
    }

    /// Whether `item` shows the evergreen selection. Only with two columns:
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

    /// The same solid evergreen selection as the Mac, instead of the
    /// system's gray (which it uses whenever the file list has focus).
    /// nil keeps the system's row background (the Plain sidebar).
    private func rowBackground(_ item: SidebarItem) -> AnyView? {
        if isHighlighted(item) {
            return AnyView(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent)
                .padding(.horizontal, 10))
        }
        return Theme.Sidebar.isTinted ? AnyView(Color.clear) : nil
    }
    #endif

    private func sectionHeader(_ title: String) -> some View {
        Text(title).foregroundStyle(Theme.Sidebar.secondary)
    }

    #if os(macOS)
    private var macFooter: some View {
        HStack(spacing: Theme.Spacing.s) {
            // Mac sidebars don't show a title, so the NAS name lives here,
            // above how it's connected (like the account in Mail's sidebar).
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeServer?.name ?? "Ownhold")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Sidebar.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ConnectionBadge(connection: model.connection)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            serverMenu
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
    }
    #endif

    private var serverMenu: some View {
        Menu {
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
            Divider()
            #if os(iOS)
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
            #else
            SettingsLink { Label("Settings", systemImage: "gearshape") }
            #endif
            Button(model.activeServer?.isDemo == true ? "Leave Demo" : "Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await model.signOut() }
            }
        } label: {
            Label("Servers", systemImage: "externaldrive.connected.to.line.below")
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

    private var title: String {
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
