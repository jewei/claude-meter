import Foundation

/// Maps Anthropic plan hints to a plan name, such as "Ultra" or "Pro".
enum ClaudePlan {
    /// A tier with a 5x or 20x multiplier refines "Max". Anthropic renamed Max 20x to Ultra and
    /// Max 5x to Max, but the tiers keep the old multipliers, such as `default_claude_max_20x`.
    /// Otherwise `subscriptionType` wins over the tier. Nil when neither hint is recognized.
    static func name(subscriptionType: String?, rateLimitTier: String?) -> String? {
        if let tier = rateLimitTier?.lowercased() {
            if tier.contains("max_20x") { return "Ultra" }
            if tier.contains("max_5x") { return "Max" }
        }
        return name(hint: subscriptionType) ?? name(hint: rateLimitTier)
    }

    /// The order of the checks matters: "max" also appears in longer tier strings.
    private static func name(hint: String?) -> String? {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !hint.isEmpty
        else { return nil }
        if hint.contains("ultra") { return "Ultra" }
        if hint.contains("max") { return "Max" }
        if hint.contains("pro") { return "Pro" }
        if hint.contains("team") { return "Team" }
        if hint.contains("enterprise") { return "Enterprise" }
        if hint.contains("free") { return "Free" }
        return nil
    }
}
