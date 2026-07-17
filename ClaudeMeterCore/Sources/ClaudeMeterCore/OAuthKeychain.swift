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
    /// Finer plan hint when present, e.g. "default_claude_max_5x" (→ "Max 5x").
    public var rateLimitTier: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
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

/// Attributes-only view of whether Claude Code has a candidate credentials item.
/// This never reads secret data and is safe to use while rendering Settings.
public enum KeychainCredentialAvailability: Sendable, Equatable {
    case available
    case missing
    case temporarilyUnavailable
}

/// Reads and writes the `claudeAiOauth` block inside Claude Code's Keychain entry.
///
/// Claude Code stores credentials under:
///   service = "Claude Code-credentials", account = current username
///
/// Newer Claude Code (≈ 2.1.52+) namespaces the entry per install/config dir as
/// `Claude Code-credentials-<hash>`, so a machine can hold several (often alongside
/// the legacy unsuffixed one after an in-place upgrade). We rank *all* candidate
/// entries by modification date in one pass and read the newest — the live login —
/// rather than blindly preferring the legacy name (see `readClaudeCodeCredentials`).
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

    /// Checks for a Claude Code credentials item without reading its secret value.
    /// Secret access remains behind an explicit user action in Settings.
    public static func credentialAvailability() -> KeychainCredentialAvailability {
        let account = claudeCodeAccount
        guard !account.isEmpty else { return .missing }
        #if canImport(Security)
            switch newestClaudeCodeCredentialRef(account: account) {
            case .found: return .available
            case .missing: return .missing
            case .temporarilyUnavailable, .invalid: return .temporarilyUnavailable
            }
        #else
            return .missing
        #endif
    }

    private static func readClaudeCodeCredentials() -> KeychainReadResult<String> {
        let account = claudeCodeAccount
        guard !account.isEmpty else { return .missing }
        #if canImport(Security)
            return readNewestClaudeCodeCredential(account: account)
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
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
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

    /// Candidate Keychain service names for a config dir's credentials, preferred
    /// first. Custom dirs use only their hashed service; the default dir prefers
    /// the legacy unsuffixed entry with the hashed one as a fallback (newer
    /// Claude Code may namespace even the default install).
    public static func credentialServices(forConfigDirPath path: String, isDefault: Bool)
        -> [String]
    {
        let hashed = service + "-" + MultiAccountOAuth.hashedServiceSuffix(forPath: path)
        return isDefault ? [service, hashed] : [hashed]
    }

    /// Reads the credentials bound to one config dir (multi-account read path).
    /// Same attributes-only enumeration + persistent-ref read as the single-slot
    /// path, but filtered to the dir's candidate services instead of "newest wins".
    public static func loadResult(configDirPath: String, isDefault: Bool)
        -> KeychainReadResult<OAuthCredentials>
    {
        let account = claudeCodeAccount
        guard !account.isEmpty else { return .missing }
        #if canImport(Security)
            let services = credentialServices(
                forConfigDirPath: standardizedConfigDirPath(configDirPath), isDefault: isDefault)
            return parseResult(readCredential(services: services, account: account))
        #else
            return .missing
        #endif
    }

    /// Standardizes a config dir path the same way the hash input expects:
    /// absolute, tilde-expanded, symlinks resolved, no trailing slash.
    static func standardizedConfigDirPath(_ raw: String) -> String {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// From candidate `(service, modificationDate)` pairs, returns the credential
    /// service — the legacy unsuffixed `Claude Code-credentials` **or** any
    /// `Claude Code-credentials-<hash>` — with the newest modification date (the entry
    /// Claude Code refreshed most recently, i.e. the live login). Ignores unrelated
    /// services. Pure; exposed for tests.
    static func newestCredentialService(among candidates: [(service: String, modified: Date)])
        -> String?
    {
        let prefix = service + "-"
        return
            candidates
            .filter { $0.service == service || $0.service.hasPrefix(prefix) }
            .max { $0.modified < $1.modified }?
            .service
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
            let status = KeychainSecurityGateway.update(
                query: query as CFDictionary, attributes: attrs as CFDictionary)
            if status == errSecSuccess { return true }
            if status == errSecItemNotFound {
                var addQuery = query
                addQuery[kSecValueData] = data
                // AfterFirstUnlock (not WhenUnlocked) so the item stays readable
                // while the screen is locked — the poll loop runs across sleep/wake.
                addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                return KeychainSecurityGateway.add(query: addQuery as CFDictionary) == errSecSuccess
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
            let status = KeychainSecurityGateway.copyMatching(
                query: query as CFDictionary, result: &result)
            return mapKeychainStatus(status, data: result as? Data)
        }

        /// Reads Claude Code's credentials by ranking *all* candidate entries — the
        /// legacy unsuffixed `Claude Code-credentials` and every per-install
        /// `…-<hash>` — in one **attributes-only** enumeration (no `kSecReturnData`, so
        /// no Allow/Deny prompt and no `security` subprocess), then reading the newest
        /// (the live login) by its persistent ref. An in-place Claude Code upgrade can
        /// leave a stale legacy entry beside a newer hashed one; ranking by
        /// modification date resolves to the entry actually in use instead of always
        /// preferring the legacy name.
        private static func readNewestClaudeCodeCredential(account: String)
            -> KeychainReadResult<String>
        {
            switch newestClaudeCodeCredentialRef(account: account) {
            case .found(let persistentRef):
                return readCredentialData(persistentRef: persistentRef)
            case .missing:
                return .missing
            case .temporarilyUnavailable:
                return .temporarilyUnavailable
            case .invalid:
                return .invalid
            }
        }

        /// Finds the newest Claude Code credential using attributes only. Keeping
        /// this separate lets Settings show availability without touching secrets.
        private static func newestClaudeCodeCredentialRef(account: String)
            -> KeychainReadResult<Data>
        {
            var query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: account,
                kSecReturnAttributes: true,
                kSecReturnPersistentRef: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            applyNoUI(to: &query)
            var result: AnyObject?
            let status = KeychainSecurityGateway.copyMatching(
                query: query as CFDictionary, result: &result)
            switch status {
            case errSecSuccess: break
            case errSecItemNotFound: return .missing
            // Locked keychain or other transient error — never assume "missing".
            default: return .temporarilyUnavailable
            }
            guard let items = result as? [[String: Any]] else { return .missing }

            let candidates: [(service: String, modified: Date)] = items.compactMap { item in
                guard let svc = item[kSecAttrService as String] as? String else { return nil }
                let modified = item[kSecAttrModificationDate as String] as? Date ?? .distantPast
                return (svc, modified)
            }
            guard let winner = newestCredentialService(among: candidates),
                let ref = items.first(where: {
                    ($0[kSecAttrService as String] as? String) == winner
                })?[kSecValuePersistentRef as String] as? Data
            else {
                return .missing
            }
            return .found(ref)
        }

        /// Reads the first present service from `services` (preference order) via
        /// attributes-only enumeration + persistent-ref data read. `.missing` only
        /// when none of the candidates exist.
        private static func readCredential(services: [String], account: String)
            -> KeychainReadResult<String>
        {
            var query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: account,
                kSecReturnAttributes: true,
                kSecReturnPersistentRef: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            applyNoUI(to: &query)
            var result: AnyObject?
            let status = KeychainSecurityGateway.copyMatching(
                query: query as CFDictionary, result: &result)
            switch status {
            case errSecSuccess: break
            case errSecItemNotFound: return .missing
            default: return .temporarilyUnavailable
            }
            guard let items = result as? [[String: Any]] else { return .missing }
            for service in services {
                if let ref = items.first(where: {
                    ($0[kSecAttrService as String] as? String) == service
                })?[kSecValuePersistentRef as String] as? Data {
                    return readCredentialData(persistentRef: ref)
                }
            }
            return .missing
        }

        /// Reads a generic-password's secret by persistent ref under the no-UI policy,
        /// so the data fetch — the only step that could prompt — stays non-interactive.
        private static func readCredentialData(persistentRef: Data) -> KeychainReadResult<String> {
            var query: [CFString: Any] = [
                kSecValuePersistentRef: persistentRef,
                kSecReturnData: true,
            ]
            applyNoUI(to: &query)
            var result: AnyObject?
            let status = KeychainSecurityGateway.copyMatching(
                query: query as CFDictionary, result: &result)
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
            _ = KeychainSecurityGateway.delete(query: query as CFDictionary)
        }

        /// All live Security.framework mutations pass through this boundary. Test
        /// processes fail closed unless explicitly opted in, preventing a unit test
        /// from reading or changing the developer's real Keychain.
        private enum KeychainSecurityGateway {
            // Process-constant — cached so every SecItem call doesn't re-bridge the
            // whole environment dictionary (repo convention, like cached formatters).
            private static let allowsLiveAccess: Bool = {
                let environment = ProcessInfo.processInfo.environment
                if environment["CLAUDE_METER_ALLOW_LIVE_KEYCHAIN_TESTS"] == "1" { return true }
                if environment["XCTestConfigurationFilePath"] != nil { return false }
                if Bundle.main.bundleURL.pathExtension == "xctest" { return false }
                if CommandLine.arguments.first?.contains(".xctest/") == true { return false }
                return !ProcessInfo.processInfo.processName.lowercased().contains("xctest")
            }()

            static func copyMatching(query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>)
                -> OSStatus
            {
                guard allowsLiveAccess else { return errSecInteractionNotAllowed }
                return SecItemCopyMatching(query, result)
            }

            static func update(query: CFDictionary, attributes: CFDictionary) -> OSStatus {
                guard allowsLiveAccess else { return errSecInteractionNotAllowed }
                return SecItemUpdate(query, attributes)
            }

            static func add(query: CFDictionary) -> OSStatus {
                guard allowsLiveAccess else { return errSecInteractionNotAllowed }
                return SecItemAdd(query, nil)
            }

            static func delete(query: CFDictionary) -> OSStatus {
                guard allowsLiveAccess else { return errSecInteractionNotAllowed }
                return SecItemDelete(query)
            }
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
