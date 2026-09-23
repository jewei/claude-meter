import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Provider timestamp parsing")
struct ProviderDateTests {
    private func utcDate(
        _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(
            from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    @Test("Fractional seconds with a UTC suffix")
    func parsesCanonicalFractionalZulu() throws {
        let d = try #require(ProviderDate.parseISO8601("2026-07-14T10:20:30.500Z"))
        #expect(abs(d.timeIntervalSince(utcDate(2026, 7, 14, 10, 20, 30)) - 0.5) < 0.001)
    }

    @Test func parsesWithoutFraction() throws {
        let d = try #require(ProviderDate.parseISO8601("2026-07-14T10:20:30Z"))
        #expect(d == utcDate(2026, 7, 14, 10, 20, 30))
    }

    @Test func parsesColonOffset() throws {
        let d = try #require(ProviderDate.parseISO8601("2026-07-14T15:50:30.000+05:30"))
        #expect(d == utcDate(2026, 7, 14, 10, 20, 30))
    }

    @Test func parsesBasicOffset() throws {
        let d = try #require(ProviderDate.parseISO8601("2026-07-14T10:20:30.000+0000"))
        #expect(d == utcDate(2026, 7, 14, 10, 20, 30))
    }

    @Test func rejectsGarbage() {
        #expect(ProviderDate.parseISO8601("") == nil)
        #expect(ProviderDate.parseISO8601("not-a-date") == nil)
        #expect(ProviderDate.parseISO8601("2026-07-14") == nil)
    }

    @Test("Repeated parses are consistent (cached formatters are read-only)")
    func repeatedParsesConsistent() {
        let first = ProviderDate.parseISO8601("2026-07-14T10:20:30.500Z")
        for _ in 0..<100 {
            #expect(ProviderDate.parseISO8601("2026-07-14T10:20:30.500Z") == first)
        }
    }
}
