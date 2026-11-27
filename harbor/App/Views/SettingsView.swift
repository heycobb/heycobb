import OwnholdKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var thumbnailBytes: Int64 = 0
    @State private var offlineBytes: Int64 = 0
    @State private var confirmRemove: ServerProfile?
    @State private var editing: ServerProfile?
    @State private var showingGuide = false
    @State private var showingPro = false
    @State private var showingAcknowledgements = false
    @AppStorage(PlaybackPositions.settingKey) private var rememberPosition = true
    @AppStorage(SyncIndicator.liveActivityKey) private var showLiveActivity = true
    @AppStorage(AppModel.filesAppChecksKey) private var keepFilesAppUpdated = true
    @AppStorage(NetworkPolicy.Use.backups.key) private var cellularBackups = NetworkPolicy.Use.backups.allowedByDefault
    @AppStorage(NetworkPolicy.Use.largeUploads.key) private var cellularLargeUploads = NetworkPolicy.Use.largeUploads.allowedByDefault
    @AppStorage(NetworkPolicy.Use.keptDownloads.key) private var cellularKeptDownloads = NetworkPolicy.Use.keptDownloads.allowedByDefault
    #if os(macOS)
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("hideDockWhenClosed") private var hideDockWhenClosed = true
    @Bindable private var loginItem = LoginItem.shared
    #endif

    var body: some View {
        content
            .task { await measure() }
            .sheet(item: $editing) { server in ServerEditView(server: server) }
            .sheet(isPresented: $showingGuide) { SetupGuideView() }
            .sheet(isPresented: $showingPro) { ProView() }
            .sheet(isPresented: $showingAcknowledgements) { AcknowledgementsView() }
            .confirmationDialog(
                "Remove \(confirmRemove?.name ?? "server")?",
                isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove Server and Offline Files", role: .destructive) {
                    if let server = confirmRemove { Task { await model.remove(server); await measure() } }
                }
            } message: {
                Text("Files on the NAS aren't affected.")
            }
    }

    /// Mac: tabs, like other Mac apps' Settings. iPhone and iPad: one list,
    /// with your NAS first.
    @ViewBuilder private var content: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                OwnForm {
                    proSection
                    startupSection
                    menuBarSection
                    browsingSection
                    securitySection
                }
                .formStyle(.grouped)
            }
            Tab("Appearance", systemImage: "paintpalette") {
                OwnForm { AppearanceSection() }.formStyle(.grouped)
            }
            Tab("NAS", systemImage: "externaldrive") {
                OwnForm {
                    serversSection
                    filesAppSection
                    cellularSection
                    storageSection
                }
                .formStyle(.grouped)
            }
            Tab("About", systemImage: "info.circle") {
                OwnForm { aboutSection }.formStyle(.grouped)
            }
        }
        #else
        OwnForm {
            proSection
            serversSection
            AppearanceSection()
            securitySection
            filesAppSection
            lockScreenSection
            cellularSection
            browsingSection
            storageSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        #endif
    }

    // MARK: Sections

    private var proSection: some View {
        Section {
            Button { showingPro = true } label: {
                LabeledContent {
                    Text(ProStore.shared.isUnlocked ? "Unlocked" : (ProStore.shared.product?.displayPrice ?? ""))
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Ownhold Pro", systemImage: ProStore.shared.isUnlocked ? "checkmark.seal.fill" : "seal")
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var serversSection: some View {
        Section("Your NAS") {
            ForEach(model.servers) { server in
                Button { editing = server } label: {
                    LabeledContent {
                        Text("Edit…").foregroundStyle(.secondary)
                    } label: {
                        Text(server.name)
                        Text(server.account).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(server.name)")
                .contextMenu {
                    Button("Edit", systemImage: "pencil") { editing = server }
                    Button("Remove", systemImage: "trash", role: .destructive) { confirmRemove = server }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { confirmRemove = server }
                        // Red, as a delete: the app's accent tint would otherwise win.
                        .tint(.red)
                }
            }
            Button("Add a NAS…") { addServer() }
        }
    }

    private var securitySection: some View {
        @Bindable var model = model
        return Section("Security") {
            Toggle(Platform.isMac ? "Lock with Touch ID or Password" : "Lock with Face ID or Passcode", isOn: $model.requireUnlock)
            #if os(iOS)
            Toggle("Hide Files in App Switcher", isOn: $model.hideInSwitcher)
            #endif
        }
    }

    private var filesAppSection: some View {
        @Bindable var model = model
        return Section {
            Toggle(Platform.isMac ? "Show NAS in Finder" : "Show NAS in Files App", isOn: $model.showInFilesApp)
                .disabled(model.requireUnlock)
            if model.showInFilesApp, !model.requireUnlock {
                // Part of Ownhold Pro.
                Toggle(isOn: Binding(
                    get: { keepFilesAppUpdated && ProStore.shared.isUnlocked },
                    set: { on in if on, !ProStore.shared.isUnlocked { showingPro = true } else { keepFilesAppUpdated = on } }
                )) {
                    Label {
                        Text(Platform.isMac ? "Keep Finder Up to Date" : "Keep Files App Up to Date")
                    } icon: {
                        if !ProStore.shared.isUnlocked { Image(systemName: "lock").foregroundStyle(.secondary) }
                    }
                }
            }
        } header: {
            Text(Platform.isMac ? "Finder" : "Files App")
        } footer: {
            // Needed: otherwise the switch looks broken while it's disabled.
            if model.requireUnlock {
                Text(Platform.isMac
                    ? "Unavailable while the app lock is on: Finder can't ask for Touch ID."
                    : "Unavailable while the app lock is on: the Files app can't ask for Face ID.")
            } else if !Platform.isMac, !model.showInFilesApp {
                // iOS keeps an empty Ownhold entry in Files that apps can't remove.
                Text("Ownhold stays listed in Files, empty. To hide it, tap ⋯ › Edit there.")
            }
        }
    }

    /// What may use cellular data (on a Mac: a Personal Hotspot). Things
    /// you open yourself always work; this covers automatic and large work.
    private var cellularSection: some View {
        Section {
            Toggle(Platform.isMac ? "Backups" : "Photo Backup", isOn: $cellularBackups)
            Toggle("Large Uploads", isOn: $cellularLargeUploads)
            #if os(macOS)
            Toggle("Keep Downloaded", isOn: $cellularKeptDownloads)
            #endif
        } header: {
            Text(Platform.isMac ? "Personal Hotspot" : "Cellular Data")
        } footer: {
            // Needed: Low Data Mode overrides these, and that isn't visible here.
            Text("Low Data Mode pauses automatic backups and downloads.")
        }
    }

    #if os(iOS)
    /// The Live Activity for long backups and uploads.
    private var lockScreenSection: some View {
        Section("Lock Screen") {
            Toggle("Show Backup and Upload Progress", isOn: $showLiveActivity)
                .onChange(of: showLiveActivity) { SyncIndicator.shared.settingChanged(showLiveActivity) }
        }
    }
    #endif

    private var browsingSection: some View {
        @Bindable var model = model
        return Section("Browsing") {
            // Off also clears the list; it never touches the files themselves.
            Toggle("Show Recents", isOn: $model.keepRecents)
            Toggle("Remember Playback Position", isOn: $rememberPosition)
                .onChange(of: rememberPosition) { if !rememberPosition { PlaybackPositions.removeAll() } }
        }
    }

    private var storageSection: some View {
        Section("Storage on This \(Platform.isMac ? "Mac" : "Device")") {
            LabeledContent("Offline Files", value: offlineBytes == 0 ? "None" : Format.bytes(offlineBytes))
            LabeledContent("Thumbnails", value: thumbnailBytes == 0 ? "None" : Format.bytes(thumbnailBytes))
            Button("Clear Thumbnails") {
                Task {
                    await model.thumbnails?.removeAll()
                    await measure()
                }
            }
            .disabled(thumbnailBytes == 0)
        }
    }

    private var aboutSection: some View {
        Section {
            Button("Setup Guide") { showingGuide = true }
                #if os(macOS)
                .buttonStyle(.link) // matches the links below
                #endif
            Link("Get Support", destination: URL(string: "https://ownhold.app/support")!)
            Link("Privacy Policy", destination: URL(string: "https://ownhold.app/privacy")!)
            Button("Acknowledgements") { showingAcknowledgements = true }
                #if os(macOS)
                .buttonStyle(.link)
                #endif
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
        } header: {
            // The Mac's tab already says About.
            if !Platform.isMac { Text("About") }
        } footer: {
            Text("Ownhold is an independent app and isn't affiliated with or endorsed by Synology Inc. or Tailscale Inc.")
        }
    }

    #if os(macOS)
    private var startupSection: some View {
        Section {
            Toggle("Open at Login", isOn: $loginItem.isOn)
            if loginItem.needsApproval {
                Button("Allow in System Settings…") { loginItem.openSystemSettings() }
            }
        } header: {
            Text("Startup")
        } footer: {
            // Needed: the switch is on but macOS won't open Ownhold until it's allowed.
            if loginItem.needsApproval {
                Text("Allow Ownhold in Login Items so macOS can open it.")
            }
        }
        .onAppear { loginItem.refresh() }
    }

    private var menuBarSection: some View {
        Section("Menu Bar") {
            Toggle("Show Ownhold in Menu Bar", isOn: $showMenuBarItem)
            if showMenuBarItem {
                Toggle("Hide Dock Icon When Closed", isOn: $hideDockWhenClosed)
            }
        }
    }
    #endif

    /// Add a NAS opens over the main window (on the Mac, bringing it forward).
    private func addServer() {
        #if os(macOS)
        DockIcon.show()
        openWindow(id: OwnholdApp.mainWindowID)
        #else
        dismiss()
        #endif
        model.isAddingServer = true
    }

    private func measure() async {
        thumbnailBytes = await model.thumbnails?.diskUsage() ?? 0
        offlineBytes = await model.offline?.totalBytes() ?? 0
    }
}
