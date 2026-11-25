import HarborKit
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
        List(selection: $selection) {
            Section {
                ForEach(shares) { share in
                    NavigationLink(value: SidebarItem.share(share)) {
                        Label(share.name, systemImage: "externaldrive")
                    }
                }
            } header: {
                Text("Shared Folders")
            }

            Section {
                NavigationLink(value: SidebarItem.offline) {
                    Label("Offline", systemImage: "arrow.down.circle")
                        .badge(model.savedPaths.count)
                }
            }
        }
        .navigationTitle(model.activeServer?.name ?? "Harbor")
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
            Divider()
            #if os(iOS)
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
            #else
            SettingsLink { Label("Settings", systemImage: "gearshape") }
            #endif
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
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

/// Shows how the app is connected right now: home network, Tailscale,
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
        case let .online(kind): kind?.label ?? "Demo library"
        case .offline: "Offline"
        }
    }

    private var symbol: String {
        switch connection {
        case .idle: "circle.dashed"
        case .connecting: "ellipsis"
        case let .online(kind): kind?.symbol ?? "shippingbox"
        case .offline: "wifi.slash"
        }
    }
}
