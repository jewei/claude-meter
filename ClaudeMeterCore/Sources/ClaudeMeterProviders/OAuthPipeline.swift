import ClaudeMeterCore
import Foundation

private enum ClaudeOAuthMode: String {
    case auto
    case manual
}

/// Pipeline that fetches rate-limit data from the Anthropic OAuth usage API using
/// Claude Code's own credentials stored in the macOS Keychain.
///
/// Transparently refreshes the access token when expired. Falls through to `fallback`
/// on any error so callers never see an OAuth-specific failure.
public final class OAuthPipeline: ClaudeMeterPipeline, @unchecked Sendable {

    private enum RefreshAttempt {
        case ready(OAuthCredentials)
        case deferred(SourceAttempt.Reason)
        case failed(SourceAttempt.Reason)
    }

    private let fallback: any ClaudeMeterPipeline
    private let thresholds: UsageThresholds

    /// Default backoff when a 429 carries no usable `Retry-After`. Matches the
    /// app's 60 s poll cadence so we retry on the next cycle.
    fileprivate static let defaultRateLimitBackoff: TimeInterval = 60
    /// An implausible server directive must not disable OAuth for the lifetime of
    /// a long-running app process. Observed valid backoffs are about one hour.
    static let maximumRateLimitBackoff: TimeInterval = 24 * 60 * 60

    // Requests go through the shared redirect-guarded transport (no cookies, 10 s
    // timeout) so a Bearer token can't leak across an off-origin redirect.
    //
    // Computed rather than stored so tests can substitute a stub (see
    // `setTransportForTesting`). Production always resolves to
    // `ProviderHTTPClient.shared` — the override is nil unless a test sets it.
    private static var transport: any HTTPTransport { OAuthSharedState.transport() }

    private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Bound an untrusted `expires_in` without losing a successfully rotated
    /// refresh-token chain. Anthropic normally returns one hour.
    static let minimumTokenLifetimeSeconds = 5 * 60
    static let maximumTokenLifetimeSeconds = 7 * 24 * 60 * 60
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    public init(
        fallback: any ClaudeMeterPipeline,
        store _: SnapshotStore,
        thresholds: UsageThresholds = .default
    ) {
        self.fallback = fallback
        self.thresholds = thresholds
    }

    /// `kind` changes nothing here — it is forwarded to the fallback only. The 429
    /// gate below protects Anthropic, not our request budget, so a user-initiated
    /// refresh must not be able to jump it.
    public func poll(now: Date, kind: RefreshKind = .background) async throws -> ParseResult {
        let oauthMode = UserDefaults.standard.string(forKey: AppGroupConfig.oauthModeKey) ?? ""
        guard let mode = ClaudeOAuthMode(rawValue: oauthMode) else {
            // The source toggle is ON (or we wouldn't be in the chain) but Connect
            // was never completed — "disabled" would send the user to the wrong fix.
            return try await fallbackResult(
                kind: kind, now: now, outcome: .skipped, reason: .notConnected)
        }

        // Honor an active 429 backoff: skip the API and serve the fallback.
        if OAuthSharedState.isRateLimited(now: now) {
            return try await fallbackResult(
                kind: kind, now: now, outcome: .skipped, reason: .rateLimited)
        }

        let keychainResult = Self.loadCredentialResult(for: mode)
        guard
            let credentialSelection = OAuthSharedState.credentialSelection(
                from: keychainResult, oauthMode: mode.rawValue)
        else {
            let reason = Self.keychainFailureReason(keychainResult)
            return try await fallbackResult(kind: kind, now: now, outcome: .skipped, reason: reason)
        }
        var creds = credentialSelection.credentials

        var didRefresh = false
        if creds.isExpired(asOf: now) {
            switch await Self.refreshCredentials(
                creds,
                mode: mode,
                lease: credentialSelection.lease,
                sourceRefreshToken: credentialSelection.sourceRefreshToken,
                now: now)
            {
            case .ready(let refreshed):
                creds = refreshed
            case .deferred(let reason):
                return try await fallbackResult(
                    kind: kind, now: now, outcome: .skipped, reason: reason)
            case .failed(let reason):
                return try await fallbackResult(
                    kind: kind, now: now, outcome: .failed, reason: reason)
            }
            didRefresh = true
        }

        let plan = ClaudePlan.displayName(
            subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier)
        do {
            return try await fetchAndBuild(
                token: creds.accessToken,
                plan: plan,
                now: now,
                mode: mode,
                lease: credentialSelection.lease,
                sourceRefreshToken: credentialSelection.sourceRefreshToken)
        } catch OAuthError.credentialSourceChanged {
            return try await fallbackResult(
                kind: kind, now: now, outcome: .skipped, reason: .notConnected)
        } catch OAuthError.unauthorized {
            // Token rejected despite appearing valid — attempt one refresh, unless we
            // already refreshed this poll (a freshly-refreshed token that still 401s
            // won't be fixed by an immediate second refresh).
            guard !didRefresh else {
                return try await fallbackResult(
                    kind: kind, now: now, outcome: .failed, reason: .unauthorized)
            }
            let refreshed: OAuthCredentials
            switch await Self.refreshCredentials(
                creds,
                mode: mode,
                lease: credentialSelection.lease,
                sourceRefreshToken: credentialSelection.sourceRefreshToken,
                now: now)
            {
            case .ready(let value): refreshed = value
            case .deferred(let reason):
                return try await fallbackResult(
                    kind: kind, now: now, outcome: .skipped, reason: reason)
            case .failed(let reason):
                return try await fallbackResult(
                    kind: kind, now: now, outcome: .failed, reason: reason)
            }
            let refreshedPlan = ClaudePlan.displayName(
                subscriptionType: refreshed.subscriptionType,
                rateLimitTier: refreshed.rateLimitTier)
            do {
                return try await fetchAndBuild(
                    token: refreshed.accessToken,
                    plan: refreshedPlan,
                    now: now,
                    mode: mode,
                    lease: credentialSelection.lease,
                    sourceRefreshToken: credentialSelection.sourceRefreshToken)
            } catch OAuthError.credentialSourceChanged {
                return try await fallbackResult(
                    kind: kind, now: now, outcome: .skipped, reason: .notConnected)
            } catch {
                return try await fallbackResult(
                    kind: kind, now: now, outcome: .failed, reason: Self.attemptReason(for: error))
            }
        } catch {
            return try await fallbackResult(
                kind: kind, now: now, outcome: .failed, reason: Self.attemptReason(for: error))
        }
    }

    private func fallbackResult(
        kind: RefreshKind,
        now: Date,
        outcome: SourceAttempt.Outcome,
        reason: SourceAttempt.Reason
    ) async throws -> ParseResult {
        try await fallback.poll(now: now, kind: kind).prependingSourceAttempt(
            SourceAttempt(source: .oauth, outcome: outcome, reason: reason))
    }

