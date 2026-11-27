import OwnholdKit
import UniformTypeIdentifiers
import SwiftUI

/// Passwords for encrypted folders: at least this long. Longer is better;
/// the footer says so without nagging.
private let minimumPasswordLength = 8

// MARK: - New encrypted folder

/// Makes an encrypted folder, optionally moves chosen items into it
/// (encrypting them), then shows its recovery key once.
struct NewEncryptedFolderView: View {
    let parent: String
    /// Items to encrypt into the new folder.
    var moving: [RemoteItem] = []
    var suggestedName = ""
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var created: (name: String, recoveryKey: String)?
    @State private var progress: String?
    @State private var moveNote: String?

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    RecoveryKeyView(folderName: created.name, recoveryKey: created.recoveryKey, note: moveNote) { dismiss() }
                } else if let progress {
                    VStack(spacing: Theme.Spacing.m) {
                        ProgressView()
                        Text(progress).foregroundStyle(.secondary)
                        Text("Keep Ownhold open until this finishes.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .padding()
                } else {
                    form
                }
            }
            .navigationTitle(created != nil ? "Recovery Key" : title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .tint(Theme.accent)
        .interactiveDismissDisabled(created != nil || working)
        .onAppear { if name.isEmpty { name = suggestedName } }
        #if os(macOS)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private var title: String {
        switch moving.count {
        case 0: "New Encrypted Folder"
        case 1: "Encrypt “\(moving[0].name)”"
        default: "Encrypt \(moving.count) Items"
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var canCreate: Bool {
        RemoteItem.isValidName(trimmedName) && password.count >= minimumPasswordLength && password == confirm && !working
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }
            Section {
                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                SecureField("Confirm Password", text: $confirm)
                    .textContentType(.newPassword)
            } footer: {
                Text(passwordFooter)
            }
            if !moving.isEmpty {
                Section {
                    Label(moving.count == 1
                          ? "“\(moving[0].name)” is encrypted and moved into the new folder. The original is deleted once it's safely copied."
                          : "The \(moving.count) items are encrypted and moved into the new folder. Each original is deleted once it's safely copied.",
                          systemImage: "arrow.down.doc")
                }
                .font(.callout)
            }
            Section {
                Label("Files are encrypted on this device before they're uploaded. Your NAS, and anyone who gets its drives, sees only scrambled data.", systemImage: "lock")
                Label("If you forget the password and lose the recovery key, no one can open these files, including Ownhold.", systemImage: "exclamationmark.triangle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .disabled(working)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if working {
                    ProgressView()
                } else {
                    Button("Create") { Task { await create() } }
                        .disabled(!canCreate)
                }
            }
        }
    }

    private var passwordFooter: String {
        if !confirm.isEmpty, password != confirm { return "The passwords don't match." }
        if !password.isEmpty, password.count < minimumPasswordLength { return "Use at least \(minimumPasswordLength) characters." }
        return "A few unrelated words make a strong password that's easy to remember."
    }

    private func create() async {
        working = true
        defer { working = false }
        error = nil
        do {
            let result = try await model.createEncryptedFolder(named: trimmedName, in: parent, password: password)
            password = ""
            confirm = ""
            if !moving.isEmpty {
                progress = moving.count == 1 ? "Encrypting “\(moving[0].name)”…" : "Encrypting \(moving.count) items…"
                let moved = await model.move(moving, to: result.folder.path)
                progress = nil
                if !moved {
                    moveNote = "Some items couldn't be moved in. They're still where they were; you can move them into “\(result.folder.name)” later."
                }
            }
            created = (result.folder.name, result.recoveryKey)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Recovery key

/// Shown once, when a folder is made. Nothing else can unlock the folder if
/// the password is forgotten, so Done waits until the user says it's saved.
struct RecoveryKeyView: View {
    let folderName: String
    let recoveryKey: String
    var note: String?
    let onDone: () -> Void
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        Form {
            if let note {
                Section {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text(recoveryKey)
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, Theme.Spacing.s)
                    .accessibilityLabel("Recovery key")
                    .accessibilityValue(recoveryKey.map(String.init).joined(separator: " "))
            } header: {
                Text("“\(folderName)”")
            } footer: {
                Text("If you forget the password, this key is the only way to open the folder. Write it down or keep it in your password manager. It isn't stored anywhere else, and Ownhold won't show it again.")
            }
            Section {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Pasteboard.copySecret(recoveryKey)
                    copied = true
                }
                ShareLink(item: "Ownhold recovery key for “\(folderName)”: \(recoveryKey)") {
                    Label("Save or Print…", systemImage: "square.and.arrow.up")
                }
            }
            Section {
                Toggle("I've saved the recovery key", isOn: $saved)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone).disabled(!saved)
            }
        }
    }
}

