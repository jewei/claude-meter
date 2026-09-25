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
    /// When the usage response was actually observed. Merge time must not make a
    /// cached reading look newly fetched.
    public let fetchedAt: Date

    public init(
        accountKey: String, label: String, email: String?, plan: String?,
        organizationId: String?, limits: LimitInfo, severity: UsageSeverity,
        fetchedAt: Date = Date()
    ) {
        self.accountKey = accountKey
        self.label = label
        self.email = email
        self.plan = plan
        self.organizationId = organizationId
        self.limits = limits
        self.severity = severity
        self.fetchedAt = fetchedAt
    }
}

extension MultiAccountOAuth {

    public static let defaultTotalTimeout: TimeInterval = 30
    public static let defaultPerAccountTimeout: TimeInterval = 10

    /// A blocked Keychain or transport operation can ignore task cancellation.
    /// Keep those abandoned tasks out of `Timeout`'s process-wide default pool.
    private static let accountTimeoutBudget = Timeout.TaskBudget(limit: 16)

    public enum AccountFetchFailure: Sendable, Equatable {
        case credentialsMissing
        case credentialsUnavailable
        case credentialsInvalid
        case credentialsExpired
        case unauthorized
        case rateLimited
        case invalidResponse
        case requestFailed
    }

    public struct AccountFetchResult: Sendable, Equatable {
        public let accountKey: String
        public let reading: OAuthAccountReading?
        public let failure: AccountFetchFailure?
    }

    /// Fetches secondary accounts with their own bearer, in sequence. Each account
    /// and the full batch have deadlines. A 429 stops the remaining requests.
    /// Secondary credentials remain read-only; expired tokens require a new login.
    public static func fetchAll(
        accounts: [AccountConfig],
        home: URL,
        thresholds: UsageThresholds,
        transport: any HTTPTransport,
        credentialsLoader:
            @escaping @Sendable (String, Bool) -> KeychainReadResult<
                OAuthCredentials
            >,
        now: Date,
        totalTimeout: TimeInterval = defaultTotalTimeout,
        perAccountTimeout: TimeInterval = defaultPerAccountTimeout
    ) async -> [OAuthAccountReading] {
        await fetchAllResults(
            accounts: accounts, home: home, thresholds: thresholds, transport: transport,
            credentialsLoader: credentialsLoader, now: now,
            totalTimeout: totalTimeout, perAccountTimeout: perAccountTimeout
        ).compactMap(\.reading)
    }

    /// Diagnostic-preserving form of `fetchAll`. Each attempted account produces a
    /// coherent success or failure instead of silently disappearing from the result.
    public static func fetchAllResults(
        accounts: [AccountConfig],
        home: URL,
        thresholds: UsageThresholds,
        transport: any HTTPTransport,
        credentialsLoader:
            @escaping @Sendable (String, Bool) -> KeychainReadResult<
                OAuthCredentials
            >,
        now: Date,
        totalTimeout: TimeInterval = defaultTotalTimeout,
        perAccountTimeout: TimeInterval = defaultPerAccountTimeout
    ) async -> [AccountFetchResult] {
        await fetchAllResults(
            accounts: accounts, home: home, thresholds: thresholds, transport: transport,
            credentialsLoader: credentialsLoader, now: now,
            totalTimeout: totalTimeout, perAccountTimeout: perAccountTimeout,
            uptime: { ProcessInfo.processInfo.systemUptime })
    }

