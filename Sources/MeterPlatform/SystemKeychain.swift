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

    /// Fails with ``KeychainError/unavailable`` while the login Keychain is locked, because
    /// the tool would then ask to unlock it.
    public func passwordThroughSecurityTool(
        service: String, account: String
    ) throws(KeychainError) -> Data? {
        try ensureAllowed()
        if Self.isLocked() { throw .unavailable }
        return try SecurityTool.password(service: service, account: account)
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

    /// Every query fails with `errSecInteractionNotAllowed` instead of showing a prompt.
    ///
    /// Both settings are necessary. `LAContext.interactionNotAllowed` covers items that need
    /// user authentication. Items of other apps (Claude Code, the Cursor CLI) in the file-based
    /// login Keychain use legacy access lists, and for them macOS can still show the "wants to
    /// use your confidential information" dialog; only the UI-fail policy suppresses it.
    func baseQuery(service: String?, account: String?) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecUseAuthenticationContext: context,
            kSecUseAuthenticationUI: Self.authenticationUIFail as CFString,
        ]
        if let service { query[kSecAttrService] = service }
        if let account { query[kSecAttrAccount] = account }
        return query
    }

    /// The value of `kSecUseAuthenticationUIFail`, read at run time.
    ///
    /// Apple deprecated the constant in macOS 11 in favor of `interactionNotAllowed`, which
    /// alone does not stop the legacy prompt (see ``baseQuery(service:account:)``). A direct
    /// reference is a deprecation warning, and the build treats warnings as errors. The symbol
    /// still ships in Security.framework, so it is looked up by name. The fallback is its
    /// documented value.
    static let authenticationUIFail: String = {
        let fallback = "u_AuthUIF"
        let path = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(path, RTLD_NOW) else { return fallback }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return fallback }
        let value = symbol.assumingMemoryBound(to: CFString?.self).pointee
        return (value as String?) ?? fallback
    }()

    private func ensureAllowed() throws(KeychainError) {
        if TestProcess.isRunning && !TestProcess.allowsLiveKeychain {
            throw .unavailable
        }
        _ = Self.interactionDisabled
    }

    /// Turns off Keychain dialogs for the whole process, once, before the first call.
    ///
    /// On recent macOS, the UI-fail policy of ``baseQuery(service:account:)`` does not stop
    /// the legacy dialog for items of other apps. The process-wide switch does. The function
    /// is deprecated, so it is looked up by name, like ``authenticationUIFail``.
    private static let interactionDisabled: Void = {
        typealias SetAllowed = @convention(c) (UInt8) -> OSStatus
        guard let symbol = securitySymbol("SecKeychainSetUserInteractionAllowed") else { return }
        _ = unsafeBitCast(symbol, to: SetAllowed.self)(0)
    }()

    /// Whether the default Keychain is locked. False when macOS cannot say, so that the read
    /// goes on and reports its own error.
    static func isLocked() -> Bool {
        typealias GetStatus =
            @convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<UInt32>)
            -> OSStatus
        guard let symbol = securitySymbol("SecKeychainGetStatus") else { return false }
        var status: UInt32 = 0
        guard unsafeBitCast(symbol, to: GetStatus.self)(nil, &status) == errSecSuccess else {
            return false
        }
        // kSecUnlockStateStatus
        return status & 1 == 0
    }

    private static func securitySymbol(_ name: String) -> UnsafeMutableRawPointer? {
        let path = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        // Security.framework stays loaded: the app links it.
        return dlsym(handle, name)
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
