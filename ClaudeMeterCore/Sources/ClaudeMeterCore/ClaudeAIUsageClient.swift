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
