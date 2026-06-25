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

@Suite("LimitInfo.menuBarDisplayPercent")
struct LimitInfoMenuBarDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_782_269_456)
    private let thresholds = UsageThresholds()  // warning 80, critical 95

    @Test("Calm: shows the session window (not the higher week)") func calmShowsSession() {
        let limits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 5),
            currentWeekAllModels: LimitWindow(percentUsed: 28))
        #expect(limits.menuBarDisplayPercent(asOf: now, thresholds: thresholds) == "5%")
    }

    @Test("Elevated week: escalates to the binding window") func elevatedShowsBinding() {
        let limits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 5),
            currentWeekAllModels: LimitWindow(percentUsed: 92))
        #expect(limits.menuBarDisplayPercent(asOf: now, thresholds: thresholds) == "92%")
    }

    @Test("Calm with no session value: falls back to binding") func calmNoSession() {
        let limits = LimitInfo(
            currentSession: LimitWindow(),
            currentWeekAllModels: LimitWindow(percentUsed: 28))
        #expect(limits.menuBarDisplayPercent(asOf: now, thresholds: thresholds) == "28%")
    }

    @Test("Elevated session itself: shows the session value") func elevatedSession() {
        let limits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 85),
            currentWeekAllModels: LimitWindow(percentUsed: 28))
        #expect(limits.menuBarDisplayPercent(asOf: now, thresholds: thresholds) == "85%")
    }
}
