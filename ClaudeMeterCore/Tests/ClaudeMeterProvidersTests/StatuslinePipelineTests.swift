import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("StatuslinePipeline.displayWindow")
struct StatuslinePipelineDisplayWindowTests {
    private let now = Date(timeIntervalSince1970: 1_782_269_456)  // Wed 24 Jun 2026, ~10:50 AM

    @Test func futureResetKeepsReportedUsage() {
        let window = StatuslineBridge.RateLimitWindow(
            usedPercentage: 42,
            resetsAt: now.addingTimeInterval(3600)
        )
        let display = StatuslinePipeline.displayWindow(for: window, now: now)
        #expect(display.percentUsed == 42)
        #expect(display.resetsAt == now.addingTimeInterval(3600))
    }

    @Test func expiredWindowResetsToZeroAndDropsCountdown() {
        // Open-but-idle session re-emitting a stale snapshot: reset already passed.
        let window = StatuslineBridge.RateLimitWindow(
            usedPercentage: 25,
            resetsAt: now.addingTimeInterval(-6 * 3600)
        )
        let display = StatuslinePipeline.displayWindow(for: window, now: now)
        #expect(display.percentUsed == 0)
        #expect(display.resetsAt == nil)
    }

    @Test func missingWindowProducesEmptyWindow() {
        let display = StatuslinePipeline.displayWindow(for: nil, now: now)
        #expect(display.percentUsed == nil)
        #expect(display.resetsAt == nil)
    }

    @Test func windowWithoutResetTimeKeepsUsage() {
        // No reset time means we can't prove expiry; show the reported usage as-is.
        let window = StatuslineBridge.RateLimitWindow(usedPercentage: 30, resetsAt: nil)
        let display = StatuslinePipeline.displayWindow(for: window, now: now)
        #expect(display.percentUsed == 30)
        #expect(display.resetsAt == nil)
    }
}

@Suite("StatuslinePipeline.activitySignature")
struct StatuslineActivitySignatureTests {
    private func payload(
        session: String, cost: Double, capturedAt: TimeInterval
    ) -> StatuslineBridge.StatuslinePayload {
        StatuslineBridge.StatuslinePayload(
            fiveHour: StatuslineBridge.RateLimitWindow(usedPercentage: 30, resetsAt: nil),
            sevenDay: StatuslineBridge.RateLimitWindow(usedPercentage: 40, resetsAt: nil),
            sessionId: session, sessionName: nil, cwd: nil, modelId: nil,
            modelDisplayName: nil, totalCostUsd: cost, totalApiDurationMs: cost * 100,
            codeLinesAdded: 1, codeLinesRemoved: 0, cliVersion: nil,
            capturedAt: Date(timeIntervalSince1970: capturedAt))
    }

    /// Two idle sessions on one account. The bridge rewrites both files every
    /// second, so whichever is "newest" alternates between polls — and with it the
    /// merged payload's `totalCostUsd`. The activity signature must not move,
    /// otherwise the account looks perpetually active and permanently wins
    /// active-account selection over the one actually being used.
    @Test func signatureIsStableWhenTheMergeBaseFlips() throws {
        let a = payload(session: "A", cost: 1.5, capturedAt: 100)
        let b = payload(session: "B", cost: 9.9, capturedAt: 200)

        let bNewest = try #require(StatuslineBridge.mergePayloads([a, b]))
        let aNewest = try #require(
            StatuslineBridge.mergePayloads([
                payload(session: "A", cost: 1.5, capturedAt: 300), b,
            ]))

        // The display field genuinely differs (it comes from the newest file)...
        #expect(bNewest.totalCostUsd == 9.9)
        #expect(aNewest.totalCostUsd == 1.5)
        // ...but the activity signal does not.
        #expect(
            StatuslinePipeline.activitySignature(bNewest)
                == StatuslinePipeline.activitySignature(aNewest))
    }

    /// Real API activity in *any* session still moves the signature.
    @Test func signatureMovesWhenASessionSpends() throws {
        let before = try #require(
            StatuslineBridge.mergePayloads([
                payload(session: "A", cost: 1.5, capturedAt: 100),
                payload(session: "B", cost: 9.9, capturedAt: 200),
            ]))
        let after = try #require(
            StatuslineBridge.mergePayloads([
                payload(session: "A", cost: 1.75, capturedAt: 100),
                payload(session: "B", cost: 9.9, capturedAt: 200),
            ]))
        #expect(
            StatuslinePipeline.activitySignature(before)
                != StatuslinePipeline.activitySignature(after))
    }

    /// Ordering of the discovered files must not matter.
    @Test func signatureIsOrderIndependent() throws {
        let a = payload(session: "A", cost: 1.5, capturedAt: 100)
        let b = payload(session: "B", cost: 9.9, capturedAt: 200)
        let forward = try #require(StatuslineBridge.mergePayloads([a, b]))
        let reversed = try #require(StatuslineBridge.mergePayloads([b, a]))
        #expect(
            StatuslinePipeline.activitySignature(forward)
                == StatuslinePipeline.activitySignature(reversed))
    }
}

