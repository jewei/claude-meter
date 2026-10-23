import Foundation
import MeterDomain

/// The summary at the top of the popover for the main meter.
public struct HeroModel: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case full, low, empty, neutral
    }

    public let emoji: String
    public let title: String
    public let subtitle: String
    public let tone: Tone

    public var accessibilityLabel: String { "\(title). \(subtitle)" }

    public init(emoji: String, title: String, subtitle: String, tone: Tone) {
        self.emoji = emoji
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
    }

    public init(_ meter: MainMeter, context: PresentationContext) {
        let name = meter.provider.displayName
        let selected: AccountUsage
        switch meter.selection {
        case .unavailable(let reason):
            // Notices leave out this text, so the reason is stated once.
            self.init(
                emoji: "🔌", title: "\(name) meter unavailable",
                subtitle: NoticeText.text(for: reason, now: context.now), tone: .neutral)
            return
        case .account(let account):
            selected = account
        }
        guard !selected.isStale else {
            // A rate limit needs no action: the refresh retries by itself. The notice states
            // the limit, so the hero only says that the app waits.
            if let retryAt = meter.issue?.retryAt,
                let countdown = Countdown.text(until: retryAt, now: context.now)
            {
                self.init(
                    emoji: "⏳", title: "Waiting to retry",
                    subtitle: "Showing the last \(name) reading. Retrying in \(countdown).",
                    tone: .neutral)
                return
            }
            self.init(
                emoji: "🛰️", title: "Refresh needed", subtitle: "\(name) data is out of date.",
                tone: .neutral)
            return
        }
        // Stale accounts are left out: old numbers must not read as current. The old-data
        // notice names them.
        let others = meter.accounts.filter {
            $0.id != selected.id && $0.hasObservation && !$0.isStale
        }
        let severity = selected.severity(context.thresholds)
        let (emoji, title, tone) = Self.headline(severity)
        let runOut = Self.soonestRunOut(
            [selected] + others, thresholds: context.thresholds, now: context.now)
        let subtitle =
            others.isEmpty
            ? Self.singleSubtitle(selected, severity: severity, runOut: runOut, now: context.now)
            : Self.multipleSubtitle([selected] + others, runOut: runOut, context: context)
        self.init(emoji: emoji, title: title, subtitle: subtitle, tone: tone)
    }

    private static func headline(_ severity: Severity) -> (String, String, Tone) {
        switch severity {
        case .normal: ("🚀", "You're cruising", .full)
        case .warning: ("⛽️", "Pace yourself", .low)
        case .critical: ("🪫", "Almost tapped out", .empty)
        case .exhausted: ("🥵", "Take a breather", .empty)
        case .unknown: ("🛰️", "Warming up", .neutral)
        }
    }

    private static func singleSubtitle(
        _ account: AccountUsage, severity: Severity, runOut: RunOut?, now: Date
    ) -> String {
        let reset = limitText(account, runOut: runOut, now: now)
        let lead =
            switch severity {
            case .normal: "Plenty in the tank"
            case .warning: "Getting low"
            case .critical: "Almost dry"
            case .exhausted: "Out of energy"
            case .unknown: "Warming up…"
            }
        guard severity != .unknown else { return lead }
        if let reset { return "\(lead) · \(reset)" }
        return severity == .normal ? "\(lead) 🎉" : lead
    }

    /// Counts the accounts with plenty left ("fresh" in the copy: normal severity) and names
    /// the lowest account, which can be the selected one: `2 fresh · Work low · Weekly resets
    /// in 1h 8m`, or `All 3 accounts fresh 🎉`.
    private static func multipleSubtitle(
        _ accounts: [AccountUsage], runOut: RunOut?, context: PresentationContext
    ) -> String {
        let rated = accounts.map { ($0, $0.severity(context.thresholds)) }
        let plenty = rated.filter { $0.1 == .normal }.count
        let warming = rated.filter { $0.1 == .unknown }.count
        let lowest = rated.filter { $0.1 > .normal }.max { $0.0.pressure < $1.0.pressure }
        let warmingText = warming == 0 ? "" : " · \(warming) warming up"

        guard let (account, severity) = lowest else {
            let runOutText = runOut.map { " · \($0.text(naming: true, now: context.now))" } ?? ""
            if warming > 0 {
                return plenty == 0
                    ? "Warming up…\(runOutText)" : "\(plenty) fresh\(runOutText)\(warmingText)"
            }
            if !runOutText.isEmpty { return "All \(accounts.count) accounts fresh\(runOutText)" }
            return "All \(accounts.count) accounts fresh 🎉"
        }
        let word =
            switch severity {
            case .exhausted: "out of energy"
            case .warning: "low"
            default: "nearly dry"
            }
        let reset = limitText(account, runOut: runOut, now: context.now).map { " · \($0)" } ?? ""
        if plenty == 0 { return "\(account.name) is \(word)\(reset)\(warmingText)" }
        return "\(plenty) fresh · \(account.name) \(word)\(reset)\(warmingText)"
    }

    /// `Weekly resets in 1h 8m` for the most constrained binding window. Equal usage picks the
    /// later reset, because that limit blocks work for longer. Never another window's reset.
    static func limitingReset(_ account: AccountUsage, now: Date) -> String? {
        limitingWindow(account).flatMap { resetText($0, now: now) }
    }

    private static func limitingWindow(_ account: AccountUsage) -> QuotaWindow? {
        account.windows.filter { $0.isBinding && $0.usedPercent != nil }.max {
            if $0.pressure != $1.pressure { return $0.pressure < $1.pressure }
            guard let left = $0.resetsAt else { return false }
            guard let right = $1.resetsAt else { return true }
            return left < right
        }
    }

    private static func resetText(_ window: QuotaWindow, now: Date) -> String? {
        guard let date = window.resetsAt, let phrase = Countdown.phrase(until: date, now: now)
        else { return nil }
        return "\(window.title) resets \(phrase)"
    }

    /// The run-out and the reset of `account`, which the subtitle names: `Session runs out in
    /// 2h 10m, resets in 3h` when both are of one window, else `Session runs out in 2h 10m ·
    /// Weekly resets in 1h 8m`. A run-out of another account names that account.
    private static func limitText(_ account: AccountUsage, runOut: RunOut?, now: Date) -> String? {
        let limiting = limitingWindow(account)
        let reset = limiting.flatMap { resetText($0, now: now) }
        guard let runOut else { return reset }
        let isOwn = runOut.account.id == account.id
        if isOwn, runOut.window.id == limiting?.id, let date = limiting?.resetsAt,
            let phrase = Countdown.phrase(until: date, now: now)
        {
            return "\(runOut.text(naming: false, now: now)), resets \(phrase)"
        }
        return ([runOut.text(naming: !isOwn, now: now)] + [reset].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// A binding window that runs out before its reset, at the projected date.
    struct RunOut {
        let account: AccountUsage
        let window: QuotaWindow
        let date: Date

        /// `Session runs out in 2h 10m`, or `Work: Session runs out now`.
        func text(naming: Bool, now: Date) -> String {
            let text = "\(window.title) runs out \(PaceText.when(date, now: now))"
            return naming ? "\(account.name): \(text)" : text
        }
    }

    /// The binding window that runs out first. The highest pressure is not always first: weekly
    /// can be more used while the session runs out sooner. Each date comes from its own
    /// account's observation. Non-binding windows show their pace on the card only, because the
    /// hero names what limits an account. An account that is already out of energy has no
    /// run-out: another window stops it first.
    static func soonestRunOut(
        _ accounts: [AccountUsage], thresholds: Thresholds, now: Date
    ) -> RunOut? {
        var soonest: RunOut?
        for account in accounts
        where !account.isStale && account.severity(thresholds) != .exhausted {
            guard let observedAt = account.observedAt else { continue }
            for window in account.windows where window.isBinding {
                guard let pace = Pace.of(window, observedAt: observedAt, now: now),
                    case .runsOut(let date) = pace.verdict
                else { continue }
                if soonest.map({ date < $0.date }) ?? true {
                    soonest = RunOut(account: account, window: window, date: date)
                }
            }
        }
        return soonest
    }
}
