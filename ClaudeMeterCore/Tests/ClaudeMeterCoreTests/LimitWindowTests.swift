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

    @Test("Rejects non-finite percent values") func nonFinite() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for value in [Double.nan, .infinity, -.infinity] {
            let window = LimitWindow(percentUsed: value)
            #expect(window.clampedPercent == nil)
            #expect(window.displayPercent == nil)
            #expect(window.percentLeft(asOf: now) == nil)
        }
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

@Suite("ExtraUsage money")
struct ExtraUsageMoneyTests {
    @Test("Exposes exact typed minor-unit amounts and clamps invalid scales")
    func typedMoney() {
        let usage = ExtraUsage(
            isEnabled: true, usedCredits: 1_234, monthlyLimit: 5_000,
            decimalPlaces: 2, currency: "usd")

        #expect(usage.usedMoney?.minorUnits == 1_234)
        #expect(usage.usedMoney?.amount == Decimal(string: "12.34"))
        #expect(usage.usedMoney?.currency == "USD")
        #expect(ExtraUsage(isEnabled: true, decimalPlaces: -3).decimalPlaces == 0)
        // `Double(Int64.max)` rounds up to 2^63. A direct Int64 conversion traps.
        #expect(MinorUnitMoney(credits: Double(Int64.max), decimalPlaces: 0, currency: nil) == nil)
    }

    @Test("Persisted extra usage is validated through its public initializer")
    func persistedValuesAreValidated() throws {
        let json = """
            {"isEnabled":true,"usedCredits":1e308,"monthlyLimit":1e-308,
             "decimalPlaces":9223372036854775807,"utilization":null,"currency":"USD"}
            """
        let usage = try JSONDecoder().decode(ExtraUsage.self, from: Data(json.utf8))

        #expect(usage.decimalPlaces == 18)
        #expect(usage.percentUsed == nil)
        #expect(
            ExtraUsage(isEnabled: true, utilization: .infinity).utilization == nil)
    }
}
