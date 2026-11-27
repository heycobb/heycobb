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
        OwnForm {
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
        let moved = moving.isEmpty ? "" : " The originals are deleted once they're copied in."
        return "If you forget the password and lose the recovery key, the files can't be recovered.\(moved)"
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
        OwnForm {
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
                Text("The only way in if you forget the password. It won't be shown again.")
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

/// The three ways a folder can open next time, as people read them.
extension VaultUnlockMode {
    static var available: [VaultUnlockMode] {
        VaultBiometrics.isAvailable ? [.password, .biometric, .keepUnlocked] : [.password, .keepUnlocked]
    }

    var title: String {
        switch self {
        case .password: "Ask for Password"
        case .biometric: "Use \(VaultBiometrics.biometryName ?? "Device Passcode")"
        case .keepUnlocked: "Keep Unlocked"
        }
    }

    /// What it means, for a footer.
    var explanation: String {
        let away = "Locks when you quit Ownhold or after \(Int(AppModel.vaultLockDelay / 60)) minutes away."
        switch self {
        case .password:
            return away
        case .biometric:
            let name = VaultBiometrics.biometryName.map { "\($0) or your passcode" } ?? "your passcode"
            return "\(away) Opens with \(name)."
        case .keepUnlocked:
            return "Opens without asking, also in \(Platform.isMac ? "Finder" : "the Files app"). Anyone using this device can open it."
        }
    }

    var symbol: String {
        switch self {
        case .password: "key"
        case .biometric:
            switch VaultBiometrics.biometryName {
            case "Face ID": "faceid"
            case "Touch ID": "touchid"
            case "Optic ID": "opticid"
            default: "lock"
            }
        case .keepUnlocked: "lock.open"
        }
    }
}

/// Fills a locked encrypted folder's screen.
struct UnlockFolderView: View {
    let root: String
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var nextTime: VaultUnlockMode = .password
    @State private var working = false
    @State private var error: String?
    @State private var recovering = false
    @State private var triedBiometrics = false
    @FocusState private var focused: Bool

    private var name: String { (root as NSString).lastPathComponent }
    private var usesBiometrics: Bool { model.unlockMode(of: root) == .biometric && VaultBiometrics.isAvailable }

    var body: some View {
        OwnForm {
            if usesBiometrics {
                Section {
                    Button {
                        Task { await unlockWithBiometrics() }
                    } label: {
                        Label("Unlock with \(VaultBiometrics.biometryName ?? "Passcode")", systemImage: VaultUnlockMode.biometric.symbol)
                    }
                    .disabled(working)
                } header: {
                    Label("Encrypted Folder", systemImage: "lock.fill")
                }
            }
            Section {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused)
                    .onSubmit { Task { await unlock() } }
                Picker("Next Time", selection: $nextTime) {
                    ForEach(VaultUnlockMode.available, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                if !usesBiometrics { Label("Encrypted Folder", systemImage: "lock.fill") }
            } footer: {
                Text(nextTime.explanation)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button(working ? "Unlocking…" : "Unlock") { Task { await unlock() } }
                    .disabled(password.isEmpty || working)
                Button("Forgot Password?") { recovering = true }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .onAppear {
            nextTime = model.unlockMode(of: root) == .keepUnlocked ? .password : model.unlockMode(of: root)
            if !VaultBiometrics.isAvailable, nextTime == .biometric { nextTime = .password }
        }
        .task(id: root) {
            // Face ID right away, once; the password stays as the fallback.
            guard usesBiometrics, !triedBiometrics, !model.lockedByHand.contains(root) else {
                focused = true
                return
            }
            triedBiometrics = true
            await unlockWithBiometrics()
        }
        .sheet(isPresented: $recovering) {
            RecoverFolderView(root: root)
        }
    }

    private func unlockWithBiometrics() async {
        guard !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            try await model.unlockWithBiometrics(root)
        } catch VaultError.biometryCanceled {
            focused = true
        } catch {
            self.error = error.localizedDescription
            nextTime = .biometric
            focused = true
        }
    }

    private func unlock() async {
        guard !password.isEmpty, !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            try await model.unlockFolder(root, password: password, mode: nextTime)
            password = ""
        } catch {
            self.error = error.localizedDescription
            password = ""
            focused = true
        }
    }
}

/// "Next Time" in an unlocked folder's lock menu.
struct UnlockModePicker: View {
    let root: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Next Time", selection: Binding(
            get: { model.unlockMode(of: root) },
            set: { model.setUnlockMode($0, for: root) }
        )) {
            ForEach(VaultUnlockMode.available, id: \.self) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.menu)
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
            OwnForm {
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
                    Text("The key shown when the folder was created.")
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
                        Text("Use at least \(minimumPasswordLength) characters.")
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
            try await model.recoverFolder(root, recoveryKey: recoveryKey, newPassword: password)
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
            OwnForm {
                Section {
                    SecureField("New Password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm Password", text: $confirm)
                        .textContentType(.newPassword)
                } footer: {
                    if !confirm.isEmpty, password != confirm {
                        Text("The passwords don't match.")
                    } else {
                        Text("Other devices will need the new password. The recovery key stays the same.")
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
