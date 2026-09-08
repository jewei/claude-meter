import Foundation
import Testing

@testable import ClaudeMeterCore

struct MainMeterOwnerTests {
    @Test func ownerChangesResetNotificationBaselineWithoutChangingThePin() throws {
        let now = Date(timeIntervalSince1970: 100)
        let previous = MainMeterReading(
            provider: .codex, accountID: "/test/home", accountLabel: "Work",
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 98)),
            observedAt: now, observationOwnerID: "owner-a")
        var current = previous
        current.observationOwnerID = "owner-b"
        current.limits.currentSession = LimitWindow(percentUsed: 10)
        #expect(previous.stableIdentity != current.stableIdentity)
        #expect(MainMeterPolicy.primary(from: [current], pinnedAccountID: "/test/home") == current)
        #expect(
            MainMeterPolicy.shouldBumpSelectionRevision(
                previous: previous, current: current, configurationChanged: false))
        #expect(
            NotificationPolicy.triggers(
                reading: current, baselines: .init(escalation: previous, recovery: previous),
                now: now
            ).isEmpty)
        #expect(
            try JSONDecoder().decode(MainMeterReading.self, from: JSONEncoder().encode(current))
                == current)
    }

    @Test func legacyReadingsDecodeWithoutAnOwner() throws {
        let reading = MainMeterReading(
            provider: .claude, accountID: "claude", accountLabel: "Claude",
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 5)), observedAt: Date())
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reading)) as? [String: Any])
        json.removeValue(forKey: "observationOwnerID")
        let decoded = try JSONDecoder().decode(
            MainMeterReading.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.observationOwnerID == nil)
        #expect(decoded.stableIdentity == "claude:claude")
    }
}
