import Foundation
import MeterPlatform

/// Cursor plan names for display.
enum CursorPlan {
    /// Known plans get their product name, such as "Ultra" for `unified_ultra` or "Pro+" for
    /// `pro_plus`. Cursor's current plans carry a `unified_` prefix; the older names (Pro,
    /// Pro+, Business) stay for logins that keep an older plan. Any other name is shown as
    /// Cursor wrote it, trimmed, with its capitalization kept.
    static func displayName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        var key = trimmed.lowercased().replacingOccurrences(of: "-", with: "_")
        if key.hasPrefix(unifiedPrefix) { key.removeFirst(unifiedPrefix.count) }
        switch key {
        case "free": return "Free"
        case "plus": return "Plus"
        case "premium": return "Premium"
        case "super": return "Super"
        case "ultra": return "Ultra"
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "business": return "Business"
        case "team", "teams": return "Teams"
        case "enterprise": return "Enterprise"
        default: return trimmed
        }
    }

    private static let unifiedPrefix = "unified_"

    /// The plan name in a `GetPlanInfo` response: `{"planInfo":{"planName":"pro"}}`.
    static func name(planInfo body: Data) -> String? {
        JSONValue.parse(body)?["planInfo"]?["planName"]?.stringValue
    }
}
