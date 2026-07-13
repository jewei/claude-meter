import CryptoKit
import Foundation

/// Per-account OAuth usage: maps each discovered Claude config dir to its own
/// Keychain credential and usage reading. Claude Code (≈2.1.52+) namespaces the
/// Keychain entry per config dir as `Claude Code-credentials-<hash>` where
/// `<hash>` is the first 8 hex chars of SHA-256 of the config dir's absolute
/// path (verified empirically); the default `~/.claude` keeps the legacy
/// unsuffixed service.
public enum MultiAccountOAuth {

    /// First 8 lowercase hex chars of SHA-256 over the path's UTF-8 bytes.
    public static func hashedServiceSuffix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}

/// One account's live OAuth usage reading.
public struct OAuthAccountReading: Sendable, Equatable {
    public let accountKey: String
    public let label: String
    public let email: String?
    public let plan: String?
    public let organizationId: String?
    public let limits: LimitInfo
    public let severity: UsageSeverity

    public init(
        accountKey: String, label: String, email: String?, plan: String?,
        organizationId: String?, limits: LimitInfo, severity: UsageSeverity
    ) {
        self.accountKey = accountKey
        self.label = label
        self.email = email
        self.plan = plan
        self.organizationId = organizationId
        self.limits = limits
        self.severity = severity
    }
}

extension MultiAccountOAuth {

    /// Fetches every account's usage with that account's own bearer, sequentially
    /// (small N; keeps 429 handling simple). An account with no credentials, an
    /// expired token, or a failed request is skipped — statusline data still
    /// covers it. A 429 aborts the remaining accounts and records the
    /// provider-wide backoff. Never throws.
    ///
    /// No token refresh here (deliberate): Claude Code refreshes its own Keychain
    /// entries as the user works, and the active account keeps full refresh via
    /// the single-slot `OAuthPipeline`. An expired secondary token just means that
    /// account stays statusline-only until its next local use.
    public static func fetchAll(
        accounts: [AccountConfig],
        home: URL,
        thresholds: UsageThresholds,
        transport: any HTTPTransport,
        credentialsLoader: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials>,
        now: Date
    ) async -> [OAuthAccountReading] {
        var readings: [OAuthAccountReading] = []
        for account in accounts {
            if OAuthPipeline.isRateLimited(now: now) { break }
            let dirPath = OAuthKeychain.standardizedConfigDirPath(account.configDir.path)
            let isDefault = account.id == "claude"
            guard let creds = credentialsLoader(dirPath, isDefault).value, !creds.isExpired
            else { continue }
            let identity = AccountIdentityReader.loadLocal(configDir: account.configDir, home: home)
            do {
                let (data, http) = try await transport.send(
                    OAuthPipeline.usageRequest(token: creds.accessToken), retry: .none)
                guard http.statusCode == 200 else {
                    if http.statusCode == 429 {
                        OAuthPipeline.recordRateLimit(
                            retryAfter: OAuthPipeline.retryAfterDate(from: http, now: now),
                            now: now)
                        break
                    }
                    continue
                }
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                readings.append(
                    reading(
                        account: account, usage: usage, identity: identity, creds: creds,
                        orgHeader: http.value(forHTTPHeaderField: "anthropic-organization-id"),
                        thresholds: thresholds))
            } catch {
                continue
            }
        }
        return readings
    }

    /// Pure assembly of one account's reading.
    private static func reading(
        account: AccountConfig,
        usage: UsageResponse,
        identity: ClaudeAccountIdentity?,
        creds: OAuthCredentials,
        orgHeader: String?,
        thresholds: UsageThresholds
    ) -> OAuthAccountReading {
        func window(_ entry: QuotaEntry?) -> LimitWindow? {
            guard let entry, let utilization = entry.utilization else { return nil }
            return LimitWindow(
                percentUsed: utilization, resetsAt: parseEpochOrISODate(entry.resetsAt))
        }
        let limits = LimitInfo(
            currentSession: window(usage.fiveHour) ?? LimitWindow(),
            currentWeekAllModels: window(usage.sevenDay) ?? LimitWindow(),
            currentWeekOpus: window(usage.sevenDayOpus),
            extraUsage: usage.extraUsage?.model)
        let severity = [
            usage.fiveHour?.utilization, usage.sevenDay?.utilization,
            usage.sevenDayOpus?.utilization,
        ].reduce(UsageSeverity.unknown) { UsageSeverity.highest($0, thresholds.severity(for: $1)) }
        return OAuthAccountReading(
            accountKey: account.id,
            label: account.label,
            email: identity?.email,
            plan: ClaudePlan.displayName(
                subscriptionType: creds.subscriptionType,
                rateLimitTier: creds.rateLimitTier ?? identity?.rateLimitTier),
            organizationId: orgHeader ?? identity?.organizationUuid,
            limits: limits,
            severity: severity)
    }
}
