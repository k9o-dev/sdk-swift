import Foundation
import Security

/// Thread-safe actor for persisting and retrieving refresh tokens in
/// the iOS/macOS Keychain.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — tokens
/// survive device restart once the device has been unlocked at least
/// once, but are never migrated to a new device via iCloud Keychain
/// backup. Suitable for end-user mobile sessions.
public actor KeychainTokenStore {
    private let service: String
    private let account: String

    public init(service: String = "dev.kilimanjaro.gate", account: String = "refresh_token") {
        self.service = service
        self.account = account
    }

    /// Persist a refresh token. Overwrites any existing value.
    public func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw K9OGateError.unknown(statusCode: -1, body: "Failed to encode token as UTF-8")
        }
        // Delete existing item first (SecItemUpdate is flakier than delete + add).
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw K9OGateError.unknown(statusCode: Int(status), body: "Keychain write failed (OSStatus \(status))")
        }
    }

    /// Retrieve the stored refresh token, or `nil` if none exists.
    public func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw K9OGateError.unknown(statusCode: -1, body: "Failed to decode Keychain data as UTF-8")
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw K9OGateError.unknown(statusCode: Int(status), body: "Keychain read failed (OSStatus \(status))")
        }
    }

    /// Remove the stored refresh token. No-op if no token is stored.
    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw K9OGateError.unknown(statusCode: Int(status), body: "Keychain delete failed (OSStatus \(status))")
        }
    }
}