    private static func attemptReason(for error: Error) -> SourceAttempt.Reason {
        if let oauthError = error as? OAuthError {
            switch oauthError {
            case .rateLimited: return .rateLimited
            case .unauthorized: return .unauthorized
            case .refreshRejected: return .refreshRejected
            case .refreshFailed: return .refreshFailed
            case .credentialSourceChanged: return .notConnected
            case .httpError: return .requestFailed
            }
        }
        if error is URLError { return .networkError }
        if error is DecodingError { return .invalidResponse }
        return .requestFailed
    }

    /// One refresh state machine shared by normal polling, 401 recovery, and
    /// enrichment. In particular, every failure clears the cached token chain.
    private static func refreshCredentials(
        _ credentials: OAuthCredentials,
        mode: ClaudeOAuthMode,
        lease: OAuthSharedState.CredentialLease,
        sourceRefreshToken: String,
        now: Date
    ) async -> RefreshAttempt {
        guard OAuthRefreshGate.shouldAttempt(refreshToken: credentials.refreshToken, now: now)
        else {
            return .deferred(
                OAuthRefreshGate.deferredReason(refreshToken: credentials.refreshToken, now: now))
        }
        do {
            let refreshed = try await coalescedRefresh(credentials, lease: lease)
            guard
                Self.automaticSourceIsStillCurrent(
                    mode: mode,
                    lease: lease,
                    sourceRefreshToken: sourceRefreshToken)
            else { return .deferred(.notConnected) }
            guard
                (try? OAuthSharedState.completeRefreshSuccess(
                    refreshed,
                    for: mode.rawValue,
                    lease: lease,
                    sourceRefreshToken: sourceRefreshToken,
                    requireManualPersistence: false)) == true
            else { return .deferred(.notConnected) }
            OAuthRefreshCoordinator.adopted(
                credentialRevision: lease.revision,
                token: credentials.refreshToken)
            return .ready(refreshed)
        } catch OAuthError.refreshRejected {
            guard
                Self.automaticSourceIsStillCurrent(
                    mode: mode,
                    lease: lease,
                    sourceRefreshToken: sourceRefreshToken)
            else { return .deferred(.notConnected) }
            guard
                OAuthSharedState.completeRefreshFailure(
                    for: mode.rawValue,
                    lease: lease,
                    sourceRefreshToken: sourceRefreshToken,
                    failure: .terminal(refreshToken: sourceRefreshToken))
            else { return .deferred(.notConnected) }
            return .failed(.refreshRejected)
        } catch {
            guard
                Self.automaticSourceIsStillCurrent(
                    mode: mode,
                    lease: lease,
                    sourceRefreshToken: sourceRefreshToken)
            else { return .deferred(.notConnected) }
            guard
                OAuthSharedState.completeRefreshFailure(
                    for: mode.rawValue,
                    lease: lease,
                    sourceRefreshToken: sourceRefreshToken,
                    failure: .transient(now: now))
            else { return .deferred(.notConnected) }
            return .failed(.refreshFailed)
        }
    }

    private static func loadCredentialResult(
        for mode: ClaudeOAuthMode
    ) -> KeychainReadResult<OAuthCredentials> {
        switch mode {
        case .auto: OAuthSharedState.loadAutomaticCredentialResult()
        case .manual: OAuthKeychain.loadManualResult()
        }
    }

    /// A process-local generation cannot observe an external Claude Code login by
    /// itself. Re-read the automatic source after the refresh suspension and stop
    /// the old chain before it can commit or supply a usage request.
    private static func automaticSourceIsStillCurrent(
        mode: ClaudeOAuthMode,
        lease: OAuthSharedState.CredentialLease,
        sourceRefreshToken: String
    ) -> Bool {
        guard mode == .auto else { return true }
        return OAuthSharedState.validateAutomaticCredentialSource(
            OAuthSharedState.loadAutomaticCredentialResult(),
            expectedRefreshToken: sourceRefreshToken,
            lease: lease)
    }

    /// Resolves Keychain read into credentials, preferring in-memory cache on a
    /// transient lock so a momentary Keychain block doesn't look like "missing".
    static func credentials(
        from result: KeychainReadResult<OAuthCredentials>,
        oauthMode: String
    ) -> OAuthCredentials? {
        OAuthSharedState.credentialSelection(from: result, oauthMode: oauthMode)?.credentials
    }

    /// Clears in-memory OAuth tokens when the user disconnects or switches away
    /// from OAuth, so refreshed credentials cannot outlive the selected source.
    public static func clearCachedCredentials() {
        OAuthSharedState.revokeCachedCredentials()
    }

    /// Disconnects the selected OAuth source as one credential-state mutation.
    /// Manual Keychain deletion, mode clearing, and refresh revocation share the
    /// same lock, so an older in-flight refresh cannot recreate deleted state.
    public static func disconnect(oauthMode: String) throws {
        try OAuthSharedState.disconnect(oauthMode: oauthMode)
    }

    /// Removes a manual credential candidate after verification fails. This uses
    /// the same generation boundary as Disconnect, so an older refresh cannot
    /// save or cache the credential again after cleanup.
    public static func discardManualCredentials() throws {
        try OAuthSharedState.discardManualCredentials()
    }

    /// Replaces app-owned manual credentials and invalidates refreshes that began
    /// with the prior token chain.
    public static func saveManualCredentials(accessToken: String, refreshToken: String) throws {
        try OAuthSharedState.replaceManualCredentials(
            accessToken: accessToken, refreshToken: refreshToken)
    }

    static func setCachedCredentialsForTesting(
        _ credentials: OAuthCredentials?,
        oauthMode: String,
        sourceRefreshToken: String? = nil
    ) {
        OAuthSharedState.setCachedCredentials(
            credentials, for: oauthMode, sourceRefreshToken: sourceRefreshToken)
    }

    /// Substitutes the HTTP transport for the whole module. Pass `nil` to restore
    /// the shared client — always do so in a `defer`, since the override is
    /// process-wide and would otherwise leak into unrelated tests.
    static func setTransportForTesting(_ transport: (any HTTPTransport)?) {
        OAuthSharedState.setTransportOverride(transport)
    }

    static func setManualCredentialPersistenceForTesting(
        save: (@Sendable (String, String) throws -> Void)?,
        delete: (@Sendable () throws -> Void)?
    ) {
        OAuthSharedState.setManualCredentialPersistenceOverride(
            save: save, delete: delete)
    }

    static func setAutomaticCredentialLoaderForTesting(
        _ loader: (@Sendable () -> KeychainReadResult<OAuthCredentials>)?
    ) {
        OAuthSharedState.setAutomaticCredentialLoadOverride(loader)
    }

    static func clearRateLimitForTesting() {
        OAuthSharedState.clearRateLimit()
    }

    // MARK: - Settings verification

