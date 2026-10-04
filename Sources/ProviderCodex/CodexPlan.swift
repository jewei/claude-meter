import Foundation

/// Readable names for the plan IDs that Codex reports. The IDs are the upstream `PlanType`
/// values (`openai/codex`, `codex-rs/app-server-protocol`).
enum CodexPlan {
    /// The display name, the trimmed ID when it is not known, or nil when there is no plan.
    static func displayName(_ plan: String?) -> String? {
        guard let trimmed = plan?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        switch trimmed.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "", "unknown": return nil
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "prolite", "pro_lite": return "Pro 5X"
        case "pro": return "Pro 20X"
        case "promax", "pro_max": return "Pro Max"
        case "team": return "Team"
        case "self_serve_business_usage_based", "self_serve_business_prolite", "business":
            return "Business"
        case "enterprise_cbp_usage_based", "enterprise_cbp_automation", "ent26", "enterprise":
            return "Enterprise"
        case "edu", "education": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        default: return trimmed
        }
    }
}
