import Foundation

/// The plan part of a Claude login row in Settings > Data: the badge that the login reports,
/// or a menu to pick one when the login reports none.
public enum PlanChoice: Equatable, Sendable {
    /// The plans that the menu offers, in menu order.
    public static let plans = ["Pro", "Max 5x", "Max 20x", "Team", "Enterprise", "Free"]

    /// The login reports its plan, so the badge cannot be changed.
    case reported(PlanBadge)
    /// The login reports no plan. `current` is the user's pick, if any.
    case pickable(current: PlanBadge?)

    public init(reported: String?, override: String?) {
        if let badge = PlanBadge(plan: reported) {
            self = .reported(badge)
        } else {
            self = .pickable(current: PlanBadge(plan: override))
        }
    }
}
