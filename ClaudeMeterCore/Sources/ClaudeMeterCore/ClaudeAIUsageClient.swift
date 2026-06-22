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
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else {
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
            throw ClaudeAIError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        guard let fiveHour = decoded.fiveHour,
              let sevenDay = decoded.sevenDay,
              let sessionResets = Self.parseDate(fiveHour.resetsAt),
              let weekResets = Self.parseDate(sevenDay.resetsAt) else {
            throw ClaudeAIError.missingFields
        }

        return UsageData(
            sessionPercent: fiveHour.utilization,
            sessionResetsAt: sessionResets,
            weekPercent: sevenDay.utilization,
            weekResetsAt: weekResets
        )
    }

    // MARK: - Org discovery

    /// Returns all org IDs found for this session key.
    public func discoverOrgIds() async throws -> [String] {
        guard let url = URL(string: "https://claude.ai/api/organizations") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        if let orgs = try? JSONDecoder().decode([OrgEntry].self, from: data) {
            return orgs.compactMap { $0.id ?? $0.uuid }
        }
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return raw.compactMap { ($0["id"] ?? $0["uuid"]) as? String }
        }
        return []
    }

    /// Convenience: returns the first org ID found (for backward compat).
    public func discoverOrgId() async throws -> String? {
        try await discoverOrgIds().first
    }

    // MARK: - Date parsing

    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let dateFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ string: String) -> Date? {
        dateFormatter.date(from: string) ?? dateFormatterNoFraction.date(from: string)
    }
}

// MARK: - Errors

public enum ClaudeAIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case missingFields
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .invalidURL:       return "Invalid API URL"
        case .invalidResponse:  return "Invalid server response"
        case .httpError(401):   return "Session expired — update your session key in Settings"
        case .httpError(403):   return "Access denied — check your session key and org ID"
        case .httpError(let c): return "HTTP error \(c)"
        case .missingFields:    return "Unexpected API response format"
        case .unauthorized:     return "Not authenticated"
        }
    }
}

// MARK: - Codable response models

private struct UsageAPIResponse: Codable {
    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct Window: Codable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct OrgEntry: Codable {
    let id: String?
    let uuid: String?
}
