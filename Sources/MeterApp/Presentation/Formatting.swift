import Foundation
import MeterDomain

/// Text and fill values shared by every model builder.
enum Formatting {
    /// The number to show for a window: energy left by default, or percent used.
    static func value(_ window: QuotaWindow?, showsUsed: Bool) -> Double? {
        guard let used = window?.usedPercent else { return nil }
        return showsUsed ? used : 100 - used
    }

    /// `60%`, or `—` when unknown. Every percentage in the app uses ``wholePercent(_:)``.
    static func percent(_ window: QuotaWindow?, showsUsed: Bool) -> String {
        value(window, showsUsed: showsUsed).map { "\(wholePercent($0))%" } ?? "—"
    }

    /// The one rounding rule for every percentage: the nearest whole number, except that a
    /// value above 0 shows at least 1 and a value below 100 shows at most 99. So 0% left
    /// appears only when the window is exhausted, and 100% left only when nothing is used.
    static func wholePercent(_ value: Double) -> Int {
        guard value > 0 else { return 0 }
        guard value < 100 else { return 100 }
        return min(99, max(1, Int(value.rounded())))
    }

    /// The share of a ring or bar to fill, 0...1. Unknown fills nothing.
    static func fraction(_ window: QuotaWindow?, showsUsed: Bool) -> Double {
        (value(window, showsUsed: showsUsed) ?? 0) / 100
    }

    /// `3d 23h`, or nil when the date has passed, with no-break spaces for text that wraps:
    /// `3d` at the end of one line with `23h` on the next reads as two values.
    static func countdown(until date: Date, now: Date) -> String? {
        Countdown.text(until: date, now: now)?.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// `Resets in 3h 12m`, or nil when the window has no future reset.
    static func resetText(_ window: QuotaWindow?, now: Date) -> String? {
        guard let date = window?.resetsAt, let text = Countdown.text(until: date, now: now) else {
            return nil
        }
        return "Resets in \(text)"
    }

    /// `Just now`, `42s ago`, `12m ago`, `3h ago`, `2d ago`, or `Not updated yet`.
    static func age(since date: Date?, now: Date) -> String {
        guard let date else { return "Not updated yet" }
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite else { return "Not updated yet" }
        switch max(0, seconds) {
        case ..<5: return "Just now"
        case ..<60: return "\(Int(seconds))s ago"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    /// The locale for numbers in English copy. A fixed locale keeps `35.8M tokens` and
    /// `$12.34` consistent with the words around them, and keeps every builder pure.
    static let numberLocale = Locale(identifier: "en_US_POSIX")

    /// `35.8M tokens`, `1 token`.
    static func tokens(_ count: Int64) -> String {
        "\(compactCount(count)) \(tokenWord(count))"
    }

    /// `token` for one, else `tokens`.
    static func tokenWord(_ count: Int64) -> String {
        count == 1 ? "token" : "tokens"
    }

    /// `35.8M`, `1`.
    static func compactCount(_ count: Int64) -> String {
        count.formatted(
            .number.notation(.compactName).precision(.fractionLength(0...1)).locale(numberLocale))
    }

    /// `$12.34` or `$1,241.00` for US dollars, otherwise the code first: `EUR 12.34`.
    static func money(_ amount: Decimal, unit: Balance.Unit) -> String {
        let number = amount.formatted(
            .number.precision(.fractionLength(2)).locale(groupingLocale))
        switch unit {
        case .currency(let code) where code.uppercased() == "USD": return "$\(number)"
        case .currency(let code): return "\(code.uppercased()) \(number)"
        case .credits: return "\(number) credits"
        }
    }

    /// `$42.10`, `$1,241`, or `<$0.01`. Under $100 two decimals; from $100 whole dollars with
    /// grouping. The tile marks an incomplete estimate itself.
    static func estimateAmount(_ estimate: CostEstimate) -> String {
        // Below a cent before rounding; above it, round to cents first, so $99.996 shows as
        // `$100`, not `$100.00`.
        guard estimate.amount >= cent else { return "<$0.01" }
        let amount = rounded(estimate.amount, scale: 2)
        let number =
            amount < 100
            ? amount.formatted(.number.precision(.fractionLength(2)).locale(numberLocale))
            : amount.formatted(.number.precision(.fractionLength(0)).locale(groupingLocale))
        return "$" + number
    }

    /// `about 42 dollars at API prices`, for VoiceOver, with `, may be higher` when the
    /// estimate is incomplete. It uses the amount that the row shows.
    static func spokenEstimate(_ estimate: CostEstimate) -> String {
        let note = estimate.isComplete ? "" : ", may be higher"
        let text: String
        if estimate.amount < cent {
            text = "under 1 cent"
        } else {
            let amount = rounded(estimate.amount, scale: 2)
            if amount < 1 {
                let cents = NSDecimalNumber(decimal: amount * 100).intValue
                text = "about \(cents) \(cents == 1 ? "cent" : "cents")"
            } else {
                let dollars = NSDecimalNumber(decimal: rounded(amount, scale: 0)).intValue
                text = "about \(dollars) \(dollars == 1 ? "dollar" : "dollars")"
            }
        }
        return "\(text) at API prices\(note)"
    }

    private static let cent = Decimal(string: "0.01") ?? 0

    /// `value` rounded half up to `scale` decimal places.
    private static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var value = value
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }

    /// Groups thousands (`1,241`), which `numberLocale` does not.
    static let groupingLocale = Locale(identifier: "en_US")

    /// `12 credits`, `1.5 credits`, `72,909.6 credits`.
    static func credits(_ amount: Decimal) -> String {
        let number = amount.formatted(
            .number.precision(.fractionLength(0...1)).locale(groupingLocale))
        return "\(number) \(amount == 1 ? "credit" : "credits")"
    }

    /// The first letter or digit of a name, uppercased, for avatars.
    static func initial(_ name: String) -> String {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }
}
