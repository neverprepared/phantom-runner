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
    }

    static func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        // Delete any prior entry; SecItemUpdate is more code than it's worth.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        guard !key.isEmpty else { return }
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
