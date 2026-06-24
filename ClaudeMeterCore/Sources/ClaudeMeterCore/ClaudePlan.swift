import Foundation

/// Maps Anthropic plan hints (OAuth `subscriptionType` or a `rate_limit_tier`
/// string) to a user-facing plan name. Prefers `subscriptionType` when present.
public enum ClaudePlan: String, Sendable {
    case max = "Max"
    case pro = "Pro"
    case team = "Team"
    case enterprise = "Enterprise"
    case free = "Free"

    public var displayName: String { rawValue }

    /// Resolves a display name from any available hint, or `nil` when unrecognized.
    public static func displayName(subscriptionType: String?, rateLimitTier: String? = nil)
        -> String?
    {
        from(subscriptionType) ?? from(rateLimitTier)
    }

    private static func from(_ raw: String?) -> String? {
        guard let tier = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !tier.isEmpty
        else { return nil }
        if tier.contains("max") { return max.rawValue }
        if tier.contains("pro") { return pro.rawValue }
        if tier.contains("team") { return team.rawValue }
        if tier.contains("enterprise") { return enterprise.rawValue }
        if tier.contains("free") { return free.rawValue }
        return nil
    }
}
