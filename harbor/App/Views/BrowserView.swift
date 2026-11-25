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
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ConnectionBadge(connection: model.connection)
            }
            ToolbarItem(placement: .automatic) {
                serverMenu
            }
        }
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
            if selection == nil, let first = shares.first, !Platform.isCompactDefault {
                selection = .share(first)
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
            .labelStyle(.iconOnly)
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
        case let .online(kind): kind?.symbol ?? "sparkles.rectangle.stack"
        case .offline: "wifi.slash"
        }
    }
}
