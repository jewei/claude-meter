import Foundation
import MeterDomain
import MeterPlatform

/// The `GetCurrentPeriodUsage` response, mapped to the domain model.
///
/// Every field is optional. Numbers are read leniently, because Connect JSON sends 64-bit
/// integers as strings. `totalPercentUsed` is the authoritative usage: Cursor grants bonus
/// credit beyond the plan limit, so spend and limit never give a percentage.
struct CursorUsageReport: Hashable, Sendable {
    /// False only when the response says `"enabled": false`.
    let isEnabled: Bool
    let windows: [QuotaWindow]
    /// Spend in the billing period with its limit. Nil when Cursor reports neither.
    let spend: Balance?

    init(body: Data) throws(CursorFailure) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body),
            case .object = json
        else { throw .unexpectedResponse }
        let usage = json["planUsage"]
        let periodEnd = DateParsing.date(json["billingCycleEnd"])
        isEnabled = json["enabled"]?.boolValue != false

        var windows = [
            QuotaWindow(
                id: "billing", title: "Billing period", kind: .billing,
                usedPercent: usage?["totalPercentUsed"]?.doubleValue, resetsAt: periodEnd)
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

        let amount = Self.dollars(cents: usage?["totalSpend"])
        // Zero or a negative limit means that the plan has no fixed limit.
        let limit = Self.dollars(cents: usage?["limit"]).flatMap { $0 > 0 ? $0 : nil }
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

    /// Whole US cents, as a number or a numeric string, converted exactly to dollars.
    static func dollars(cents value: JSONValue?) -> Decimal? {
        let text: String
        switch value {
        case .number(let number) where number.isFinite:
            text = String(number)
        case .string(let string) where NumericText.double(string) != nil:
            text = string
        default:
            return nil
        }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")).map { $0 / 100 }
    }
}
