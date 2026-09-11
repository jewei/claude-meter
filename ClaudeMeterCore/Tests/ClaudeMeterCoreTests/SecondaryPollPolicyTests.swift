import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("SecondaryPollPolicy")
struct SecondaryPollPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var defaultIdle: TimeInterval {
        SecondaryPollPolicy.idleInterval(
            staleAfterSeconds: AppGroupConfig.defaultStaleAfterSeconds)
    }

    private func shouldPoll(
        lastAttemptAt: Date?,
        lastPopoverOpenAt: Date? = nil,
        isPopoverOpen: Bool = false,
        isInteractive: Bool = false,
        idleInterval: TimeInterval? = nil
    ) -> Bool {
        SecondaryPollPolicy.shouldPoll(
            now: now, lastAttemptAt: lastAttemptAt, lastPopoverOpenAt: lastPopoverOpenAt,
            isPopoverOpen: isPopoverOpen, isInteractive: isInteractive,
            idleInterval: idleInterval ?? defaultIdle)
    }

    @Test("A source that never ran polls immediately")
    func firstAttemptIsAdmitted() {
        #expect(shouldPoll(lastAttemptAt: nil))
    }

    @Test("An idle secondary source skips the 60-second cycle")
    func idleSecondarySourceSkipsCycle() {
        #expect(
            !shouldPoll(
                lastAttemptAt: now.addingTimeInterval(-60),
                lastPopoverOpenAt: now.addingTimeInterval(-3600)))
    }

    @Test("An idle secondary source runs again after the idle interval")
    func idleSecondarySourceRunsAfterInterval() {
        #expect(
            shouldPoll(
                lastAttemptAt: now.addingTimeInterval(-defaultIdle),
                lastPopoverOpenAt: now.addingTimeInterval(-3600)))
    }

    @Test("A recent popover visit restores the fast cadence")
    func recentViewRestoresFastCadence() {
        #expect(
            shouldPoll(
                lastAttemptAt: now.addingTimeInterval(-60),
                lastPopoverOpenAt: now.addingTimeInterval(-30)))
    }

    @Test("An open popover keeps every source on the fast cadence")
    func openPopoverKeepsFastCadence() {
        // A popover can stay open past the interaction window. Its cards are
        // visible and it runs a one-second clock, so it must not freeze.
        #expect(
            shouldPoll(
                lastAttemptAt: now.addingTimeInterval(-60),
                lastPopoverOpenAt: now.addingTimeInterval(-3600),
                isPopoverOpen: true))
    }

    @Test("The idle interval always stays below the stale threshold")
    func idleIntervalRespectsStaleThreshold() {
        // The policy must never be the reason a card reports itself stale. Leave at
        // least one poll cycle of headroom under whatever threshold is configured.
        for stale in [60.0, 120, 180, 240, 300, 3600, 86_400] {
            let interval = SecondaryPollPolicy.idleInterval(staleAfterSeconds: stale)
            #expect(interval + 60 <= max(stale, 120))
            #expect(interval >= 60)
            #expect(interval <= SecondaryPollPolicy.maximumIdleInterval)
        }
        // The shipped default keeps a full cycle of headroom under 180 s.
        #expect(SecondaryPollPolicy.idleInterval(staleAfterSeconds: 180) == 120)
        // A threshold at or below the cadence disables the slow cadence.
        #expect(SecondaryPollPolicy.idleInterval(staleAfterSeconds: 60) == 60)
        #expect(SecondaryPollPolicy.idleInterval(staleAfterSeconds: .nan) > 0)
    }

    @Test("The fast cadence stops after the interaction window")
    func fastCadenceExpires() {
        let justOutside = now.addingTimeInterval(-SecondaryPollPolicy.recentInteractionWindow)
        #expect(!SecondaryPollPolicy.isRecentlyViewed(now: now, lastPopoverOpenAt: justOutside))
        #expect(
            SecondaryPollPolicy.isRecentlyViewed(
                now: now, lastPopoverOpenAt: justOutside.addingTimeInterval(1)))
    }

    @Test("An interactive refresh always polls")
    func interactiveAlwaysPolls() {
        #expect(shouldPoll(lastAttemptAt: now, isInteractive: true))
    }

    @Test("A backward clock change cannot park a source")
    func futureAttemptDoesNotPark() {
        // A last attempt in the future gives a negative interval. Treat it as due
        // rather than waiting for the clock to catch up.
        #expect(shouldPoll(lastAttemptAt: now.addingTimeInterval(3600)))
    }

    @Test("A future popover timestamp reads as a recent view")
    func futureViewReadsAsRecent() {
        #expect(
            SecondaryPollPolicy.isRecentlyViewed(
                now: now, lastPopoverOpenAt: now.addingTimeInterval(120)))
    }

    @Test("The interaction window outlives one poll cycle")
    func interactionWindowOutlivesOneCycle() {
        #expect(SecondaryPollPolicy.recentInteractionWindow >= 60)
    }
}
