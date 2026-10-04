import Foundation
import MeterDomain

/// Text and fill values shared by every model builder.
enum Formatting {
    /// The number to show for a window: energy left by default, or percent used.
    static func value(_ window: QuotaWindow?, showsUsed: Bool) -> Double? {
        guard let used = window?.usedPercent else { return nil }
        return showsUsed ? used : 100 - used
    }

    /// `60%`, or `—` when unknown. Every percentage in the app rounds to a whole number.
    static func percent(_ window: QuotaWindow?, showsUsed: Bool) -> String {
        value(window, showsUsed: showsUsed).map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// `60% left`, `40% used`, or `—`.
    static func percentWithCaption(_ window: QuotaWindow?, showsUsed: Bool) -> String {
        guard window?.usedPercent != nil else { return "—" }
        return "\(percent(window, showsUsed: showsUsed)) \(showsUsed ? "used" : "left")"
    }

    /// The share of a ring or bar to fill, 0...1. Unknown fills nothing.
    static func fraction(_ window: QuotaWindow?, showsUsed: Bool) -> Double {
        (value(window, showsUsed: showsUsed) ?? 0) / 100
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

    /// `35.8M tokens`, `1 token`.
    static func tokens(_ count: Int64) -> String {
        let number = count.formatted(
            .number.notation(.compactName).precision(.fractionLength(0...1)))
        return "\(number) \(count == 1 ? "token" : "tokens")"
    }

    /// `$12.34` for US dollars, otherwise the code first: `EUR 12.34`.
    static func money(_ amount: Decimal, unit: Balance.Unit) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        switch unit {
        case .currency(let code) where code.uppercased() == "USD": return "$\(number)"
        case .currency(let code): return "\(code.uppercased()) \(number)"
        case .credits: return "\(number) credits"
        }
    }

    /// `12 credits`, `1.5 credits`.
    static func credits(_ amount: Decimal) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(0...1)))
        return "\(number) \(amount == 1 ? "credit" : "credits")"
    }

    /// The first letter or digit of a name, uppercased, for avatars.
    static func initial(_ name: String) -> String {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }
}
