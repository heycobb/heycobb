import OwnholdKit
import SwiftUI

/// Chooses a destination folder for Move. Shows folders only.
struct FolderPicker: View {
    let items: [RemoteItem]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FolderPickerLevel(folder: nil, items: items) { destination in
                dismiss()
                onPick(destination)
            }
            .navigationDestination(for: RemoteItem.self) { folder in
                FolderPickerLevel(folder: folder, items: items) { destination in
                    dismiss()
                    onPick(destination)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }
}

private struct FolderPickerLevel: View {
    /// nil = the list of shared folders.
    let folder: RemoteItem?
    let items: [RemoteItem]
    let onPick: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [RemoteItem] = []
    @State private var loading = true

    var body: some View {
        List(folders) { child in
            NavigationLink(value: child) {
                Label(child.name, systemImage: child.isShare ? "externaldrive" : "folder")
                    .labelStyle(PickerLabelStyle())
            }
            // A folder can't be moved into itself.
            .disabled(items.contains { $0.path == child.path })
        }
        .overlay {
            if loading {
                ProgressView()
            } else if folders.isEmpty {
                ContentUnavailableView("No Folders", systemImage: "folder")
            }
        }
        .navigationTitle(folder?.name ?? title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Move Here") { if let folder { onPick(folder.path) } }
                    .disabled(!canMoveHere)
            }
        }
        .task { await load() }
    }

    private var title: String {
        items.count == 1 ? "Move “\(items[0].name)”" : "Move \(items.count) Items"
    }

    /// Not the shares list, not where everything already is, and not inside
    /// a folder that's being moved.
    private var canMoveHere: Bool {
        guard let folder else { return false }
        if items.allSatisfy({ $0.parentPath == folder.path }) { return false }
        return !items.contains { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }
    }

    private func load() async {
        guard let service = model.service else { return }
        defer { loading = false }
        do {
            if let folder {
                folders = try await service.list(folder: folder.path, offset: 0, limit: 2000, sort: .name, ascending: true)
                    .items.filter(\.isDirectory)
            } else {
                folders = try await service.listShares()
            }
        } catch {
            model.handle(error)
        }
    }
}

private struct PickerLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            configuration.icon.foregroundStyle(Theme.accent)
            configuration.title
        }
    }
}