// MARK: - Unlock

/// Fills a locked encrypted folder's screen.
struct UnlockFolderView: View {
    let root: String
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var remember = false
    @State private var working = false
    @State private var error: String?
    @State private var recovering = false
    @FocusState private var focused: Bool

    private var name: String { (root as NSString).lastPathComponent }

    var body: some View {
        Form {
            Section {
                VStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                    Text("“\(name)” is encrypted")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.s)
            }
            Section {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused)
                    .onSubmit { Task { await unlock() } }
                Toggle("Keep Unlocked on This Device", isOn: $remember)
            } footer: {
                Text(remember
                     ? "The folder's key is kept in this device's Keychain, so it opens without the password, also in \(Platform.isMac ? "Finder" : "the Files app"). Lock it to stop."
                     : "It locks again when Ownhold quits\(model.requireUnlock ? " or locks" : "").")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button(working ? "Unlocking…" : "Unlock") { Task { await unlock() } }
                    .disabled(password.isEmpty || working)
                    .keyboardShortcut(.defaultAction)
                Button("Forgot Password?") { recovering = true }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
        .sheet(isPresented: $recovering) {
            RecoverFolderView(root: root)
        }
    }

    private func unlock() async {
        guard !password.isEmpty, !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            try await model.unlockFolder(root, password: password, remember: remember)
            password = ""
        } catch {
            self.error = error.localizedDescription
            password = ""
            focused = true
        }
    }
}

/// Unlocks with the recovery key, then sets a new password.
struct RecoverFolderView: View {
    let root: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKey = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-…", text: $recoveryKey, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                } header: {
                    Text("Recovery Key")
                } footer: {
                    Text("The key shown when the folder was made.")
                }
                Section {
                    SecureField("New Password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm Password", text: $confirm)
                        .textContentType(.newPassword)
                } footer: {
                    if !confirm.isEmpty, password != confirm {
                        Text("The passwords don't match.")
                    } else {
                        Text("Use at least \(minimumPasswordLength) characters. The recovery key keeps working.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            .navigationTitle("Forgot Password")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") { Task { await recover() } }
                        .disabled(recoveryKey.isEmpty || password.count < minimumPasswordLength || password != confirm || working)
                }
            }
        }
        .tint(Theme.accent)
        #if os(macOS)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private func recover() async {
        working = true
        defer { working = false }
        error = nil
        do {
            try await model.recoverFolder(root, recoveryKey: recoveryKey, newPassword: password, remember: false)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Settings › Change Password for an unlocked encrypted folder.
struct ChangeFolderPasswordView: View {
    let root: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New Password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm Password", text: $confirm)
                        .textContentType(.newPassword)
                } footer: {
                    if !confirm.isEmpty, password != confirm {
                        Text("The passwords don't match.")
                    } else {
                        Text("Files aren't re-encrypted, so this is instant. Other devices need the new password next time they unlock. The recovery key doesn't change.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            .navigationTitle("Change Password")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") { Task { await change() } }
                        .disabled(password.count < minimumPasswordLength || password != confirm || working)
                }
            }
        }
        .tint(Theme.accent)
        #if os(macOS)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private func change() async {
        working = true
        defer { working = false }
        do {
            try await model.changeFolderPassword(root, to: password)
            model.banner = "Password changed."
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension Pasteboard {
    /// Copies something sensitive: on iPhone and iPad it stays on this
    /// device (no Universal Clipboard) and clears after two minutes.
    static func copySecret(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UTType.plainText.identifier: string]],
                                      options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)])
        #else
        copy(string)
        #endif
    }
}
