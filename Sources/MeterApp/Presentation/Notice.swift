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

    /// Notices for the main provider, and the failed refresh of every other enabled provider.
    /// The issue that the hero states (the reason the meter is unavailable) is left out, also
    /// when a notice would prefix it with an account name.
    static func notices(_ context: PresentationContext, meter: MainMeter) -> [Notice] {
        var notices: [Notice] = []
        let name = meter.provider.displayName
        let several = meter.accounts.count > 1
        let reason: UsageIssue? =
            if case .unavailable(let reason) = meter.selection { reason } else { nil }
        var refreshFailed = false
        if context.isEnabled(meter.provider),
            let failure = refreshFailure(context.readings[meter.provider])
        {
            if !failure.isCarried, failure.issue != reason {
                notices.append(Notice(issue: failure.issue, now: context.now))
            }
            refreshFailed = true
        }
        for account in meter.accounts {
            guard let issue = account.issue, issue != reason else { continue }
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
        // The same rule as the main provider's: a failed refresh that no account carries.
        // The cards of these providers state their accounts' own issues and old data.
        for provider in ProviderID.allCases
        where provider != meter.provider && context.isEnabled(provider) {
            guard let failure = refreshFailure(context.readings[provider]), !failure.isCarried
            else { continue }
            let issue = failure.issue
            notices.append(
                Notice(
                    text:
                        "\(provider.displayName): \(NoticeText.text(for: issue, now: context.now))",
                    kind: issue.needsAction ? .action : .warning))
        }
        var seen: Set<String> = []
        return notices.filter { seen.insert($0.text).inserted }
    }

    /// The issue of a failed refresh, and whether an account of the reading carries it. A
    /// carried issue reports through that account's notice or card, never a second time: for
    /// example a 429 that a stale refresh and its account both report, or the first account's
    /// issue of a failed reading that observed no account. A provider error after such a
    /// reading keeps its accounts, with an issue of its own.
    private static func refreshFailure(_ reading: Reading<ProviderUsage>?)
        -> (issue: UsageIssue, isCarried: Bool)?
    {
        switch reading {
        case .stale(let value, _, let issue):
            (issue, value.accounts.contains { $0.issue == issue })
        case .failed(let issue, let partial):
            (issue, partial?.accounts.contains { $0.issue == issue } == true)
        case .current, nil: nil
        }
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
