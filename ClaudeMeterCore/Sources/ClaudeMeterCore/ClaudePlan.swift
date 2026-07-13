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
    /// A tier string carrying the 5x/20x multiplier refines a bare "Max".
    public static func displayName(subscriptionType: String?, rateLimitTier: String? = nil)
        -> String?
    {
        if let detailed = maxTierName(rateLimitTier) { return detailed }
        return from(subscriptionType) ?? from(rateLimitTier)
    }

    /// "Max 5x" / "Max 20x" when the tier string carries the multiplier
    /// (e.g. `default_claude_max_5x` from `.claude.json` / Keychain creds).
    private static func maxTierName(_ raw: String?) -> String? {
        guard let tier = raw?.lowercased() else { return nil }
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        return nil
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
