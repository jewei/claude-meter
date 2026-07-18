import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

/// Parity pins for `JournalReader.parseTimestamp`/`dayString` — these run per
/// transcript line in all three scanners, so the implementation is free to swap
/// formatter strategies (e.g. cached ISO8601 fast path) as long as these hold.
@Suite("JournalReader timestamp parsing")
struct JournalTimestampTests {
    private func utcDate(
        _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(
            from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    @Test("Claude Code's canonical format: 3 fraction digits + Z")
    func parsesCanonicalFractionalZulu() throws {
        let d = try #require(JournalReader.parseTimestamp("2026-07-14T10:20:30.500Z"))
        #expect(abs(d.timeIntervalSince(utcDate(2026, 7, 14, 10, 20, 30)) - 0.5) < 0.001)
    }

    @Test func parsesWithoutFraction() throws {
        let d = try #require(JournalReader.parseTimestamp("2026-07-14T10:20:30Z"))
        #expect(d == utcDate(2026, 7, 14, 10, 20, 30))
    }

    @Test func parsesColonOffset() throws {
        let d = try #require(JournalReader.parseTimestamp("2026-07-14T15:50:30.000+05:30"))
        #expect(d == utcDate(2026, 7, 14, 10, 20, 30))
    }

    @Test func parsesBasicOffset() throws {
        let d = try #require(JournalReader.parseTimestamp("2026-07-14T10:20:30.000+0000"))
        #expect(d == utcDate(2026, 7, 14, 10, 20, 30))
    }

    @Test func rejectsGarbage() {
        #expect(JournalReader.parseTimestamp("") == nil)
        #expect(JournalReader.parseTimestamp("not-a-date") == nil)
        #expect(JournalReader.parseTimestamp("2026-07-14") == nil)
    }

    @Test("dayString uses the local calendar day")
    func dayStringIsLocalDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 12))!
        #expect(JournalReader.dayString(from: date) == "2026-07-14")
    }

    @Test("Repeated parses are consistent (cached formatters are read-only)")
    func repeatedParsesConsistent() {
        let first = JournalReader.parseTimestamp("2026-07-14T10:20:30.500Z")
        for _ in 0..<100 {
            #expect(JournalReader.parseTimestamp("2026-07-14T10:20:30.500Z") == first)
        }
    }
}
