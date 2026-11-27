import Foundation
import OwnholdKit

/// Encrypted folders: files encrypted on this device before they reach the
/// NAS. The work happens in OwnholdKit's VaultFileService, which wraps the
/// NAS connection; this is what the screens call.
extension AppModel {
    var vaultService: VaultFileService? { service as? VaultFileService }

    func makeVaultState(for profile: ServerProfile) -> VaultState {
        let state = VaultStore.makeState(for: profile.id)
        let save = state.onRootsChange
        state.onRootsChange = { [weak self] roots in
            save?(roots)
            Task { @MainActor in self?.vaultRevision += 1 }
        }
        state.onKeysChange = { [weak self] in
            Task { @MainActor in self?.vaultRevision += 1 }
        }
        return state
    }

    /// Whether `path` is an encrypted folder itself.
    func isEncryptedFolder(_ path: String) -> Bool {
        _ = vaultRevision
        return vaultService?.state.isRoot(path) ?? false
    }

    /// Whether `path` is inside an encrypted folder (or is one).
    func isEncrypted(_ path: String) -> Bool {
        _ = vaultRevision
        return vaultService?.isEncrypted(path) ?? false
    }

    /// The encrypted folder `path` is in, if any.
    func encryptedRoot(of path: String) -> String? {
        _ = vaultRevision
        return vaultService?.state.root(containing: path)
    }

    func isUnlocked(_ root: String) -> Bool {
        _ = vaultRevision
        return vaultService?.state.isUnlocked(root) ?? false
    }

    func isRemembered(_ root: String) -> Bool {
        unlockMode(of: root) == .keepUnlocked
    }

    /// How a folder opens next time on this device.
    func unlockMode(of root: String) -> VaultUnlockMode {
        _ = vaultRevision
        guard let id = activeServer?.id else { return .password }
        return VaultStore.mode(for: root, server: id)
    }

    /// Changes how an unlocked folder opens next time.
    func setUnlockMode(_ mode: VaultUnlockMode, for root: String) {
        guard let id = activeServer?.id, let keys = vaultService?.state.keys(for: root) else { return }
        do {
            try VaultStore.setMode(mode, keys: keys, root: root, server: id)
        } catch {
            handle(error)
        }
        vaultRevision += 1
    }

    /// Makes an encrypted folder and returns its recovery key.
    func createEncryptedFolder(named name: String, in parent: String, password: String) async throws -> (folder: RemoteItem, recoveryKey: String) {
        guard let vaultService else { throw NASError.unreachable }
        let result = try await vaultService.createVault(named: name, in: parent, password: password)
        folderChanged(parent)
        return result
    }

    func unlockFolder(_ root: String, password: String, mode: VaultUnlockMode) async throws {
        guard let vaultService, let id = activeServer?.id else { throw NASError.unreachable }
        let keys = try await vaultService.unlock(root, password: password)
        try? VaultStore.setMode(mode, keys: keys, root: root, server: id)
        lockedByHand.remove(root)
        vaultRevision += 1
        folderChanged(root)
    }

    /// Unlocks with Face ID (or the device passcode). Throws
    /// `.biometryUnavailable` when the password is needed instead.
    func unlockWithBiometrics(_ root: String) async throws {
        guard let vaultService, let id = activeServer?.id else { throw NASError.unreachable }
        let name = (root as NSString).lastPathComponent
        do {
            let keys = try await VaultStore.biometricKeys(for: root, server: id, reason: "Unlock “\(name)”")
            vaultService.state.unlock(root, keys: keys)
            lockedByHand.remove(root)
            folderChanged(root)
        } catch {
            vaultRevision += 1
            throw error
        }
    }

    /// Unlocks with the recovery key and sets a new password.
    func recoverFolder(_ root: String, recoveryKey: String, newPassword: String) async throws {
        guard let vaultService else { throw NASError.unreachable }
        _ = try await vaultService.unlock(root, recoveryKey: recoveryKey)
        try await vaultService.changePassword(of: root, to: newPassword)
        folderChanged(root)
    }

    func changeFolderPassword(_ root: String, to password: String) async throws {
        guard let vaultService else { throw NASError.unreachable }
        try await vaultService.changePassword(of: root, to: password)
    }

    /// Locks a folder now. A folder kept unlocked stops being kept unlocked;
    /// Face ID stays on (it opens with Face ID next time).
    func lockFolder(_ root: String) {
        guard let vaultService else { return }
        if let id = activeServer?.id { VaultStore.forget(root, server: id) }
        vaultService.state.lock(root)
        lockedByHand.insert(root)
        vaultRevision += 1
        folderChanged(root)
    }

    /// How long Ownhold can be in the background before folders that aren't
    /// kept unlocked lock again.
    nonisolated static let vaultLockDelay: TimeInterval = 180

    /// Called when Ownhold comes back: locks folders after time away.
    func lockEncryptedFoldersIfAway(since date: Date?) {
        guard let date, Date().timeIntervalSince(date) >= Self.vaultLockDelay else { return }
        lockEncryptedFolders()
    }

    /// When the app lock engages: folders not set to stay unlocked lock too.
    func lockEncryptedFolders() {
        guard let vaultService, let id = activeServer?.id else { return }
        for root in vaultService.state.knownRoots where !VaultStore.isRemembered(root, for: id) && vaultService.state.isUnlocked(root) {
            vaultService.state.lock(root)
        }
    }
}
