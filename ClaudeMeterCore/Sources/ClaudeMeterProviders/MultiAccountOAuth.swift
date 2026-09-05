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

    /// Fetches every account's usage with that account's own bearer, sequentially
    /// (small N; keeps 429 handling simple). An account with no credentials, an
    /// expired token, or a failed request is skipped — statusline data still
    /// covers it. A 429 aborts the remaining accounts and records the
    /// provider-wide backoff. Each account and the complete loop have independent
    /// deadlines, so one blocked read cannot discard earlier results. Never throws.
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
        guard totalTimeout.isFinite, totalTimeout > 0,
            perAccountTimeout.isFinite, perAccountTimeout > 0
        else {
            return accounts.map {
                AccountFetchResult(
                    accountKey: $0.id, reading: nil, failure: .requestFailed)
            }
        }

        var results: [AccountFetchResult] = []
        let deadline = ProcessInfo.processInfo.systemUptime + totalTimeout
        for account in accounts {
            if Task.isCancelled { break }
            if OAuthPipeline.isRateLimited(now: now) { break }

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
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
            severity: severity,
            fetchedAt: fetchedAt)
    }
}

// MARK: - Snapshot merge

extension MultiAccountOAuth {

    /// Merges per-account OAuth readings into a snapshot's `accounts` list.
    /// Statusline data (near-real-time) wins on conflict. OAuth fills missing
    /// fields and can replace only a statusline window whose recorded reset is
    /// past with an observation made after that reset. A newer OAuth observation
    /// replaces OAuth-visible fields in a stale cached account. This prevents an
    /// idle statusline file from holding the active meter at an inferred 0% while
    /// allowing a successful request to advance a cached fallback. Active-account
    /// plan, Opus, scoped limits, and extra usage come from the newest complete
    /// OAuth observation; the per-account request wins when timestamps match.
    public static func merge(
        readings: [OAuthAccountReading],
        into snapshot: ClaudeUsageSnapshot,
        now: Date,
        thresholds: UsageThresholds = .default,
        activeTopLevelOAuthDetailsObservedAt: Date? = nil
    ) -> ClaudeUsageSnapshot {
        guard !readings.isEmpty || activeTopLevelOAuthDetailsObservedAt != nil else {
            return snapshot
        }
        let topLevelOAuthDetails = activeTopLevelOAuthDetailsObservedAt.map {
            OAuthDetailsObservation(snapshot: snapshot, observedAt: $0)
        }
        let usableReadings = readings.map {
            usableReading($0, asOf: now, thresholds: thresholds)
        }
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: `fetchAll` is public and
        // maps 1:1 over a caller-supplied account list, so a duplicate account key
        // (two config dirs sharing a basename) would otherwise trap mid-poll.
        var byKey = Dictionary(
            usableReadings.map { ($0.accountKey, $0) }, uniquingKeysWith: { a, _ in a })
        let readingsByKey = byKey
        var snap = snapshot

        if var accounts = snap.accounts, !accounts.isEmpty {
            var replacedCachedAccountKeys: Set<String> = []
            for index in accounts.indices {
                guard let reading = byKey.removeValue(forKey: accounts[index].id) else {
                    continue
                }
                if snap.state.isStale,
                    shouldReplaceCachedAccount(accounts[index], with: reading)
                {
                    accounts[index] = replacingCachedOAuthFields(
                        in: accounts[index], from: reading)
                    replacedCachedAccountKeys.insert(accounts[index].id)
                } else {
                    accounts[index] = filled(
                        accounts[index], from: reading, now: now, thresholds: thresholds)
                }
            }
            accounts.append(
                contentsOf: byKey.values.sorted { $0.accountKey < $1.accountKey }
                    .map { newAccount(from: $0) })
            snap.accounts = sorted(accounts)
            if let activeAccount = accounts.first(where: \.isActive),
                let reading = readingsByKey[activeAccount.id]
            {
                if replacedCachedAccountKeys.contains(activeAccount.id) {
                    replaceCachedTopLevelOAuthFields(in: &snap, from: activeAccount)
                } else {
                    repairExpiredTopLevelWindows(
                        in: &snap, from: reading, now: now, thresholds: thresholds)
                }
            }
            return normalizingActiveOAuthDetails(
                in: snap,
                topLevel: topLevelOAuthDetails,
                readingsByKey: readingsByKey,
                now: now,
                thresholds: thresholds)
        }

        // `accounts == nil` is the historical shape for one default `claude`
        // statusline account. Keep that identity even when only a secondary OAuth
        // request succeeds. Otherwise the secondary account would become active
        // and could repair the default account's top-level windows.
        let defaultReading = byKey.removeValue(forKey: "claude")
        guard !byKey.isEmpty else {
            if let defaultReading {
                let defaultAccount = accountFromTopLevelSnapshot(snap)
                if snap.state.isStale,
                    shouldReplaceCachedAccount(defaultAccount, with: defaultReading)
                {
                    replaceCachedTopLevelOAuthFields(
                        in: &snap,
                        from: replacingCachedOAuthFields(
                            in: defaultAccount, from: defaultReading))
                } else {
                    repairExpiredTopLevelWindows(
                        in: &snap, from: defaultReading, now: now, thresholds: thresholds)
                }
            }
            return normalizingActiveOAuthDetails(
                in: snap,
                topLevel: topLevelOAuthDetails,
                readingsByKey: readingsByKey,
                now: now,
                thresholds: thresholds)
        }

        var defaultAccount = accountFromTopLevelSnapshot(snap)
        var replacedCachedDefault = false
        if let defaultReading {
            if snap.state.isStale,
                shouldReplaceCachedAccount(defaultAccount, with: defaultReading)
            {
                defaultAccount = replacingCachedOAuthFields(
                    in: defaultAccount, from: defaultReading)
                replacedCachedDefault = true
            } else {
                defaultAccount = filled(
                    defaultAccount, from: defaultReading, now: now, thresholds: thresholds)
            }
        }
        var accounts = [defaultAccount]
        accounts.append(
            contentsOf: byKey.values.sorted { $0.accountKey < $1.accountKey }
                .map { newAccount(from: $0) })
        snap.accounts = sorted(accounts)
        if let defaultReading {
            if replacedCachedDefault {
                replaceCachedTopLevelOAuthFields(in: &snap, from: defaultAccount)
            } else {
                repairExpiredTopLevelWindows(
                    in: &snap, from: defaultReading, now: now, thresholds: thresholds)
            }
        }
        return normalizingActiveOAuthDetails(
            in: snap,
            topLevel: topLevelOAuthDetails,
            readingsByKey: readingsByKey,
            now: now,
            thresholds: thresholds)
    }

