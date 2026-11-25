import SwiftUI

/// Mac menu bar commands for the folder in the front window, as in Finder:
/// File › New Folder and Upload Files…, Edit › Rename… and Delete…,
/// View › Select Items. Rename and Delete act on the selected items
/// (View › Select Items, then click to select).
struct FolderMenuCommands: Commands {
    @FocusedValue(\.folderCommands) private var folder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { folder?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(folder?.canChange != true)
            Button("Upload Files…") { folder?.uploadFiles() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(folder?.canChange != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename…") { folder?.rename?() }
                .disabled(folder?.rename == nil)
            Button("Delete…") { folder?.delete?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(folder?.delete == nil)
        }
        CommandGroup(after: .toolbar) {
            Button(folder?.isSelecting == true ? "Stop Selecting" : "Select Items") { folder?.toggleSelecting() }
                .disabled(folder == nil)
        }
    }
}
