import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("AppGroupConfig")
struct AppGroupConfigTests {

    @Test("currentThresholds reads from injected defaults")
    func thresholdsFromDefaults() {
        let defaults = UserDefaults(suiteName: "com.claudemeter.tests.thresholds")!
        defaults.removePersistentDomain(forName: "com.claudemeter.tests.thresholds")
        defaults.set(70.0, forKey: AppGroupConfig.warningThresholdKey)
        defaults.set(90.0, forKey: AppGroupConfig.criticalThresholdKey)

        // shared: nil → read purely from the injected suite (hermetic; the real App
        // Group suite the running app syncs into must not leak in).
        let thresholds = AppGroupConfig.currentThresholds(shared: nil, defaults: defaults)
        #expect(thresholds.warning == 70)
        #expect(thresholds.critical == 90)
        #expect(thresholds.severity(for: 75) == .warning)
    }

    @Test("Threshold repair replaces corrupt settings with safe values")
    func thresholdRepair() {
        let suiteName = "com.claudemeter.tests.threshold-repair"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: AppGroupConfig.warningThresholdKey)
        defaults.set(1e308, forKey: AppGroupConfig.criticalThresholdKey)
        let repaired = AppGroupConfig.repairThresholdSettings(defaults: defaults)

        #expect(repaired == .default)
        #expect(defaults.double(forKey: AppGroupConfig.warningThresholdKey) == 80)
        #expect(defaults.double(forKey: AppGroupConfig.criticalThresholdKey) == 95)

