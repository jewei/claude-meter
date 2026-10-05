import Foundation
import MeterDomain
import MeterPlatform

/// What the last refresh did, successful or not, for Diagnostics only. It is never a source of
/// usage.
final class RefreshRecord: Sendable {
    private enum Outcome: Sendable {
        case usage(activeID: AccountID?, accounts: [(id: AccountID, summary: String)])
        /// The refresh as a whole failed, with the text for the user.
        case failed(String)
    }

    private struct Entry: Sendable {
        let at: Date
        let outcome: Outcome
    }

    private let entry = Locked<Entry?>(nil)

    /// - Parameter activeID: The account of the active login; nil when it is unknown.
    func record(_ usage: ProviderUsage, activeID: AccountID?, at date: Date) {
        let accounts = usage.accounts.map { account in
            (id: account.id, summary: Self.summary(account))
        }
        entry.withLock {
            $0 = Entry(at: date, outcome: .usage(activeID: activeID, accounts: accounts))
        }
    }

    /// Records a refresh that failed as a whole, so Diagnostics never shows an older success
    /// as the last refresh.
    func record(failure: ProviderError, at date: Date) {
        entry.withLock { $0 = Entry(at: date, outcome: .failed(failure.issue.message)) }
    }

    func facts() -> [DiagnosticFact] {
        guard let entry = entry.value else { return [DiagnosticFact("Last refresh", "None")] }
        let date = DiagnosticFact("Last refresh", entry.at.formatted(.iso8601))
        switch entry.outcome {
        case .usage(let activeID, let accounts):
            return [
                date, DiagnosticFact("Last refresh result", "Usage returned"),
                DiagnosticFact("Active login account", activeID?.rawValue ?? "Unknown"),
            ] + accounts.map { DiagnosticFact("Account \($0.id)", $0.summary) }
        case .failed(let message):
            return [date, DiagnosticFact("Last refresh result", "Failed: \(message)")]
        }
    }

    private static func summary(_ account: AccountUsage) -> String {
        var parts: [String] = []
        if let observedAt = account.observedAt {
            parts.append("observed \(observedAt.formatted(.iso8601))")
        }
        if let attemptedAt = account.attemptedAt {
            parts.append("attempted \(attemptedAt.formatted(.iso8601))")
        }
        if let issue = account.issue {
            parts.append("issue: \(issue.message)")
        }
        if account.sharesLogin {
            parts.append("shares its login with another account")
        }
        return parts.isEmpty ? "No reading" : parts.joined(separator: "; ")
    }
}
