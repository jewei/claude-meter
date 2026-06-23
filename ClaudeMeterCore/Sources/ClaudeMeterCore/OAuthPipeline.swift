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
        guard let loaded = cachedCredentials ?? OAuthKeychain.load() else {
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
            OAuthKeychain.save(refreshed)
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
            OAuthKeychain.save(refreshed)
            if let result = try? await fetchAndBuild(token: refreshed.accessToken, now: now) {
                return result
            }
            return try await fallback.poll(now: now)
        } catch {
            return try await fallback.poll(now: now)
        }
    }

    // MARK: - API calls

    private func fetchAndBuild(token: String, now: Date) async throws -> ParseResult {
        let quotas = try await fetchUsage(token: token)
        let snapshot = buildSnapshot(quotas: quotas, now: now)
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

    private func fetchUsage(token: String) async throws -> [String: QuotaEntry] {
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
        return try JSONDecoder().decode([String: QuotaEntry].self, from: data)
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

    private func buildSnapshot(quotas: [String: QuotaEntry], now: Date) -> ClaudeUsageSnapshot {
        let fiveHour = quotas["five_hour"]
        let sevenDay = quotas["seven_day"]

        let sessionWindow = fiveHour.map { q in
            LimitWindow(percentUsed: q.utilization, resetsAt: q.resetsAt.flatMap(Self.parseDate))
        } ?? LimitWindow()

        let weekWindow = sevenDay.map { q in
            LimitWindow(percentUsed: q.utilization, resetsAt: q.resetsAt.flatMap(Self.parseDate))
        } ?? LimitWindow()

        let severity = UsageSeverity.highest(
            thresholds.severity(for: fiveHour?.utilization),
            thresholds.severity(for: sevenDay?.utilization)
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

private struct QuotaEntry: Decodable {
    let utilization: Double
    let resetsAt: String?
    let isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
        case isEnabled = "is_enabled"
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