@Suite("StatuslinePipeline.eligibleGroups")
struct StatuslinePipelineEligibleGroupsTests {
    private func payload(five: Double?) -> StatuslineBridge.StatuslinePayload {
        StatuslineBridge.StatuslinePayload(
            fiveHour: five.map {
                StatuslineBridge.RateLimitWindow(usedPercentage: $0, resetsAt: nil)
            },
            sevenDay: nil, sessionId: "s", sessionName: nil, cwd: nil, modelId: nil,
            modelDisplayName: nil, totalCostUsd: nil, totalApiDurationMs: nil,
            codeLinesAdded: nil, codeLinesRemoved: nil, cliVersion: nil,
            capturedAt: Date(timeIntervalSince1970: 1))
    }

    @Test func dropsDisabledNonDefaultAccounts() {
        let groups = ["claude": payload(five: 10), "claude-work": payload(five: 90)]
        let kept = StatuslinePipeline.eligibleGroups(groups, disabled: ["claude-work"])
        #expect(Set(kept.keys) == ["claude"])
    }

    @Test func neverDropsDefaultAccountEvenIfDisabled() {
        // The default `claude` account can't be disabled, even if listed.
        let groups = ["claude": payload(five: 10)]
        let kept = StatuslinePipeline.eligibleGroups(groups, disabled: ["claude"])
        #expect(Set(kept.keys) == ["claude"])
    }

    @Test func dropsAccountsWithoutAnyWindow() {
        let groups = ["claude": payload(five: 10), "claude-empty": payload(five: nil)]
        let kept = StatuslinePipeline.eligibleGroups(groups, disabled: [])
        #expect(Set(kept.keys) == ["claude"])
    }
}

@Suite("StatuslinePipeline.selectActive")
struct StatuslinePipelineSelectActiveTests {
    private func payload(cost: Double, reset: TimeInterval) -> StatuslineBridge.StatuslinePayload {
        StatuslineBridge.StatuslinePayload(
            fiveHour: StatuslineBridge.RateLimitWindow(
                usedPercentage: 10, resetsAt: Date(timeIntervalSince1970: reset)),
            sevenDay: nil, sessionId: "s", sessionName: nil, cwd: nil, modelId: nil,
            modelDisplayName: nil, totalCostUsd: cost, totalApiDurationMs: nil,
            codeLinesAdded: nil, codeLinesRemoved: nil, cliVersion: nil,
            capturedAt: Date(timeIntervalSince1970: 1))
    }

    @Test func switchesToTheAccountBeingUsedDespiteLaterResetElsewhere() {
        // Reproduces the real bug: tech-oneone has the later window-reset (the old
        // recency proxy picked it), but it-oneone is the one actually being prompted.
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        let g1 = [
            "claude-it": payload(cost: 1.0, reset: 1000),
            "claude-tech": payload(cost: 5.0, reset: 2000),
        ]
        let (first, a1) = StatuslinePipeline.selectActive(
            groups: g1, prior: [:], sticky: nil, now: t1)
        #expect(first == "claude-tech")  // seed: tie on activity → later reset wins

        // it-oneone is prompted (cost rises); tech sits idle (unchanged).
        let g2 = [
            "claude-it": payload(cost: 1.5, reset: 1000),
            "claude-tech": payload(cost: 5.0, reset: 2000),
        ]
        let (second, _) = StatuslinePipeline.selectActive(
            groups: g2, prior: a1, sticky: nil, now: t2)
        #expect(second == "claude-it")
    }

    @Test func idleAccountKeepsFrozenActivityTime() {
        // Both seeded together; neither changes → active stays deterministic (no flap).
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        let g = [
            "claude-it": payload(cost: 1.0, reset: 1000),
            "claude-tech": payload(cost: 5.0, reset: 2000),
        ]
        let (first, a1) = StatuslinePipeline.selectActive(
            groups: g, prior: [:], sticky: nil, now: t1)
        let (second, _) = StatuslinePipeline.selectActive(
            groups: g, prior: a1, sticky: nil, now: t2)
        #expect(first == second)
    }

    @Test func stickyBreaksColdStartTie() {
        // Cold start / rebuild: both accounts freshly seeded (tie). The sticky key
        // (seeded from the last snapshot's active account) wins, even though the
        // other has a later window-reset that would otherwise take the tie-break.
        let g = [
            "claude-it": payload(cost: 1.0, reset: 1000),
            "claude-tech": payload(cost: 5.0, reset: 2000),
        ]
        let (active, _) = StatuslinePipeline.selectActive(
            groups: g, prior: [:], sticky: "claude-it", now: Date(timeIntervalSince1970: 100))
        #expect(active == "claude-it")
    }
}
