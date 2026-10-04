import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct AccountSelectionTests {
    private func account(
        _ id: AccountID, used: Double?, resetsIn seconds: TimeInterval? = nil,
        observed: Bool = true, isBinding: Bool = true
    ) -> AccountUsage {
        AccountUsage(
            id: id, name: id.rawValue,
            windows: [
                QuotaWindow(
                    id: "session", title: "Session", kind: .session, usedPercent: used,
                    resetsAt: seconds.map { .reference($0) }, isBinding: isBinding)
            ],
            observedAt: observed ? .reference() : nil)
    }

    @Test func picksTheAccountNearestItsLimit() {
        let accounts = [account("personal", used: 20), account("work", used: 80)]
        #expect(AccountSelection.primary(in: accounts, pinned: nil)?.id == "work")
    }

    @Test func exactPinWins() {
        let accounts = [account("personal", used: 20), account("work", used: 80)]
        #expect(AccountSelection.primary(in: accounts, pinned: "personal")?.id == "personal")
    }

    @Test func missingPinNeverFallsBack() {
        let accounts = [account("personal", used: 20)]
        #expect(AccountSelection.primary(in: accounts, pinned: "missing") == nil)
        #expect(
            AccountSelection.primary(in: [account("x", used: 5, observed: false)], pinned: "x")
                == nil)
    }

    @Test func emptyInputSelectsNothing() {
        #expect(AccountSelection.primary(in: [], pinned: nil) == nil)
    }

    @Test func knownZeroRanksAboveUnknown() {
        let accounts = [account("unknown", used: nil), account("zero", used: 0)]
        #expect(AccountSelection.primary(in: accounts, pinned: nil)?.id == "zero")
    }

    @Test func tiesKeepInputOrder() {
        let accounts = [account("first", used: 20), account("second", used: 20)]
        #expect(AccountSelection.primary(in: accounts, pinned: nil)?.id == "first")
    }

    @Test func unavailableAccountsAreNeverSelected() {
        let accounts = [account("gone", used: 99, observed: false), account("ok", used: 1)]
        #expect(AccountSelection.primary(in: accounts, pinned: nil)?.id == "ok")
    }

    @Test func informationalWindowsDoNotRank() {
        let accounts = [account("scoped", used: 99, isBinding: false), account("ok", used: 1)]
        #expect(AccountSelection.primary(in: accounts, pinned: nil)?.id == "ok")
    }

    @Test func resolvedResetChangesTheRanking() {
        let stale = account("stale", used: 90, resetsIn: 60)
        let fresh = account("fresh", used: 20)
        let now = Date.reference(60)
        let resolved = [
            stale.resolved(at: now, isStale: true), fresh.resolved(at: now, isStale: false),
        ]
        #expect(AccountSelection.primary(in: [stale, fresh], pinned: nil)?.id == "stale")
        #expect(AccountSelection.primary(in: resolved, pinned: nil)?.id == "fresh")
        #expect(AccountSelection.primary(in: resolved, pinned: "stale")?.id == "stale")
    }
}

@Suite struct AccountUsageTests {
    private func window(_ id: String, used: Double?, resetsIn seconds: TimeInterval?) -> QuotaWindow
    {
        QuotaWindow(
            id: id, title: id, kind: .weekly, usedPercent: used,
            resetsAt: seconds.map { .reference($0) })
    }

    @Test func bindingWindowPrefersHigherUsageThenLaterReset() {
        let usage = AccountUsage(
            id: "a", name: "A",
            windows: [
                window("early", used: 50, resetsIn: 60),
                window("late", used: 50, resetsIn: 120),
                window("low", used: 10, resetsIn: 999),
            ],
            observedAt: .reference())
        #expect(usage.bindingWindow(.weekly)?.id == "late")
    }

    @Test func unknownResetCountsAsLatest() {
        let usage = AccountUsage(
            id: "a", name: "A",
            windows: [
                window("dated", used: 50, resetsIn: 60), window("open", used: 50, resetsIn: nil),
            ],
            observedAt: .reference())
        #expect(usage.bindingWindow(.weekly)?.id == "open")
    }

    @Test func retainedObservationIsStaleWithTheIssue() {
        let usage = AccountUsage(
            id: "a", name: "A", windows: [window("w", used: 70, resetsIn: -1)],
            observedAt: .reference(-600))
        let retained = usage.retained(issue: UsageIssue("Offline"), now: .reference())
        #expect(retained.isStale)
        #expect(retained.issue?.message == "Offline")
        #expect(retained.observedAt == .reference(-600))
        #expect(retained.windows.first?.usedPercent == nil)
    }

    @Test func severityIgnoresInformationalWindows() {
        let usage = AccountUsage(
            id: "a", name: "A",
            windows: [
                QuotaWindow(
                    id: "s", title: "S", kind: .scoped, usedPercent: 99, resetsAt: nil,
                    isBinding: false),
                QuotaWindow(id: "w", title: "W", kind: .weekly, usedPercent: 10, resetsAt: nil),
            ],
            observedAt: .reference())
        #expect(usage.severity(.standard) == .normal)
    }
}
