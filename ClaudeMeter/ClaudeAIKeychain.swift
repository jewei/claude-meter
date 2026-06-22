import Foundation
import Security

/// Stores the claude.ai session key and org ID in the macOS Keychain.
enum ClaudeAIKeychain {

    private static let service = "com.jewei.claudemeter"
    private static let accountSessionKey = "claudeai.sessionKey"
    private static let accountOrgId = "claudeai.orgId"

    struct Credentials {
        let sessionKey: String
        let orgId: String
    }

    static func save(sessionKey: String, orgId: String) -> Bool {
        let saveOK = writeItem(account: accountSessionKey, value: sessionKey)
        let saveOrg = writeItem(account: accountOrgId, value: orgId)
        return saveOK && saveOrg
    }

    static func load() -> Credentials? {
        guard let sk = readItem(account: accountSessionKey),
              let org = readItem(account: accountOrgId),
              !sk.isEmpty, !org.isEmpty else { return nil }
        return Credentials(sessionKey: sk, orgId: org)
    }

    static func delete() {
        deleteItem(account: accountSessionKey)
        deleteItem(account: accountOrgId)
    }

    // MARK: - Low-level Keychain helpers

    @discardableResult
    private static func writeItem(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    private static func readItem(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static func deleteItem(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
