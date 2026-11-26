#if os(macOS)
import AppKit
import OwnholdKit
import SwiftUI

/// The Ownhold menu bar item: connection status, uploads in progress, and
/// quick ways into your NAS. Everything here also exists in the main
/// window; this is a shortcut, not a second app.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var shares: [RemoteItem] = []

    var body: some View {
        if model.isLocked {
            // Locked: no names of files, folders or servers.
            Text("Ownhold Is Locked")
            Button("Unlock…") {
                showMainWindow()
                Task { await model.unlock() }
            }
            Divider()
            appItems
        } else {
            status
            uploads
            if model.service != nil {
                Divider()
                uploadMenu
                sharesMenu
            }
            offlineMenu
            serversMenu
            Divider()
            appItems
        }
    }

    // MARK: Sections

    @ViewBuilder private var status: some View {
        if let server = model.activeServer {
            Text(server.name)
            Text(statusLine)
            if model.connection == .offline {
                Button("Reconnect") { Task { await model.reconnect() } }
                if model.canWake {
                    Button(model.isWaking ? "Waking…" : "Wake NAS") { Task { await model.wakeNAS() } }
                        .disabled(model.isWaking)
                }
            }
        } else {
            Text("No NAS Added")
            Button("Add a NAS…") {
                showMainWindow()
                model.isAddingServer = true
            }
        }
    }

    private var statusLine: String {
        switch model.connection {
        case .idle: "Not signed in"
        case .connecting: "Connecting…"
        case let .online(endpoint): endpoint.map { "Connected via \($0.displayName)" } ?? "Demo library"
        case .offline: "Can't reach NAS. Offline files still work."
        }
    }

    @ViewBuilder private var uploads: some View {
        let queue = model.uploads
        if let progress = model.syncProgress, progress.kind == .folderBackup {
            Divider()
            Text(progress.fraction.map { "\(progress.title): \(progress.detail) (\(Int($0 * 100))%)" } ?? "\(progress.title)…")
        }
        if queue.isRunning {
            Divider()
            Text("Uploading \(queue.completed + 1) of \(queue.jobs.count { $0.state != .cancelled }) (\(Int(queue.fraction * 100))%)")
            Button("Cancel Uploads") { queue.cancelAll() }
        } else if queue.failed > 0 {
            Divider()
            Text(queue.failed == 1 ? "1 upload failed" : "\(queue.failed) uploads failed")
            Button("Retry Failed Uploads") { queue.retryFailed() }
        } else if queue.preparing > 0 {
            Divider()
            Text("Preparing uploads…")
        }
    }

    private var uploadMenu: some View {
        Menu("Upload To") {
            ForEach(shares) { share in
                Button(share.name) { upload(to: share) }
            }
        }
        .disabled(shares.isEmpty)
        .task(id: model.connection) { await loadShares() }
    }

    private var sharesMenu: some View {
        Menu("Open") {
            ForEach(shares) { share in
                Button(share.name) { show(.share(share)) }
            }
        }
        .disabled(shares.isEmpty)
    }

    @ViewBuilder private var offlineMenu: some View {
        if model.activeServer != nil {
            Menu("Offline Files") {
                if model.offlineEntries.isEmpty {
                    Text("Nothing saved for offline use")
                } else {
                    Section("Recently Saved") {
                        ForEach(model.offlineEntries.prefix(8)) { entry in
                            Button(entry.item.name) { open(entry) }
                        }
                    }
                    Divider()
                    Button("Show All Offline Files") { show(.offline) }
                }
            }
        }
    }

    @ViewBuilder private var serversMenu: some View {
        if model.servers.count > 1 {
            Menu("Switch NAS") {
                ForEach(model.servers) { server in
                    Toggle(server.name, isOn: Binding(
                        get: { server.id == model.activeServer?.id },
                        set: { on in if on { Task { await model.activate(server) } } }
                    ))
                }
            }
        }
    }

    @ViewBuilder private var appItems: some View {
        Button("Open Ownhold") { showMainWindow() }
        Button("Settings…") {
            DockIcon.show()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Ownhold") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: Actions

    private func showMainWindow() {
        DockIcon.show()
        openWindow(id: OwnholdApp.mainWindowID)
    }

    private func show(_ target: SidebarItem) {
        model.navigationRequest = target
        showMainWindow()
    }

    /// Picks files or folders, then queues them for the share. Name clashes
    /// keep both copies, since there's no window here to ask in.
    private func upload(to share: RemoteItem) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Upload to \(share.name)"
        panel.prompt = "Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let pending = panel.urls.map { PendingUpload(url: $0, name: $0.lastPathComponent, ownsFile: false) }
        Task {
            let existing = (try? await model.service?.list(folder: share.path, offset: 0, limit: 5000, sort: .name, ascending: true))?
                .items.map(\.name) ?? []
            model.uploads.add(pending, to: share.path, existing: Set(existing), onConflict: .keepBoth)
        }
    }

    /// Opens a copy in its default app, so the offline copy itself stays
    /// exactly as it was downloaded.
    private func open(_ entry: OfflineEntry) {
        Task {
            guard let url = await model.offline?.localURL(for: entry.item.path) else { return }
            let folder = PreviewFiles.directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let copy = folder.appending(path: entry.item.name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
                NSWorkspace.shared.open(copy)
            } catch {
                model.banner = "Couldn't open \(entry.item.name)."
            }
        }
    }

    private func loadShares() async {
        shares = (try? await model.service?.listShares()) ?? []
    }
}
#endif
