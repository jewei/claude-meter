import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct TokenHistoryTests {
    private let calendar = Calendar.fixed("UTC")
    private var today: Date { calendar.startOfDay(for: .reference()) }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }

    private func history(
        _ daily: [Int: Int64], coverageDays: Int = -6, timeZoneID: String? = nil,
        hasRecords: Bool = true
    ) -> TokenHistory {
        TokenHistory(
            dailyTokens: Dictionary(uniqueKeysWithValues: daily.map { (day($0.key), $0.value) }),
            coverageStart: day(coverageDays), observedAt: .reference(),
            timeZoneID: timeZoneID ?? calendar.timeZone.identifier,
            hasRecords: hasRecords)
    }

    @Test func sumsEachPeriod() {
        let history = history([0: 10, -1: 20, -6: 5, -7: 1000])
        #expect(history.tokens(in: .today, now: .reference(), calendar: calendar) == 10)
        #expect(history.tokens(in: .yesterday, now: .reference(), calendar: calendar) == 20)
        #expect(history.tokens(in: .lastSevenDays, now: .reference(), calendar: calendar) == 35)
    }

    @Test func coveredEmptyDayIsZero() {
        #expect(history([:]).tokens(in: .today, now: .reference(), calendar: calendar) == 0)
    }

    @Test func noRecordsIsUnknown() {
        let empty = history([:], hasRecords: false)
        #expect(empty.tokens(in: .today, now: .reference(), calendar: calendar) == nil)
    }

    @Test func uncoveredPeriodIsUnknown() {
        let shortHistory = history([0: 1], coverageDays: 0)
        #expect(
            shortHistory.tokens(in: .lastSevenDays, now: .reference(), calendar: calendar) == nil)
        #expect(shortHistory.tokens(in: .today, now: .reference(), calendar: calendar) == 1)
    }

    @Test func observationFromAnEarlierDayCannotAnswerToday() {
        let tomorrow = Date.reference(.days(1))
        #expect(history([0: 1]).tokens(in: .today, now: tomorrow, calendar: calendar) == nil)
    }

    @Test(arguments: [TokenPeriod.yesterday, .lastSevenDays])
    func observationFromAnEarlierDayCannotAnswerAPeriodThatEndedLater(period: TokenPeriod) {
        // Observed yesterday at 10:00: the rest of yesterday and all of today are missing.
        let yesterdayMorning = TokenHistory(
            dailyTokens: [day(-1): 100], coverageStart: day(-7),
            observedAt: day(-1).addingTimeInterval(.hours(10)),
            timeZoneID: calendar.timeZone.identifier)
        #expect(yesterdayMorning.tokens(in: period, now: .reference(), calendar: calendar) == nil)
        // Observed five days ago: five days are missing.
        let older = TokenHistory(
            dailyTokens: [day(-5): 7], coverageStart: day(-12),
            observedAt: day(-5).addingTimeInterval(.hours(12)),
            timeZoneID: calendar.timeZone.identifier)
        #expect(older.tokens(in: period, now: .reference(), calendar: calendar) == nil)
    }

    @Test func observationEarlierTodayAnswersEveryPeriod() {
        let morning = TokenHistory(
            dailyTokens: [day(-1): 20, day(0): 10], coverageStart: day(-6),
            observedAt: today.addingTimeInterval(.minutes(1)),
            timeZoneID: calendar.timeZone.identifier)
        #expect(morning.tokens(in: .today, now: .reference(), calendar: calendar) == 10)
        #expect(morning.tokens(in: .yesterday, now: .reference(), calendar: calendar) == 20)
        #expect(morning.tokens(in: .lastSevenDays, now: .reference(), calendar: calendar) == 30)
    }

    @Test func timeZoneChangeIsUnknown() {
        let other = history([0: 1], timeZoneID: "Asia/Tokyo")
        #expect(other.tokens(in: .today, now: .reference(), calendar: calendar) == nil)
    }

    @Test func overflowIsUnknown() {
        let huge = history([0: .max, -1: .max])
        #expect(huge.tokens(in: .lastSevenDays, now: .reference(), calendar: calendar) == nil)
    }

    @Test func invalidEntriesMakeHistoryPartial() {
        let partial = TokenHistory(
            dailyTokens: [day(0): -1], coverageStart: day(-6), observedAt: .reference(),
            timeZoneID: calendar.timeZone.identifier)
        #expect(partial.isPartial)
        #expect(partial.dailyTokens.isEmpty)
    }

    @Test func lastSevenDaysIncludesToday() throws {
        let interval = try #require(
            TokenPeriod.lastSevenDays.interval(at: .reference(), calendar: calendar))
        #expect(interval.start == day(-6))
        #expect(interval.end == day(1))
    }

    @Test func accountWithoutRecordsReadsAsUnknown() {
        let provider = ProviderTokenHistory(
            provider: .claude, source: .thisMac, accounts: ["claude": history([0: 5])],
            coverageStart: day(-6), observedAt: .reference(),
            timeZoneID: calendar.timeZone.identifier)
        #expect(
            provider.history(for: "claude").tokens(
                in: .today, now: .reference(), calendar: calendar) == 5)
        #expect(provider.history(for: "other").hasRecords == false)
    }
}

