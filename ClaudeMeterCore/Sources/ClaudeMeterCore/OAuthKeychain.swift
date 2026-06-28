import Foundation

#if canImport(Security)
    import Darwin
    import LocalAuthentication
    import Security
#endif

public struct OAuthCredentials: Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    /// Plan hint from Claude Code's credentials (`subscriptionType`), e.g. "max".
    public var subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        subscriptionType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// True when the access token is expired or within 60 s of expiry.
    public var isExpired: Bool {
        Date().timeIntervalSince(expiresAt) > -60
    }
}

/// Outcome of a Keychain read. Distinguishes a genuinely absent item from a
/// transient lock (Keychain not yet unlocked / interaction not allowed) and from
/// a present-but-corrupt value — so a momentary lock isn't mistaken for "no
/// credentials" (which would wrongly drop the source).
public enum KeychainReadResult<Value: Sendable>: Sendable {
    case found(Value)
    case missing
    case temporarilyUnavailable
    case invalid

    public var value: Value? {
        if case .found(let v) = self { return v }
        return nil
    }
}

/// Reads and writes the `claudeAiOauth` block inside Claude Code's Keychain entry.
///
/// Claude Code stores credentials under:
///   service = "Claude Code-credentials", account = current username
///
/// The `-a $(whoami)` flag is required — without it the correct entry is not found.
public enum OAuthKeychain: Sendable {

    private static let service = "Claude Code-credentials"

    /// Matches `$(whoami)` — required as the Keychain account for Claude Code's entry.
    private static var claudeCodeAccount: String { NSUserName() }

    public static func load() -> OAuthCredentials? {
        loadResult().value
    }

    /// Like `load()` but distinguishes missing / locked / corrupt. Callers that
    /// must not drop a source on a transient Keychain lock should branch on this.
    public static func loadResult() -> KeychainReadResult<OAuthCredentials> {
        parseResult(readClaudeCodeCredentials())
    }

    private static func readClaudeCodeCredentials() -> KeychainReadResult<String> {
        let account = claudeCodeAccount
        guard !account.isEmpty else { return .missing }
        #if canImport(Security)
            return readKeychainItemResult(service: service, account: account)
        #else
            guard
                let json = runSecurity([
                    "find-generic-password", "-s", service, "-a", account, "-w",
                ])
            else {
                return .missing
            }
            return .found(json)
        #endif
    }

    /// Maps a raw credentials-JSON read into a typed credentials result.
    private static func parseResult(_ result: KeychainReadResult<String>) -> KeychainReadResult<
        OAuthCredentials
    > {
        switch result {
        case .found(let json):
            return parse(json).map(KeychainReadResult.found) ?? .invalid
        case .missing: return .missing
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .invalid: return .invalid
        }
    }

    // MARK: - Helpers

    /// Exposed for unit tests.
    internal static func parseForTesting(_ jsonString: String?) -> OAuthCredentials? {
        parse(jsonString)
    }

    private static func parse(_ jsonString: String?) -> OAuthCredentials? {
        guard let str = jsonString,
            let data = str.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = obj["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty,
            let expiresAtMs = numericValue(oauth["expiresAt"])
        else { return nil }
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAtMs / 1000),
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    // MARK: - App-owned manual token storage

    private static let manualService = "com.jewei.claudemeter-oauth"
    private static let manualAccount = "oauthManual"

    public static func loadManual() -> OAuthCredentials? {
        loadManualResult().value
    }

    public static func loadManualResult() -> KeychainReadResult<OAuthCredentials> {
        #if canImport(Security)
            return parseResult(
                readKeychainItemResult(service: manualService, account: manualAccount))
        #else
            guard
                let json = runSecurity([
                    "find-generic-password", "-s", manualService, "-a", manualAccount, "-w",
                ])
            else {
                return .missing
            }
            return parseResult(.found(json))
        #endif
    }

    public static func saveManual(accessToken: String, refreshToken: String) {
        let expiry = Date.distantFuture.timeIntervalSince1970 * 1000
        guard
            let data = try? JSONSerialization.data(withJSONObject: [
                "claudeAiOauth": [
                    "accessToken": accessToken,
                    "refreshToken": refreshToken,
                    "expiresAt": expiry,
                ] as [String: Any]
            ]), let str = String(data: data, encoding: .utf8)
        else { return }
        #if canImport(Security)
            writeKeychainItem(service: manualService, account: manualAccount, value: str)
        #else
            runSecurity([
                "add-generic-password", "-U", "-s", manualService, "-a", manualAccount, "-w", str,
            ])
        #endif
    }

    public static func deleteManual() {
        #if canImport(Security)
            deleteKeychainItem(service: manualService, account: manualAccount)
        #else
            runSecurity(["delete-generic-password", "-s", manualService, "-a", manualAccount])
        #endif
    }

    // MARK: - Helpers

    #if canImport(Security)
        @discardableResult
        private static func writeKeychainItem(service: String, account: String, value: String)
            -> Bool
        {
            guard let data = value.data(using: .utf8) else { return false }
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            let attrs: [CFString: Any] = [
                kSecValueData: data
            ]
            let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status == errSecSuccess { return true }
            if status == errSecItemNotFound {
                var addQuery = query
                addQuery[kSecValueData] = data
                // AfterFirstUnlock (not WhenUnlocked) so the item stays readable
                // while the screen is locked — the poll loop runs across sleep/wake.
                addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
            }
            return false
        }

        /// Reads an item and classifies the `OSStatus` so callers can tell a missing
        /// item from a transient lock.
        private static func readKeychainItemResult(service: String, account: String)
            -> KeychainReadResult<String>
        {
            var query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            applyNoUI(to: &query)
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return mapKeychainStatus(status, data: result as? Data)
        }

        /// Attaches a non-interactive policy so a Keychain read can never surface an
        /// Allow/Deny prompt. Critical because `Claude Code-credentials` is owned by
        /// another app (Claude Code), where a bare read can prompt; with this a
        /// locked/forbidden item returns `errSecInteractionNotAllowed` →
        /// `.temporarilyUnavailable` cleanly.
        private static func applyNoUI(to query: inout [CFString: Any]) {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
            // On macOS `interactionNotAllowed` alone can still surface the legacy
            // prompt; the UI-fail policy is what actually suppresses it. Resolve the
            // (deprecated) constant at runtime to avoid a compile-time deprecation.
            query[kSecUseAuthenticationUI] = noUIFailPolicy as CFString
        }

        private static let noUIFailPolicy: String = {
            let path = "/System/Library/Frameworks/Security.framework/Security"
            guard let handle = dlopen(path, RTLD_NOW) else { return "u_AuthUIF" }
            defer { dlclose(handle) }
            guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
                return "u_AuthUIF"
            }
            let ptr = symbol.assumingMemoryBound(to: CFString?.self)
            return (ptr.pointee as String?) ?? "u_AuthUIF"
        }()

        /// Pure mapping of a Keychain read status to a result (exposed for tests).
        static func mapKeychainStatus(_ status: OSStatus, data: Data?) -> KeychainReadResult<String>
        {
            switch status {
            case errSecSuccess:
                guard let data, let string = String(data: data, encoding: .utf8) else {
                    return .invalid
                }
                return .found(string)
            case errSecItemNotFound:
                return .missing
            case errSecAuthFailed:
                return .invalid
            default:
                // Locked Keychain (errSecInteractionNotAllowed), user cancel, or any
                // unexpected status → transient. Never assume "missing" on error.
                return .temporarilyUnavailable
            }
        }

        private static func deleteKeychainItem(service: String, account: String) {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    #endif

    @discardableResult
    private static func runSecurity(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
