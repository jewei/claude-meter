import Foundation
import MeterDomain

/// Turns limit windows into ``GaugeModel`` values.
struct GaugeBuilder {
    /// The short titles of ring rows, which the ring legend repeats.
    static let sessionShortTitle = "5-hr"
    static let weeklyShortTitle = "week"

    let context: PresentationContext

    func gauge(_ window: QuotaWindow?, title: String, shortTitle: String) -> GaugeModel {
        let showsUsed = context.showsUsed
        let severity = window?.severity(context.thresholds) ?? .unknown
        let reset = Formatting.resetText(window, now: context.now)
        var spoken: [String] = []
        if let value = Formatting.value(window, showsUsed: showsUsed) {
            spoken.append(
                "\(Formatting.wholePercent(value)) percent \(showsUsed ? "used" : "left")")
        } else {
            spoken.append("percentage unknown")
        }
        spoken.append(Self.words(severity))
        if let date = window?.resetsAt, let phrase = Countdown.phrase(until: date, now: context.now)
        {
            spoken.append("resets \(phrase)")
        }
        return GaugeModel(
            title: title,
            shortTitle: shortTitle,
            valueText: Formatting.percent(window, showsUsed: showsUsed),
            caption: window?.usedPercent == nil ? nil : (showsUsed ? "used" : "left"),
            fraction: Formatting.fraction(window, showsUsed: showsUsed),
            severity: severity,
            resetText: reset,
            accessibilityValue: spoken.joined(separator: ", "))
    }

    func gauge(_ window: QuotaWindow) -> GaugeModel {
        gauge(window, title: window.title, shortTitle: Self.shortTitle(window))
    }

    func session(_ account: AccountUsage) -> GaugeModel {
        gauge(account.bindingWindow(.session), title: "Session", shortTitle: Self.sessionShortTitle)
    }

    func weekly(_ account: AccountUsage) -> GaugeModel {
        gauge(account.bindingWindow(.weekly), title: "Weekly", shortTitle: Self.weeklyShortTitle)
    }

    /// Scoped windows (Opus, Sonnet, …) after the session and weekly windows.
    func scoped(_ account: AccountUsage) -> [GaugeModel] {
        account.windows.filter { $0.kind == .scoped }.map(gauge)
    }

    /// `Opus Weekly` → `opus`.
    static func shortTitle(_ window: QuotaWindow) -> String {
        switch window.kind {
        case .session: sessionShortTitle
        case .weekly: weeklyShortTitle
        case .scoped, .billing:
            window.title.replacingOccurrences(of: " Weekly", with: "").lowercased()
        }
    }

    static func words(_ severity: Severity) -> String {
        switch severity {
        case .normal: "full energy"
        case .warning: "low energy"
        case .critical: "almost empty"
        case .exhausted: "tapped out"
        case .unknown: "energy status unknown"
        }
    }
}
