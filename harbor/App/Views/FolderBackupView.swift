#if os(macOS)
import AppKit
import ArkenalKit
import SwiftUI

/// Folder Backup (Mac): which folders, where they go, Back Up Now, and the
/// optional backup when files change.
struct FolderBackupView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingDestination = false

    var body: some View {
        @Bindable var backup = model.folderBackup
        OwnForm {
            Section {
                status
                if backup.isRunning {
                    Button("Stop", role: .destructive) { backup.cancel() }
                } else {
                    Button("Back Up Now") { backup.backUpNow() }
                        .disabled(!backup.isReady || model.service == nil)
                }
            }

            Section("Folders") {
                ForEach(Array(zip(backup.settings.sources, backup.folderNames)), id: \.0.id) { source, _ in
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text(source.path)
                                    .font(.path)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { backup.remove(source) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Stop backing up \(source.name)")
                    }
                }
                Button("Add Folder…") { addFolders() }
            }
            .disabled(backup.isRunning)

            Section("Back Up To") {
                Button {
                    choosingDestination = true
                } label: {
                    LabeledContent("Folder") {
                        Text(backup.settings.destination.map { ($0 as NSString).lastPathComponent } ?? "Choose…")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.service == nil || backup.isRunning)
                if let destination = backup.settings.destination {
                    Text(destination)
                        .font(.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section {
                Toggle("Back Up When Files Change", isOn: $backup.settings.automatic)
            } footer: {
                // The one rule people need to know before trusting it.
                Text("Files are only added or updated on the NAS. Deleting a file on this Mac doesn't delete its backup.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Folder Backup")
        .sheet(isPresented: $choosingDestination) {
            FolderPicker(items: [], title: "Back Up To", actionTitle: "Choose") { path in backup.setDestination(path) }
        }
        .task(id: backup.settings) { await backup.check() }
    }

    @ViewBuilder private var status: some View {
        let backup = model.folderBackup
        switch backup.phase {
        case .scanning:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking your folders…").padding(.leading, Theme.Spacing.s)
            }
        case let .uploading(done, total, current):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done + 1) of \(total): \(current)")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        default:
            LabeledContent("Status", value: summary)
        }
    }

    private var summary: String {
        let backup = model.folderBackup
        if backup.settings.sources.isEmpty { return "Add a folder" }
        if backup.settings.destination == nil { return "Choose where to back up" }
        if let wait = backup.networkWait { return wait }
        if let waiting = backup.waiting, waiting > 0 { return waiting == 1 ? "1 file to back up" : "\(waiting) files to back up" }
        if let last = backup.settings.lastBackup { return "Backed up \(last.formatted(.relative(presentation: .named)))" }
        return backup.waiting == 0 ? "Up to date" : "Not backed up yet"
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.title = "Back Up Folders"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        model.folderBackup.add(panel.urls)
    }
}
#endif
