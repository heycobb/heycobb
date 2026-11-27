import Foundation
import LocalAuthentication
import Security

/// How an encrypted folder opens next time on this device.
public enum VaultUnlockMode: String, Sendable, CaseIterable, Codable {
    /// Type the password (the default). Locks when Arkenal quits.
    case password
    /// Face ID, Touch ID or Optic ID, with the device passcode as fallback.
    case biometric
    /// No prompt: the key is kept in the Keychain (also lets the Files app
    /// and Finder open the folder).
    case keepUnlocked
}

/// The Face ID option. The folder's key is kept in the Keychain behind an
/// access control that the system enforces in the Secure Enclave: reading it
/// needs a face or finger enrolled now (adding a new one invalidates it) or
/// the device passcode. Arkenal never sees biometric data; it gets the key
/// only after the system says yes. The item is this device only, needs a
/// device passcode to exist, and isn't shared with the extensions.
public enum VaultBiometrics {
    static let service = "com.snowlightlabs.arkenal.vault-biometric"

    static func account(_ root: String, server id: UUID) -> String { id.uuidString + "|" + root }

    private static func baseQuery(_ root: String, server id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(root, server: id),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// What the device offers, for labels: "Face ID", "Touch ID", "Optic ID",
    /// or nil when there's no biometry (the passcode is then used alone).
    public static var biometryName: String? {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    /// Whether this device can protect a key this way (it needs a passcode).
    public static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Stores the key behind Face ID (or the passcode). Doesn't prompt.
    static func store(_ keys: VaultKeys, root: String, server id: UUID) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.biometryCurrentSet, .or, .devicePasscode],
            &error
        ) else { throw VaultError.biometryUnavailable }
        remove(root: root, server: id)
        var item = baseQuery(root, server: id)
        item[kSecValueData as String] = keys.masterData
        item[kSecAttrAccessControl as String] = access
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VaultError.biometryUnavailable }
    }

    /// Asks for Face ID (or the passcode) and returns the key. Runs off the
    /// main thread: the Keychain waits for the person to answer.
    static func keys(root: String, server id: UUID, reason: String) async throws -> VaultKeys {
        let query = baseQuery(root, server: id)
        return try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedReason = reason
            var search = query
            search[kSecReturnData as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            search[kSecUseAuthenticationContext as String] = context
            var result: AnyObject?
            let status = SecItemCopyMatching(search as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let keys = VaultKeys(masterData: data) else { throw VaultError.biometryUnavailable }
                return keys
            case errSecUserCanceled:
                throw VaultError.biometryCanceled
            default:
                // Gone, or invalidated (a face or finger was added): the
                // password is needed to turn it on again.
                throw VaultError.biometryUnavailable
            }
        }.value
    }

    static func remove(root: String, server id: UUID) {
        SecItemDelete(baseQuery(root, server: id) as CFDictionary)
    }
}

public extension VaultStore {
    private static func biometricKey(_ id: UUID) -> String { "vaultBiometric.\(id.uuidString)" }

    private static func biometricRoots(for id: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: biometricKey(id)) ?? [])
    }

    private static func saveBiometricRoots(_ roots: Set<String>, for id: UUID) {
        if roots.isEmpty {
            UserDefaults.standard.removeObject(forKey: biometricKey(id))
        } else {
            UserDefaults.standard.set(roots.sorted(), forKey: biometricKey(id))
        }
    }

    /// How a folder opens next time on this device.
    static func mode(for root: String, server id: UUID) -> VaultUnlockMode {
        if isRemembered(root, for: id) { return .keepUnlocked }
        if biometricRoots(for: id).contains(root) { return .biometric }
        return .password
    }

    /// Sets how a folder opens next time. Needs its keys (it's unlocked).
    static func setMode(_ mode: VaultUnlockMode, keys: VaultKeys, root: String, server id: UUID) throws {
        forget(root, server: id)
        forgetBiometric(root, server: id)
        switch mode {
        case .password:
            break
        case .keepUnlocked:
            remember(keys, for: root, server: id)
        case .biometric:
            try VaultBiometrics.store(keys, root: root, server: id)
            saveBiometricRoots(biometricRoots(for: id).union([root]), for: id)
        }
    }

    /// Asks for Face ID (or the passcode) and returns the folder's keys. If
    /// the saved key is gone or no longer valid, it's forgotten and
    /// `.biometryUnavailable` is thrown: the password is needed.
    static func biometricKeys(for root: String, server id: UUID, reason: String) async throws -> VaultKeys {
        do {
            return try await VaultBiometrics.keys(root: root, server: id, reason: reason)
        } catch VaultError.biometryUnavailable {
            forgetBiometric(root, server: id)
            throw VaultError.biometryUnavailable
        }
    }

    static func forgetBiometric(_ root: String, server id: UUID) {
        var roots = biometricRoots(for: id)
        guard roots.remove(root) != nil else { return }
        VaultBiometrics.remove(root: root, server: id)
        saveBiometricRoots(roots, for: id)
    }

    /// Forgets Face ID for folders that no longer exist under these paths.
    internal static func pruneBiometric(keeping roots: Set<String>, server id: UUID) {
        for root in biometricRoots(for: id) where !roots.contains(root) {
            forgetBiometric(root, server: id)
        }
    }

    internal static func forgetAllBiometric(server id: UUID) {
        for root in biometricRoots(for: id) { forgetBiometric(root, server: id) }
    }
}
