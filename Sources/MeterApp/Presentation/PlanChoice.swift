import Foundation

/// The plan menu of a login in Settings > Data. The user's pick wins over the plan that the
/// login reports.
public struct PlanChoice: Equatable, Sendable {
    /// The plans that the Claude menu offers, in menu order.
    public static let plans = ["Pro", "Max", "Ultra", "Team", "Enterprise", "Free"]
    /// The plans that the Antigravity menu offers, in menu order.
    public static let antigravityPlans = ["Pro", "Ultra", "Enterprise", "Free"]

    /// The badge that the card shows: the user's pick, else the reported plan.
    public let current: PlanBadge?
    /// The plan that the login reports, if any.
    public let reported: PlanBadge?
    /// The user picked the badge.
    public let isPicked: Bool
    /// The reported plan for menu and tooltip text.
    private let reportedName: String?

    public init(reported: String?, override: String?, verbatim: Bool = false) {
        let picked = PlanBadge(plan: override, verbatim: verbatim)
        self.reported = PlanBadge(plan: reported, verbatim: verbatim)
        reportedName =
            self.reported == nil
            ? nil
            : reported.map {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return verbatim ? trimmed : ClaudePlanName.current(trimmed)
            }
        current = picked ?? self.reported
        isPicked = picked != nil
    }

    /// The menu item that removes the pick, or nil when there is no pick.
    public var resetTitle: String? {
        guard isPicked else { return nil }
        return reportedName.map { "Use reported plan (\($0))" } ?? "Remove plan"
    }

    public var help: String {
        guard let plan = reportedName else {
            return "This login reports no plan. Choose the badge to show."
        }
        return isPicked
            ? "You chose this badge. The login reports \(plan)."
            : "The login reports \(plan). Choose another badge if your plan changed."
    }
}