    /// The active account can have two complete OAuth-details observations: the
    /// refreshable single-slot request and the per-account request. Keep one
    /// complete value so nil fields from the newer response clear older data.
    private struct OAuthDetailsObservation {
        let observedAt: Date
        let plan: String?
        let opus: LimitWindow?
        let scopedWeekly: [ScopedLimitWindow]?
        let extraUsage: ExtraUsage?

        init(snapshot: ClaudeUsageSnapshot, observedAt: Date) {
            self.observedAt = observedAt
            self.plan = snapshot.account?.plan
            self.opus = snapshot.limits.currentWeekOpus
            self.scopedWeekly = snapshot.limits.scopedWeekly
            self.extraUsage = snapshot.limits.extraUsage
        }

        init(reading: OAuthAccountReading) {
            self.observedAt = reading.fetchedAt
            self.plan = reading.plan
            self.opus = reading.limits.currentWeekOpus
            self.scopedWeekly = reading.limits.scopedWeekly
            self.extraUsage = reading.limits.extraUsage
        }
    }

    private static func normalizingActiveOAuthDetails(
        in snapshot: ClaudeUsageSnapshot,
        topLevel: OAuthDetailsObservation?,
        readingsByKey: [String: OAuthAccountReading],
        now: Date,
        thresholds: UsageThresholds
    ) -> ClaudeUsageSnapshot {
        let activeAccountKey: String
        if let accounts = snapshot.accounts, !accounts.isEmpty {
            guard let active = accounts.first(where: \.isActive) else { return snapshot }
            activeAccountKey = active.id
        } else {
            activeAccountKey = "claude"
        }

        let perAccount = readingsByKey[activeAccountKey].map(OAuthDetailsObservation.init)
        let newest: OAuthDetailsObservation?
        switch (topLevel, perAccount) {
        case (.some(let topLevel), .some(let perAccount)):
            // The per-account request runs after enrichment. Prefer it when both
            // responses have the same observation time.
            newest = topLevel.observedAt > perAccount.observedAt ? topLevel : perAccount
        case (.some(let topLevel), .none):
            newest = topLevel
        case (.none, .some(let perAccount)):
            newest = perAccount
        case (.none, .none):
            newest = nil
        }
        guard let newest else { return snapshot }

        var normalized = snapshot
        normalized.account = replacingPlan(newest.plan, in: normalized.account)
        normalized.limits.currentWeekOpus = newest.opus
        normalized.limits.scopedWeekly = newest.scopedWeekly
        normalized.limits.extraUsage = newest.extraUsage
        normalized.state.severity = severity(
            for: normalized.limits, thresholds: thresholds, now: now)

        if var accounts = normalized.accounts,
            let activeIndex = accounts.firstIndex(where: \.isActive)
        {
            accounts[activeIndex].account = replacingPlan(
                newest.plan, in: accounts[activeIndex].account)
            accounts[activeIndex].limits.currentWeekOpus = newest.opus
            accounts[activeIndex].limits.scopedWeekly = newest.scopedWeekly
            accounts[activeIndex].limits.extraUsage = newest.extraUsage
            accounts[activeIndex].severity = severity(
                for: accounts[activeIndex].limits,
                thresholds: thresholds,
                now: now)
            normalized.accounts = accounts
        }
        return normalized
    }

