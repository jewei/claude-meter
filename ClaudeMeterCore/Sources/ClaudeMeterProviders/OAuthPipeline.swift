import ClaudeMeterCore
import Foundation

/// Pipeline that fetches rate-limit data from the Anthropic OAuth usage API using
/// Claude Code's own credentials stored in the macOS Keychain.
///
/// Transparently refreshes the access token when expired. Falls through to `fallback`
/// on any error so callers never see an OAuth-specific failure.
public final class OAuthPipeline: ClaudeMeterPipeline, @unchecked Sendable {

    private let fallback: any ClaudeMeterPipeline
    private let store: SnapshotStore
    private let thresholds: UsageThresholds

    /// Default backoff when a 429 carries no usable `Retry-After`. Matches the
    /// app's 60 s poll cadence so we retry on the next cycle.
    private static let defaultRateLimitBackoff: TimeInterval = 60

    // Requests go through the shared redirect-guarded transport (no cookies, 10 s
    // timeout) so a Bearer token can't leak across an off-origin redirect.
    private static let transport: any HTTPTransport = ProviderHTTPClient.shared

    private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    public init(
        fallback: any ClaudeMeterPipeline,
        store: SnapshotStore,
        thresholds: UsageThresholds = .default
    ) {
        self.fallback = fallback
        self.store = store
        self.thresholds = thresholds
    }

    public func poll(now: Date) async throws -> ParseResult {
        let oauthMode = UserDefaults.standard.string(forKey: AppGroupConfig.oauthModeKey) ?? ""
        guard oauthMode == "auto" || oauthMode == "manual" else {
            // The source toggle is ON (or we wouldn't be in the chain) but Connect
            // was never completed — "disabled" would send the user to the wrong fix.
            return try await fallbackResult(now: now, outcome: .skipped, reason: .notConnected)
        }

        // Honor an active 429 backoff: skip the API and serve the fallback.
        if OAuthSharedState.isRateLimited(now: now) {
            return try await fallbackResult(now: now, outcome: .skipped, reason: .rateLimited)
        }

        let keychainResult =
            oauthMode == "manual"
            ? OAuthKeychain.loadManualResult()
            : OAuthKeychain.loadResult()
        guard var creds = Self.credentials(from: keychainResult, oauthMode: oauthMode) else {
            let reason: SourceAttempt.Reason
            switch keychainResult {
            case .missing: reason = .credentialsMissing
            case .temporarilyUnavailable: reason = .credentialsUnavailable
            case .invalid: reason = .credentialsInvalid
            case .found: reason = .credentialsInvalid
            }
            return try await fallbackResult(now: now, outcome: .skipped, reason: reason)
        }

        var didRefresh = false
        if creds.isExpired {
            guard OAuthRefreshGate.shouldAttempt(refreshToken: creds.refreshToken, now: now) else {
                return try await fallbackResult(
                    now: now, outcome: .skipped, reason: .refreshDeferred)
            }
            let refreshed: OAuthCredentials
            do {
                refreshed = try await Self.coalescedRefresh(creds)
            } catch OAuthError.refreshRejected {
                OAuthRefreshGate.recordTerminal(refreshToken: creds.refreshToken)
                OAuthSharedState.setCachedCredentials(nil, for: oauthMode)
                return try await fallbackResult(
                    now: now, outcome: .failed, reason: .refreshRejected)
            } catch {
                OAuthRefreshGate.recordTransient(now: now)
                OAuthSharedState.setCachedCredentials(nil, for: oauthMode)
                return try await fallbackResult(
                    now: now, outcome: .failed, reason: .refreshFailed)
            }
            OAuthRefreshGate.recordSuccess()
            didRefresh = true
            creds = refreshed
            OAuthSharedState.setCachedCredentials(refreshed, for: oauthMode)
            if oauthMode == "manual" {
                OAuthKeychain.saveManual(
                    accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken)
            }
        }

        let plan = ClaudePlan.displayName(
            subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier)
        do {
            return try await fetchAndBuild(token: creds.accessToken, plan: plan, now: now)
        } catch OAuthError.unauthorized {
            // Token rejected despite appearing valid — attempt one refresh, unless we
            // already refreshed this poll (a freshly-refreshed token that still 401s
            // won't be fixed by an immediate second refresh).
            guard !didRefresh else {
                return try await fallbackResult(
                    now: now, outcome: .failed, reason: .unauthorized)
            }
            guard OAuthRefreshGate.shouldAttempt(refreshToken: creds.refreshToken, now: now) else {
                return try await fallbackResult(
                    now: now, outcome: .skipped, reason: .refreshDeferred)
            }
            let refreshed: OAuthCredentials
            do {
                refreshed = try await Self.coalescedRefresh(creds)
            } catch OAuthError.refreshRejected {
                OAuthRefreshGate.recordTerminal(refreshToken: creds.refreshToken)
                OAuthSharedState.setCachedCredentials(nil, for: oauthMode)
                return try await fallbackResult(
                    now: now, outcome: .failed, reason: .refreshRejected)
            } catch {
                OAuthRefreshGate.recordTransient(now: now)
                OAuthSharedState.setCachedCredentials(nil, for: oauthMode)
                return try await fallbackResult(
                    now: now, outcome: .failed, reason: .refreshFailed)
            }
            OAuthRefreshGate.recordSuccess()
            OAuthSharedState.setCachedCredentials(refreshed, for: oauthMode)
            if oauthMode == "manual" {
                OAuthKeychain.saveManual(
                    accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken)
            }
            let refreshedPlan = ClaudePlan.displayName(
                subscriptionType: refreshed.subscriptionType,
                rateLimitTier: refreshed.rateLimitTier)
            if let result = try? await fetchAndBuild(
                token: refreshed.accessToken, plan: refreshedPlan, now: now)
            {
                return result
            }
            return try await fallbackResult(
                now: now, outcome: .failed, reason: .unauthorized)
        } catch {
            return try await fallbackResult(
                now: now, outcome: .failed, reason: Self.attemptReason(for: error))
        }
    }