/// Cost estimates share the coverage rules of token counts.
@Suite struct TokenHistoryCostTests {
    private let calendar = Calendar.fixed()

    private func history(
        cost: [Int: String] = [:], unpriced: [Int: Int64] = [:], isPartial: Bool = false,
        observedAt: Date = .reference()
    ) -> TokenHistory {
        let today = calendar.startOfDay(for: .reference())
        func day(_ offset: Int) -> Date { today.addingTimeInterval(.days(Double(offset))) }
        return TokenHistory(
            dailyTokens: [day(0): 1_000, day(-1): 1_000], coverageStart: day(-6),
            observedAt: observedAt, timeZoneID: calendar.timeZone.identifier,
            isPartial: isPartial,
            dailyCost: Dictionary(
                uniqueKeysWithValues: cost.map { (day($0.key), Decimal(string: $0.value) ?? 0) }),
            dailyUnpricedTokens: Dictionary(
                uniqueKeysWithValues: unpriced.map { (day($0.key), $0.value) }))
    }

    private func cost(_ history: TokenHistory, _ period: TokenPeriod = .today) -> CostEstimate? {
        history.cost(in: period, now: .reference(), calendar: calendar)
    }

    @Test func aCompleteEstimate() {
        let estimate = cost(history(cost: [0: "1.25", -1: "2"]), .lastSevenDays)
        #expect(estimate == CostEstimate(amount: Decimal(string: "3.25") ?? 0, isComplete: true))
    }

    @Test func unpricedTokensOrAPartialHistoryMakeItIncomplete() {
        #expect(cost(history(cost: [0: "1"], unpriced: [0: 5]))?.isComplete == false)
        #expect(cost(history(cost: [0: "1"], isPartial: true))?.isComplete == false)
        // Unpriced tokens of another day do not touch today's estimate.
        #expect(cost(history(cost: [0: "1"], unpriced: [-1: 5]))?.isComplete == true)
    }

    /// No priced token gives no estimate, not $0.
    @Test func nothingPricedGivesNoEstimate() {
        #expect(cost(history(unpriced: [0: 5])) == nil)
        #expect(
            history(unpriced: [0: 5]).unpricedTokens(
                in: .today, now: .reference(), calendar: calendar) == 5)
    }

    @Test func anOldHistoryCannotAnswer() {
        let old = history(cost: [0: "1"], observedAt: .reference(-.days(1)))
        #expect(cost(old) == nil)
        #expect(old.unpricedTokens(in: .today, now: .reference(), calendar: calendar) == nil)
    }
}

/// A period whose unpriced tokens do not fit in `Int64` keeps its estimate, as incomplete.
@Suite struct TokenHistoryCostOverflowTests {
    @Test func anOverflowingUnpricedPeriodIsIncomplete() {
        let calendar = Calendar.fixed()
        let today = calendar.startOfDay(for: .reference())
        let yesterday = today.addingTimeInterval(-.days(1))
        let history = TokenHistory(
            dailyTokens: [today: 1, yesterday: 1],
            coverageStart: today.addingTimeInterval(-.days(6)),
            observedAt: .reference(), timeZoneID: calendar.timeZone.identifier,
            dailyCost: [today: 1],
            dailyUnpricedTokens: [today: Int64.max - 1, yesterday: Int64.max - 1])
        let estimate = history.cost(in: .lastSevenDays, now: .reference(), calendar: calendar)
        #expect(estimate == CostEstimate(amount: 1, isComplete: false))
    }
}