    /// Verifies credentials by calling the usage API once, refreshing first when
    /// they're expired. `oauthMode` names the slot the rotated credential is cached
    /// under — required, because Anthropic rotates the refresh token on every
    /// refresh: dropping the rotated one here would leave the Keychain holding a
    /// consumed token, so the very next poll would `invalid_grant` and terminally
    /// gate the account moments after a "successful" Connect.
    public static func verify(credentials: OAuthCredentials, oauthMode: String = "auto")
        async throws -> (sessionPct: Double, weekPct: Double)
    {
        try await verifyResolvedCredentials(
            credentials,
            oauthMode: oauthMode,
            beforeRefreshCoordinator: nil)
    }

    /// Test seam that suspends after credential selection but before refresh
    /// coordinator acquisition. This makes preselection races deterministic.
    static func verifyAfterCredentialSelectionForTesting(
        credentials: OAuthCredentials,
        oauthMode: String = "auto",
        beforeRefreshCoordinator: @escaping @Sendable () async -> Void
    ) async throws -> (sessionPct: Double, weekPct: Double) {
        try await verifyResolvedCredentials(
            credentials,
            oauthMode: oauthMode,
            beforeRefreshCoordinator: beforeRefreshCoordinator)
    }

    private static func verifyResolvedCredentials(
        _ credentials: OAuthCredentials,
        oauthMode: String,
        beforeRefreshCoordinator: (@Sendable () async -> Void)?
    ) async throws -> (sessionPct: Double, weekPct: Double) {
        let now = Date()
        guard !OAuthSharedState.isRateLimited(now: now) else { throw OAuthError.rateLimited }

        guard
            let credentialSelection = OAuthSharedState.credentialSelection(
                from: .found(credentials), oauthMode: oauthMode)
        else { throw CancellationError() }
        var creds = credentialSelection.credentials
        if creds.isExpired(asOf: now) {
            let refreshToken = creds.refreshToken
            creds = try await coalescedRefresh(
                creds,
                lease: credentialSelection.lease,
                beforeCoordinator: beforeRefreshCoordinator)
            guard
                try OAuthSharedState.completeRefreshSuccess(
                    creds,
                    for: oauthMode,
                    lease: credentialSelection.lease,
                    sourceRefreshToken: credentialSelection.sourceRefreshToken,
                    requireManualPersistence: true)
            else { throw CancellationError() }
            OAuthRefreshCoordinator.adopted(
                credentialRevision: credentialSelection.lease.revision,
                token: refreshToken)
        }
        // Refresh can take several seconds. Use a fresh timestamp for the request
        // gate and any Retry-After value returned by the server.
        let usage = try await requestUsage(token: creds.accessToken)
        return verificationPercentages(from: usage)
    }

    internal static func verificationPercentages(from usage: UsageResponse) -> (
        sessionPct: Double, weekPct: Double
    ) {
        (
            LimitWindow(percentUsed: usage.fiveHour?.utilization).clampedPercent ?? 0,
            LimitWindow(percentUsed: usage.sevenDay?.utilization).clampedPercent ?? 0
        )
    }

    // MARK: - Enrichment

    /// A complete observation of the OAuth-only fields the statusline source cannot
    /// provide. A non-`nil` enrichment means the request succeeded, so optional
    /// fields that are `nil` must clear older values. `fetchEnrichment` reserves its
    /// outer `nil` for "no new observation" (disabled, unavailable, or failed).
    public struct OAuthEnrichment: Sendable, Equatable {
        public let opus: LimitWindow?
        public let scopedWeekly: [ScopedLimitWindow]?
        public let extraUsage: ExtraUsage?
        public let plan: String?

        public init(
            opus: LimitWindow?,
            scopedWeekly: [ScopedLimitWindow]?,
            extraUsage: ExtraUsage?,
            plan: String?
        ) {
            self.opus = opus
            self.scopedWeekly = scopedWeekly
            self.extraUsage = extraUsage
            self.plan = plan
        }
    }

    /// Typed result for the auxiliary enrichment request. Unlike the optional
    /// convenience API, this retains why no new observation was available so the
    /// app can mark a cached enrichment stale without marking the primary
    /// statusline snapshot stale too.
    public enum OAuthEnrichmentFetchResult: Sendable, Equatable {
        case success(OAuthEnrichment)
        case unavailable(SourceAttempt.Reason)
    }

    /// Best-effort fetch of the Opus weekly window, extra-usage spend, and plan
    /// from the OAuth usage API — used to enrich a snapshot produced by another
    /// source (e.g. the statusline bridge, which omits these). Returns `nil` when
    /// OAuth isn't configured or the call fails; never throws.
    public static func fetchEnrichment(now: Date = Date()) async -> OAuthEnrichment? {
        guard case .success(let enrichment) = await fetchEnrichmentResult(now: now) else {
            return nil
        }
        return enrichment
    }

    /// Detailed enrichment fetch used by lifecycle-aware callers. A successful
    /// response remains `.success` even when every optional field is absent: that
    /// is an explicit empty observation, not a failure.
    public static func fetchEnrichmentResult(
        now: Date = Date()
    ) async -> OAuthEnrichmentFetchResult {
        let oauthMode = UserDefaults.standard.string(forKey: AppGroupConfig.oauthModeKey) ?? ""
        guard let mode = ClaudeOAuthMode(rawValue: oauthMode) else {
            return .unavailable(.notConnected)
        }
        guard !OAuthSharedState.isRateLimited(now: now) else {
            return .unavailable(.rateLimited)
        }
        let keychainResult = loadCredentialResult(for: mode)
        guard
            let credentialSelection = OAuthSharedState.credentialSelection(
                from: keychainResult, oauthMode: oauthMode)
        else {
            return .unavailable(keychainFailureReason(keychainResult))
        }
        var creds = credentialSelection.credentials
        if creds.isExpired(asOf: now) {
            switch await refreshCredentials(
                creds,
                mode: mode,
                lease: credentialSelection.lease,
                sourceRefreshToken: credentialSelection.sourceRefreshToken,
                now: now)
            {
            case .ready(let refreshed):
                creds = OAuthCredentials(
                    accessToken: refreshed.accessToken,
                    refreshToken: refreshed.refreshToken,
                    expiresAt: refreshed.expiresAt,
                    subscriptionType: creds.subscriptionType,
                    rateLimitTier: creds.rateLimitTier
                )
            case .deferred(let reason), .failed(let reason):
                return .unavailable(reason)
            }
        }
        let usage: UsageResponse
        do {
            usage = try await requestUsage(token: creds.accessToken, now: now)
        } catch {
            return .unavailable(attemptReason(for: error))
        }
        guard
            automaticSourceIsStillCurrent(
                mode: mode,
                lease: credentialSelection.lease,
                sourceRefreshToken: credentialSelection.sourceRefreshToken)
        else { return .unavailable(.notConnected) }
        let opus = usage.sevenDayOpus.flatMap { entry -> LimitWindow? in
            guard let u = entry.utilization else { return nil }
            return LimitWindow(percentUsed: u, resetsAt: parseEpochOrISODate(entry.resetsAt))
                .resolved(asOf: now)
        }
        return .success(
            OAuthEnrichment(
                opus: opus,
                scopedWeekly: scopedWindows(from: usage),
                extraUsage: usage.extraUsage?.model,
                plan: ClaudePlan.displayName(
                    subscriptionType: creds.subscriptionType,
                    rateLimitTier: creds.rateLimitTier
                )
            )
        )
    }

