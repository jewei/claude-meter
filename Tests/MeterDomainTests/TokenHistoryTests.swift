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
