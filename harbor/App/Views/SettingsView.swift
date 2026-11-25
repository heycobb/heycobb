import OwnholdKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnailBytes: Int64 = 0
    @State private var offlineBytes: Int64 = 0
    @State private var confirmRemove: ServerProfile?
    @State private var editing: ServerProfile?
    @State private var showingGuide = false
    #if os(macOS)
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    #endif

    var body: some View {
        @Bindable var model = model
        Form {
            AppearanceSection()

            Section {
                Toggle(Platform.isMac ? "Lock with Touch ID or Password" : "Lock with Face ID or Passcode", isOn: $model.requireUnlock)
                #if os(iOS)
                Toggle("Hide Files in App Switcher", isOn: $model.hideInSwitcher)
                #endif
                Toggle(Platform.isMac ? "Show NAS in Finder" : "Show NAS in Files App", isOn: $model.showInFilesApp)
                    .disabled(model.requireUnlock)
            } header: {
                Text("Privacy")
            } footer: {
                // Needed: otherwise the switch looks broken while it's disabled.
                if model.requireUnlock {
                    Text(Platform.isMac
                        ? "Off while the app lock is on, because Finder can't ask for Touch ID."
                        : "Off while the app lock is on, because the Files app can't ask for Face ID.")
                }
            }

            #if os(macOS)
            Section("Menu Bar") {
                Toggle("Show Ownhold in Menu Bar", isOn: $showMenuBarItem)
            }
            #endif

            Section("Storage") {
                LabeledContent("Offline Files", value: offlineBytes == 0 ? "None" : Format.bytes(offlineBytes))
                LabeledContent("Thumbnails", value: thumbnailBytes == 0 ? "None" : Format.bytes(thumbnailBytes))
                Button("Clear Thumbnails") {
                    Task {
                        await model.thumbnails?.removeAll()
                        await measure()
                    }
                }
            }

            if !model.servers.isEmpty {
                Section("Servers") {
                    ForEach(model.servers) { server in
                        Button { editing = server } label: {
                            LabeledContent(server.name) {
                                Text("Edit…").foregroundStyle(.secondary)
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
                        }
                    }
                }
            }

            Section("Help") {
                Button("Open Setup Guide") { showingGuide = true }
            }

            Section("About") {
                Link("Get Support", destination: URL(string: "https://ownhold.app/support")!)
                Link("Privacy Policy", destination: URL(string: "https://ownhold.app/privacy")!)
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("Ownhold is an independent app and isn't affiliated with or endorsed by Synology Inc. or Tailscale Inc.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        #endif
        .task { await measure() }
        .sheet(item: $editing) { server in ServerEditView(server: server) }
        .sheet(isPresented: $showingGuide) { SetupGuideView() }
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

    private func measure() async {
        thumbnailBytes = await model.thumbnails?.diskUsage() ?? 0
        offlineBytes = await model.offline?.totalBytes() ?? 0
    }
}
