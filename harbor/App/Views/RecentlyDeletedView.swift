import ArkenalKit
import SwiftUI

/// Recently Deleted: each shared folder's DSM Recycle Bin, browsable like a
/// folder, with Restore and Delete Permanently.
struct RecentlyDeletedView: View {
    let bins: [AppModel.RecycleBinFolder]

    var body: some View {
        OwnList {
            ForEach(bins) { bin in
                NavigationLink {
                    RecycleFolderView(path: bin.path, title: bin.title)
                } label: {
                    Label(bin.title, systemImage: "externaldrive")
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .overlay {
            if bins.isEmpty {
                ContentUnavailableView("Nothing Deleted", systemImage: "trash")
            }
        }
    }
}

/// One folder inside a Recycle Bin.
private struct RecycleFolderView: View {
    let path: String
    let title: String

    @Environment(AppModel.self) private var model
    @State private var items: [RemoteItem]?
    @State private var confirmDelete: RemoteItem?

    var body: some View {
        OwnList {
            ForEach(items ?? []) { item in
                row(item)
                    .contextMenu { actions(item) }
                    .swipeActions {
                        Button("Delete", role: .destructive) { confirmDelete = item }.tint(.red)
                        Button("Restore") { Task { await restore(item) } }.tint(Theme.accent)
                    }
            }
        }
        .navigationTitle(title)
        .overlay {
            if items == nil {
                DelayedProgressView()
            } else if items?.isEmpty == true {
                ContentUnavailableView("Nothing Deleted", systemImage: "trash")
            }
        }
        .task(id: model.revision(of: path)) { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Delete \(confirmDelete?.name ?? "item") permanently?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let item = confirmDelete { Task { _ = await model.delete([item]); await load() } }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func row(_ item: RemoteItem) -> some View {
        HStack {
            if item.isDirectory {
                NavigationLink {
                    RecycleFolderView(path: item.path, title: item.name)
                } label: {
                    ItemRow(item: item, saved: false, busy: false)
                }
            } else {
                ItemRow(item: item, saved: false, busy: false)
            }
            // Visible, not only in the menu: restoring is why you're here.
            Button("Restore") { Task { await restore(item) } }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder private func actions(_ item: RemoteItem) -> some View {
        Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore(item) } }
        Button("Delete Permanently…", systemImage: "trash", role: .destructive) { confirmDelete = item }
    }

    private func restore(_ item: RemoteItem) async {
        if await model.restore(item) { await load() }
    }

    private func load() async {
        guard let service = model.service else { return }
        items = (try? await service.list(folder: path, offset: 0, limit: 5000, sort: .name, ascending: true).items) ?? []
    }
}
