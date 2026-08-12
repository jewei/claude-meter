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

    @Test("typed appearance settings reject unknown persisted strings")
    func typedAppearanceFallbacks() {
        let defaultsName = "com.claudemeter.tests.appearance"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("future-style", forKey: AppGroupConfig.cardStyleKey)
        defaults.set("future-mode", forKey: AppGroupConfig.progressionModeKey)

        #expect(AppGroupConfig.resolvedCardStyle(from: defaults, shared: nil) == .rings)
        #expect(AppGroupConfig.resolvedProgressionMode(from: defaults, shared: nil) == .left)
        #expect(AppGroupConfig.MenuBarAccountSelection(storedValue: "nearest") == .nearest)
        #expect(
            AppGroupConfig.MenuBarAccountSelection(storedValue: "claude-work")
                == .account(key: "claude-work"))
    }
}
