import Foundation

/// The plan menu of a Claude login in Settings > Data. The user's pick wins over the plan that
/// the login reports, because Claude Code keeps the plan of the last sign-in: after a plan
/// change, the reported plan can be old until the next sign-in.
public struct PlanChoice: Equatable, Sendable {
    /// The plans that the menu offers, in menu order.
    public static let plans = ["Pro", "Max 5x", "Max 20x", "Team", "Enterprise", "Free"]

    /// The badge that the card shows: the user's pick, else the reported plan.
    public let current: PlanBadge?
    /// The plan that the login reports, if any.
    public let reported: PlanBadge?
    /// The user picked the badge.
    public let isPicked: Bool
    /// The reported plan as the login names it, such as `Max 5x`, for text.
    private let reportedName: String?

    public init(reported: String?, override: String?) {
        let picked = PlanBadge(plan: override)
        self.reported = PlanBadge(plan: reported)
        reportedName = self.reported == nil ? nil : reported?.trimmingCharacters(in: .whitespaces)
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