    private func fallbackResult(
        now: Date,
        outcome: SourceAttempt.Outcome,
        reason: SourceAttempt.Reason
    ) async throws -> ParseResult {
        try await fallback.poll(now: now).prependingSourceAttempt(
            SourceAttempt(source: .oauth, outcome: outcome, reason: reason))
    }

    private static func attemptReason(for error: Error) -> SourceAttempt.Reason {
        if let oauthError = error as? OAuthError {
            switch oauthError {
            case .rateLimited: return .rateLimited
            case .unauthorized: return .unauthorized
            case .refreshRejected: return .refreshRejected
            case .refreshFailed: return .refreshFailed
            case .httpError: return .requestFailed
            case .invalidResponse: return .invalidResponse
            }
        }
        if error is URLError { return .networkError }
        if error is DecodingError { return .invalidResponse }
        return .requestFailed
    }

    /// Resolves Keychain read into credentials, preferring in-memory cache on a
    /// transient lock so a momentary Keychain block doesn't look like "missing".
    static func credentials(
        from result: KeychainReadResult<OAuthCredentials>,
        oauthMode: String
    ) -> OAuthCredentials? {
        switch result {
        case .found(let creds):
            // Prefer a non-expired in-memory credential over an expired Keychain one.
            // After an (in-memory-only) auto refresh the Keychain still holds the old
            // refresh token, which Anthropic may have rotated/invalidated — using it
            // would fail and terminally gate. The cache carries the live token. When
            // Claude Code refreshes the Keychain itself, that entry is non-expired and
            // still wins.
            if creds.isExpired,
                let cached = OAuthSharedState.cachedCredentials(for: oauthMode), !cached.isExpired
            {
                return cached
            }
            return creds
        case .temporarilyUnavailable: return OAuthSharedState.cachedCredentials(for: oauthMode)
        case .missing, .invalid: return nil
        }
    }

    /// Clears in-memory OAuth tokens when the user disconnects or switches away
    /// from OAuth, so refreshed credentials cannot outlive the selected source.
    public static func clearCachedCredentials() {
        OAuthSharedState.clearCachedCredentials()
    }

    static func setCachedCredentialsForTesting(
        _ credentials: OAuthCredentials?,
        oauthMode: String
    ) {
        OAuthSharedState.setCachedCredentials(credentials, for: oauthMode)
    }

    // MARK: - Settings verification

