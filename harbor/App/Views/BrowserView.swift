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
    @State private var selection: SidebarItem?
    @State private var shares: [RemoteItem] = []
    @State private var path: [RemoteItem] = []
    @State private var showingSettings = false
    @State private var visibility: NavigationSplitViewVisibility = .automatic

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
        .task(id: model.connection) { await loadShares() }
        .onChange(of: selection) { path = [] }
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
            .scrollContentBackground(.hidden)
            .background(Theme.Sidebar.background)
        .navigationTitle(model.activeServer?.name ?? "Ownhold")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
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
            Section {
                ForEach(shares) { share in
                    NavigationLink(value: SidebarItem.share(share)) {
                        sidebarLabel(share.name, symbol: "externaldrive")
                    }
                    .listRowBackground(selection == .share(share) ? nil : Color.clear)
                }
            } header: {
                sectionHeader("Shared Folders")
            }
            Section {
                NavigationLink(value: SidebarItem.offline) {
                    sidebarLabel("Offline", symbol: "arrow.down.circle")
                        .badge(model.savedPaths.count)
                }
                .listRowBackground(selection == .offline ? nil : Color.clear)
            }
        }
        .listItemTint(.fixed(Theme.accent))
    }

    private func sidebarLabel(_ title: String, symbol: String) -> some View {
        Label {
            Text(title).foregroundStyle(Theme.Sidebar.text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
    }
    #endif

    private func sectionHeader(_ title: String) -> some View {
        Text(title).foregroundStyle(Theme.Sidebar.secondary)
    }

    #if os(macOS)
    private var macFooter: some View {
        HStack(spacing: Theme.Spacing.s) {
            ConnectionBadge(connection: model.connection)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .lineLimit(1)
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
            if selection == nil, !Platform.isCompactDefault {
                var initial = shares.first
                #if DEBUG
                // `-share Photos` opens a specific share: used for screenshots.
                if let name = UserDefaults.standard.string(forKey: "share") {
                    initial = shares.first { $0.name == name } ?? initial
                }
                #endif
                if let initial { selection = .share(initial) }
            }
        } catch {
            model.handle(error)
        }
    }
}

extension Platform {
    /// On iPhone the sidebar is the first screen, so nothing is pre-selected.
    @MainActor static var isCompactDefault: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
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
