import Foundation
import LocalAuthentication
import Security

/// The login Keychain, accessed without any user interface.
///
/// Inside a test process every call throws ``KeychainError/unavailable``, unless the
/// environment sets `CLAUDE_METER_LIVE_KEYCHAIN=1`.
public struct SystemKeychain: Keychain {
    public init() {}

    public func password(service: String, account: String?) throws(KeychainError) -> Data? {
        try ensureAllowed()
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }

    public func items(
        servicePrefix: String, account: String?
    ) throws(KeychainError) -> [KeychainItem] {
        try ensureAllowed()
        var query = baseQuery(service: nil, account: account)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        let rows = result as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String,
                service.hasPrefix(servicePrefix)
            else { return nil }
            return KeychainItem(
                service: service,
                account: row[kSecAttrAccount as String] as? String,
                modifiedAt: row[kSecAttrModificationDate as String] as? Date)
        }
    }

    public func setPassword(
        _ password: Data, service: String, account: String
    ) throws(KeychainError) {
        try ensureAllowed()
        let query = baseQuery(service: service, account: account)
        let update = [kSecValueData: password] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = password
            try check(SecItemAdd(item as CFDictionary, nil))
            return
        }
        try check(status)
    }

    public func deletePassword(service: String, account: String) throws(KeychainError) {
        try ensureAllowed()
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    private func baseQuery(service: String?, account: String?) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecUseAuthenticationContext: context,
        ]
        if let service { query[kSecAttrService] = service }
        if let account { query[kSecAttrAccount] = account }
        return query
    }

    private func ensureAllowed() throws(KeychainError) {
        if TestProcess.isRunning && !TestProcess.allowsLiveKeychain {
            throw .unavailable
        }
    }

    private func check(_ status: OSStatus) throws(KeychainError) {
        switch status {
        case errSecSuccess:
            return
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecUserCanceled,
            errSecNoSuchKeychain:
            throw .unavailable
        case errSecAuthFailed:
            throw .denied
        default:
            throw .failure(status: status)
        }
    }
}

/// Detects test processes, so live system access fails closed during tests.
public enum TestProcess {
    public static let isRunning: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        {
            return true
        }
        // `swift test` runs a helper whose name and environment vary; the loaded test
        // frameworks do not.
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if path.contains("/XCTest.framework/") || path.contains("/Testing.framework/")
                || path.hasSuffix("/libXCTestSwiftSupport.dylib")
            {
                return true
            }
        }
        return false
    }()

    public static var allowsLiveKeychain: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_METER_LIVE_KEYCHAIN"] == "1"
    }
}
