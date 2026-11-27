import SwiftUI

/// Mac menu bar commands for the folder in the front window, as in Finder:
/// File › New Folder, New Encrypted Folder…, Upload Files…, Rename… and Delete…, and
/// View › Select Items. Rename and Delete act on the selected items
/// (View › Select Items, then click to select).
struct FolderMenuCommands: Commands {
    @FocusedValue(\.folderCommands) private var folder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { folder?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(folder?.canChange != true)
            Button("New Encrypted Folder…") { folder?.newEncryptedFolder() }
                .disabled(folder?.canNewEncryptedFolder != true)
            Button("Upload Files…") { folder?.uploadFiles() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(folder?.canChange != true)
            Divider()
            Button("Rename…") { folder?.rename() }
                .disabled(folder?.canRename != true)
            Button("Share Link…") { folder?.shareLink() }
                .disabled(folder?.canShareLink != true)
            Button("Compress") { folder?.compress() }
                .disabled(folder?.canDelete != true)
            Button("Encrypt into New Folder…") { folder?.encryptSelection() }
                .disabled(folder?.canEncryptSelection != true)
            Button("Extract Here") { folder?.extract() }
                .disabled(folder?.canExtract != true)
            Divider()
            Button("Delete…") { folder?.delete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(folder?.canDelete != true)
        }
        CommandGroup(after: .toolbar) {
            Button(folder?.isSelecting == true ? "Stop Selecting" : "Select Items") { folder?.toggleSelecting() }
                .disabled(folder == nil)
        }
    }
}
