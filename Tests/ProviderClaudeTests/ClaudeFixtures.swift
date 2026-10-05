import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport

@testable import ProviderClaude

/// Recorded response bodies and builders for Claude tests.
enum ClaudeFixtures {
    /// A full usage response, shaped like a recorded one.
    static let fullUsage = """
        {
          "five_hour": {"utilization": 42.0, "resets_at": "2026-10-04T15:00:00.462328+00:00"},
          "seven_day": {"utilization": 61.0, "resets_at": "2026-10-09T07:00:00+00:00"},
          "seven_day_opus": {"utilization": 88.0, "resets_at": "2026-10-09T07:00:00Z"},
          "seven_day_sonnet": {"utilization": 34.0, "resets_at": "2026-10-10T00:00:00Z"},
          "seven_day_cowork": {"utilization": null},
          "seven_day_oauth_apps": null,
          "extra_usage": {
            "is_enabled": false, "used_credits": 1615, "monthly_limit": 2000,
            "decimal_places": 2, "utilization": 80.75, "currency": "usd"
          },
          "cedar_ember": {
            "eligible": true,
            "grants": [
              {"id": "launch", "label": "Launch reset", "resets_total": 2, "resets_left": 2,
               "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": "2026-10-22T16:00:00+00:00"}
            ]
          },
          "spend": {}
        }
        """

    /// A token response that rotates both tokens for one hour.
    static let rotated =
        #"{"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}"#

    /// The answer of a token endpoint that rotates each refresh token once, as Anthropic does:
    /// refresh token `token` gets `access-<token>` and `next-<token>` for one hour, and a
    /// refresh token that `spent` holds already gets `invalid_grant`. Adds the refresh token of
    /// `request` to `spent`.
    static func rotation(of request: HTTPRequest, spent: Locked<[String]>) -> HTTPResponse {
        let body = request.body.flatMap {
            try? JSONDecoder().decode([String: String].self, from: $0)
        }
        let token = body?["refresh_token"] ?? ""
        let isSpent = spent.withLock { sent -> Bool in
            defer { sent.append(token) }
            return sent.contains(token)
        }
        guard !isSpent else { return .json(400, #"{"error": "invalid_grant"}"#) }
        return .json(
            200,
            #"{"access_token": "access-\#(token)", "refresh_token": "next-\#(token)", "#
                + #""expires_in": 3600}"#)
    }

    /// The card text of manual tokens that no longer work.
    static let manualConnectAgain = UsageIssue(
        "The saved Claude tokens no longer work. Connect again in Settings with new tokens.",
        needsAction: true)

    static func usage(session: Double, weekly: Double = 10) -> String {
        """
        {"five_hour": {"utilization": \(session), "resets_at": "2026-10-04T15:00:00Z"},
         "seven_day": {"utilization": \(weekly), "resets_at": "2026-10-09T07:00:00Z"}}
        """
    }

    /// The value of a Claude Code Keychain item.
    static func claudeCodeItem(
        accessToken: String, refreshToken: String = "refresh", expiresAt: Date = .reference(3600),
        subscriptionType: String? = "max", rateLimitTier: String? = nil
    ) -> String {
        var oauth: [String: Any] = [
            "accessToken": accessToken, "refreshToken": refreshToken,
            "expiresAt": (expiresAt.timeIntervalSince1970 * 1000).rounded(),
            "scopes": ["user:inference"],
        ]
        oauth["subscriptionType"] = subscriptionType
        oauth["rateLimitTier"] = rateLimitTier
        let data = try? JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// A `.claude.json` with an `oauthAccount`.
    static func identity(account: String, organization: String = "org-1", tier: String? = nil)
        -> String
    {
        let tierField = tier.map { #", "organizationRateLimitTier": "\#($0)""# } ?? ""
        return """
            {"numStartups": 3, "oauthAccount": {"accountUuid": "\(account)",
             "organizationUuid": "\(organization)", "emailAddress": "a@example.com"\(tierField)}}
            """
    }
}

/// The bearer token of a request, or nil.
func bearer(_ request: HTTPRequest) -> String? {
    request.headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) }
}
