import ArkenalKit
import Photos
import SwiftUI

/// Photo Backup: where photos go, what's included, Back Up Now, and the
/// optional automatic backup.
struct BackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var choosingFolder = false

    private var backup: PhotoBackup { model.backup }

    var body: some View {
        @Bindable var backup = model.backup
        OwnForm {
            statusSection

            Section("Back Up To") {
                Button {
                    choosingFolder = true
                } label: {
                    LabeledContent("Folder") {
                        Text(backup.settings.destination.map { ($0 as NSString).lastPathComponent } ?? "Choose…")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.service == nil || backup.isRunning)
                if let destination = backup.settings.destination {
                    Text(destination + "/Year/Month")
                        .font(.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Section("Include") {
                Toggle("Videos", isOn: $backup.settings.includeVideos)
                Toggle("Live Photo Videos", isOn: $backup.settings.includeLivePhotoVideos)
                Picker("Photos", selection: Binding(
                    get: { backup.settings.since == nil },
                    set: { all in backup.settings.since = all ? nil : .now }
                )) {
                    Text("All").tag(true)
                    Text("New Only").tag(false)
                }
            }
            .disabled(backup.isRunning)

            Section {
                // Automatic backup is part of Arkenal Pro; Back Up Now is free.
                Toggle(isOn: Binding(
                    get: { backup.settings.automatic && ProStore.shared.isUnlocked },
                    set: { on in
                        if on, !ProStore.shared.isUnlocked { model.showingPro = true } else { backup.settings.automatic = on }
                    }
                )) {
                    Label {
                        Text("Back Up Automatically")
                    } icon: {
                        if !ProStore.shared.isUnlocked { Image(systemName: "lock").foregroundStyle(.secondary) }
                    }
                }
                #if os(iOS)
                if backup.settings.automatic {
                    Toggle("Only While Charging", isOn: $backup.settings.chargingOnly)
                }
                #endif
            } footer: {
                if backup.settings.automatic {
                    #if os(iOS)
                    Text("Runs when you open Arkenal and in the background, except in Low Power Mode.")
                    #else
                    Text("Runs while Arkenal is open, as new photos arrive, except in Low Power Mode.")
                    #endif
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Photo Backup")
        .sheet(isPresented: $choosingFolder) {
            FolderPicker(items: [], title: "Back Up To", actionTitle: "Choose") { path in backup.setDestination(path) }
        }
        .task(id: backup.settings.destination) { await backup.check() }
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            switch backup.access {
            case .notDetermined:
                Button("Allow Access to Photos") { Task { await backup.requestAccess(); await backup.check() } }
            case .denied, .restricted:
                Button(Platform.isMac ? "Allow Access in System Settings…" : "Allow Access in Settings") {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    #else
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { openURL(url) }
                    #endif
                }
            default:
                status
                if backup.isRunning {
                    Button("Stop", role: .destructive) { backup.cancel() }
                } else {
                    Button("Back Up Now") { backup.backUpNow() }
                        .disabled(!backup.isReady || model.service == nil)
                }
            }
        } footer: {
            if backup.access == .limited {
                Text("Only the photos you selected are backed up. Allow full access in Settings to include everything.")
            } else if Platform.isMac {
                // Needed: on a Mac this is the question people ask first.
                Text("Photos already backed up from an iPhone on the same iCloud library are skipped.")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch backup.phase {
        case .scanning:
            HStack {
                ProgressView()
                Text("Checking your library…").padding(.leading, Theme.Spacing.s)
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
        if backup.settings.destination == nil { return "Choose a folder" }
        if let wait = backup.networkWait { return wait }
        if let waiting = backup.waiting, waiting > 0 { return waiting == 1 ? "1 item to back up" : "\(waiting) items to back up" }
        if let last = backup.settings.lastBackup { return "Backed up \(last.formatted(.relative(presentation: .named)))" }
        return backup.waiting == 0 ? "Up to date" : "Not backed up yet"
    }
}