    private static func replacingPlan(_ plan: String?, in account: AccountInfo?) -> AccountInfo? {
        var updated = account ?? AccountInfo()
        updated.plan = plan
        return updated.isEmpty ? nil : updated
    }

    /// A retained per-account reading becomes stale when a later poll cannot
    /// replace it. After one of its rolling windows resets, the old percentage
    /// cannot describe the new window. Clear that percentage before it reaches a
    /// snapshot, and keep the stored severity coherent with the usable windows.
    private static func usableReading(
        _ reading: OAuthAccountReading,
        asOf now: Date,
        thresholds: UsageThresholds
    ) -> OAuthAccountReading {
        func usableWindow(_ window: LimitWindow) -> LimitWindow {
            guard let resetAt = window.resetsAt,
                reading.fetchedAt < resetAt,
                resetAt <= now
            else { return window }
            return LimitWindow()
        }
        let source = reading.limits
        let limits = LimitInfo(
            currentSession: usableWindow(source.currentSession),
            currentWeekAllModels: usableWindow(source.currentWeekAllModels),
            currentWeekOpus: source.currentWeekOpus.map(usableWindow),
            scopedWeekly: source.scopedWeekly?.map {
                ScopedLimitWindow(id: $0.id, window: usableWindow($0.window))
            },
            extraUsage: source.extraUsage)
        let severity = limits.bindingWindows.reduce(UsageSeverity.unknown) { current, descriptor in
            UsageSeverity.highest(
                current,
                thresholds.severity(for: descriptor.window.percentUsed))
        }
        return OAuthAccountReading(
            accountKey: reading.accountKey,
            label: reading.label,
            email: reading.email,
            plan: reading.plan,
            organizationId: reading.organizationId,
            limits: limits,
            severity: severity,
            fetchedAt: reading.fetchedAt)
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

    private static func filled(
        _ existing: AccountUsage,
        from reading: OAuthAccountReading,
        now: Date,
        thresholds: UsageThresholds
    ) -> AccountUsage {
        var account = existing
        var info = account.account ?? AccountInfo()
        if info.email == nil { info.email = reading.email }
        if info.plan == nil { info.plan = reading.plan }
        if info.organization == nil { info.organization = reading.organizationId }
        if info.loginMethod == nil { info.loginMethod = "OAuth" }
        account.account = info.isEmpty ? nil : info
        var replacedExpiredWindow = false
        if let existingOpus = account.limits.currentWeekOpus,
            shouldReplaceExpiredWindow(
                existingOpus,
                with: reading.limits.currentWeekOpus,
                fetchedAt: reading.fetchedAt,
                now: now)
        {
            account.limits.currentWeekOpus = reading.limits.currentWeekOpus
            replacedExpiredWindow = true
        } else if account.limits.currentWeekOpus == nil {
            account.limits.currentWeekOpus = reading.limits.currentWeekOpus
        }
        if account.limits.scopedWeekly == nil {
            account.limits.scopedWeekly = reading.limits.scopedWeekly
        }
        if account.limits.extraUsage == nil {
            account.limits.extraUsage = reading.limits.extraUsage
        }
        if shouldReplaceExpiredWindow(
            account.limits.currentSession,
            with: reading.limits.currentSession,
            fetchedAt: reading.fetchedAt,
            now: now)
        {
            account.limits.currentSession = reading.limits.currentSession
            replacedExpiredWindow = true
        } else if account.limits.currentSession.percentUsed == nil {
            account.limits.currentSession = reading.limits.currentSession
        }
        if shouldReplaceExpiredWindow(
            account.limits.currentWeekAllModels,
            with: reading.limits.currentWeekAllModels,
            fetchedAt: reading.fetchedAt,
            now: now)
        {
            account.limits.currentWeekAllModels = reading.limits.currentWeekAllModels
            replacedExpiredWindow = true
        } else if account.limits.currentWeekAllModels.percentUsed == nil {
            account.limits.currentWeekAllModels = reading.limits.currentWeekAllModels
        }
        if replacedExpiredWindow { account.lastSuccessfulPollAt = reading.fetchedAt }
        account.severity = severity(for: account.limits, thresholds: thresholds, now: now)
        return account
    }

    private static func shouldReplaceCachedAccount(
        _ existing: AccountUsage,
        with reading: OAuthAccountReading
    ) -> Bool {
        guard let existingObservation = existing.lastSuccessfulPollAt else { return true }
        return reading.fetchedAt > existingObservation
    }

    private static func replacingCachedOAuthFields(
        in existing: AccountUsage,
        from reading: OAuthAccountReading
    ) -> AccountUsage {
        var account = existing
        account.account = oauthAccountInfo(from: reading)
        account.limits = reading.limits
        account.lastSuccessfulPollAt = reading.fetchedAt
        account.severity = reading.severity
        return account
    }

    private static func replaceCachedTopLevelOAuthFields(
        in snapshot: inout ClaudeUsageSnapshot,
        from account: AccountUsage
    ) {
        snapshot.account = account.account
        snapshot.limits = account.limits
        snapshot.lastSuccessfulPollAt = account.lastSuccessfulPollAt
        snapshot.state.severity = account.severity
    }

    private static func repairExpiredTopLevelWindows(
        in snapshot: inout ClaudeUsageSnapshot,
        from reading: OAuthAccountReading,
        now: Date,
        thresholds: UsageThresholds
    ) {
        var replaced = false
        if shouldReplaceExpiredWindow(
            snapshot.limits.currentSession,
            with: reading.limits.currentSession,
            fetchedAt: reading.fetchedAt,
            now: now)
        {
            snapshot.limits.currentSession = reading.limits.currentSession
            replaced = true
        }
        if shouldReplaceExpiredWindow(
            snapshot.limits.currentWeekAllModels,
            with: reading.limits.currentWeekAllModels,
            fetchedAt: reading.fetchedAt,
            now: now)
        {
            snapshot.limits.currentWeekAllModels = reading.limits.currentWeekAllModels
            replaced = true
        }
        if let existingOpus = snapshot.limits.currentWeekOpus,
            shouldReplaceExpiredWindow(
                existingOpus,
                with: reading.limits.currentWeekOpus,
                fetchedAt: reading.fetchedAt,
                now: now)
        {
            snapshot.limits.currentWeekOpus = reading.limits.currentWeekOpus
            replaced = true
        }
        guard replaced else { return }
        snapshot.lastSuccessfulPollAt = reading.fetchedAt
        snapshot.state.severity = severity(
            for: snapshot.limits, thresholds: thresholds, now: now)
    }

    private static func shouldReplaceExpiredWindow(
        _ existing: LimitWindow,
        with candidate: LimitWindow?,
        fetchedAt: Date,
        now: Date
    ) -> Bool {
        guard let resetAt = existing.resetsAt,
            resetAt <= now,
            fetchedAt >= resetAt,
            candidate?.percentUsed != nil
        else { return false }
        return true
    }

    private static func severity(
        for limits: LimitInfo,
        thresholds: UsageThresholds,
        now: Date
    ) -> UsageSeverity {
        limits.bindingWindows.reduce(.unknown) { current, descriptor in
            UsageSeverity.highest(
                current,
                thresholds.severity(for: descriptor.window.resolved(asOf: now).percentUsed))
        }
    }

    private static func newAccount(from reading: OAuthAccountReading) -> AccountUsage {
        AccountUsage(
            id: reading.accountKey,
            label: reading.label,
            account: oauthAccountInfo(from: reading),
            limits: reading.limits,
            lastSuccessfulPollAt: reading.fetchedAt,
            severity: reading.severity,
            isActive: false)
    }

    private static func oauthAccountInfo(from reading: OAuthAccountReading) -> AccountInfo {
        AccountInfo(
            loginMethod: "OAuth",
            organization: reading.organizationId,
            email: reading.email,
            plan: reading.plan)
    }

    private static func accountFromTopLevelSnapshot(
        _ snapshot: ClaudeUsageSnapshot
    ) -> AccountUsage {
        AccountUsage(
            id: "claude",
            label: "default",
            account: snapshot.account,
            session: snapshot.session,
            limits: snapshot.limits,
            lastSuccessfulPollAt: snapshot.lastSuccessfulPollAt,
            severity: snapshot.state.severity,
            isActive: true)
    }

    private static func sorted(_ accounts: [AccountUsage]) -> [AccountUsage] {
        accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.id < rhs.id
        }
    }
}
