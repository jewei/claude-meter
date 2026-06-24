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
    // In-memory cache survives token refresh within a session even if Keychain write fails.
    private let stateQueue = DispatchQueue(label: "com.jewei.claudemeter.oauth-pipeline.state")
    private var cachedCredentials: OAuthCredentials? = nil
    // When Anthropic returns 429, back off until this time before calling the API
    // again (honoring Retry-After when present). Falling through to the fallback
    // pipeline meanwhile avoids hammering the endpoint and earning a longer block.
    private var blockedUntil: Date? = nil

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
        guard !oauthMode.isEmpty else {
            return try await fallback.poll(now: now)
        }

        // Honor an active 429 backoff: skip the API and serve the fallback.
        if isRateLimited(now: now) {
            return try await fallback.poll(now: now)
        }

        let sourceCreds: OAuthCredentials? = oauthMode == "manual"
            ? OAuthKeychain.loadManual()
            : OAuthKeychain.load()
        guard let loaded = cachedCredentialsValue() ?? sourceCreds else {
            return try await fallback.poll(now: now)
        }
        var creds = loaded

        if creds.isExpired {
            guard let refreshed = try? await refreshToken(creds) else {
                setCachedCredentials(nil)
                return try await fallback.poll(now: now)
            }
            creds = refreshed
            setCachedCredentials(refreshed)
            if oauthMode == "manual" {
                OAuthKeychain.saveManual(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken)
            }
        }

        let plan = ClaudePlan.displayName(subscriptionType: creds.subscriptionType)
        do {
            return try await fetchAndBuild(token: creds.accessToken, plan: plan, now: now)
        } catch OAuthError.unauthorized {
            // Token rejected despite appearing valid — attempt one refresh.
            guard let refreshed = try? await refreshToken(creds) else {
                setCachedCredentials(nil)
                return try await fallback.poll(now: now)
            }
            setCachedCredentials(refreshed)
            if oauthMode == "manual" {
                OAuthKeychain.saveManual(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken)
            }
            if let result = try? await fetchAndBuild(token: refreshed.accessToken, plan: plan, now: now) {
                return result
            }
            return try await fallback.poll(now: now)
        } catch {
            return try await fallback.poll(now: now)
        }
    }

    private func cachedCredentialsValue() -> OAuthCredentials? {
        stateQueue.sync { cachedCredentials }
    }

    private func setCachedCredentials(_ credentials: OAuthCredentials?) {
        stateQueue.sync { cachedCredentials = credentials }
    }

    /// True while a prior 429 backoff is still in effect.
    private func isRateLimited(now: Date) -> Bool {
        stateQueue.sync {
            guard let until = blockedUntil else { return false }
            if now >= until { blockedUntil = nil; return false }
            return true
        }
    }

    private func recordRateLimit(retryAfter: Date?, now: Date) {
        stateQueue.sync {
            blockedUntil = retryAfter ?? now.addingTimeInterval(Self.defaultRateLimitBackoff)
        }
    }

    // MARK: - Settings verification

    public static func verify(credentials: OAuthCredentials) async throws -> (sessionPct: Double, weekPct: Double) {
        var creds = credentials
        if creds.isExpired {
            creds = try await verifyRefresh(creds)
        }
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await transport.send(request)
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OAuthError.unauthorized }
            throw OAuthError.httpError(http.statusCode)
        }
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        return verificationPercentages(from: usage)
    }

    internal static func verificationPercentages(from usage: UsageResponse) -> (sessionPct: Double, weekPct: Double) {
        (
            usage.fiveHour?.utilization ?? 0,
            usage.sevenDay?.utilization ?? 0
        )
    }

    // MARK: - Enrichment

    /// OAuth-only fields the statusline and claude.ai sources can't provide.
    public struct OAuthEnrichment: Sendable, Equatable {
        public let opus: LimitWindow?
        public let extraUsage: ExtraUsage?
        public let plan: String?

        public var isEmpty: Bool { opus == nil && extraUsage == nil && plan == nil }
    }

    /// Best-effort fetch of the Opus weekly window, extra-usage spend, and plan
    /// from the OAuth usage API — used to enrich a snapshot produced by another
    /// source (e.g. the statusline bridge, which omits these). Returns `nil` when
    /// OAuth isn't configured or the call fails; never throws.
    public static func fetchEnrichment(now: Date = Date()) async -> OAuthEnrichment? {
        let oauthMode = UserDefaults.standard.string(forKey: AppGroupConfig.oauthModeKey) ?? ""
        guard !oauthMode.isEmpty else { return nil }
        let sourceCreds = oauthMode == "manual" ? OAuthKeychain.loadManual() : OAuthKeychain.load()
        guard var creds = sourceCreds else { return nil }
        if creds.isExpired {
            guard let refreshed = try? await verifyRefresh(creds) else { return nil }
            creds = OAuthCredentials(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt,
                subscriptionType: creds.subscriptionType
            )
        }
        guard let usage = try? await requestUsage(token: creds.accessToken) else { return nil }
        let opus = usage.sevenDayOpus.flatMap { entry -> LimitWindow? in
            guard let u = entry.utilization else { return nil }
            return LimitWindow(percentUsed: u, resetsAt: entry.resetsAt.flatMap(parseDate)).resolved(asOf: now)
        }
        let enrichment = OAuthEnrichment(
            opus: opus,
            extraUsage: usage.extraUsage?.model,
            plan: ClaudePlan.displayName(
                subscriptionType: creds.subscriptionType,
                rateLimitTier: nil
            )
        )
        return enrichment.isEmpty ? nil : enrichment
    }

    /// Shared static usage GET (no instance rate-limit gate). Used by `verify` and
    /// `fetchEnrichment`.
    private static func requestUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await transport.send(request)
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OAuthError.unauthorized }
            throw OAuthError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    private static func verifyRefresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
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
            throw OAuthError.refreshFailed
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthCredentials(
            accessToken: resp.accessToken,
            refreshToken: resp.refreshToken ?? credentials.refreshToken,
            expiresAt: Date().addingTimeInterval(Double(resp.expiresIn))
        )
    }

    // MARK: - API calls

    private func fetchAndBuild(token: String, plan: String?, now: Date) async throws -> ParseResult {
        let usage = try await fetchUsage(token: token, now: now)
        let snapshot = buildSnapshot(usage: usage, plan: plan, now: now)
        try? store.writeLatest(snapshot)
        try? store.clearLastError()
        return ParseResult(
            snapshot: snapshot,
            warnings: [],
            errors: [],
            rawHash: "",
            parserVersion: "oauth-api-1.0"
        )
    }

    private func fetchUsage(token: String, now: Date) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await Self.transport.send(request)
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OAuthError.unauthorized }
            if http.statusCode == 429 {
                recordRateLimit(retryAfter: Self.retryAfterDate(from: http, now: now), now: now)
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
        guard let raw = (response.value(forHTTPHeaderField: "Retry-After"))?
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

    private func refreshToken(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": Self.oauthClientId,
        ])
        let (data, http) = try await Self.transport.send(request)
        guard http.statusCode == 200 else {
            throw OAuthError.refreshFailed
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthCredentials(
            accessToken: resp.accessToken,
            refreshToken: resp.refreshToken ?? credentials.refreshToken,
            expiresAt: Date().addingTimeInterval(Double(resp.expiresIn))
        )
    }

    // MARK: - Snapshot builder

    private func buildSnapshot(usage: UsageResponse, plan: String?, now: Date) -> ClaudeUsageSnapshot {
        let sessionWindow = Self.window(from: usage.fiveHour)
        let weekWindow = Self.window(from: usage.sevenDay)
        let opusWindow = usage.sevenDayOpus.map { Self.window(from: $0) }
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
                extraUsage: extra
            ),
            state: SnapshotState(status: .ok, severity: severity)
        )
    }

    /// Builds a `LimitWindow` from a quota entry, dropping `nil` utilization to an
    /// empty (unknown) window rather than fabricating 0%.
    private static func window(from entry: QuotaEntry?) -> LimitWindow {
        guard let entry, let utilization = entry.utilization else { return LimitWindow() }
        return LimitWindow(percentUsed: utilization, resetsAt: entry.resetsAt.flatMap(parseDate))
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

// MARK: - Errors

enum OAuthError: Error {
    case unauthorized
    case rateLimited
    case invalidResponse
    case httpError(Int)
    case refreshFailed
}

// MARK: - Codable models

internal struct UsageResponse: Decodable {
    let fiveHour: QuotaEntry?
    let sevenDay: QuotaEntry?
    /// Weekly Opus-only window — often the binding limit for Max subscribers.
    let sevenDayOpus: QuotaEntry?
    let extraUsage: ExtraUsageEntry?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
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
