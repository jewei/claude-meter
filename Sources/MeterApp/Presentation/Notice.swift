import Foundation
import MeterDomain

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
