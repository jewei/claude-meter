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

    @Test func staleObservationClearsTheStreakInternally() {
        var tracker = PredictiveNotificationTracker()
        let snapshot = makeSnapshot(used: 50, resetAt: now.addingTimeInterval(4 * 3600))

        #expect(tracker.observe(snapshot: snapshot, now: now).isEmpty)
        #expect(
            tracker.observe(snapshot: snapshot, isFresh: false, now: now.addingTimeInterval(60))
                .isEmpty)
        #expect(tracker.observe(snapshot: snapshot, now: now.addingTimeInterval(120)).isEmpty)
    }

    @Test func dedupKeySeparatesAccounts() {
        let reset = now.addingTimeInterval(3600)
        let first = PredictiveNotificationTrigger(
            accountID: "claude", scope: "session", resetAt: reset, secondsUntilDepleted: 60
        ).dedupKey
        let second = PredictiveNotificationTrigger(
            accountID: "claude-work", scope: "session", resetAt: reset, secondsUntilDepleted: 60
        ).dedupKey

        #expect(first != second)
        #expect(first.hasPrefix(NotificationPolicy.dedupKeyPrefix))
    }

    @Test func dedupKeyBucketsResetJitter() {
        let reset = now.addingTimeInterval(3600)
        let jittered = reset.addingTimeInterval(45)
        let key = { (date: Date) in
            PredictiveNotificationTrigger(
                accountID: "claude", scope: "session", resetAt: date, secondsUntilDepleted: 60
            ).dedupKey
        }
        #expect(key(reset) == key(jittered))
        #expect(key(reset) != key(reset.addingTimeInterval(3600)))
    }

    @Test func invalidResetProducesSafeDedupKey() {
        let invalid = Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)
        let key = PredictiveNotificationTrigger(
            accountID: "claude", scope: "session", resetAt: invalid,
            secondsUntilDepleted: 60
        ).dedupKey

        #expect(key.hasSuffix(".invalid"))
        #expect(PredictiveNotificationTracker.bucketedEpoch(invalid) == nil)
    }

    /// Pins the bucket width itself. `bucketedReset` moved here when the unused
    /// usage-history store was deleted, so this is now the only place it lives —
    /// widening the bucket would start collapsing genuinely distinct reset cycles
    /// onto one dedup key and silently swallow a real forecast.
    @Test func resetBucketRoundsToFiveMinutes() {
        // Exactly on a bucket boundary: 800_000_100 is a multiple of 300.
        let base = Date(timeIntervalSinceReferenceDate: 800_000_100)
        let bucketed = { PredictiveNotificationTracker.bucketedReset($0) }

        // Anything inside ±2.5 min collapses onto the same bucket...
        #expect(bucketed(base.addingTimeInterval(60)) == bucketed(base))
        #expect(bucketed(base.addingTimeInterval(-60)) == bucketed(base))
        // ...and the next bucket is distinct.
        #expect(bucketed(base.addingTimeInterval(300)) != bucketed(base))
        #expect(bucketed(nil) == nil)
    }

    @Test func streakSurvivesResetJitterAcrossPolls() {
        var tracker = PredictiveNotificationTracker()
        let reset = now.addingTimeInterval(4 * 3600)
        let first = makeSnapshot(used: 50, resetAt: reset)
        let jittered = makeSnapshot(used: 50, resetAt: reset.addingTimeInterval(30))

        #expect(tracker.observe(snapshot: first, now: now).isEmpty)
        #expect(tracker.observe(snapshot: jittered, now: now.addingTimeInterval(60)).count == 1)
    }

    @Test func streakSurvivesJitterAcrossARoundingBoundary() {
        var tracker = PredictiveNotificationTracker()
        // ±2 seconds around the nearest-five-minute midpoint would ordinarily round
        // to adjacent buckets even though both readings describe the same cycle.
        let boundary = Date(timeIntervalSince1970: 1_800_014_550)
        let first = makeSnapshot(used: 50, resetAt: boundary.addingTimeInterval(-2))
        let second = makeSnapshot(used: 50, resetAt: boundary.addingTimeInterval(2))

        #expect(tracker.observe(snapshot: first, now: now).isEmpty)
        #expect(tracker.observe(snapshot: second, now: now.addingTimeInterval(60)).count == 1)
    }

    @Test func accountIdentityStickyWhenAccountsAbsent() {
        var tracker = PredictiveNotificationTracker()
        let reset = now.addingTimeInterval(4 * 3600)
        // Statusline-tier poll: carries the accounts list with the real key.
        let statusline = makeSnapshot(
            used: 50, resetAt: reset, accounts: [makeAccount(id: "claude-work", isActive: true)])
        // OAuth-tier poll for the same account: accounts == nil.
        let oauthTier = makeSnapshot(used: 50, resetAt: reset)

        #expect(tracker.observe(snapshot: statusline, now: now).isEmpty)
        let triggers = tracker.observe(snapshot: oauthTier, now: now.addingTimeInterval(60))
        #expect(triggers.count == 1)
        #expect(triggers.first?.accountID == "claude-work")
    }

    private func makeAccount(id: String, isActive: Bool) -> AccountUsage {
        AccountUsage(
            id: id,
            label: id,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(3600))
            ),
            severity: .normal,
            isActive: isActive
        )
    }

    private func makeSnapshot(
        used: Double, resetAt: Date, accounts: [AccountUsage]? = nil
    ) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            parserVersion: "test",
            createdAt: now,
            source: SourceInfo(cliPath: "test", command: "test"),
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: used, resetsAt: resetAt)
            ),
            state: SnapshotState(status: .ok, severity: .normal),
            accounts: accounts
        )
    }
}