    private static func keychainFailureReason(
        _ result: KeychainReadResult<OAuthCredentials>
    ) -> SourceAttempt.Reason {
        switch result {
        case .missing: .credentialsMissing
        case .temporarilyUnavailable: .credentialsUnavailable
        case .invalid, .found: .credentialsInvalid
        }
    }

    /// Backoff bridge for the multi-account fetcher (`OAuthSharedState` is private).
    static func isRateLimited(now: Date) -> Bool {
        OAuthSharedState.isRateLimited(now: now)
    }

    static func recordRateLimit(retryAfter: Date?, now: Date) {
        OAuthSharedState.recordRateLimit(retryAfter: retryAfter, now: now)
    }

    /// When an active 429 backoff lifts, or `nil` when we aren't throttled.
    /// Read-only — unlike `isRateLimited(now:)` this never clears an elapsed
    /// gate, so the UI can poll it without mutating pipeline state.
    public static func rateLimitedUntil(now: Date = Date()) -> Date? {
        OAuthSharedState.blockedUntilIfActive(now: now)
    }

    /// Builds the authenticated GET for the usage API (shared header setup).
    static func usageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Shared usage GET. Honors the process-wide 429 backoff used by `poll` and
    /// `fetchEnrichment`.
    private static func requestUsage(token: String, now: Date = Date()) async throws
        -> UsageResponse
    {
        guard !OAuthSharedState.isRateLimited(now: now) else { throw OAuthError.rateLimited }

        let (data, http) = try await transport.send(usageRequest(token: token))
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OAuthError.unauthorized }
            if http.statusCode == 429 {
                OAuthSharedState.recordRateLimit(
                    retryAfter: retryAfterDate(from: http, now: now),
                    now: now
                )
                throw OAuthError.rateLimited
            }
            throw OAuthError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    /// Refreshes the access token, **coalescing concurrent refreshes of the same
    /// refresh token into one network request** (single-flight).
    ///
    /// Anthropic *rotates* the refresh token on each refresh, so two overlapping
    /// refreshes of the same token — `poll` + `fetchEnrichment`, or a wake/reconnect
    /// `refreshNow` racing the poll loop — would have the second send an
    /// already-consumed token and get `invalid_grant`, terminally gating the account
    /// until it changes (a spurious "logged out"). Coalescing makes the second caller
    /// await the first's result and reuse the rotated token instead.
    private static func coalescedRefresh(
        _ credentials: OAuthCredentials,
        lease: OAuthSharedState.CredentialLease,
        beforeCoordinator: (@Sendable () async -> Void)? = nil
    ) async throws -> OAuthCredentials {
        if let beforeCoordinator { await beforeCoordinator() }
        return try await OAuthRefreshCoordinator.refresh(
            credentialRevision: lease.revision,
            token: credentials.refreshToken
        ) {
            try await performTokenRefresh(credentials)
        }
    }

    /// The actual token-endpoint POST. Always go through `coalescedRefresh`, never
    /// this directly, so concurrent refreshes share one request.
    private static func performTokenRefresh(_ credentials: OAuthCredentials) async throws
        -> OAuthCredentials
    {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": oauthClientId,
        ])
        let (data, http) = try await transport.send(request)
        guard http.statusCode == 200 else {
            throw isInvalidGrant(data: data, status: http.statusCode)
                ? OAuthError.refreshRejected : OAuthError.refreshFailed
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !resp.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            resp.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        else { throw OAuthError.refreshFailed }
        let lifetime = min(
            max(resp.expiresIn, minimumTokenLifetimeSeconds),
            maximumTokenLifetimeSeconds)
        guard
            let expiresAt = boundedProviderDate(
                timeIntervalSince1970: Date().timeIntervalSince1970 + Double(lifetime))
        else { throw OAuthError.refreshFailed }
        return OAuthCredentials(
            accessToken: resp.accessToken,
            refreshToken: resp.refreshToken ?? credentials.refreshToken,
            expiresAt: expiresAt,
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier
        )
    }

    /// Classifies a non-200 token-endpoint response as a terminal `invalid_grant`
    /// (dead refresh token) vs a transient failure, by inspecting the JSON body.
    static func isInvalidGrant(data: Data, status: Int) -> Bool {
        guard status == 400 || status == 401 || status == 403 else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let error = (obj["error"] as? String) ?? (obj["error_description"] as? String) ?? ""
        return error.localizedCaseInsensitiveContains("invalid_grant")
    }

    // MARK: - API calls

    private func fetchAndBuild(
        token: String,
        plan: String?,
        now: Date,
        mode: ClaudeOAuthMode,
        lease: OAuthSharedState.CredentialLease,
        sourceRefreshToken: String
    ) async throws -> ParseResult {
        let usage = try await Self.requestUsage(token: token, now: now)
        guard
            Self.automaticSourceIsStillCurrent(
                mode: mode,
                lease: lease,
                sourceRefreshToken: sourceRefreshToken)
        else { throw OAuthError.credentialSourceChanged }
        let snapshot = buildSnapshot(usage: usage, plan: plan, now: now)
        return ParseResult(
            snapshot: snapshot,
            warnings: [],
            errors: [],
            rawHash: "",
            parserVersion: "oauth-api-1.0",
            sourceAttempts: [
                SourceAttempt(source: .oauth, outcome: .selected, reason: .freshData)
            ]
        )
    }

    /// The usage endpoint is Claude Code-internal; identify as the CLI so Anthropic
    /// doesn't reject an unrecognized client. Version is best-effort insurance.
    static let userAgent = "claude-code/2.1.0"

    /// Absolute time to resume from a `Retry-After` header, or `nil` when absent,
    /// unparseable, or in the past. Delegates to the transport's single parser so
    /// the two `Retry-After` readers in this module can't drift apart.
    static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard
            let seconds = HTTPRetryPolicy.retryAfterSeconds(
                response.value(forHTTPHeaderField: "Retry-After"), now: now)
        else { return nil }
        return now.addingTimeInterval(min(seconds, maximumRateLimitBackoff))
    }

    // MARK: - Snapshot builder

    private func buildSnapshot(usage: UsageResponse, plan: String?, now: Date)
        -> ClaudeUsageSnapshot
    {
        let sessionWindow = Self.window(from: usage.fiveHour)
        let weekWindow = Self.window(from: usage.sevenDay)
        let opusWindow = usage.sevenDayOpus.map { Self.window(from: $0) }
        let scoped = Self.scopedWindows(from: usage)
        let extra = usage.extraUsage.map(\.model)

        // The binding limit can be any window; aggregate all reported percentages
        // (including Opus weekly) so the menu-bar icon reflects the real ceiling.
        let severity = [
            usage.fiveHour?.utilization,
            usage.sevenDay?.utilization,
            usage.sevenDayOpus?.utilization,
        ].reduce(UsageSeverity.unknown) { UsageSeverity.highest($0, thresholds.severity(for: $1)) }

        return ClaudeUsageSnapshot(
            parserVersion: "oauth-api-1.0",
            createdAt: now,
            lastSuccessfulPollAt: now,
            source: SourceInfo(cliPath: "api.anthropic.com", command: "GET /api/oauth/usage"),
            account: plan.map { AccountInfo(loginMethod: "OAuth", plan: $0) },
            limits: LimitInfo(
                currentSession: sessionWindow,
                currentWeekAllModels: weekWindow,
                currentWeekOpus: opusWindow,
                scopedWeekly: scoped,
                extraUsage: extra
            ),
            state: SnapshotState(status: .ok, severity: severity)
        )
    }

    /// Builds a `LimitWindow` from a quota entry, dropping `nil` utilization to an
    /// empty (unknown) window rather than fabricating 0%.
    private static func window(from entry: QuotaEntry?) -> LimitWindow {
        guard let entry, let utilization = entry.utilization else { return LimitWindow() }
        return LimitWindow(percentUsed: utilization, resetsAt: parseEpochOrISODate(entry.resetsAt))
    }

    /// Scoped `seven_day_<scope>` windows with real data; nil-utilization entries
    /// (empty/unused scopes) are dropped rather than shown as unknown rows.
    static func scopedWindows(from usage: UsageResponse) -> [ScopedLimitWindow]? {
        let scoped = usage.scopedWeekly.compactMap { key, entry -> ScopedLimitWindow? in
            guard entry.utilization != nil else { return nil }
            return ScopedLimitWindow(id: key, window: Self.window(from: entry))
        }
        return scoped.isEmpty ? nil : scoped
    }
}

