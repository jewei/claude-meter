import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite("LimitWindow display")
struct LimitWindowDisplayTests {
    @Test("Formats whole percent") func whole() {
        let w = LimitWindow(percentUsed: 25)
        #expect(w.displayPercent == "25%")
    }

    @Test("Formats decimal percent") func decimal() {
        let w = LimitWindow(percentUsed: 84.5)
        #expect(w.displayPercent == "84.5%")
    }

    @Test("Formats over-limit percent") func overLimit() {
        let w = LimitWindow(percentUsed: 102)
        #expect(w.displayPercent == "100%+")
    }

    @Test("Returns nil when percent missing") func missing() {
        #expect(LimitWindow().displayPercent == nil)
    }
}

@Suite("LimitWindow resolved")
struct LimitWindowResolvedTests {
    private let now = Date(timeIntervalSince1970: 1_782_269_456)

    @Test("Future reset is unchanged") func future() {
        let w = LimitWindow(percentUsed: 42, resetsAt: now.addingTimeInterval(3600))
        #expect(w.resolved(asOf: now) == w)
    }

    @Test("Expired rolling window resets to 0% and drops countdown") func expired() {
        let w = LimitWindow(percentUsed: 25, resetsAt: now.addingTimeInterval(-6 * 3600))
        let resolved = w.resolved(asOf: now)
        #expect(resolved.percentUsed == 0)
        #expect(resolved.resetsAt == nil)
    }

    @Test("No reset time is unchanged") func noReset() {
        let w = LimitWindow(percentUsed: 30)
        #expect(w.resolved(asOf: now) == w)
    }

    @Test("Missing percent stays nil even when reset passed") func missingPercent() {
        let w = LimitWindow(percentUsed: nil, resetsAt: now.addingTimeInterval(-3600))
        #expect(w.resolved(asOf: now).percentUsed == nil)
    }
}
