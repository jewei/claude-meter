/// Chooses the account that owns the menu bar, the hero, and the first card.
public enum AccountSelection {
    /// An exact pin wins and never falls back to another account: a missing pinned account
    /// gives nil. Without a pin, the observed account nearest its limit wins. Ties keep input
    /// order, and an account with only unknown windows ranks below a known 0%.
    ///
    /// Pass accounts resolved at the render time (``AccountUsage/resolved(at:isStale:)``), so
    /// an expired window ranks by its reset value.
    public static func primary(in accounts: [AccountUsage], pinned: AccountID?) -> AccountUsage? {
        let observed = accounts.filter(\.hasObservation)
        if let pinned {
            return observed.first { $0.id == pinned }
        }
        var selected: AccountUsage?
        for account in observed {
            if let leader = selected, account.pressure <= leader.pressure { continue }
            selected = account
        }
        return selected
    }
}
