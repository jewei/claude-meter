import Foundation
import MeterPlatform

/// Cursor plan names for display.
enum CursorPlan {
    /// Known plans get their product name, such as "Pro+" for `pro_plus`. Any other name is
    /// shown as Cursor wrote it, trimmed, with its capitalization kept.
    static func displayName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        switch trimmed.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "free": return "Free"
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "ultra": return "Ultra"
        case "business": return "Business"
        case "team", "teams": return "Teams"
        default: return trimmed
        }
    }

    /// The plan name in a `GetPlanInfo` response: `{"planInfo":{"planName":"pro"}}`.
    static func name(planInfo body: Data) -> String? {
        JSONValue.parse(body)?["planInfo"]?["planName"]?.stringValue
    }
}
