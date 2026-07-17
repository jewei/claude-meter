import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("Predictive notifications")
struct PredictiveNotificationPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requiresTwoConsecutiveQualifyingPolls() {
        var tracker = PredictiveNotificationTracker()
        let snapshot = makeSnapshot(used: 50, resetAt: now.addingTimeInterval(4 * 3600))

        #expect(tracker.observe(snapshot: snapshot, now: now).isEmpty)
        #expect(tracker.observe(snapshot: snapshot, now: now.addingTimeInterval(60)).count == 1)
    }

    @Test func nonqualifyingPollResetsTheStreak() {
        var tracker = PredictiveNotificationTracker()
        let hot = makeSnapshot(used: 50, resetAt: now.addingTimeInterval(4 * 3600))
        let sustainable = makeSnapshot(used: 10, resetAt: now.addingTimeInterval(4 * 3600))

        #expect(tracker.observe(snapshot: hot, now: now).isEmpty)
        #expect(tracker.observe(snapshot: sustainable, now: now.addingTimeInterval(60)).isEmpty)
        #expect(tracker.observe(snapshot: hot, now: now.addingTimeInterval(120)).isEmpty)
        #expect(tracker.observe(snapshot: hot, now: now.addingTimeInterval(180)).count == 1)
    }

    @Test func resetCycleRequiresFreshConfirmation() {
        var tracker = PredictiveNotificationTracker()
        let first = makeSnapshot(used: 50, resetAt: now.addingTimeInterval(4 * 3600))
        let next = makeSnapshot(used: 50, resetAt: now.addingTimeInterval(5 * 3600))

        #expect(tracker.observe(snapshot: first, now: now).isEmpty)
        #expect(tracker.observe(snapshot: first, now: now.addingTimeInterval(60)).count == 1)
        #expect(tracker.observe(snapshot: next, now: now.addingTimeInterval(120)).isEmpty)
    }

    @Test func staleResetClearsTheStreak() {
        var tracker = PredictiveNotificationTracker()
        let snapshot = makeSnapshot(used: 50, resetAt: now.addingTimeInterval(4 * 3600))

        #expect(tracker.observe(snapshot: snapshot, now: now).isEmpty)
        tracker.reset()
        #expect(tracker.observe(snapshot: snapshot, now: now.addingTimeInterval(60)).isEmpty)
    }

    @Test func dedupKeySeparatesAccounts() {
        let reset = now.addingTimeInterval(3600)
        let first = PredictiveNotificationPolicy.dedupKey(
            accountID: "claude", scope: "session", resetAt: reset)
        let second = PredictiveNotificationPolicy.dedupKey(
            accountID: "claude-work", scope: "session", resetAt: reset)

        #expect(first != second)
        #expect(first.hasPrefix(NotificationPolicy.dedupKeyPrefix))
    }

    private func makeSnapshot(used: Double, resetAt: Date) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            parserVersion: "test",
            createdAt: now,
            source: SourceInfo(cliPath: "test", command: "test"),
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: used, resetsAt: resetAt)
            ),
            state: SnapshotState(status: .ok, severity: .normal)
        )
    }
}