// MARK: - Errors

enum OAuthError: LocalizedError {
    case unauthorized
    case rateLimited
    case httpError(Int)
    /// Transient refresh failure (network / 5xx) — safe to retry with backoff.
    case refreshFailed
    /// Terminal refresh rejection (`invalid_grant`) — the refresh token is dead
    /// (e.g. user ran `claude logout`); don't retry until credentials change.
    case refreshRejected
    /// The automatic Keychain source changed while a request was suspended.
    case credentialSourceChanged

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Claude Code sign-in was rejected — run `claude auth login`, then retry"
        case .rateLimited:
            "Anthropic is rate-limiting usage checks — retrying automatically"
        case .httpError(let status):
            "Anthropic usage check failed (HTTP \(status))"
        case .refreshFailed:
            "Claude Code sign-in could not be refreshed — try again shortly"
        case .refreshRejected:
            "Claude Code sign-in expired — run `claude auth login`, then retry"
        case .credentialSourceChanged:
            "Claude Code sign-in changed during the usage check"
        }
    }
}

// MARK: - Codable models

internal struct UsageResponse: Decodable {
    let fiveHour: QuotaEntry?
    let sevenDay: QuotaEntry?
    /// Weekly Opus-only window — often the binding limit for Max subscribers.
    let sevenDayOpus: QuotaEntry?
    let extraUsage: ExtraUsageEntry?
    /// Any other `seven_day_<scope>` windows (sonnet, cowork, …), key-sorted.
    /// Keys with a non-quota shape are skipped rather than failing the decode.
    let scopedWeekly: [(key: String, entry: QuotaEntry)]

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        fiveHour = try? container.decodeIfPresent(QuotaEntry.self, forKey: DynamicKey("five_hour"))
        sevenDay = try? container.decodeIfPresent(QuotaEntry.self, forKey: DynamicKey("seven_day"))
        extraUsage = try? container.decodeIfPresent(
            ExtraUsageEntry.self, forKey: DynamicKey("extra_usage"))

        // Model-scoped weekly windows are migrating from dedicated
        // `seven_day_<model>` fields to entries in the generic `limits` array, and
        // the flat fields have been observed going null as that happens. Derive the
        // same `(key, entry)` shape from `limits` so the rest of the pipeline —
        // `opusWindow`, `scopedWindows`, enrichment — needs no knowledge of which
        // form the server used. Flat fields always win; `limits` only fills gaps.
        let derived = Self.scopedEntriesFromLimits(
            (try? container.decodeIfPresent([LimitEntry].self, forKey: DynamicKey("limits"))) ?? nil
        )

        let flatOpus = try? container.decodeIfPresent(
            QuotaEntry.self, forKey: DynamicKey("seven_day_opus"))
        sevenDayOpus = flatOpus ?? derived["seven_day_opus"]

        let claimed: Set<String> = ["five_hour", "seven_day", "seven_day_opus", "extra_usage"]
        let flatScoped = container.allKeys
            .filter { $0.stringValue.hasPrefix("seven_day_") && !claimed.contains($0.stringValue) }
            .compactMap { key in
                ((try? container.decodeIfPresent(QuotaEntry.self, forKey: key)) ?? nil)
                    .map { (key.stringValue, $0) }
            }
        let flatKeys = Set(flatScoped.map(\.0)).union(claimed)
        scopedWeekly = (flatScoped + derived.filter { !flatKeys.contains($0.key) }.map { ($0, $1) })
            .sorted { $0.0 < $1.0 }
    }

    /// Folds `limits[]` down to the `seven_day_<model>` keys the rest of the
    /// pipeline already speaks.
    ///
    /// Only `weekly_scoped` entries carry a model; `session` / `weekly_all` kinds
    /// mirror `five_hour` / `seven_day` and are skipped (extend here if those flat
    /// fields ever go null too). The key is the **first word** of the display name
    /// lowercased — "Opus 4.5" → `seven_day_opus` — so a migrated Opus window lands
    /// on exactly the key the flat field used.
    private static func scopedEntriesFromLimits(_ limits: [LimitEntry]?) -> [String: QuotaEntry] {
        var result: [String: QuotaEntry] = [:]
        for entry in limits ?? [] {
            guard entry.kind == "weekly_scoped",
                let word = entry.scope?.model?.displayName?
                    .split(separator: " ").first?.lowercased(),
                !word.isEmpty,
                let percent = entry.percent
            else { continue }
            // First entry wins, so a duplicated model can't flip between polls.
            let key = "seven_day_\(word)"
            if result[key] == nil {
                result[key] = QuotaEntry(utilization: percent, resetsAt: entry.resetsAt)
            }
        }
        return result
    }
}

/// Entry in the newer generic `limits` array. Model-scoped weekly windows appear
/// here as `kind: "weekly_scoped"` with the model under `scope`, rather than as a
/// dedicated `seven_day_<model>` field.
internal struct LimitEntry: Decodable {
    let kind: String?
    /// Percent **used** — same scale and direction as `QuotaEntry.utilization`.
    let percent: Double?
    let resetsAt: String?
    let scope: LimitScope?

    enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
    }
}

internal struct LimitScope: Decodable {
    let model: LimitScopeModel?
}

internal struct LimitScopeModel: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

internal struct QuotaEntry: Decodable {
    // Optional so a `null` (or a key the endpoint added but left empty) degrades to
    // "no data" instead of failing the whole decode.
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

internal struct ExtraUsageEntry: Decodable {
    let isEnabled: Bool?
    let usedCredits: Double?
    let monthlyLimit: Double?
    let decimalPlaces: Int?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
        case decimalPlaces = "decimal_places"
        case utilization
        case currency
    }

    var model: ExtraUsage {
        ExtraUsage(
            isEnabled: isEnabled ?? false,
            usedCredits: usedCredits,
            monthlyLimit: monthlyLimit,
            decimalPlaces: decimalPlaces ?? 2,
            utilization: utilization,
            currency: currency
        )
    }
}

// MARK: - Shared OAuth session state

/// Process-wide OAuth backoff + in-memory token cache shared by the instance
/// pipeline and static enrichment fetches.
private enum OAuthSharedState {
    struct CredentialLease: Sendable {
        fileprivate let revision: UInt64
    }

    struct CredentialSelection: Sendable {
        let credentials: OAuthCredentials
        let sourceRefreshToken: String
        let lease: CredentialLease
    }

    private struct CachedCredentialChain {
        let credentials: OAuthCredentials
        /// The Keychain refresh token from which this possibly rotated chain began.
        let sourceRefreshToken: String
    }

    enum RefreshFailure {
        case terminal(refreshToken: String)
        case transient(now: Date)
    }

    private static let lock = NSLock()
    private static nonisolated(unsafe) var blockedUntil: Date?
    private static nonisolated(unsafe) var cachedCredsByMode: [String: CachedCredentialChain] = [:]
    private static nonisolated(unsafe) var observedSourceTokensByMode: [String: String] = [:]
    private static nonisolated(unsafe) var credentialRevision: UInt64 = 0
    private static nonisolated(unsafe) var transportOverride: (any HTTPTransport)?
    private static nonisolated(unsafe) var manualCredentialSaveOverride:
        (@Sendable (String, String) throws -> Void)?
    private static nonisolated(unsafe) var manualCredentialDeleteOverride:
        (@Sendable () throws -> Void)?
    private static nonisolated(unsafe) var automaticCredentialLoadOverride:
        (@Sendable () -> KeychainReadResult<OAuthCredentials>)?

    static func isRateLimited(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = blockedUntil else { return false }
        if now >= until {
            blockedUntil = nil
            return false
        }
        return true
    }

    static func recordRateLimit(retryAfter: Date?, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        let candidate = retryAfter ?? now.addingTimeInterval(OAuthPipeline.defaultRateLimitBackoff)
        // Never shorten an active backoff. The gate is process-wide, so a second
        // 429 carrying no `Retry-After` (default 60 s) must not undo a longer
        // window an earlier response explicitly asked us to wait out.
        if let existing = blockedUntil, existing > candidate { return }
        blockedUntil = candidate
    }

