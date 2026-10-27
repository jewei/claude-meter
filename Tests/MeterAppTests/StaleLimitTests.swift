import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

/// The stale limit comes from the cadence: 600 s normally, 1500 s under strain.
@Suite struct StaleLimitTests {
    private func isStale(age: TimeInterval, staleAfter: TimeInterval) -> Bool {
        let usage = Fixture.usage(.claude, Fixture.account("a", observedAt: .reference()))
        let context = Fixture.context(
            Fixture.settings(), readings: [.claude: Fixture.current(usage)],
            now: .reference(age), staleAfter: staleAfter)
        return context.accounts(for: .claude).first?.isStale == true
    }

    @Test func aReadingOfSevenHundredSecondsIsFreshOnlyUnderStrain() {
        #expect(isStale(age: 700, staleAfter: RefreshScheduler.staleAfter))
        #expect(!isStale(age: 700, staleAfter: RefreshScheduler.constrainedStaleAfter))
    }

    /// The worst healthy age under strain: the 900 s cadence, Claude's 290 s skip of an
    /// account it checked recently, and the 90 s deadline.
    @Test func theWorstHealthyAgeUnderStrainIsCurrent() {
        #expect(!isStale(age: 1_280, staleAfter: RefreshScheduler.constrainedStaleAfter))
    }

    @Test func theStrainBorder() {
        #expect(!isStale(age: 1_499, staleAfter: RefreshScheduler.constrainedStaleAfter))
        #expect(isStale(age: 1_501, staleAfter: RefreshScheduler.constrainedStaleAfter))
    }

    @Test func theTokenNoteFollowsTheSameLimit() {
        let calendar = Calendar.fixed()
        let day = calendar.startOfDay(for: .reference())
        let account = TokenHistory(
            dailyTokens: [day: 1_000], coverageStart: day.addingTimeInterval(-.days(6)),
            observedAt: .reference(), timeZoneID: calendar.timeZone.identifier)
        let history = ProviderTokenHistory(
            provider: .claude, source: .thisMac, accounts: ["a": account],
            coverageStart: account.coverageStart, observedAt: .reference(),
            timeZoneID: calendar.timeZone.identifier)
        func note(staleAfter: TimeInterval) -> String? {
            let context = PresentationContext(
                settings: Fixture.settings(),
                histories: [.claude: .current(history, observedAt: .reference())],
                now: .reference(700), calendar: calendar, staleAfter: staleAfter)
            return TokenRowsBuilder(context: context).model(provider: .claude, account: "a")?
                .note
        }
        #expect(note(staleAfter: RefreshScheduler.staleAfter) == "Token data may be stale")
        #expect(note(staleAfter: RefreshScheduler.constrainedStaleAfter) == nil)
    }
}
