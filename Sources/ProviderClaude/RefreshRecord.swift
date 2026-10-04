import Foundation
import MeterDomain
import MeterPlatform

/// What the last refresh did, for Diagnostics only. It is never a source of usage.
final class RefreshRecord: Sendable {
    private struct Entry: Sendable {
        let at: Date
        let activeID: AccountID
        let accounts: [(id: AccountID, summary: String)]
    }

    private let entry = Locked<Entry?>(nil)

    func record(_ usage: ProviderUsage, activeID: AccountID, at date: Date) {
        let accounts = usage.accounts.map { account in
            (id: account.id, summary: Self.summary(account))
        }
        entry.withLock { $0 = Entry(at: date, activeID: activeID, accounts: accounts) }
    }

    func facts() -> [DiagnosticFact] {
        guard let entry = entry.value else { return [DiagnosticFact("Last refresh", "None")] }
        return [
            DiagnosticFact("Last refresh", entry.at.formatted(.iso8601)),
            DiagnosticFact("Active login account", entry.activeID.rawValue),
        ] + entry.accounts.map { DiagnosticFact("Account \($0.id)", $0.summary) }
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
