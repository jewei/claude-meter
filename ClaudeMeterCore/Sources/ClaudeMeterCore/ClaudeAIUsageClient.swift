import Foundation

/// HTTP client for https://claude.ai/api/organizations/{orgId}/usage
///
/// This is the same endpoint the claude.ai web app uses internally.
/// Auth uses the browser session cookie (sessionKey).
public struct ClaudeAIUsageClient: Sendable {

    public let sessionKey: String
    public let orgId: String

    public init(sessionKey: String, orgId: String) {
        self.sessionKey = sessionKey
        self.orgId = orgId
    }

    public struct UsageData: Sendable {
        public let sessionPercent: Double
        public let sessionResetsAt: Date
        public let weekPercent: Double
        public let weekResetsAt: Date
        /// Weekly Opus-only window, when claude.ai reports `seven_day_opus`.
        public let weekOpusPercent: Double?
        public let weekOpusResetsAt: Date?

        public init(
            sessionPercent: Double,
            sessionResetsAt: Date,
            weekPercent: Double,
            weekResetsAt: Date,
            weekOpusPercent: Double? = nil,
            weekOpusResetsAt: Date? = nil
        ) {
            self.sessionPercent = sessionPercent
            self.sessionResetsAt = sessionResetsAt
            self.weekPercent = weekPercent
            self.weekResetsAt = weekResetsAt
            self.weekOpusPercent = weekOpusPercent
            self.weekOpusResetsAt = weekOpusResetsAt
        }
    }

    /// URLSession that bypasses the system cookie store so our manual Cookie header is sent as-is.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    public func fetchUsage() async throws -> UsageData {
        guard CredentialValidator.isValidOrgId(orgId),
              let normalizedOrg = CredentialValidator.normalizedOrgId(orgId) else {
            throw ClaudeAIError.invalidOrgId
        }
        guard CredentialValidator.isValidSessionKey(sessionKey) else {
            throw ClaudeAIError.invalidSessionKey
        }
        guard let url = URL(string: "https://claude.ai/api/organizations/\(normalizedOrg)/usage") else {
            throw ClaudeAIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ClaudeAIError.unauthorized
            }
            throw ClaudeAIError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        guard let fiveHour = decoded.fiveHour, let sessionPercent = fiveHour.utilization,
              let sevenDay = decoded.sevenDay, let weekPercent = sevenDay.utilization,
              let sessionResets = fiveHour.resetsAt.flatMap(Self.parseDate),
              let weekResets = sevenDay.resetsAt.flatMap(Self.parseDate) else {
            throw ClaudeAIError.missingFields
        }

        return UsageData(
            sessionPercent: sessionPercent,
            sessionResetsAt: sessionResets,
            weekPercent: weekPercent,
            weekResetsAt: weekResets,
            weekOpusPercent: decoded.sevenDayOpus?.utilization,
            weekOpusResetsAt: decoded.sevenDayOpus?.resetsAt.flatMap(Self.parseDate)
        )
    }

    // MARK: - Organization resolution

    public struct Organization: Sendable, Equatable {
        public let uuid: String
        public let name: String?
        public let capabilities: [String]

        public init(uuid: String, name: String?, capabilities: [String]) {
            self.uuid = uuid
            self.name = name
            self.capabilities = capabilities
        }
    }

    /// Picks the org to query for usage: prefer one with the `chat` capability (the
    /// personal Claude org), falling back to the first. Mirrors what claude.ai does
    /// and avoids the "auto-detect picked the wrong org" trap of grabbing index 0.
    public static func selectOrganization(from orgs: [Organization]) -> Organization? {
        orgs.first { $0.capabilities.contains("chat") } ?? orgs.first
    }

    /// Fetches the caller's organizations and returns the best org UUID for usage
    /// queries, so users don't have to paste a UUID by hand.
    public static func resolveOrgId(sessionKey: String) async throws -> String {
        guard CredentialValidator.isValidSessionKey(sessionKey) else {
            throw ClaudeAIError.invalidSessionKey
        }
        guard let url = URL(string: "https://claude.ai/api/organizations") else {
            throw ClaudeAIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeAIError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ClaudeAIError.unauthorized }
            throw ClaudeAIError.httpError(http.statusCode)
        }
        let orgs = try parseOrganizations(data)
        guard let chosen = selectOrganization(from: orgs) else {
            throw ClaudeAIError.missingFields
        }
        return chosen.uuid
    }

    static func parseOrganizations(_ data: Data) throws -> [Organization] {
        let decoded = try JSONDecoder().decode([OrganizationResponse].self, from: data)
        return decoded.compactMap { entry in
            guard let uuid = entry.uuid, !uuid.isEmpty else { return nil }
            return Organization(uuid: uuid, name: entry.name, capabilities: entry.capabilities ?? [])
        }
    }

    // MARK: - Date parsing

    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Redacted command string safe for snapshots and diagnostics.
    public static let redactedUsageCommand = "GET /api/organizations/[redacted]/usage"
}

// MARK: - Errors

public enum ClaudeAIError: Error, LocalizedError, Equatable {
    case invalidURL
    case invalidOrgId
    case invalidSessionKey
    case invalidResponse
    case httpError(Int)
    case missingFields
    case unauthorized

    public var isAuthFailure: Bool {
        switch self {
        case .unauthorized: return true
        case .httpError(401), .httpError(403): return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid API URL"
        case .invalidOrgId:         return "Invalid organization ID — paste a valid UUID"
        case .invalidSessionKey:    return "Invalid session key format"
        case .invalidResponse:      return "Invalid server response"
        case .httpError(401):       return "Session expired — update your session key in Settings"
        case .httpError(403):       return "Access denied — check your session key and org ID"
        case .httpError(let c):     return "HTTP error \(c)"
        case .missingFields:        return "Unexpected API response format"
        case .unauthorized:         return "Session expired — update your session key in Settings"
        }
    }
}

// MARK: - Codable response models

private struct UsageAPIResponse: Codable {
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
    }
}

private struct OrganizationResponse: Decodable {
    let uuid: String?
    let name: String?
    let capabilities: [String]?
}

private struct Window: Codable {
    // Optional so a present-but-empty window (or an added key) degrades gracefully
    // instead of failing the whole response decode.
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
