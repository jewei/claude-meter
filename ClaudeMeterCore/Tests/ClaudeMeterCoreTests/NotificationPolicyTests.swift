import Testing
import Foundation
@testable import ClaudeMeterCore

private let fixedNow = Date(timeIntervalSince1970: 1_782_108_000)
private let resetAt = fixedNow.addingTimeInterval(3600)

@Suite("NotificationPolicy")
struct NotificationPolicyTests {

    private func window(percent: Double?) -> LimitWindow {
        LimitWindow(percentUsed: percent, resetsAt: resetAt, rawResetText: "2:50pm")
    }

    private func snapshot(session: Double?, week: Double? = 30) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            parserVersion: "0.1.0",
            createdAt: fixedNow,
            source: SourceInfo(cliPath: "/claude", command: "status"),
            limits: LimitInfo(
                currentSession: window(percent: session),
                currentWeekAllModels: window(percent: week)
            ),
            state: SnapshotState(status: .ok, severity: .normal)
        )
    }

    @Test("Custom thresholds shift warning crossing")
    func customThresholds() {
        let thresholds = UsageThresholds(warning: 70, critical: 90)
        let previous = snapshot(session: 65)
        let current = snapshot(session: 75)
        let triggers = NotificationPolicy.triggers(
            snapshot: current,
            previous: previous,
            thresholds: thresholds,
            now: fixedNow
        )
        #expect(triggers.contains { $0.scope == "session" && $0.level == "warning" })
    }

    @Test("Fires warning when crossing from normal to warning")
    func warningCrossing() {
        let previous = snapshot(session: 75)
        let current = snapshot(session: 85)
        let triggers = NotificationPolicy.triggers(snapshot: current, previous: previous, now: fixedNow)
        #expect(triggers.contains { $0.scope == "session" && $0.level == "warning" })
    }

    @Test("Does not fire when already at warning level")
    func noRepeatWarning() {
        let previous = snapshot(session: 85)
        let current = snapshot(session: 86)
        let triggers = NotificationPolicy.triggers(snapshot: current, previous: previous, now: fixedNow)
        #expect(triggers.isEmpty)
    }

    @Test("Fires critical when jumping from normal to critical")
    func criticalJump() {
        let previous = snapshot(session: 75)
        let current = snapshot(session: 96)
        let triggers = NotificationPolicy.triggers(snapshot: current, previous: previous, now: fixedNow)
        #expect(triggers.count == 1)
        #expect(triggers[0].level == "critical")
    }

    @Test("Fires critical when escalating from warning to critical")
    func warningToCritical() {
        let previous = snapshot(session: 85)
        let current = snapshot(session: 96)
        let triggers = NotificationPolicy.triggers(snapshot: current, previous: previous, now: fixedNow)
        #expect(triggers.contains { $0.scope == "session" && $0.level == "critical" })
        #expect(!triggers.contains { $0.level == "warning" })
    }

    @Test("Fires warning when reset time is unknown")
    func warningWithoutResetTime() {
        let previous = snapshot(session: 75)
        var current = snapshot(session: 85)
        current.limits.currentSession = LimitWindow(
            percentUsed: 85,
            resetsAt: nil,
            rawResetText: "unknown"
        )
        let triggers = NotificationPolicy.triggers(snapshot: current, previous: previous, now: fixedNow)
        #expect(triggers.contains { $0.scope == "session" && $0.level == "warning" })
    }

    @Test("Skips when reset time is in the past")
    func pastReset() {
        let pastWindow = LimitWindow(
            percentUsed: 96,
            resetsAt: fixedNow.addingTimeInterval(-60),
            rawResetText: "1:00pm"
        )
        let current = ClaudeUsageSnapshot(
            parserVersion: "0.1.0",
            createdAt: fixedNow,
            source: SourceInfo(cliPath: "/claude", command: "status"),
            limits: LimitInfo(currentSession: pastWindow),
            state: SnapshotState(status: .ok, severity: .critical)
        )
        #expect(NotificationPolicy.triggers(snapshot: current, previous: nil, now: fixedNow).isEmpty)
    }

    @Test("dedupKey embeds scope, level, and reset epoch")
    func dedupKeyFormat() {
        let key = NotificationPolicy.dedupKey(scope: "session", level: "warning", resetAt: resetAt)
        #expect(key == "com.claudemeter.notif.session.warning.\(Int(resetAt.timeIntervalSince1970))")
    }

    @Test("expiredDedupKeys removes keys for past reset windows")
    func pruneExpired() {
        let pastEpoch = Int(fixedNow.addingTimeInterval(-3600).timeIntervalSince1970)
        let futureEpoch = Int(resetAt.timeIntervalSince1970)
        let keys = [
            "com.claudemeter.notif.session.warning.\(pastEpoch)",
            "com.claudemeter.notif.session.critical.\(futureEpoch)",
            "unrelated.key",
        ]
        let expired = NotificationPolicy.expiredDedupKeys(in: keys, now: fixedNow)
        #expect(expired == ["com.claudemeter.notif.session.warning.\(pastEpoch)"])
    }
}
