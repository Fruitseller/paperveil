import Foundation
import Security

public enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus, operation: String)
}

/// Small wrapper around the macOS Keychain for secret settings, e.g. a private
/// key passphrase the user chooses to store. Non-secret settings belong in
/// `settings.json` instead (D03, D07).
///
/// Callers must never log, persist or transmit the secret values.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "de.paperveil") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "", // filled per call
        ]
    }

    /// Stores a secret for an account, replacing an existing value.
    public func set(_ secret: Data, for account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account

        var addQuery = query
        addQuery[kSecValueData as String] = secret
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery = [String: Any](uniqueKeysWithValues: [(kSecValueData as String, secret)])
            status = SecItemUpdate(query as CFDictionary, updateQuery as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status, operation: "write \(account)")
        }
    }

    /// Reads the secret for an account; `nil` when none is stored.
    public func secret(for account: String) throws -> Data? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status, operation: "read \(account)")
        }
        return item as? Data
    }

    /// Deletes the secret for an account (D07). Removing a missing item is not an error.
    public func delete(account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status, operation: "delete \(account)")
        }
    }
}
