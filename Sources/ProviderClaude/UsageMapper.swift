import Foundation
import MeterDomain

/// Maps a usage response to the domain model. The one mapper for every Claude account.
enum UsageMapper {
    /// Session, Weekly, Opus Weekly (only with a value), other scoped weekly windows, and the
    /// extra-usage billing window. Only session, weekly, and Opus windows are binding.
    static func windows(_ response: UsageResponse) -> [QuotaWindow] {
        var windows = [
            window(response.fiveHour, id: "session", title: "Session", kind: .session),
            window(response.sevenDay, id: "weekly", title: "Weekly", kind: .weekly),
        ]
        if let opus = response.sevenDayOpus {
            windows.append(window(opus, id: "seven_day_opus", title: "Opus Weekly", kind: .scoped))
        }
        windows += response.scoped.map {
            window(
                $0.window, id: $0.key, title: scopeTitle($0.key), kind: .scoped, isBinding: false)
        }
        if let extra = response.extraUsage {
            windows.append(
                QuotaWindow(
                    id: "extra-usage", title: "Extra usage", kind: .billing,
                    usedPercent: extraUsagePercent(extra), resetsAt: nil, isBinding: false))
        }
        return windows
    }

    /// The extra-usage spend and its monthly limit, scaled from minor units exactly.
    static func balances(_ response: UsageResponse) -> [Balance] {
        guard let extra = response.extraUsage else { return [] }
        return [
            Balance(
                kind: .extraUsage,
                amount: amount(minorUnits: extra.usedCredits, decimalPlaces: extra.decimalPlaces),
                limit: amount(minorUnits: extra.monthlyLimit, decimalPlaces: extra.decimalPlaces),
                unit: .currency(extra.currency?.uppercased() ?? "USD"),
                isPaused: !extra.isEnabled)
        ]
    }

    /// One reset entry per available reset, so the details match the total.
    static func resetAllowance(_ response: UsageResponse) -> ResetAllowance? {
        guard let grants = response.resetGrants else { return nil }
        let resets = grants.flatMap { grant in
            Array(
                repeating: ResetAllowance.Reset(title: grant.title, expiresAt: grant.expiresAt),
                count: grant.resetsLeft)
        }
        return ResetAllowance(available: resets.count, resets: resets)
    }

    /// "Sonnet Weekly" from `seven_day_sonnet`, "Oauth Apps Weekly" from
    /// `seven_day_oauth_apps`. A key without a scope keeps its raw name.
    static func scopeTitle(_ key: String) -> String {
        let prefix = "seven_day_"
        let scope = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        guard !scope.isEmpty else { return "\(key) Weekly" }
        let words = scope.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.joined(separator: " ") + " Weekly"
    }

    /// The API's utilization, else spend over limit.
    static func extraUsagePercent(_ extra: UsageResponse.ExtraUsage) -> Double? {
        if let utilization = extra.utilization { return utilization }
        guard let used = extra.usedCredits, let limit = extra.monthlyLimit, limit > 0 else {
            return nil
        }
        let percent = used / limit * 100
        return percent.isFinite ? percent : nil
    }

    /// `minorUnits / 10^decimalPlaces` without binary floating-point error.
    static func amount(minorUnits: Double?, decimalPlaces: Int) -> Decimal? {
        guard let minorUnits, minorUnits.isFinite else { return nil }
        let exact: Decimal
        if let integer = Int64(exactly: minorUnits) {
            exact = Decimal(integer)
        } else if let parsed = Decimal(string: String(minorUnits)) {
            exact = parsed
        } else {
            return nil
        }
        var divisor = Decimal(1)
        for _ in 0..<min(18, max(0, decimalPlaces)) { divisor *= 10 }
        return exact / divisor
    }

    private static func window(
        _ window: UsageResponse.Window?, id: String, title: String, kind: QuotaWindow.Kind,
        isBinding: Bool = true
    ) -> QuotaWindow {
        QuotaWindow(
            id: id, title: title, kind: kind, usedPercent: window?.utilization,
            resetsAt: window?.resetsAt, isBinding: isBinding)
    }
}
