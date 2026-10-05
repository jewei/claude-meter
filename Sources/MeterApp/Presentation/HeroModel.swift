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
        let subtitle =
            others.isEmpty
            ? Self.singleSubtitle(selected, severity: severity, now: context.now)
            : Self.multipleSubtitle([selected] + others, context: context)
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
        _ account: AccountUsage, severity: Severity, now: Date
    ) -> String {
        let reset = limitingReset(account, now: now)
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
        _ accounts: [AccountUsage], context: PresentationContext
    ) -> String {
        let rated = accounts.map { ($0, $0.severity(context.thresholds)) }
        let plenty = rated.filter { $0.1 == .normal }.count
        let warming = rated.filter { $0.1 == .unknown }.count
        let lowest = rated.filter { $0.1 > .normal }.max { $0.0.pressure < $1.0.pressure }
        let warmingText = warming == 0 ? "" : " · \(warming) warming up"

        guard let (account, severity) = lowest else {
            if warming > 0 {
                return plenty == 0 ? "Warming up…" : "\(plenty) fresh\(warmingText)"
            }
            return "All \(accounts.count) accounts fresh 🎉"
        }
        let word =
            switch severity {
            case .exhausted: "out of energy"
            case .warning: "low"
            default: "nearly dry"
            }
        let reset = limitingReset(account, now: context.now).map { " · \($0)" } ?? ""
        if plenty == 0 { return "\(account.name) is \(word)\(reset)\(warmingText)" }
        return "\(plenty) fresh · \(account.name) \(word)\(reset)\(warmingText)"
    }

    /// `Weekly resets in 1h 8m` for the most constrained binding window. Equal usage picks the
    /// later reset, because that limit blocks work for longer. Never another window's reset.
    static func limitingReset(_ account: AccountUsage, now: Date) -> String? {
        let limiting = account.windows.filter { $0.isBinding && $0.usedPercent != nil }.max {
            if $0.pressure != $1.pressure { return $0.pressure < $1.pressure }
            guard let left = $0.resetsAt else { return false }
            guard let right = $1.resetsAt else { return true }
            return left < right
        }
        guard let limiting, let date = limiting.resetsAt,
            let phrase = Countdown.phrase(until: date, now: now)
        else { return nil }
        return "\(limiting.title) resets \(phrase)"
    }
}
