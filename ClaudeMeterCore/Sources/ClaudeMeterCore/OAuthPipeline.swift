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
    private var cachedCredentials: OAuthCredentials? = nil

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

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
        let oauthMode = UserDefaults.standard.string(forKey: "oauthMode") ?? ""
        guard !oauthMode.isEmpty else {
            return try await fallback.poll(now: now)
        }

        let sourceCreds: OAuthCredentials? = oauthMode == "manual"
            ? OAuthKeychain.loadManual()
            : OAuthKeychain.load()
        guard let loaded = cachedCredentials ?? sourceCreds else {
            return try await fallback.poll(now: now)
        }
        var creds = loaded

        if creds.isExpired {
            guard let refreshed = try? await refreshToken(creds) else {
                cachedCredentials = nil
                return try await fallback.poll(now: now)
            }
            creds = refreshed
            cachedCredentials = refreshed
            if oauthMode == "manual" {
                OAuthKeychain.saveManual(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken)
            } else {
                OAuthKeychain.save(refreshed)
            }
        }

        do {
            return try await fetchAndBuild(token: creds.accessToken, now: now)
        } catch OAuthError.unauthorized {
            // Token rejected despite appearing valid — attempt one refresh.
            guard let refreshed = try? await refreshToken(creds) else {
                cachedCredentials = nil
                return try await fallback.poll(now: now)
            }
            cachedCredentials = refreshed
            if oauthMode == "manual" {
                OAuthKeychain.saveManual(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken)
            } else {
                OAuthKeychain.save(refreshed)
            }
            if let result = try? await fetchAndBuild(token: refreshed.accessToken, now: now) {
                return result
            }
            return try await fallback.poll(now: now)
        } catch {
            return try await fallback.poll(now: now)
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OAuthError.unauthorized }
            throw OAuthError.httpError(http.statusCode)
        }
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        return (
            (usage.fiveHour?.utilization ?? 0) * 100,
            (usage.sevenDay?.utilization ?? 0) * 100
        )
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
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

    private func fetchAndBuild(token: String, now: Date) async throws -> ParseResult {
        let usage = try await fetchUsage(token: token)
        let snapshot = buildSnapshot(usage: usage, now: now)
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

    private func fetchUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OAuthError.unauthorized }
            throw OAuthError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
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
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
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

    private func buildSnapshot(usage: UsageResponse, now: Date) -> ClaudeUsageSnapshot {
        let sessionWindow = usage.fiveHour.map { q in
            LimitWindow(percentUsed: q.utilization, resetsAt: q.resetsAt.flatMap(Self.parseDate))
        } ?? LimitWindow()

        let weekWindow = usage.sevenDay.map { q in
            LimitWindow(percentUsed: q.utilization, resetsAt: q.resetsAt.flatMap(Self.parseDate))
        } ?? LimitWindow()

        let severity = UsageSeverity.highest(
            thresholds.severity(for: usage.fiveHour?.utilization),
            thresholds.severity(for: usage.sevenDay?.utilization)
        )

        return ClaudeUsageSnapshot(
            parserVersion: "oauth-api-1.0",
            createdAt: now,
            lastSuccessfulPollAt: now,
            source: SourceInfo(cliPath: "api.anthropic.com", command: "GET /api/oauth/usage"),
            limits: LimitInfo(currentSession: sessionWindow, currentWeekAllModels: weekWindow),
            state: SnapshotState(status: .ok, severity: severity)
        )
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
    case invalidResponse
    case httpError(Int)
    case refreshFailed
}

// MARK: - Codable models

private struct UsageResponse: Decodable {
    let fiveHour: QuotaEntry?
    let sevenDay: QuotaEntry?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct QuotaEntry: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
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