    static func cachedCredentials(for oauthMode: String) -> OAuthCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return cachedCredsByMode[oauthMode]?.credentials
    }

    /// Resolves a Keychain observation and its generation lease as one atomic
    /// operation. When Claude Code replaces its token chain, this invalidates work
    /// that began from the prior chain before that work can overwrite the cache.
    static func credentialSelection(
        from result: KeychainReadResult<OAuthCredentials>,
        oauthMode: String
    ) -> CredentialSelection? {
        lock.lock()
        defer { lock.unlock() }

        let credentials: OAuthCredentials
        let sourceRefreshToken: String
        switch result {
        case .found(let source):
            if let observed = observedSourceTokensByMode[oauthMode],
                observed != source.refreshToken
            {
                credentialRevision &+= 1
                cachedCredsByMode[oauthMode] = nil
                OAuthRefreshGate.recordSuccess()
            }
            observedSourceTokensByMode[oauthMode] = source.refreshToken
            sourceRefreshToken = source.refreshToken

            // A cache entry can hold Anthropic's rotated refresh token while the
            // Keychain still holds the consumed source token. It is valid only for
            // that same source lineage. A different Keychain token is a new login
            // and must win even when an older cache has a later expiry.
            if let cached = cachedCredsByMode[oauthMode],
                cached.sourceRefreshToken == source.refreshToken,
                cached.credentials.refreshToken != source.refreshToken
                    || cached.credentials.expiresAt > source.expiresAt
            {
                credentials = cached.credentials
            } else {
                credentials = source
            }
        case .temporarilyUnavailable:
            guard let cached = cachedCredsByMode[oauthMode] else { return nil }
            credentials = cached.credentials
            sourceRefreshToken = cached.sourceRefreshToken
        case .missing, .invalid:
            return nil
        }

        return CredentialSelection(
            credentials: credentials,
            sourceRefreshToken: sourceRefreshToken,
            lease: CredentialLease(revision: credentialRevision)
        )
    }

    /// Reads Claude Code's current automatic credential source. Copy the test
    /// closure under the lock, then call it outside the lock because a loader can
    /// perform Keychain I/O.
    static func loadAutomaticCredentialResult() -> KeychainReadResult<OAuthCredentials> {
        lock.lock()
        let loader = automaticCredentialLoadOverride
        lock.unlock()
        return loader?() ?? OAuthKeychain.loadResult()
    }

    /// Confirms the automatic source after a refresh suspension. A missing,
    /// invalid, or replaced source invalidates the old lease. A temporary
    /// Keychain read failure keeps the observed lineage, as it does at poll start.
    static func validateAutomaticCredentialSource(
        _ result: KeychainReadResult<OAuthCredentials>,
        expectedRefreshToken: String,
        lease: CredentialLease
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let mode = ClaudeOAuthMode.auto.rawValue
        guard credentialRevision == lease.revision,
            observedSourceTokensByMode[mode] == expectedRefreshToken
        else { return false }

        switch result {
        case .found(let current) where current.refreshToken == expectedRefreshToken:
            return true
        case .temporarilyUnavailable:
            return true
        case .found(let current):
            credentialRevision &+= 1
            cachedCredsByMode[mode] = nil
            observedSourceTokensByMode[mode] = current.refreshToken
        case .missing, .invalid:
            credentialRevision &+= 1
            cachedCredsByMode[mode] = nil
            observedSourceTokensByMode[mode] = nil
        }
        OAuthRefreshGate.recordSuccess()
        return false
    }

    static func setCachedCredentials(
        _ credentials: OAuthCredentials?,
        for oauthMode: String,
        sourceRefreshToken: String?
    ) {
        lock.lock()
        if let credentials {
            let lineage = sourceRefreshToken ?? credentials.refreshToken
            cachedCredsByMode[oauthMode] = CachedCredentialChain(
                credentials: credentials, sourceRefreshToken: lineage)
            observedSourceTokensByMode[oauthMode] = lineage
        } else {
            cachedCredsByMode[oauthMode] = nil
            observedSourceTokensByMode[oauthMode] = nil
        }
        lock.unlock()
    }

    /// Invalidates every lease before removing the cache. A refresh that started
    /// before this call can finish its network request, but it cannot commit local
    /// credentials or refresh-gate state.
    static func revokeCachedCredentials() {
        lock.lock()
        credentialRevision &+= 1
        cachedCredsByMode.removeAll()
        observedSourceTokensByMode.removeAll()
        OAuthRefreshGate.recordSuccess()
        lock.unlock()
    }

    /// Commits all local success side effects while the credential lease is still
    /// current. Manual persistence stays under this lock so disconnect cannot
    /// delete the Keychain item between the lease check and the save.
    static func completeRefreshSuccess(
        _ credentials: OAuthCredentials,
        for oauthMode: String,
        lease: CredentialLease,
        sourceRefreshToken: String,
        requireManualPersistence: Bool
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard credentialRevision == lease.revision,
            observedSourceTokensByMode[oauthMode].map({ $0 == sourceRefreshToken }) ?? true
        else { return false }

        var storedLineage = sourceRefreshToken
        if oauthMode == ClaudeOAuthMode.manual.rawValue {
            if requireManualPersistence {
                try saveManualCredentials(credentials)
                storedLineage = credentials.refreshToken
                observedSourceTokensByMode[oauthMode] = storedLineage
            } else {
                // Polling remains best-effort: the in-memory rotated chain remains
                // usable for this process when persistence is temporarily blocked.
                if (try? saveManualCredentials(credentials)) != nil {
                    storedLineage = credentials.refreshToken
                    observedSourceTokensByMode[oauthMode] = storedLineage
                }
            }
        }
        cachedCredsByMode[oauthMode] = CachedCredentialChain(
            credentials: credentials, sourceRefreshToken: storedLineage)
        OAuthRefreshGate.recordSuccess()
        return true
    }

    /// Applies failure state only for the refresh generation that started it. A
    /// current failure also advances the generation before it clears the cache.
    /// Thus, a retained handoff from an already-consumed ancestor token cannot
    /// restore a rejected descendant chain.
    static func completeRefreshFailure(
        for oauthMode: String,
        lease: CredentialLease,
        sourceRefreshToken: String,
        failure: RefreshFailure
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard credentialRevision == lease.revision,
            observedSourceTokensByMode[oauthMode].map({ $0 == sourceRefreshToken }) ?? true
        else { return false }
        credentialRevision &+= 1
        switch failure {
        case .terminal(let refreshToken):
            OAuthRefreshGate.recordTerminal(refreshToken: refreshToken)
        case .transient(let now):
            OAuthRefreshGate.recordTransient(now: now)
        }
        cachedCredsByMode[oauthMode] = nil
        return true
    }

    /// Deletes app-owned credentials and clears the selected mode without opening
    /// a window in which an older refresh can restore either value.
    static func disconnect(oauthMode: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if oauthMode == ClaudeOAuthMode.manual.rawValue {
            if let manualCredentialDeleteOverride {
                try manualCredentialDeleteOverride()
            } else {
                try OAuthKeychain.deleteManual()
            }
        }
        UserDefaults.standard.set("", forKey: AppGroupConfig.oauthModeKey)
        credentialRevision &+= 1
        cachedCredsByMode.removeAll()
        observedSourceTokensByMode.removeAll()
        OAuthRefreshGate.recordSuccess()
    }

    /// Invalidates the candidate before deletion. Even if Keychain deletion
    /// fails, the source mode is cleared and older work cannot restore cache state.
    static func discardManualCredentials() throws {
        lock.lock()
        defer { lock.unlock() }
        credentialRevision &+= 1
        cachedCredsByMode.removeAll()
        observedSourceTokensByMode.removeAll()
        OAuthRefreshGate.recordSuccess()
        UserDefaults.standard.set("", forKey: AppGroupConfig.oauthModeKey)
        if let manualCredentialDeleteOverride {
            try manualCredentialDeleteOverride()
        } else {
            try OAuthKeychain.deleteManual()
        }
    }

    /// Writes a user-supplied token chain under the same lock used by refresh
    /// commits. A completed replacement always invalidates older refresh leases.
    static func replaceManualCredentials(accessToken: String, refreshToken: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let manualCredentialSaveOverride {
            try manualCredentialSaveOverride(accessToken, refreshToken)
        } else {
            try OAuthKeychain.saveManual(
                accessToken: accessToken, refreshToken: refreshToken)
        }
        credentialRevision &+= 1
        cachedCredsByMode.removeAll()
        observedSourceTokensByMode.removeAll()
        observedSourceTokensByMode[ClaudeOAuthMode.manual.rawValue] = refreshToken
        OAuthRefreshGate.recordSuccess()
    }

    private static func saveManualCredentials(_ credentials: OAuthCredentials) throws {
        if let manualCredentialSaveOverride {
            try manualCredentialSaveOverride(
                credentials.accessToken, credentials.refreshToken)
        } else {
            try OAuthKeychain.saveManual(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken)
        }
    }

    /// Transport used by every OAuth request. `nil` override — the production
    /// case — resolves to the shared redirect-guarded client; tests substitute a
    /// stub so the refresh and usage paths can be exercised without a network.
    static func transport() -> any HTTPTransport {
        lock.lock()
        defer { lock.unlock() }
        return transportOverride ?? ProviderHTTPClient.shared
    }

    static func setTransportOverride(_ transport: (any HTTPTransport)?) {
        lock.lock()
        transportOverride = transport
        lock.unlock()
    }

    static func setManualCredentialPersistenceOverride(
        save: (@Sendable (String, String) throws -> Void)?,
        delete: (@Sendable () throws -> Void)?
    ) {
        lock.lock()
        manualCredentialSaveOverride = save
        manualCredentialDeleteOverride = delete
        lock.unlock()
    }

    static func setAutomaticCredentialLoadOverride(
        _ loader: (@Sendable () -> KeychainReadResult<OAuthCredentials>)?
    ) {
        lock.lock()
        automaticCredentialLoadOverride = loader
        lock.unlock()
    }

    /// The active backoff deadline, or `nil` when none is in force. Deliberately
    /// non-mutating (`isRateLimited` clears an elapsed gate as a side effect), so
    /// a UI read can't disturb the pipeline's own bookkeeping.
    static func blockedUntilIfActive(now: Date) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let until = blockedUntil, now < until else { return nil }
        return until
    }

    /// Clears the 429 gate. Test-only: production reopens it by elapsing
    /// `blockedUntil`, never by fiat.
    static func clearRateLimit() {
        lock.lock()
        blockedUntil = nil
        lock.unlock()
    }
}

