import Foundation
import Testing

@testable import ClaudeMeterCore

struct TokenUsageTests {
    @Test func sevenCalendarDaysIncludeTodayAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let range = try #require(
            TokenUsagePeriod.lastSevenDays.interval(asOf: now, calendar: calendar))
        #expect(range.duration == 167 * 3600)
        var daily: [Date: Int64] = [:]
        for offset in -7...0 {
            let day = try #require(
                calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)))
            daily[day] = offset == -7 ? 10_000 : Int64(offset + 7)
        }
        let snapshot = TokenUsageSnapshot(
            provider: .claude, daily: daily, periodStart: range.start, observedAt: now,
            timeZoneID: calendar.timeZone.identifier)
        #expect(snapshot.tokens(for: .today, asOf: now, calendar: calendar) == 7)
        #expect(snapshot.tokens(for: .yesterday, asOf: now, calendar: calendar) == 6)
        #expect(snapshot.tokens(for: .lastSevenDays, asOf: now, calendar: calendar) == 28)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        #expect(snapshot.tokens(for: .today, asOf: tomorrow, calendar: calendar) == nil)
    }

    @Test func missingCoverageAndChangedTimeZoneRemainUnknown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_856_000)
        let start = try #require(
            TokenUsagePeriod.lastSevenDays.interval(asOf: now, calendar: calendar)
        ).start
        let empty = TokenUsageSnapshot(
            provider: .grok, daily: [:], periodStart: start, observedAt: now,
            timeZoneID: calendar.timeZone.identifier, hasRecords: false)
        #expect(empty.tokens(for: .today, asOf: now, calendar: calendar) == nil)
        let zero = TokenUsageSnapshot(
            provider: .cursor, daily: [:], periodStart: start, observedAt: now,
            timeZoneID: calendar.timeZone.identifier)
        #expect(zero.tokens(for: .lastSevenDays, asOf: now, calendar: calendar) == 0)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        #expect(zero.tokens(for: .today, asOf: now, calendar: calendar) == nil)
    }

    @Test func accountHistoryUsesOnlyThatAccountsFolders() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_856_000)
        let today = calendar.startOfDay(for: now)
        let start = try #require(
            TokenUsagePeriod.lastSevenDays.interval(asOf: now, calendar: calendar)
        ).start
        func snapshot(
            _ count: Int64, accounts: [String: TokenUsageSnapshot] = [:]
        ) -> TokenUsageSnapshot {
            TokenUsageSnapshot(
                provider: .claude, daily: [today: count], periodStart: start, observedAt: now,
                timeZoneID: calendar.timeZone.identifier, accounts: accounts)
        }
        let local = snapshot(110, accounts: ["claude": snapshot(100), "claude-work": snapshot(10)])
        #expect(
            local.account("claude-work").tokens(for: .today, asOf: now, calendar: calendar) == 10)
        // An account with no local folder has no records, not the provider total.
        let unmapped = local.account("unmapped")
        #expect(!unmapped.hasRecords)
        #expect(unmapped.tokens(for: .today, asOf: now, calendar: calendar) == nil)
        // A source without folders, such as Cursor's export, belongs to its one account.
        let export = snapshot(42)
        #expect(export.account("default") == export)
    }

    @Test func invalidDatesAndOverflowNeverBecomeCounts() throws {
        let now = Date(timeIntervalSince1970: 1_790_856_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let start = try #require(
            TokenUsagePeriod.lastSevenDays.interval(asOf: now, calendar: calendar)
        ).start
        let snapshot = TokenUsageSnapshot(
            provider: .codex, daily: [today: .max, yesterday: 1], periodStart: start,
            observedAt: now,
            timeZoneID: calendar.timeZone.identifier)
        #expect(snapshot.tokens(for: .lastSevenDays, asOf: now, calendar: calendar) == nil)
        #expect(
            TokenUsagePeriod.today.interval(
                asOf: Date(timeIntervalSince1970: .infinity), calendar: calendar) == nil)
    }
}
