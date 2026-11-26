import OwnholdKit
import SwiftUI

/// Recently Deleted: each shared folder's DSM Recycle Bin, browsable like a
/// folder, with Restore and Delete Permanently.
struct RecentlyDeletedView: View {
    let bins: [RemoteItem]

    var body: some View {
        List {
            ForEach(bins) { share in
                NavigationLink {
                    RecycleFolderView(path: RecycleBin.folder(forShare: share.path), title: share.name)
                } label: {
                    Label(share.name, systemImage: "externaldrive")
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
        List {
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
                ProgressView()
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

    @ViewBuilder private func row(_ item: RemoteItem) -> some View {
        if item.isDirectory {
            NavigationLink {
                RecycleFolderView(path: item.path, title: item.name)
            } label: {
                ItemRow(item: item, saved: false, busy: false)
            }
        } else {
            ItemRow(item: item, saved: false, busy: false)
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