    public static func verify(credentials: OAuthCredentials) async throws -> (
        sessionPct: Double, weekPct: Double
    ) {
        var creds = credentials
        if creds.isExpired {
            creds = try await coalescedRefresh(creds)
        }
        let (data, http) = try await transport.send(usageRequest(token: creds.accessToken))
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OAuthError.unauthorized }
            throw OAuthError.httpError(http.statusCode)
        }
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        return verificationPercentages(from: usage)
    }

    internal static func verificationPercentages(from usage: UsageResponse) -> (
        sessionPct: Double, weekPct: Double
    ) {
        (
            usage.fiveHour?.utilization ?? 0,
            usage.sevenDay?.utilization ?? 0
        )
    }

    // MARK: - Enrichment

    /// OAuth-only fields the statusline and claude.ai sources can't provide.
    public struct OAuthEnrichment: Sendable, Equatable {
        public let opus: LimitWindow?
        public let scopedWeekly: [ScopedLimitWindow]?
        public let extraUsage: ExtraUsage?
        public let plan: String?

        public var isEmpty: Bool {
            opus == nil && scopedWeekly == nil && extraUsage == nil && plan == nil
        }
    }

    /// Best-effort fetch of the Opus weekly window, extra-usage spend, and plan
    /// from the OAuth usage API — used to enrich a snapshot produced by another
    /// source (e.g. the statusline bridge, which omits these). Returns `nil` when
    /// OAuth isn't configured or the call fails; never throws.
    public static func fetchEnrichment(now: Date = Date()) async -> OAuthEnrichment? {
        let oauthMode = UserDefaults.standard.string(forKey: AppGroupConfig.oauthModeKey) ?? ""
        guard oauthMode == "auto" || oauthMode == "manual" else { return nil }
        guard !OAuthSharedState.isRateLimited(now: now) else { return nil }
        let keychainResult =
            oauthMode == "manual"
            ? OAuthKeychain.loadManualResult()
            : OAuthKeychain.loadResult()
        guard var creds = credentials(from: keychainResult, oauthMode: oauthMode) else {
            return nil
        }
        if creds.isExpired {
            guard OAuthRefreshGate.shouldAttempt(refreshToken: creds.refreshToken, now: now) else {
                return nil
            }
            let refreshed: OAuthCredentials
            do {
                refreshed = try await coalescedRefresh(creds)
            } catch OAuthError.refreshRejected {
                OAuthRefreshGate.recordTerminal(refreshToken: creds.refreshToken)
                return nil
            } catch {
                OAuthRefreshGate.recordTransient(now: now)
                return nil
            }
            OAuthRefreshGate.recordSuccess()
            creds = OAuthCredentials(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt,
                subscriptionType: creds.subscriptionType,
                rateLimitTier: creds.rateLimitTier
            )
            OAuthSharedState.setCachedCredentials(creds, for: oauthMode)
            if oauthMode == "manual" {
                OAuthKeychain.saveManual(
                    accessToken: creds.accessToken, refreshToken: creds.refreshToken)
            }
        }
        guard let usage = try? await requestUsage(token: creds.accessToken, now: now) else {
            return nil
        }
        let opus = usage.sevenDayOpus.flatMap { entry -> LimitWindow? in
            guard let u = entry.utilization else { return nil }
            return LimitWindow(percentUsed: u, resetsAt: parseEpochOrISODate(entry.resetsAt))
                .resolved(asOf: now)
        }
        let enrichment = OAuthEnrichment(
            opus: opus,
            scopedWeekly: scopedWindows(from: usage),
            extraUsage: usage.extraUsage?.model,
            plan: ClaudePlan.displayName(
                subscriptionType: creds.subscriptionType,
                rateLimitTier: creds.rateLimitTier
            )
        )
        return enrichment.isEmpty ? nil : enrichment
    }

    /// Backoff bridge for the multi-account fetcher (`OAuthSharedState` is private).
    static func isRateLimited(now: Date) -> Bool {
        OAuthSharedState.isRateLimited(now: now)
    }

    static func recordRateLimit(retryAfter: Date?, now: Date) {
        OAuthSharedState.recordRateLimit(retryAfter: retryAfter, now: now)
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
    static func coalescedRefresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        try await OAuthRefreshCoordinator.refresh(token: credentials.refreshToken) {
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
        return OAuthCredentials(
            accessToken: resp.accessToken,
            refreshToken: resp.refreshToken ?? credentials.refreshToken,
            expiresAt: Date().addingTimeInterval(Double(resp.expiresIn)),
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

    private func fetchAndBuild(token: String, plan: String?, now: Date) async throws -> ParseResult
    {
        let usage = try await fetchUsage(token: token, now: now)
        let snapshot = buildSnapshot(usage: usage, plan: plan, now: now)
        try? store.writeLatest(snapshot)
        try? store.clearLastError()
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

    private func fetchUsage(token: String, now: Date) async throws -> UsageResponse {
        let (data, http) = try await Self.transport.send(Self.usageRequest(token: token))
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OAuthError.unauthorized }
            if http.statusCode == 429 {
                OAuthSharedState.recordRateLimit(
                    retryAfter: Self.retryAfterDate(from: http, now: now),
                    now: now
                )
                throw OAuthError.rateLimited
            }
            throw OAuthError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    /// The usage endpoint is Claude Code-internal; identify as the CLI so Anthropic
    /// doesn't reject an unrecognized client. Version is best-effort insurance.
    static let userAgent = "claude-code/2.1.0"

    /// Parses a `Retry-After` header (delta-seconds or HTTP-date). Returns the
    /// absolute time to resume, or `nil` when absent/unparseable.
    static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard
            let raw = (response.value(forHTTPHeaderField: "Retry-After"))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
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

enum OAuthError: Error {
    case unauthorized
    case rateLimited
    case invalidResponse
    case httpError(Int)
    /// Transient refresh failure (network / 5xx) — safe to retry with backoff.
    case refreshFailed
    /// Terminal refresh rejection (`invalid_grant`) — the refresh token is dead
    /// (e.g. user ran `claude logout`); don't retry until credentials change.
    case refreshRejected
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
        sevenDayOpus = try? container.decodeIfPresent(
            QuotaEntry.self, forKey: DynamicKey("seven_day_opus"))
        extraUsage = try? container.decodeIfPresent(
            ExtraUsageEntry.self, forKey: DynamicKey("extra_usage"))
        let claimed: Set<String> = ["five_hour", "seven_day", "seven_day_opus", "extra_usage"]
        scopedWeekly = container.allKeys
            .filter { $0.stringValue.hasPrefix("seven_day_") && !claimed.contains($0.stringValue) }
            .compactMap { key in
                ((try? container.decodeIfPresent(QuotaEntry.self, forKey: key)) ?? nil)
                    .map { (key.stringValue, $0) }
            }
            .sorted { $0.0 < $1.0 }
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
    private static let lock = NSLock()
    private static nonisolated(unsafe) var blockedUntil: Date?
    private static nonisolated(unsafe) var cachedCredsByMode: [String: OAuthCredentials] = [:]

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
        blockedUntil = retryAfter ?? now.addingTimeInterval(60)
        lock.unlock()
    }

    static func cachedCredentials(for oauthMode: String) -> OAuthCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return cachedCredsByMode[oauthMode]
    }

    static func setCachedCredentials(_ credentials: OAuthCredentials?, for oauthMode: String) {
        lock.lock()
        if let credentials {
            cachedCredsByMode[oauthMode] = credentials
        } else {
            cachedCredsByMode[oauthMode] = nil
        }
        lock.unlock()
    }

    static func clearCachedCredentials() {
        lock.lock()
        cachedCredsByMode.removeAll()
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

    /// Whether a refresh of `refreshToken` may be attempted as of `now`.
    static func shouldAttempt(refreshToken: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if deadRefreshToken == refreshToken { return false }
        if let until = transientBlockedUntil, now < until { return false }
        return true
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

/// Coalesces concurrent token refreshes that share the same refresh token into a
/// single in-flight request, so a rotating refresh token is consumed exactly once.
/// Process-wide and lock-guarded, mirroring `OAuthSharedState`.
enum OAuthRefreshCoordinator {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var inFlight: [String: Task<OAuthCredentials, Error>] = [:]

    private enum Acquisition {
        case joined(Task<OAuthCredentials, Error>)
        case owned(Task<OAuthCredentials, Error>)
    }

    /// Runs `perform` for `token`, or — if a refresh of the same token is already
    /// running — joins it and returns its result. The check-and-register is atomic
    /// under one lock hold, so exactly one `perform` runs per token at a time. The
    /// lock is only ever held in synchronous helpers, never across the `await`.
    static func refresh(
        token: String,
        perform: @escaping @Sendable () async throws -> OAuthCredentials
    ) async throws -> OAuthCredentials {
        switch acquire(token: token, perform: perform) {
        case .joined(let existing):
            return try await existing.value
        case .owned(let task):
            defer { release(token: token, task: task) }
            return try await task.value
        }
    }

    private static func acquire(
        token: String,
        perform: @escaping @Sendable () async throws -> OAuthCredentials
    ) -> Acquisition {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[token] { return .joined(existing) }
        let task = Task { try await perform() }  // scheduled, not awaited under lock
        inFlight[token] = task
        return .owned(task)
    }

    /// Clear only if still ours, so a newer refresh that replaced us survives.
    private static func release(token: String, task: Task<OAuthCredentials, Error>) {
        lock.lock()
        if inFlight[token] == task { inFlight[token] = nil }
        lock.unlock()
    }

    static func resetForTesting() {
        lock.lock()
        inFlight.removeAll()
        lock.unlock()
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