        defaults.set(90.0, forKey: AppGroupConfig.warningThresholdKey)
        defaults.set(60.0, forKey: AppGroupConfig.criticalThresholdKey)
        let ordered = AppGroupConfig.repairThresholdSettings(defaults: defaults)
        #expect(ordered.warning == 90)
        #expect(ordered.critical == 95)
    }

    @Test("isSnapshotStale respects staleAfterSeconds")
    func staleDetection() {
        let defaults = UserDefaults(suiteName: "com.claudemeter.tests.stale")!
        defaults.removePersistentDomain(forName: "com.claudemeter.tests.stale")
        defaults.set(120.0, forKey: AppGroupConfig.staleAfterSecondsKey)

        let now = Date()
        let fresh = now.addingTimeInterval(-60)
        let old = now.addingTimeInterval(-180)

        #expect(
            !AppGroupConfig.isSnapshotStale(
                lastPollAt: fresh, shared: nil, defaults: defaults, now: now))
        #expect(
            AppGroupConfig.isSnapshotStale(
                lastPollAt: old, shared: nil, defaults: defaults, now: now))
        #expect(
            AppGroupConfig.resolvedStaleAfterSeconds(shared: nil, defaults: defaults) == 120)

        defaults.set(Double.infinity, forKey: AppGroupConfig.staleAfterSecondsKey)
        #expect(
            AppGroupConfig.resolvedStaleAfterSeconds(shared: nil, defaults: defaults)
                == AppGroupConfig.defaultStaleAfterSeconds)
        defaults.set(1e308, forKey: AppGroupConfig.staleAfterSecondsKey)
        #expect(
            AppGroupConfig.resolvedStaleAfterSeconds(shared: nil, defaults: defaults)
                == AppGroupConfig.defaultStaleAfterSeconds)
        defaults.set(Double.greatestFiniteMagnitude, forKey: AppGroupConfig.staleAfterSecondsKey)
        #expect(
            AppGroupConfig.resolvedStaleAfterSeconds(shared: nil, defaults: defaults)
                == AppGroupConfig.defaultStaleAfterSeconds)
    }

    @Test("Staleness rejects invalid and far-future poll dates")
    func staleDetectionRejectsInvalidDates() {
        let defaultsName = "com.claudemeter.tests.stale-dates"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(
            !AppGroupConfig.isSnapshotStale(
                lastPollAt: now.addingTimeInterval(300),
                shared: nil,
                defaults: defaults,
                now: now))
        #expect(
            AppGroupConfig.isSnapshotStale(
                lastPollAt: now.addingTimeInterval(301),
                shared: nil,
                defaults: defaults,
                now: now))
        #expect(
            AppGroupConfig.isSnapshotStale(
                lastPollAt: .distantFuture,
                shared: nil,
                defaults: defaults,
                now: now))
        #expect(
            AppGroupConfig.isSnapshotStale(
                lastPollAt: Date(timeIntervalSinceReferenceDate: .nan),
                shared: nil,
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

    @Test("syncDisplaySettings removes values reset in the source suite")
    func syncRemovesResetValues() {
        let sourceName = "com.claudemeter.tests.sync-source"
        let sharedName = "com.claudemeter.tests.sync-shared"
        let source = UserDefaults(suiteName: sourceName)!
        let shared = UserDefaults(suiteName: sharedName)!
        defer {
            source.removePersistentDomain(forName: sourceName)
            shared.removePersistentDomain(forName: sharedName)
        }

        shared.set("used", forKey: AppGroupConfig.progressionModeKey)
        source.removeObject(forKey: AppGroupConfig.progressionModeKey)
        AppGroupConfig.syncDisplaySettings(from: source, to: shared)

        #expect(shared.object(forKey: AppGroupConfig.progressionModeKey) == nil)
    }

    @Test("Main meter defaults to Claude and keeps provider account pins separate")
    func mainMeterMigrationDefaults() {
        let defaultsName = "com.claudemeter.tests.main-meter"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        #expect(AppGroupConfig.resolvedMainMeterProvider(from: defaults, shared: nil) == .claude)
        defaults.set("codex", forKey: AppGroupConfig.mainMeterProviderKey)
        defaults.set("claude-work", forKey: AppGroupConfig.menuBarAccountKey)
        defaults.set("/tmp/codex", forKey: AppGroupConfig.codexMainMeterAccountKey)

        #expect(AppGroupConfig.resolvedMainMeterProvider(from: defaults, shared: nil) == .codex)
        #expect(
            AppGroupConfig.mainMeterAccountSelection(
                provider: .claude, defaults: defaults, shared: nil)
                == .account(key: "claude-work"))
        #expect(
            AppGroupConfig.mainMeterAccountSelection(
                provider: .codex, defaults: defaults, shared: nil)
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

        var published = codex[0]
        published.selectionRevision = 4
        #expect(
            MainMeterPolicy.acceptsPublished(
                published, provider: .codex, pinnedAccountID: "first", selectionRevision: 4))
        #expect(
            !MainMeterPolicy.acceptsPublished(
                published, provider: .claude, pinnedAccountID: "first", selectionRevision: 4))
        #expect(
            !MainMeterPolicy.acceptsPublished(
                published, provider: .codex, pinnedAccountID: "other", selectionRevision: 4))
        #expect(
            !MainMeterPolicy.acceptsPublished(
                published, provider: .codex, pinnedAccountID: "first", selectionRevision: 5))
    }

    @Test("Main meter publication policy tracks identity, source, and reading changes")
    func mainMeterPublicationPolicy() {
        func reading(_ id: String, _ used: Double) -> MainMeterReading {
            MainMeterReading(
                provider: .codex,
                accountID: id,
                accountLabel: id,
                limits: LimitInfo(currentSession: LimitWindow(percentUsed: used)),
                observedAt: Date(timeIntervalSince1970: 100))
        }
        let first = reading("first", 20)
        let updated = reading("first", 21)
        let nearestChanged = reading("second", 30)
        var refreshedOnly = first
        refreshedOnly.observedAt = Date(timeIntervalSince1970: 200)

        #expect(
            !MainMeterPolicy.shouldBumpSelectionRevision(
                previous: first, current: updated, configurationChanged: false))
        #expect(
            MainMeterPolicy.shouldBumpSelectionRevision(
                previous: first, current: nearestChanged, configurationChanged: false))
        #expect(
            MainMeterPolicy.shouldBumpSelectionRevision(
                previous: first, current: first, configurationChanged: true))
        #expect(MainMeterPolicy.shouldReloadWidget(previous: first, current: updated))
        #expect(MainMeterPolicy.shouldReloadWidget(previous: first, current: nearestChanged))
        #expect(!MainMeterPolicy.shouldReloadWidget(previous: first, current: refreshedOnly))
        #expect(!MainMeterPolicy.shouldReloadWidget(previous: first, current: first))

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
        #expect(
            MainMeterPolicy.shouldBumpSelectionRevision(
                previous: beforeReset,
                current: afterReset,
                configurationChanged: false))
    }

    @Test("Main meter revision is mirrored and monotonic")
    func mainMeterRevision() {
        let defaultsName = "com.claudemeter.tests.main-revision"
        let sharedName = "com.claudemeter.tests.main-revision-shared"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let shared = UserDefaults(suiteName: sharedName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            shared.removePersistentDomain(forName: sharedName)
        }

        #expect(AppGroupConfig.bumpMainMeterRevision(defaults: defaults, shared: shared) == 1)
        #expect(AppGroupConfig.mainMeterRevision(defaults: defaults, shared: shared) == 1)
        #expect(shared.integer(forKey: AppGroupConfig.mainMeterRevisionKey) == 1)
        #expect(AppGroupConfig.bumpMainMeterRevision(defaults: defaults, shared: shared) == 2)
    }

    @Test("typed appearance settings reject unknown persisted strings")
    func typedAppearanceFallbacks() {
        let defaultsName = "com.claudemeter.tests.appearance"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("future-style", forKey: AppGroupConfig.cardStyleKey)
        defaults.set("future-mode", forKey: AppGroupConfig.progressionModeKey)
        defaults.set("future-provider", forKey: AppGroupConfig.mainMeterProviderKey)

        #expect(AppGroupConfig.resolvedCardStyle(from: defaults, shared: nil) == .rings)
        #expect(AppGroupConfig.resolvedProgressionMode(from: defaults, shared: nil) == .left)
        #expect(AppGroupConfig.resolvedMainMeterProvider(from: defaults, shared: nil) == .claude)
        #expect(AppGroupConfig.MenuBarAccountSelection(storedValue: "nearest") == .nearest)
        #expect(
            AppGroupConfig.MenuBarAccountSelection(storedValue: "claude-work")
                == .account(key: "claude-work"))
    }
}
