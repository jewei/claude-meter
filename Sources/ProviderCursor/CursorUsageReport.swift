import Foundation
import MeterDomain
import MeterPlatform

/// The `GetCurrentPeriodUsage` response, mapped to the domain model.
///
/// Every field is optional. Numbers are read leniently, because Connect JSON sends 64-bit
/// integers as strings. `totalPercentUsed` is the authoritative usage: Cursor grants bonus
/// credit beyond the plan limit, so spend and limit never give a percentage.
///
/// Connect JSON also omits proto3 zero values. A present `planUsage` object proves that the
/// server sent the message, so an absent `totalPercentUsed` or `totalSpend` in it is zero, not
/// unknown. Without `planUsage`, both are unknown.
struct CursorUsageReport: Hashable, Sendable {
    /// False only when the response says `"enabled": false`. A plain proto3 `false` is
    /// omitted, so an absent field reads as enabled.
    let isEnabled: Bool
    let windows: [QuotaWindow]
    /// Spend in the billing period with its limit. Nil when Cursor reports neither.
    let spend: Balance?

    init(body: Data) throws(CursorFailure) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body),
            case .object = json
        else { throw .unexpectedResponse }
        let usage = json["planUsage"]
        var hasUsage = false
        if case .object? = usage { hasUsage = true }
        let periodEnd = DateParsing.date(json["billingCycleEnd"])
        isEnabled = json["enabled"]?.boolValue != false

        let total = usage?["totalPercentUsed"]
        var windows = [
            QuotaWindow(
                id: "billing", title: "Billing period", kind: .billing,
                usedPercent: total == nil || total == .null
                    ? (hasUsage ? 0 : nil) : total?.doubleValue,
                resetsAt: periodEnd)
        ]
        // Older responses have no breakdown, so a row appears only when its field does.
        let breakdown = [
            ("auto", "Auto + Composer", "autoPercentUsed"), ("api", "API", "apiPercentUsed"),
        ]
        for (id, title, key) in breakdown {
            guard let value = usage?[key], value != .null else { continue }
            windows.append(
                QuotaWindow(
                    id: id, title: title, kind: .scoped, usedPercent: value.doubleValue,
                    resetsAt: periodEnd, isBinding: false))
        }
        self.windows = windows

        let spent = usage?["totalSpend"]
        let amount =
            spent == nil || spent == .null
            ? (hasUsage ? 0 : nil) : spent?.dollarsFromCents
        // Zero or a negative limit means that the plan has no fixed limit.
        let limit = usage?["limit"]?.dollarsFromCents.flatMap { $0 > 0 ? $0 : nil }
        spend =
            amount == nil && limit == nil
            ? nil : Balance(kind: .spend, amount: amount, limit: limit, unit: .currency("USD"))
    }

    /// The observed account. The email is never part of it.
    func account(plan: String?, owner: AccountOwner, now: Date) -> AccountUsage {
        AccountUsage(
            id: .default, name: CursorProvider.accountName, plan: CursorPlan.displayName(plan),
            windows: windows, balances: spend.map { [$0] } ?? [], observedAt: now,
            attemptedAt: now, owner: owner)
    }
}
