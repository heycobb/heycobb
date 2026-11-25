import Foundation
import Security

/// Small wrapper over the Keychain. Items are stored device-only
/// (never synced to iCloud Keychain) and are readable after first unlock.
public struct Keychain: Sendable {
    public let service: String

    public init(service: String = "app.harbor.keychain") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Use the modern keychain on macOS too, so behavior matches iOS.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func data(for key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    public func set(_ data: Data, for key: String) -> Bool {
        let query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { $1 }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public func remove(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    public func codable<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        data(for: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    @discardableResult
    public func setCodable<T: Encodable>(_ value: T, for key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return set(data, for: key)
    }
}
