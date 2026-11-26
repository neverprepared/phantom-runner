import Foundation
import Security

/// Thin SecItem wrapper for the runner's API key. One item, one service.
/// Account == bundle id so multiple installations (sandbox copies, etc.) get
/// distinct entries on the same Mac.
enum KeychainStore {
    private static let service = "com.neverprepared.brainbox-runner"
    private static var account: String {
        Bundle.main.bundleIdentifier ?? "default"
    }

    enum KeychainError: Error {
        case status(OSStatus)
        /// The value is not shaped like a credential (see CredentialShape).
        case notACredential(CredentialShape)
    }

    /// Store the runner's credential. Refuses anything that is not a 64-hex
    /// credential (a pairing code, a truncated paste), because the running loop
    /// would keep using the good key in memory and the bad value would surface
    /// only at the next Keychain read: a session create, or the next relaunch.
    static func saveAPIKey(_ raw: String) throws {
        guard let key = CredentialShape.normalizedAPIKey(raw) else {
            throw KeychainError.notACredential(CredentialShape.classify(raw))
        }
        let data = Data(key.utf8)
        // Delete any prior entry; SecItemUpdate is more code than it's worth.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func hasAPIKey() -> Bool {
        loadAPIKey() != nil
    }
}
