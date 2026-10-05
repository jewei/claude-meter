import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct ReadingTests {
    private let issue = UsageIssue("Offline")

    @Test func failedAndStaleReadingsAlwaysNeedRefresh() {
        #expect(Reading<Int>.failed(issue).needsRefresh(at: .reference(), maxAge: 60))
        #expect(
            Reading<Int>.stale(1, observedAt: .reference(), issue: issue)
                .needsRefresh(at: .reference(), maxAge: 60))
    }

    @Test(arguments: [60.0, 300.0])
    func currentReadingNeedsRefreshAtMaxAge(maxAge: TimeInterval) {
        let reading = Reading<Int>.current(1, observedAt: .reference())
        #expect(!reading.needsRefresh(at: .reference(maxAge - 1), maxAge: maxAge))
        #expect(reading.needsRefresh(at: .reference(maxAge), maxAge: maxAge))
    }

    @Test func futureObservationNeedsRefresh() {
        let reading = Reading<Int>.current(1, observedAt: .reference(1))
        #expect(reading.needsRefresh(at: .reference(), maxAge: 60))
    }

    @Test func accessors() {
        let stale = Reading<Int>.stale(7, observedAt: .reference(), issue: issue)
        #expect(stale.value == 7)
        #expect(stale.issue == issue)
        #expect(stale.observedAt == .reference())
        #expect(stale.isStale)
        let failed = Reading<Int>.failed(issue, partial: 3)
        #expect(failed.value == 3)
        #expect(failed.observedAt == nil)
    }

    @Test func providerUsageObservationIsTheNewestAccount() {
        let usage = ProviderUsage(
            provider: .codex,
            accounts: [
                AccountUsage(id: "a", name: "A", observedAt: .reference(-60)),
                AccountUsage(id: "b", name: "B", observedAt: .reference()),
                AccountUsage.unavailable(id: "c", name: "C", issue: issue),
            ])
        #expect(usage.observedAt == .reference())
        #expect(usage.hasObservation)
        #expect(usage.account("c")?.hasObservation == false)
    }
}
