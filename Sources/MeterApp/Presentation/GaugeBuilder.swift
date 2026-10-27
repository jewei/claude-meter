import Foundation
import MeterDomain

/// Turns limit windows into ``GaugeModel`` values.
struct GaugeBuilder {
    /// The short titles of ring rows, which the ring legend repeats.
    static let sessionShortTitle = "5-hr"
    static let weeklyShortTitle = "week"

    let context: PresentationContext

    /// `account` is the window's account. Its observation gives the pace; without it, or when
    /// it is stale, the gauge has no pace.
    func gauge(
        _ window: QuotaWindow?, title: String, shortTitle: String, account: AccountUsage? = nil
    ) -> GaugeModel {
        let showsUsed = context.showsUsed
        let severity = window?.severity(context.thresholds) ?? .unknown
        let reset = Formatting.resetText(window, now: context.now)
        let pace = window.flatMap { pace(of: $0, account: account) }
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
        if let pace {
            spoken.append(PaceText.spoken(pace, now: context.now, showsUsed: showsUsed))
        }
        return GaugeModel(
            title: title,
            shortTitle: shortTitle,
            valueText: Formatting.percent(window, showsUsed: showsUsed),
            caption: window?.usedPercent == nil ? nil : (showsUsed ? "used" : "left"),
            fraction: Formatting.fraction(window, showsUsed: showsUsed),
            severity: severity,
            resetText: reset,
            paceText: pace.flatMap { Self.showsPaceText($0) ? $0 : nil }.map {
                PaceText.text($0, now: context.now, showsUsed: showsUsed)
            },
            paceSeverity: pace.flatMap { Self.paceSeverity($0, window: severity) },
            evenPaceFraction: pace.map {
                showsUsed ? $0.expectedUsed / 100 : 1 - $0.expectedUsed / 100
            },
            accessibilityValue: spoken.joined(separator: ", "))
    }

    func gauge(_ window: QuotaWindow, account: AccountUsage? = nil) -> GaugeModel {
        gauge(window, title: window.title, shortTitle: Self.shortTitle(window), account: account)
    }

    func session(_ account: AccountUsage) -> GaugeModel {
        gauge(
            account.bindingWindow(.session), title: "Session", shortTitle: Self.sessionShortTitle,
            account: account)
    }

    func weekly(_ account: AccountUsage) -> GaugeModel {
        gauge(
            account.bindingWindow(.weekly), title: "Weekly", shortTitle: Self.weeklyShortTitle,
            account: account)
    }

    /// Scoped windows (Opus, Sonnet, …) after the session and weekly windows.
    func scoped(_ account: AccountUsage) -> [GaugeModel] {
        account.windows.filter { $0.kind == .scoped }.map { gauge($0, account: account) }
    }

    /// A card states a pace that needs attention. "Lasts until reset" is only spoken: the
    /// even-pace mark already shows it.
    static func showsPaceText(_ pace: Pace) -> Bool {
        if case .lastsUntilReset = pace.verdict { return false }
        return true
    }

    /// Warning for a run-out before the reset, or the window's severity when that is worse.
    static func paceSeverity(_ pace: Pace, window: Severity) -> Severity? {
        guard case .runsOut = pace.verdict else { return nil }
        return max(window, .warning)
    }

    /// Stale numbers must not predict anything, so a stale account has no pace.
    private func pace(of window: QuotaWindow, account: AccountUsage?) -> Pace? {
        guard let account, !account.isStale, let observedAt = account.observedAt else {
            return nil
        }
        return Pace.of(window, observedAt: observedAt, now: context.now)
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
