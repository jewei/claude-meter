import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("Reset phrase")
struct ResetPhraseTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    @Test func pastOrNowReturnsNil() {
        #expect(ResetPhrase.duration(until: now, asOf: now) == nil)
        #expect(ResetPhrase.duration(until: at(-60), asOf: now) == nil)
        #expect(ResetPhrase.spoken(until: at(-60), asOf: now) == nil)
        #expect(ResetPhrase.compact(until: at(-60), asOf: now) == nil)
    }

    @Test func underAnHourShowsMinutes() {
        #expect(ResetPhrase.duration(until: at(30), asOf: now) == "1m")
        #expect(ResetPhrase.duration(until: at(42 * 60), asOf: now) == "42m")
        #expect(ResetPhrase.spoken(until: at(42 * 60), asOf: now) == "in 42m")
        #expect(ResetPhrase.compact(until: at(42 * 60), asOf: now) == "42m")
    }

    @Test func roundedUnitBoundariesDoNotEmitSixtyMinutesOrFortyEightHours() {
        #expect(ResetPhrase.duration(until: at(59 * 60 + 30), asOf: now) == "1h")
        #expect(ResetPhrase.duration(until: at(47 * 3600 + 59 * 60 + 30), asOf: now) == "2d")
    }

    @Test func underTwelveHoursKeepsMinuteDetail() {
        #expect(ResetPhrase.duration(until: at(3 * 3600 + 20 * 60), asOf: now) == "3h 20m")
        #expect(ResetPhrase.duration(until: at(3 * 3600), asOf: now) == "3h")
        #expect(ResetPhrase.compact(until: at(3 * 3600 + 20 * 60), asOf: now) == "3h")
    }

    @Test func twelveToFortyEightHoursShowsWholeHours() {
        #expect(ResetPhrase.duration(until: at(36 * 3600 + 20 * 60), asOf: now) == "36h")
        #expect(ResetPhrase.duration(until: at(47 * 3600), asOf: now) == "47h")
        #expect(ResetPhrase.compact(until: at(36 * 3600), asOf: now) == "36h")
    }

    @Test func fortyEightHoursAndBeyondKeepsHourDetail() {
        #expect(ResetPhrase.duration(until: at(48 * 3600), asOf: now) == "2d")
        #expect(ResetPhrase.duration(until: at(4 * 86400 + 3600), asOf: now) == "4d 1h")
        #expect(ResetPhrase.spoken(until: at(4 * 86400), asOf: now) == "in 4d")
        #expect(ResetPhrase.compact(until: at(4 * 86400), asOf: now) == "4d")

        let weeklySeconds = 6 * 86400 + 7 * 3600 + 45 * 60
        let weeklyReset = at(TimeInterval(weeklySeconds))
        #expect(ResetPhrase.duration(until: weeklyReset, asOf: now) == "6d 7h")
        #expect(ResetPhrase.spoken(until: weeklyReset, asOf: now) == "in 6d 7h")
        #expect(ResetPhrase.compact(until: weeklyReset, asOf: now) == "6d 7h")
    }

    @Test func dayRemaindersDoNotRoundUpToTheNextDay() {
        #expect(ResetPhrase.duration(until: at(6 * 86400 + 23 * 3600), asOf: now) == "6d 23h")
        #expect(
            ResetPhrase.duration(until: at(7 * 86400 - 30), asOf: now) == "7d")
    }
}
