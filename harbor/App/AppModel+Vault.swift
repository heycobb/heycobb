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
        _ = vaultRevision
        guard let id = activeServer?.id else { return false }
        return VaultStore.isRemembered(root, for: id)
    }

    /// Makes an encrypted folder and returns its recovery key.
    func createEncryptedFolder(named name: String, in parent: String, password: String) async throws -> (folder: RemoteItem, recoveryKey: String) {
        guard let vaultService else { throw NASError.unreachable }
        let result = try await vaultService.createVault(named: name, in: parent, password: password)
        folderChanged(parent)
        return result
    }

    func unlockFolder(_ root: String, password: String, remember: Bool) async throws {
        guard let vaultService, let id = activeServer?.id else { throw NASError.unreachable }
        let keys = try await vaultService.unlock(root, password: password)
        if remember { VaultStore.remember(keys, for: root, server: id) }
        folderChanged(root)
    }

    /// Unlocks with the recovery key and sets a new password.
    func recoverFolder(_ root: String, recoveryKey: String, newPassword: String, remember: Bool) async throws {
        guard let vaultService, let id = activeServer?.id else { throw NASError.unreachable }
        let keys = try await vaultService.unlock(root, recoveryKey: recoveryKey)
        try await vaultService.changePassword(of: root, to: newPassword)
        if remember { VaultStore.remember(keys, for: root, server: id) }
        folderChanged(root)
    }

    func changeFolderPassword(_ root: String, to password: String) async throws {
        guard let vaultService else { throw NASError.unreachable }
        try await vaultService.changePassword(of: root, to: password)
    }

    /// Locks a folder now; it also stops staying unlocked on this device.
    func lockFolder(_ root: String) {
        guard let vaultService else { return }
        if let id = activeServer?.id { VaultStore.forget(root, server: id) }
        vaultService.state.lock(root)
        folderChanged(root)
    }

    /// When the app lock engages: folders not set to stay unlocked lock too.
    func lockEncryptedFolders() {
        guard let vaultService, let id = activeServer?.id else { return }
        for root in vaultService.state.knownRoots where !VaultStore.isRemembered(root, for: id) && vaultService.state.isUnlocked(root) {
            vaultService.state.lock(root)
        }
    }
}