    /// Keep elapsed-budget tests independent of the test host's scheduling delays.
    /// The actual account deadline still runs through `Timeout` on a Dispatch timer.
    static func fetchAllResults(
        accounts: [AccountConfig],
        home: URL,
        thresholds: UsageThresholds,
        transport: any HTTPTransport,
        credentialsLoader:
            @escaping @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials>,
        now: Date,
        totalTimeout: TimeInterval,
        perAccountTimeout: TimeInterval,
        uptime: @Sendable () -> TimeInterval
    ) async -> [AccountFetchResult] {
        guard totalTimeout.isFinite, totalTimeout > 0,
            perAccountTimeout.isFinite, perAccountTimeout > 0
        else {
            return accounts.map {
                AccountFetchResult(
                    accountKey: $0.id, reading: nil, failure: .requestFailed)
            }
        }

        var results: [AccountFetchResult] = []
        let deadline = uptime() + totalTimeout
        for account in accounts {
            if Task.isCancelled { break }
            if OAuthPipeline.isRateLimited(now: now) { break }

            let remaining = deadline - uptime()
            guard remaining > 0 else { break }
            let timeout = min(perAccountTimeout, remaining)

            do {
                let result = try await Timeout.run(
                    seconds: timeout,
                    budget: accountTimeoutBudget
                ) {
                    await fetchResult(
                        account: account, home: home, thresholds: thresholds,
                        transport: transport, credentialsLoader: credentialsLoader, now: now)
                }
                results.append(result)
                if result.failure == .rateLimited { break }
            } catch {
                if error is CancellationError || Task.isCancelled { break }
                results.append(.init(accountKey: account.id, reading: nil, failure: .requestFailed))
            }
        }
        return results
    }

    private static func fetchResult(
        account: AccountConfig,
        home: URL,
        thresholds: UsageThresholds,
        transport: any HTTPTransport,
        credentialsLoader: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials>,
        now: Date
    ) async -> AccountFetchResult {
        let dirPath = OAuthKeychain.standardizedConfigDirPath(account.configDir.path)
        let credentialResult = credentialsLoader(dirPath, account.id == "claude")
        guard !Task.isCancelled else {
            return .init(accountKey: account.id, reading: nil, failure: .requestFailed)
        }
        guard let creds = credentialResult.value else {
            let failure: AccountFetchFailure
            switch credentialResult {
            case .missing: failure = .credentialsMissing
            case .temporarilyUnavailable: failure = .credentialsUnavailable
            case .invalid, .found: failure = .credentialsInvalid
            }
            return .init(accountKey: account.id, reading: nil, failure: failure)
        }
        guard !creds.isExpired(asOf: now) else {
            return .init(accountKey: account.id, reading: nil, failure: .credentialsExpired)
        }

        let identity = AccountIdentityReader.loadLocal(configDir: account.configDir, home: home)
        guard !Task.isCancelled else {
            return .init(accountKey: account.id, reading: nil, failure: .requestFailed)
        }
        do {
            let (data, http) = try await transport.send(
                OAuthPipeline.usageRequest(token: creds.accessToken), retry: .none)
            guard http.statusCode == 200 else {
                if http.statusCode == 429 {
                    OAuthPipeline.recordRateLimit(
                        retryAfter: OAuthPipeline.retryAfterDate(from: http, now: now),
                        now: now)
                    return .init(accountKey: account.id, reading: nil, failure: .rateLimited)
                }
                return .init(
                    accountKey: account.id, reading: nil,
                    failure: http.statusCode == 401 || http.statusCode == 403
                        ? .unauthorized : .requestFailed)
            }
            do {
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                let value = reading(
                    account: account, usage: usage, identity: identity, creds: creds,
                    orgHeader: http.value(forHTTPHeaderField: "anthropic-organization-id"),
                    thresholds: thresholds, fetchedAt: now)
                return .init(accountKey: account.id, reading: value, failure: nil)
            } catch {
                return .init(accountKey: account.id, reading: nil, failure: .invalidResponse)
            }
        } catch {
            return .init(accountKey: account.id, reading: nil, failure: .requestFailed)
        }
    }

    /// Pure assembly of one account's reading.
    private static func reading(
        account: AccountConfig,
        usage: UsageResponse,
        identity: ClaudeAccountIdentity?,
        creds: OAuthCredentials,
        orgHeader: String?,
        thresholds: UsageThresholds,
        fetchedAt: Date
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
            scopedWeekly: OAuthPipeline.scopedWindows(from: usage),
            extraUsage: usage.extraUsage?.model,
            usageResets: usage.usageResets?.grants(asOf: fetchedAt))
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
            severity: severity,
            fetchedAt: fetchedAt)
    }
}
