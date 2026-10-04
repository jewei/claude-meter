import Foundation
import MeterDomain

/// Everything the popover shows, built from one ``PresentationContext``.
public struct PopoverModel: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// A spinner with a message.
        case loading(String)
        /// A full-size message with one action: welcome, paused, nothing set up, or an error.
        case status(StatusScreen)
        case accounts(AccountsModel)
    }

    /// `2m ago` for the main meter's observation. Nil before onboarding.
    public let updatedText: String?
    public let showsQuit: Bool
    public let showsUpdateNotice: Bool
    public let content: Content

    public init(_ context: PresentationContext) {
        let settings = context.settings
        let onboarded = settings.hasCompletedOnboarding
        let meter = MainMeter(context)
        updatedText =
            onboarded ? Formatting.age(since: meter.selected?.observedAt, now: context.now) : nil
        showsQuit = onboarded
        showsUpdateNotice = context.isUpdateAvailable
        content = Self.content(context, meter: meter)
    }

    private static func content(_ context: PresentationContext, meter: MainMeter) -> Content {
        let settings = context.settings
        guard settings.hasCompletedOnboarding else { return .status(.onboarding) }

        let automatic = CardBuilder(context: context, meter: meter).cards()
        let enabled = settings.enabledProviders
        // Sources whose switch is on, with Claude counted before it is connected.
        let switchedOn = settings.claude.needsConnection ? enabled.union([.claude]) : enabled
        if settings.isPaused, automatic.isEmpty { return .status(.paused) }
        guard !switchedOn.isEmpty else { return .status(.noSources) }
        if automatic.isEmpty {
            if !context.refreshing.isDisjoint(with: enabled) {
                return .loading(loadingMessage(enabled))
            }
            if let (provider, issue) = firstFailure(context, meter: meter) {
                return .status(.error(provider, message: issue.message))
            }
            return .status(.setup(switchedOn))
        }
        return .accounts(AccountsModel(context, meter: meter, automatic: automatic))
    }

    private static func loadingMessage(_ enabled: Set<ProviderID>) -> String {
        guard enabled.count == 1, let only = enabled.first else { return "Checking your tanks…" }
        return "Checking \(only.displayName)…"
    }

    /// The main provider's failure first, then the others in provider order.
    private static func firstFailure(
        _ context: PresentationContext, meter: MainMeter
    ) -> (ProviderID, UsageIssue)? {
        let order = [meter.provider] + ProviderID.allCases.filter { $0 != meter.provider }
        for provider in order where context.isEnabled(provider) {
            if let issue = context.readings[provider]?.issue { return (provider, issue) }
        }
        return nil
    }
}

/// The hero, notices, and cards.
public struct AccountsModel: Equatable, Sendable {
    public let notices: [Notice]
    public let hero: HeroModel
    public let cards: [CardModel]
    public let showsRingLegend: Bool
    /// Shown when more than one card can own the menu bar.
    public let dragHint: String?

