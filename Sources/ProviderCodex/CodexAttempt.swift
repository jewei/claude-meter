import Foundation
import MeterDomain

/// What one fetch did for one home: the outcome and when it finished.
struct CodexAttempt: Sendable {
    let home: CodexHome
    let outcome: CodexAccountRefresh.Outcome
    let attemptedAt: Date

    /// The account for this attempt.
    ///
    /// A failure keeps `previous` as stale only while it belongs to the current owner status
    /// (``AccountUsage/belongs(to:)``). Otherwise the account is unavailable with the issue.
    func account(previous: AccountUsage?) -> AccountUsage {
        switch outcome.result {
        case .observed(let quota, let owner):
            return quota.usage(for: home, observedAt: attemptedAt, owner: owner)
        case .failed(let error, let status):
            if let previous, previous.hasObservation, previous.belongs(to: status) {
                var kept = previous.retained(issue: error.issue, now: attemptedAt)
                kept.name = home.name
                return kept
            }
            return .unavailable(
                id: home.id, name: home.name, issue: error.issue, attemptedAt: attemptedAt)
        }
    }

    /// Sets ``AccountUsage/sharesLogin`` on observed accounts whose owner appears more than once.
    static func markingSharedLogins(_ accounts: [AccountUsage]) -> [AccountUsage] {
        let owners = accounts.filter(\.hasObservation).compactMap(\.owner)
        let counts = Dictionary(owners.map { ($0, 1) }, uniquingKeysWith: +)
        return accounts.map { account in
            var copy = account
            copy.sharesLogin =
                account.hasObservation && account.owner.map { counts[$0, default: 0] > 1 } == true
            return copy
        }
    }

    /// Diagnostics for this attempt. Memory only.
    var facts: [DiagnosticFact] {
        let label = home.label
        let result: String =
            switch outcome.result {
            case .observed: "Updated"
            case .failed(let error, _): error.localizedDescription
            }
        return [
            DiagnosticFact("\(label) home", home.directory.path),
            DiagnosticFact("\(label) auth file", outcome.login ?? "Not read"),
            DiagnosticFact("\(label) source", outcome.source?.rawValue ?? "None"),
            DiagnosticFact("\(label) last attempt", attemptedAt.formatted(.iso8601)),
            DiagnosticFact("\(label) result", result),
        ]
    }
}
