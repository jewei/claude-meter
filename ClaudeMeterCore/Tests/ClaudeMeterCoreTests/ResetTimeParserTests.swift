import Testing
import Foundation
@testable import ClaudeMeterCore

// Fixed reference point: 2026-06-22 06:00:00 UTC
// In Asia/Kuala_Lumpur (UTC+8): 2026-06-22 14:00:00 (2:00 PM MYT)
private let fixedNow = Date(timeIntervalSince1970: 1_782_108_000) // 2026-06-22T06:00:00Z
private let klTZ = TimeZone(identifier: "Asia/Kuala_Lumpur")!
private let utcTZ = TimeZone(abbreviation: "UTC")!

@Suite("ResetTimeParser")
struct ResetTimeParserTests {

    // MARK: - Time-only formats

    @Test("Parses h:mma format (future same day)")
    func timeOnlyHMMA() throws {
        // 2:50pm MYT = 06:50 UTC — still in the future at 06:00 UTC
        let result = ResetTimeParser.parse("2:50pm (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        // 2026-06-22T06:00:00Z + 50 min = 2026-06-22T06:50:00Z
        let expected = Date(timeIntervalSince1970: 1_782_111_000)
        #expect(result != nil)
        #expect(abs(result!.timeIntervalSince(expected)) < 60, "Expected ~06:50 UTC, got \(result!)")
    }

    @Test("Parses ha format")
    func timeOnlyHA() throws {
        // 3pm MYT = 07:00 UTC — still in the future at 06:00 UTC
        let result = ResetTimeParser.parse("3pm (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        // 2026-06-22T06:00:00Z + 60 min = 2026-06-22T07:00:00Z
        let expected = Date(timeIntervalSince1970: 1_782_111_600)
        #expect(abs(result!.timeIntervalSince(expected)) < 60)
    }

    @Test("Parses h:mm a format (with space before AM/PM)")
    func timeOnlyHMMSpace() throws {
        let result = ResetTimeParser.parse("2:50 PM (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        let expected = Date(timeIntervalSince1970: 1_782_111_000) // same as h:mma
        #expect(abs(result!.timeIntervalSince(expected)) < 60)
    }

    @Test("Rolls to next day when time is in the past")
    func timeOnlyRollsToNextDay() throws {
        // 1:00pm MYT = 05:00 UTC — already past at 06:00 UTC
        let result = ResetTimeParser.parse("1:00pm (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        // Should be 2026-06-23T05:00:00Z (next day)
        #expect(result! > fixedNow, "Should be after now")
        let comps = Calendar.current.dateComponents(in: klTZ, from: result!)
        #expect(comps.day == 23)
        #expect(comps.hour == 13)
    }

    // MARK: - Date + time formats

    @Test("Parses MMM d at ha")
    func dateTimeShortMonth() throws {
        let result = ResetTimeParser.parse("Jun 27 at 3pm (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        let comps = Calendar.current.dateComponents(in: klTZ, from: result!)
        #expect(comps.month == 6)
        #expect(comps.day == 27)
        #expect(comps.hour == 15)
        #expect(comps.minute == 0)
    }

    @Test("Parses MMMM d at h:mm a (long month, space AM/PM)")
    func dateTimeLongMonthSpaceAMPM() throws {
        let result = ResetTimeParser.parse("June 27 at 3:00 PM (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        let comps = Calendar.current.dateComponents(in: klTZ, from: result!)
        #expect(comps.month == 6)
        #expect(comps.day == 27)
        #expect(comps.hour == 15)
        #expect(comps.minute == 0)
    }

    @Test("Parses MMM d at h:mma")
    func dateTimeHMMA() throws {
        let result = ResetTimeParser.parse("Jun 27 at 2:50pm (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        let comps = Calendar.current.dateComponents(in: klTZ, from: result!)
        #expect(comps.day == 27)
        #expect(comps.hour == 14)
        #expect(comps.minute == 50)
    }

    // MARK: - Timezone fallback

    @Test("Uses fallback timezone when none present")
    func fallbackTimezone() throws {
        // "2:50pm" with no timezone, fallback = UTC
        // At fixedNow (06:00 UTC), 2:50pm UTC is in the future
        let result = ResetTimeParser.parse("2:50pm", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        let comps = Calendar.current.dateComponents(in: utcTZ, from: result!)
        #expect(comps.hour == 14)
        #expect(comps.minute == 50)
    }

    // MARK: - Year resolution

    @Test("Resolves to next year for past month/day dates")
    func yearRollsForward() throws {
        // "Jan 5 at 3pm" when now = June 2026 → should be Jan 5 2027
        let result = ResetTimeParser.parse("Jan 5 at 3pm (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        let comps = Calendar.current.dateComponents(in: klTZ, from: result!)
        #expect(comps.year == 2027)
        #expect(comps.month == 1)
        #expect(comps.day == 5)
    }

    @Test("Rolls forward when date is in the past within 24 hours")
    func recentPastDateRollsForward() throws {
        // "Jun 21 at 3pm" when now = Jun 22 14:00 MYT → should be Jun 21 2027
        let result = ResetTimeParser.parse("Jun 21 at 3pm (Asia/Kuala_Lumpur)", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result != nil)
        #expect(result! > fixedNow)
        let comps = Calendar.current.dateComponents(in: klTZ, from: result!)
        #expect(comps.year == 2027)
        #expect(comps.month == 6)
        #expect(comps.day == 21)
    }

    @Test("hasTimezoneIdentifier detects IANA timezone")
    func hasTimezone() {
        #expect(ResetTimeParser.hasTimezoneIdentifier("2:50pm (Asia/Kuala_Lumpur)"))
        #expect(!ResetTimeParser.hasTimezoneIdentifier("2:50pm"))
        #expect(!ResetTimeParser.hasTimezoneIdentifier("2:50pm (Not/A/Zone)"))
    }

    // MARK: - Invalid input

    @Test("Returns nil for unparseable text")
    func returnsNilForGarbage() {
        let result = ResetTimeParser.parse("not a time", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result == nil)
    }

    @Test("Returns nil for empty string")
    func returnsNilForEmpty() {
        let result = ResetTimeParser.parse("", now: fixedNow, fallbackTimeZone: utcTZ)
        #expect(result == nil)
    }
}
