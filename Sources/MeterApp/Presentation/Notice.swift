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
            let issue = refreshIssue(context.readings[meter.provider])
        {
            if issue != reason { notices.append(Notice(issue: issue, now: context.now)) }
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
            guard let issue = refreshIssue(context.readings[provider]) else { continue }
            notices.append(
                Notice(
                    text:
                        "\(provider.displayName): \(NoticeText.text(for: issue, now: context.now))",
                    kind: issue.needsAction ? .action : .warning))
        }
        var seen: Set<String> = []
        return notices.filter { seen.insert($0.text).inserted }
    }

    /// The issue of a failed refresh. A failed reading whose accounts carry its issue (the
    /// first account's issue when no account was observed) reports through their notices or
    /// cards. A provider error after such a reading keeps its accounts, with an issue of its
    /// own.
    private static func refreshIssue(_ reading: Reading<ProviderUsage>?) -> UsageIssue? {
        switch reading {
        case .stale(_, _, let issue): issue
        case .failed(let issue, let partial):
            partial?.accounts.contains { $0.issue == issue } == true ? nil : issue
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