/// Gates background OAuth token-refresh attempts so a dead refresh token (e.g.
/// after `claude logout`) can't hammer the token endpoint every poll forever.
///
/// A terminal rejection (`invalid_grant`) blocks until the stored refresh token
/// changes — i.e. the user re-authenticates and the Keychain holds a new token,
/// which differs from the dead one, so the gate reopens automatically with no
/// manual reset. Transient failures use exponential backoff. In-memory and
/// process-wide, mirroring `OAuthSharedState` (consistent with our in-memory-only
/// refresh policy). User-initiated refreshes (`verify`) bypass this gate.
enum OAuthRefreshGate {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var deadRefreshToken: String?
    private static nonisolated(unsafe) var transientBlockedUntil: Date?
    private static nonisolated(unsafe) var transientFailureCount = 0

    static let baseTransientBackoff: TimeInterval = 5 * 60
    static let maxTransientBackoff: TimeInterval = 6 * 60 * 60

    /// Why a refresh is (or isn't) allowed right now. The distinction matters to
    /// the UI: a dead token needs the user to re-authenticate Claude Code, while a
    /// transient backoff resolves on its own.
    enum Availability: Equatable {
        case allowed
        /// This exact refresh token was rejected as `invalid_grant`. Only a new
        /// stored token reopens the gate.
        case tokenRejected
        /// Exponential backoff after transient failures.
        case backingOff
    }

    static func availability(refreshToken: String, now: Date) -> Availability {
        lock.lock()
        defer { lock.unlock() }
        if deadRefreshToken == refreshToken { return .tokenRejected }
        if let until = transientBlockedUntil, now < until { return .backingOff }
        return .allowed
    }

    /// Whether a refresh of `refreshToken` may be attempted as of `now`.
    static func shouldAttempt(refreshToken: String, now: Date) -> Bool {
        availability(refreshToken: refreshToken, now: now) == .allowed
    }

    /// The attempt reason to report when a refresh is skipped — so diagnostics and
    /// the popover can distinguish "sign-in is dead" from "we're backing off".
    static func deferredReason(refreshToken: String, now: Date) -> SourceAttempt.Reason {
        availability(refreshToken: refreshToken, now: now) == .tokenRejected
            ? .refreshRejected : .refreshDeferred
    }

    static func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        deadRefreshToken = nil
        transientBlockedUntil = nil
        transientFailureCount = 0
    }

    /// Terminal rejection: block this exact token until it changes.
    static func recordTerminal(refreshToken: String) {
        lock.lock()
        defer { lock.unlock() }
        deadRefreshToken = refreshToken
        transientBlockedUntil = nil
        transientFailureCount = 0
    }

    static func recordTransient(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        transientFailureCount += 1
        let backoff = min(
            baseTransientBackoff * pow(2, Double(transientFailureCount - 1)),
            maxTransientBackoff
        )
        transientBlockedUntil = now.addingTimeInterval(backoff)
    }

    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        deadRefreshToken = nil
        transientBlockedUntil = nil
        transientFailureCount = 0
    }
}

/// Coalesces in-flight work and retains completed results in a small LRU. Adoption
/// refreshes the LRU position but does not remove a result: a caller can select a
/// one-use token before another caller adopts its rotation, then reach this object
/// afterwards. The retained handoff lets that late caller reuse the rotation.
final class RefreshResultHandoffCoordinator<Key: Hashable & Sendable, Value: Sendable>:
    @unchecked Sendable
{
    private enum Acquisition {
        case completed(Value)
        case task(Task<Value, Error>)
    }

    private let lock = NSLock()
    private let maximumCompletedHandoffs: Int
    private var inFlight: [Key: Task<Value, Error>] = [:]
    private var completed: [Key: Value] = [:]
    /// Oldest first. The list is short and bounded, so simple removal keeps the
    /// state easy to audit and avoids another cache dependency in token code.
    private var completionOrder: [Key] = []

    init(maximumCompletedHandoffs: Int = 32) {
        precondition(maximumCompletedHandoffs > 0)
        self.maximumCompletedHandoffs = maximumCompletedHandoffs
    }

    func run(
        key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let acquisition: Acquisition = lock.withLock {
            if let value = completed[key] {
                touchCompleted(key)
                return .completed(value)
            }
            if let existing = inFlight[key] { return .task(existing) }
            let task = Task { try await operation() }
            inFlight[key] = task
            return .task(task)
        }

        switch acquisition {
        case .completed(let value):
            return value
        case .task(let task):
            return try await resolve(task, for: key)
        }
    }

    private func resolve(_ task: Task<Value, Error>, for key: Key) async throws -> Value {
        do {
            let value = try await task.value
            lock.withLock {
                // Several callers can await one task. Only its first resolver may
                // publish the handoff. A later waiter must not replace a newer task
                // for `key`, or restore a result after a test reset.
                guard inFlight[key] == task else { return }
                inFlight.removeValue(forKey: key)
                retainCompleted(value, for: key)
            }
            return value
        } catch {
            lock.withLock {
                if inFlight[key] == task { inFlight.removeValue(forKey: key) }
            }
            throw error
        }
    }

    func adopted(key: Key) {
        lock.withLock {
            guard completed[key] != nil else { return }
            touchCompleted(key)
        }
    }

    private func retainCompleted(_ value: Value, for key: Key) {
        completed[key] = value
        touchCompleted(key)
        while completionOrder.count > maximumCompletedHandoffs {
            let oldest = completionOrder.removeFirst()
            completed.removeValue(forKey: oldest)
        }
    }

    private func touchCompleted(_ key: Key) {
        completionOrder.removeAll { $0 == key }
        completionOrder.append(key)
    }

    func resetForTesting() {
        lock.withLock {
            inFlight.removeAll()
            completed.removeAll()
            completionOrder.removeAll()
        }
    }
}

/// Coalesces concurrent token refreshes that share the same refresh token into a
/// single request, so a rotating refresh token is consumed exactly once.
/// Process-wide, mirroring `OAuthSharedState`.
enum OAuthRefreshCoordinator {
    private struct Key: Hashable, Sendable {
        let credentialRevision: UInt64
        let token: String
    }

    private static let handoffs =
        RefreshResultHandoffCoordinator<Key, OAuthCredentials>()

    /// Runs `perform` for `token`, or — if a refresh of the same token is already
    /// running — joins it and returns its result. The check-and-register is atomic
    /// under one lock hold, so exactly one `perform` runs per token at a time. The
    /// lock is only ever held in synchronous helpers, never across the `await`.
    static func refresh(
        credentialRevision: UInt64,
        token: String,
        perform: @escaping @Sendable () async throws -> OAuthCredentials
    ) async throws -> OAuthCredentials {
        try await handoffs.run(
            key: Key(credentialRevision: credentialRevision, token: token),
            operation: perform)
    }

    static func adopted(credentialRevision: UInt64, token: String) {
        handoffs.adopted(key: Key(credentialRevision: credentialRevision, token: token))
    }

    static func resetForTesting() {
        handoffs.resetForTesting()
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
