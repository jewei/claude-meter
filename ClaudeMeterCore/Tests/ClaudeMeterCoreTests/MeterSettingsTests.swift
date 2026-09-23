import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("MeterSettings")
struct MeterSettingsTests {

    @Test(
        "Menu-bar modes normalize before Settings reads them",
        arguments: ["forecast", "unknown", "nearest", "5h", "7d", "both"])
    func menuBarModeNormalization(stored: String) throws {
        let sourceName = "com.claudemeter.tests.menu-source.\(UUID().uuidString)"
        let source = try #require(UserDefaults(suiteName: sourceName))
        defer {
            source.removePersistentDomain(forName: sourceName)
        }
        source.set(stored, forKey: MeterSettings.menuBarWindowKey)
        let expected = ["forecast", "unknown"].contains(stored) ? "nearest" : stored

        MeterSettings.repairMenuBarWindow(defaults: source)
        #expect(source.string(forKey: MeterSettings.menuBarWindowKey) == expected)
        MeterSettings.repairMenuBarWindow(defaults: source)
        #expect(source.string(forKey: MeterSettings.menuBarWindowKey) == expected)
        source.removeObject(forKey: MeterSettings.menuBarWindowKey)
        MeterSettings.repairMenuBarWindow(defaults: source)
        #expect(source.object(forKey: MeterSettings.menuBarWindowKey) == nil)
        #expect(
            MeterSettings.MenuBarWindow.allCases.map(\.rawValue) == [
                "nearest", "5h", "7d", "both",
            ])
    }

    @Test("currentThresholds reads from injected defaults")
    func thresholdsFromDefaults() {
        let defaults = UserDefaults(suiteName: "com.claudemeter.tests.thresholds")!
        defaults.removePersistentDomain(forName: "com.claudemeter.tests.thresholds")
        defaults.set(70.0, forKey: MeterSettings.warningThresholdKey)
        defaults.set(90.0, forKey: MeterSettings.criticalThresholdKey)

        let thresholds = MeterSettings.currentThresholds(defaults: defaults)
        #expect(thresholds.warning == 70)
        #expect(thresholds.critical == 90)
        #expect(thresholds.severity(for: 75) == .warning)
    }

    @Test("Threshold repair replaces corrupt settings with safe values")
    func thresholdRepair() {
        let suiteName = "com.claudemeter.tests.threshold-repair"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: MeterSettings.warningThresholdKey)
        defaults.set(1e308, forKey: MeterSettings.criticalThresholdKey)
        let repaired = MeterSettings.repairThresholdSettings(defaults: defaults)

        #expect(repaired == .default)
        #expect(defaults.double(forKey: MeterSettings.warningThresholdKey) == 80)
        #expect(defaults.double(forKey: MeterSettings.criticalThresholdKey) == 95)

        defaults.set(90.0, forKey: MeterSettings.warningThresholdKey)
        defaults.set(60.0, forKey: MeterSettings.criticalThresholdKey)
        let ordered = MeterSettings.repairThresholdSettings(defaults: defaults)
        #expect(ordered.warning == 90)
        #expect(ordered.critical == 95)
    }

    @Test("UI staleness has ten-minute headroom, including older stored settings")
    func staleDetection() {
        let defaults = UserDefaults(suiteName: "com.claudemeter.tests.stale")!
        defaults.removePersistentDomain(forName: "com.claudemeter.tests.stale")
        defer { defaults.removePersistentDomain(forName: "com.claudemeter.tests.stale") }
        let now = Date()
        let fresh = now.addingTimeInterval(-600)
        let old = now.addingTimeInterval(-601)
        #expect(MeterSettings.resolvedStaleAfterSeconds(defaults: defaults) == 600)
        defaults.set(180.0, forKey: MeterSettings.staleAfterSecondsKey)

        #expect(
            !MeterSettings.isSnapshotStale(
                lastPollAt: fresh, defaults: defaults, now: now))
        #expect(
            MeterSettings.isSnapshotStale(
                lastPollAt: old, defaults: defaults, now: now))
        #expect(
            MeterSettings.resolvedStaleAfterSeconds(defaults: defaults) == 600)

        defaults.set(1200.0, forKey: MeterSettings.staleAfterSecondsKey)
        #expect(MeterSettings.resolvedStaleAfterSeconds(defaults: defaults) == 1200)
        defaults.set(Double.infinity, forKey: MeterSettings.staleAfterSecondsKey)
        #expect(
            MeterSettings.resolvedStaleAfterSeconds(defaults: defaults)
                == MeterSettings.defaultStaleAfterSeconds)
        defaults.set(1e308, forKey: MeterSettings.staleAfterSecondsKey)
        #expect(
            MeterSettings.resolvedStaleAfterSeconds(defaults: defaults)
                == MeterSettings.defaultStaleAfterSeconds)
        defaults.set(Double.greatestFiniteMagnitude, forKey: MeterSettings.staleAfterSecondsKey)
        #expect(
            MeterSettings.resolvedStaleAfterSeconds(defaults: defaults)
                == MeterSettings.defaultStaleAfterSeconds)
    }

    @Test("Staleness rejects invalid and far-future poll dates")
    func staleDetectionRejectsInvalidDates() {
        let defaultsName = "com.claudemeter.tests.stale-dates"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(
            !MeterSettings.isSnapshotStale(
                lastPollAt: now.addingTimeInterval(300),
                defaults: defaults,
                now: now))
        #expect(
            MeterSettings.isSnapshotStale(
                lastPollAt: now.addingTimeInterval(301),
                defaults: defaults,
                now: now))
        #expect(
            MeterSettings.isSnapshotStale(
                lastPollAt: .distantFuture,
                defaults: defaults,
                now: now))
        #expect(
            MeterSettings.isSnapshotStale(
                lastPollAt: Date(timeIntervalSinceReferenceDate: .nan),
                defaults: defaults,
                now: now))
    }

    @Test("Elapsed seconds are bounded and nonnegative")
    func elapsedSecondsAreBounded() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(now.boundedNonnegativeElapsedSeconds(since: now.addingTimeInterval(60)) == 0)
        #expect(
            now.boundedNonnegativeElapsedSeconds(
                since: Date(timeIntervalSinceReferenceDate: .nan)) == 0)
        #expect(
            now.boundedNonnegativeElapsedSeconds(
                since: Date(timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude))
                == Int.max)
    }

    @Test("Main meter defaults to Claude and keeps provider account pins separate")
    func mainMeterMigrationDefaults() {
        let defaultsName = "com.claudemeter.tests.main-meter"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        #expect(MeterSettings.resolvedMainMeterProvider(from: defaults) == .claude)
        defaults.set("codex", forKey: MeterSettings.mainMeterProviderKey)
        defaults.set("claude-work", forKey: MeterSettings.menuBarAccountKey)
        defaults.set("/tmp/codex", forKey: MeterSettings.codexMainMeterAccountKey)

        #expect(MeterSettings.resolvedMainMeterProvider(from: defaults) == .codex)
        #expect(
            MeterSettings.mainMeterAccountSelection(
                provider: .claude, defaults: defaults)
                == .account(key: "claude-work"))
        #expect(
            MeterSettings.mainMeterAccountSelection(
                provider: .codex, defaults: defaults)
                == .account(key: "/tmp/codex"))
    }

    @Test("Main meter policy keeps pins exact and applies provider defaults")
    func mainMeterAccountPolicy() {
        func reading(_ provider: MainMeterProvider, _ id: String, _ used: Double)
            -> MainMeterReading
        {
            MainMeterReading(
                provider: provider,
                accountID: id,
                accountLabel: id,
                limits: LimitInfo(currentSession: LimitWindow(percentUsed: used)),
                observedAt: Date(timeIntervalSince1970: 100))
        }

        let claude = [reading(.claude, "active", 20), reading(.claude, "near", 95)]
        #expect(MainMeterPolicy.primary(from: claude, pinnedAccountID: nil)?.accountID == "near")

        let codex = [reading(.codex, "first", 20), reading(.codex, "near", 95)]
        #expect(MainMeterPolicy.primary(from: codex, pinnedAccountID: nil)?.accountID == "near")
        #expect(MainMeterPolicy.primary(from: codex, pinnedAccountID: "missing") == nil)
        #expect(MainMeterPolicy.considered(codex, pinnedAccountID: "missing").isEmpty)
        #expect(
            MainMeterPolicy.considered(codex, pinnedAccountID: "first").map(\.accountID)
                == ["first"])

    }

    @Test("Nearest-limit selection follows authoritative resets")
    func selectionChangesAfterReset() {
        let expiring = MainMeterReading(
            provider: .claude,
            accountID: "expiring",
            accountLabel: "Expiring",
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 95,
                    resetsAt: Date(timeIntervalSince1970: 150))),
            observedAt: Date(timeIntervalSince1970: 100))
        let steady = MainMeterReading(
            provider: .claude,
            accountID: "steady",
            accountLabel: "Steady",
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 80,
                    resetsAt: Date(timeIntervalSince1970: 300))),
            observedAt: Date(timeIntervalSince1970: 100))
        let beforeReset = MainMeterPolicy.primary(
            from: [expiring, steady], pinnedAccountID: nil,
            asOf: Date(timeIntervalSince1970: 100))
        let afterReset = MainMeterPolicy.primary(
            from: [expiring, steady], pinnedAccountID: nil,
            asOf: Date(timeIntervalSince1970: 200))
        #expect(beforeReset?.accountID == "expiring")
        #expect(afterReset?.accountID == "steady")
    }

    @Test("typed appearance settings reject unknown persisted strings")
    func typedAppearanceFallbacks() {
        let defaultsName = "com.claudemeter.tests.appearance"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("future-provider", forKey: MeterSettings.mainMeterProviderKey)

        #expect(MeterSettings.resolvedMainMeterProvider(from: defaults) == .claude)
        #expect(MeterSettings.MenuBarAccountSelection(storedValue: "nearest") == .nearest)
        #expect(
            MeterSettings.MenuBarAccountSelection(storedValue: "claude-work")
                == .account(key: "claude-work"))
    }
}
