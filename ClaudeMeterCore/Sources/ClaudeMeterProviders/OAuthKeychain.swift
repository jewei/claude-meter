import ClaudeMeterCore
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
        isExpired(asOf: Date())
    }

    public func isExpired(asOf now: Date) -> Bool {
        now.timeIntervalSince(expiresAt) > -60
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

public enum OAuthKeychainWriteError: Error, LocalizedError, Sendable {
    case encodingFailed
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: "Could not encode OAuth credentials."
        case .keychain(let status): "Keychain operation failed (OSStatus \(status))."
        }
    }
}

/// Reads and writes the `claudeAiOauth` block inside Claude Code's Keychain entry.
///
/// Claude Code stores credentials under:
///   service = "Claude Code-credentials", account = current username
///
/// Newer Claude Code (≈ 2.1.52+) namespaces the entry per install/config dir as
/// `Claude Code-credentials-<hash>`. The single-slot path preserves the legacy
/// unsuffixed entry when present and discovers the newest hashed entry only after
/// a genuine legacy miss. A lock/error never triggers fallback.
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
            switch credentialReference(services: [service], account: account) {
            case .found: return .available
            case .missing:
                switch newestHashedCredentialRef(account: account) {
                case .found: return .available
                case .missing: return .missing
                case .temporarilyUnavailable, .invalid: return .temporarilyUnavailable
                }
            case .temporarilyUnavailable, .invalid: return .temporarilyUnavailable
            }
        #else
            return .missing
        #endif
    }

    /// Attributes-only preflight for the app-owned manual credential. This is safe
    /// to call while rendering Settings because it never requests secret data.
    public static func manualCredentialAvailability() -> KeychainCredentialAvailability {
        #if canImport(Security)
            var query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: manualService,
                kSecAttrAccount: manualAccount,
                kSecReturnAttributes: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            KeychainGateway.applyNoUI(to: &query)
            var result: AnyObject?
            switch KeychainGateway.copyMatching(query: query as CFDictionary, result: &result) {
            case errSecSuccess: return .available
            case errSecItemNotFound: return .missing
            default: return .temporarilyUnavailable
            }
        #else
            return .missing
        #endif
    }

    private static func readClaudeCodeCredentials() -> KeychainReadResult<String> {
        let account = claudeCodeAccount
        guard !account.isEmpty else { return .missing }
        #if canImport(Security)
            switch readKeychainItemResult(service: service, account: account) {
            case .missing: return readNewestHashedCredential(account: account)
            case let result: return result
            }
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

    /// Returns the newest hashed Claude Code credential and ignores the legacy
    /// unsuffixed entry. The caller consults this only after the legacy item is
    /// genuinely missing. Pure; exposed for tests.
    static func newestHashedService(among candidates: [(service: String, modified: Date)])
        -> String?
    {
        let prefix = service + "-"
        return
            candidates
            .filter { $0.service.hasPrefix(prefix) }
            .max {
                if $0.modified != $1.modified { return $0.modified < $1.modified }
                // Stable even when Security.framework returns equal timestamps in
                // an unspecified enumeration order.
                return $0.service > $1.service
            }?
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

    public static func saveManual(accessToken: String, refreshToken: String) throws {
        let expiry = Date.distantFuture.timeIntervalSince1970 * 1000
        guard
            let data = try? JSONSerialization.data(withJSONObject: [
                "claudeAiOauth": [
                    "accessToken": accessToken,
                    "refreshToken": refreshToken,
                    "expiresAt": expiry,
                ] as [String: Any]
            ]), let str = String(data: data, encoding: .utf8)
        else { throw OAuthKeychainWriteError.encodingFailed }
        #if canImport(Security)
            try writeKeychainItem(service: manualService, account: manualAccount, value: str)
        #else
            guard
                runSecurity([
                    "add-generic-password", "-U", "-s", manualService, "-a", manualAccount, "-w",
                    str,
                ]) != nil
            else { throw OAuthKeychainWriteError.keychain(-1) }
        #endif
    }

    public static func deleteManual() throws {
        #if canImport(Security)
            try deleteKeychainItem(service: manualService, account: manualAccount)
        #else
            guard
                runSecurity(["delete-generic-password", "-s", manualService, "-a", manualAccount])
                    != nil
            else { throw OAuthKeychainWriteError.keychain(-1) }
        #endif
    }

    // MARK: - Helpers

    #if canImport(Security)
        private static func writeKeychainItem(service: String, account: String, value: String)
            throws
        {
            guard let data = value.data(using: .utf8) else {
                throw OAuthKeychainWriteError.encodingFailed
            }
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            let attrs: [CFString: Any] = [
                kSecValueData: data
            ]
            let status = KeychainGateway.update(
                query: query as CFDictionary, attributes: attrs as CFDictionary)
            if status == errSecSuccess { return }
            if status == errSecItemNotFound {
                var addQuery = query
                addQuery[kSecValueData] = data
                // AfterFirstUnlock (not WhenUnlocked) so the item stays readable
                // while the screen is locked — the poll loop runs across sleep/wake.
                addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let addStatus = KeychainGateway.add(query: addQuery as CFDictionary)
                guard addStatus == errSecSuccess else {
                    throw OAuthKeychainWriteError.keychain(addStatus)
                }
                return
            }
            throw OAuthKeychainWriteError.keychain(status)
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
            KeychainGateway.applyNoUI(to: &query)
            var result: AnyObject?
            let status = KeychainGateway.copyMatching(
                query: query as CFDictionary, result: &result)
            return mapKeychainStatus(status, data: result as? Data)
        }

        /// Reads the newest hashed fallback via attributes-only enumeration, then
        /// fetches its secret by persistent ref. The caller invokes this only after
        /// the legacy unsuffixed item is genuinely missing.
        private static func readNewestHashedCredential(account: String)
            -> KeychainReadResult<String>
        {
            switch newestHashedCredentialRef(account: account) {
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

        /// Finds the newest hashed Claude Code credential using attributes only.
        private static func newestHashedCredentialRef(account: String)
            -> KeychainReadResult<Data>
        {
            var query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: account,
                kSecReturnAttributes: true,
                kSecReturnPersistentRef: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            KeychainGateway.applyNoUI(to: &query)
            var result: AnyObject?
            let status = KeychainGateway.copyMatching(
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
            guard let winner = newestHashedService(among: candidates),
                let ref = items.first(where: {
                    ($0[kSecAttrService as String] as? String) == winner
                })?[kSecValuePersistentRef as String] as? Data
            else {
                return .missing
            }
            return .found(ref)
        }

        /// Locates the first preferred service without reading its secret.
        private static func credentialReference(services: [String], account: String)
            -> KeychainReadResult<Data>
        {
            var query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: account,
                kSecReturnAttributes: true,
                kSecReturnPersistentRef: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            KeychainGateway.applyNoUI(to: &query)
            var result: AnyObject?
            let status = KeychainGateway.copyMatching(query: query as CFDictionary, result: &result)
            switch status {
            case errSecSuccess: break
            case errSecItemNotFound: return .missing
            default: return .temporarilyUnavailable
            }
            guard let items = result as? [[String: Any]] else { return .missing }
            for candidate in services {
                if let ref = items.first(where: {
                    ($0[kSecAttrService as String] as? String) == candidate
                })?[kSecValuePersistentRef as String] as? Data {
                    return .found(ref)
                }
            }
            return .missing
        }

        /// Reads the first present service from `services` (preference order) via
        /// attributes-only enumeration + persistent-ref data read. `.missing` only
        /// when none of the candidates exist.
        private static func readCredential(services: [String], account: String)
            -> KeychainReadResult<String>
        {
            switch credentialReference(services: services, account: account) {
            case .found(let ref): return readCredentialData(persistentRef: ref)
            case .missing: return .missing
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .invalid: return .invalid
            }
        }

        /// Reads a generic-password's secret by persistent ref under the no-UI policy,
        /// so the data fetch — the only step that could prompt — stays non-interactive.
        private static func readCredentialData(persistentRef: Data) -> KeychainReadResult<String> {
            var query: [CFString: Any] = [
                kSecValuePersistentRef: persistentRef,
                kSecReturnData: true,
            ]
            KeychainGateway.applyNoUI(to: &query)
            var result: AnyObject?
            let status = KeychainGateway.copyMatching(
                query: query as CFDictionary, result: &result)
            return mapKeychainStatus(status, data: result as? Data)
        }

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

        private static func deleteKeychainItem(service: String, account: String) throws {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            let status = KeychainGateway.delete(query: query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw OAuthKeychainWriteError.keychain(status)
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
