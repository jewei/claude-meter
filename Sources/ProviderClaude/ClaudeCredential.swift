import Foundation
import MeterDomain

/// An OAuth login for the Claude usage API.
struct ClaudeCredential: Sendable, Equatable {
    /// A token that expires within this margin counts as expired. One margin for every account.
    static let expiryMargin: TimeInterval = 60

    var accessToken: String
    var refreshToken: String?
    /// Nil when the expiry is unknown, for example for manual tokens entered without one.
    var expiresAt: Date?
    /// Plan hint, such as `max`.
    var subscriptionType: String?
    /// Finer plan hint, such as `default_claude_max_20x`.
    var rateLimitTier: String?

    /// True when the token expires within ``expiryMargin`` of `now`. An unknown expiry is
    /// never expired; the server decides with HTTP 401.
    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < Self.expiryMargin
    }

    /// Parses the value of a Claude Code Keychain item:
    /// `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt" (epoch ms), ...}}`.
    /// Nil when a required field is missing or invalid.
    static func claudeCode(_ data: Data) -> ClaudeCredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty,
            let milliseconds = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
            let expiresAt = DateBounds.date(secondsSince1970: milliseconds / 1000)
        else { return nil }
        return ClaudeCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String)
    }
}
