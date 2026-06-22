import Testing
import Foundation
@testable import ClaudeMeterCore

@Suite("AppGroupConfig")
struct AppGroupConfigTests {

    @Test("currentThresholds reads from injected defaults")
    func thresholdsFromDefaults() {
        let defaults = UserDefaults(suiteName: "com.claudemeter.tests.thresholds")!
        defaults.removePersistentDomain(forName: "com.claudemeter.tests.thresholds")
        defaults.set(70.0, forKey: AppGroupConfig.warningThresholdKey)
        defaults.set(90.0, forKey: AppGroupConfig.criticalThresholdKey)

        let thresholds = AppGroupConfig.currentThresholds(defaults: defaults)
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

        #expect(!AppGroupConfig.isSnapshotStale(lastPollAt: fresh, defaults: defaults, now: now))
        #expect(AppGroupConfig.isSnapshotStale(lastPollAt: old, defaults: defaults, now: now))
    }
}