    init(_ context: PresentationContext, meter: MainMeter, automatic: [CardModel]) {
        let ids = CardOrder.ordered(
            automatic: automatic.map(\.id), saved: context.settings.cards.order, main: meter.cardID)
        let byID = Dictionary(
            automatic.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cards = ids.compactMap { byID[$0] }
        hero = HeroModel(meter, context: context)
        notices = Notice.notices(context, meter: meter, hero: hero, cards: cards)
        showsRingLegend = cards.contains { if case .rings = $0.summary { true } else { false } }
        let eligible = cards.filter { $0.id.menuBarSelection != nil }.count
        dragHint = eligible > 1 ? "Drag a Claude or Codex card to the top for the menu bar." : nil
    }
}

/// A message above the hero.
public struct Notice: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// The user must act, for example sign in again.
        case action
        /// Something failed; the app retries by itself.
        case warning
        /// Old data, nothing failed.
        case info
    }

    public let text: String
    public let kind: Kind

    public var id: String { text }

    /// Notices for the main provider, and for enabled providers that failed with no card.
    /// Text that the hero already states (the reason the meter is unavailable) is left out.
    static func notices(
        _ context: PresentationContext, meter: MainMeter, hero: HeroModel, cards: [CardModel]
    ) -> [Notice] {
        var notices: [Notice] = []
        let name = meter.provider.displayName
        let several = meter.accounts.count > 1
        // A failed reading that still lists accounts reports through their own issues.
        var refreshFailed = false
        switch context.readings[meter.provider] {
        case .stale(_, _, let issue), .failed(let issue, partial: nil):
            if context.isEnabled(meter.provider) {
                notices.append(Notice(issue: issue, now: context.now))
                refreshFailed = true
            }
        default:
            break
        }
        for account in meter.accounts {
            guard let issue = account.issue else { continue }
            let text = NoticeText.text(for: issue, now: context.now)
            notices.append(
                Notice(
                    text: several ? "\(account.name): \(text)" : text,
                    kind: issue.needsAction ? .action : .warning))
        }
        // Old data that no failure above explains, whatever else is listed.
        let observed = meter.accounts.filter(\.hasObservation)
        let old = observed.filter { $0.isStale && $0.issue == nil }
        if !refreshFailed, !old.isEmpty {
            if old.count == observed.count {
                notices.append(Notice(text: "\(name) data may be stale.", kind: .info))
            } else {
                for account in old {
                    notices.append(
                        Notice(text: "\(account.name): Data may be stale.", kind: .info))
                }
            }
        }
        let providersWithCards = Set(cards.map(\.provider))
        for provider in ProviderID.allCases
        where provider != meter.provider && context.isEnabled(provider)
            && !providersWithCards.contains(provider)
        {
            guard let issue = context.readings[provider]?.issue else { continue }
            notices.append(
                Notice(
                    text:
                        "\(provider.displayName): \(NoticeText.text(for: issue, now: context.now))",
                    kind: issue.needsAction ? .action : .warning))
        }
        var seen: Set<String> = meter.selected == nil ? [hero.subtitle] : []
        return notices.filter { seen.insert($0.text).inserted }
    }

    init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    init(issue: UsageIssue, now: Date) {
        self.init(
            text: NoticeText.text(for: issue, now: now),
            kind: issue.needsAction ? .action : .warning)
    }
}

/// A full-size popover message.
public struct StatusScreen: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case getStarted
        case openSettings
    }

    public let emoji: String
    public let title: String
    public let message: String
    public let action: Action
    public let actionTitle: String

    static let onboarding = StatusScreen(
        emoji: "🚀", title: "Welcome to Claude Meter",
        message: "Connect a data source to start your engines.", action: .getStarted,
        actionTitle: "Get started →")

    static let paused = StatusScreen(
        emoji: "😴", title: "Paused", message: "Resume updates in Settings when you are ready.",
        action: .openSettings, actionTitle: "Open Settings")

    static let noSources = StatusScreen(
        emoji: "🔌", title: "No data sources on",
        message: "Turn on at least one source in Settings > Data.", action: .openSettings,
        actionTitle: "Open Settings")

    static func error(_ provider: ProviderID, message: String) -> StatusScreen {
        StatusScreen(
            emoji: "⚠️", title: "Couldn't read \(provider.displayName)", message: message,
            action: .openSettings, actionTitle: "Open Settings")
    }

    static func setup(_ enabled: Set<ProviderID>) -> StatusScreen {
        let message: String =
            switch enabled {
            case [.codex]:
                "Install Codex or run `codex login` so Claude Meter can read Codex usage."
            case [.cursor]: "Sign in to the Cursor app so Claude Meter can read your billing usage."
            case [.grok]:
                "Install Grok Build or run `grok login` so Claude Meter can read Grok usage."
            case [.claude]: "Connect Claude in Settings to read your usage."
            default: "Sign in to the enabled sources, or connect Claude in Settings."
            }
        return StatusScreen(
            emoji: "🪫", title: "No usage yet", message: message, action: .openSettings,
            actionTitle: "Open Settings")
    }
}
