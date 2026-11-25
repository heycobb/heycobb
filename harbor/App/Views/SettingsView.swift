import HarborKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnailBytes: Int64 = 0
    @State private var offlineBytes: Int64 = 0
    @State private var confirmRemove: ServerProfile?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(Platform.isMac ? "Require Touch ID or Password" : "Require Face ID or Passcode", isOn: $model.requireUnlock)
                #if os(iOS)
                Toggle("Hide Content in App Switcher", isOn: $model.hideInSwitcher)
                #endif
            } header: {
                Text("Privacy")
            } footer: {
                Text("Harbor never collects analytics or sends data anywhere except your NAS.")
            }

            Section("Storage on This Device") {
                LabeledContent("Offline files", value: offlineBytes == 0 ? "None" : Format.bytes(offlineBytes))
                LabeledContent("Thumbnail cache", value: thumbnailBytes == 0 ? "None" : Format.bytes(thumbnailBytes))
                Button("Clear Thumbnail Cache") {
                    Task {
                        await model.thumbnails?.removeAll()
                        await measure()
                    }
                }
            }

            if !model.servers.isEmpty {
                Section("Servers") {
                    ForEach(model.servers) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.endpoints.map { $0.url.host() ?? "" }.joined(separator: "  ·  "))
                                .font(.path)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { confirmRemove = server }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { confirmRemove = server }
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("Harbor is an independent app and isn't affiliated with or endorsed by Synology Inc. or Tailscale Inc.")
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
