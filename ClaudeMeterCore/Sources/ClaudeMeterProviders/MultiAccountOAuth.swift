import ClaudeMeterCore
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

// MARK: - Snapshot merge

extension MultiAccountOAuth {

    /// Merges per-account OAuth readings into a snapshot's `accounts` list.
    /// Fill-only-missing: statusline data (near-real-time) wins on conflict;
    /// OAuth contributes what the statusline can't see (Opus weekly, extra
    /// usage, plan, email, org) and covers accounts with no live session.
    /// The snapshot's TOP-LEVEL fields are never modified here.
    public static func merge(
        readings: [OAuthAccountReading],
        into snapshot: ClaudeUsageSnapshot,
        now: Date
    ) -> ClaudeUsageSnapshot {
        guard !readings.isEmpty else { return snapshot }
        var byKey = Dictionary(uniqueKeysWithValues: readings.map { ($0.accountKey, $0) })
        var snap = snapshot

        if var accounts = snap.accounts, !accounts.isEmpty {
            for index in accounts.indices {
                guard let reading = byKey.removeValue(forKey: accounts[index].id) else {
                    continue
                }
                accounts[index] = filled(accounts[index], from: reading)
            }
            accounts.append(
                contentsOf: byKey.values.sorted { $0.accountKey < $1.accountKey }
                    .map { newAccount(from: $0, now: now) })
            snap.accounts = sorted(accounts)
            return snap
        }

        // No accounts list: only materialize one for a real multi-account picture
        // (a lone default account keeps `current.json` byte-identical).
        guard readings.count >= 2 else { return snap }
        let activeKey = byKey["claude"] != nil ? "claude" : readings[0].accountKey
        let accounts = readings.map { reading in
            var account = newAccount(from: reading, now: now)
            account.isActive = reading.accountKey == activeKey
            return account
        }
        snap.accounts = sorted(accounts)
        return snap
    }

    /// Account keys that share an organization id with another account — two
    /// config dirs logged into the same login (their quota is one bucket shown
    /// twice).
    public static func duplicateOrgAccountKeys(_ accounts: [AccountUsage]) -> Set<String> {
        var byOrg: [String: [String]] = [:]
        for account in accounts {
            guard let org = account.account?.organization, !org.isEmpty else { continue }
            byOrg[org, default: []].append(account.id)
        }
        return Set(byOrg.values.filter { $0.count >= 2 }.flatMap { $0 })
    }

    private static func filled(_ existing: AccountUsage, from reading: OAuthAccountReading)
        -> AccountUsage
    {
        var account = existing
        var info = account.account ?? AccountInfo()
        if info.email == nil { info.email = reading.email }
        if info.plan == nil { info.plan = reading.plan }
        if info.organization == nil { info.organization = reading.organizationId }
        if info.loginMethod == nil { info.loginMethod = "OAuth" }
        account.account = info.isEmpty ? nil : info
        if account.limits.currentWeekOpus == nil {
            account.limits.currentWeekOpus = reading.limits.currentWeekOpus
        }
        if account.limits.extraUsage == nil {
            account.limits.extraUsage = reading.limits.extraUsage
        }
        if account.limits.currentSession.percentUsed == nil {
            account.limits.currentSession = reading.limits.currentSession
        }
        if account.limits.currentWeekAllModels.percentUsed == nil {
            account.limits.currentWeekAllModels = reading.limits.currentWeekAllModels
        }
        return account
    }

    private static func newAccount(from reading: OAuthAccountReading, now: Date) -> AccountUsage {
        AccountUsage(
            id: reading.accountKey,
            label: reading.label,
            account: AccountInfo(
                loginMethod: "OAuth",
                organization: reading.organizationId,
                email: reading.email,
                plan: reading.plan),
            limits: reading.limits,
            lastSuccessfulPollAt: now,
            severity: reading.severity,
            isActive: false)
    }

    private static func sorted(_ accounts: [AccountUsage]) -> [AccountUsage] {
        accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.id < rhs.id
        }
    }
}
