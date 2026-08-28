import ClaudeMeterCore
import ClaudeMeterProviders
import Foundation
import Testing

@testable import ClaudeMeter

@MainActor
private final class TestPopoverWindowAdapter: PopoverWindowAdapter {
    struct Animation {
        let source: CGRect
        let target: CGRect
        let completion: @MainActor (PopoverWindowAnimationOutcome) -> Void
    }

    var isVisible = true
    var frame: CGRect?
    var visibleScreenFrame: CGRect? = CGRect(x: 0, y: 0, width: 1_440, height: 720)
    var canAnimate = true
    private(set) var immediateFrames: [CGRect] = []
    private(set) var animations: [Animation] = []
    private(set) var interruptionCount = 0

    init(frame: CGRect = CGRect(x: 100, y: 500, width: 360, height: 220)) {
        self.frame = frame
    }

    func interruptAndCapturePresentation() -> CGRect? {
        interruptionCount += 1
        return frame
    }

    func setFrameImmediately(_ frame: CGRect, display _: Bool) {
        self.frame = frame
        immediateFrames.append(frame)
    }

    func animateFrame(
        to frame: CGRect,
        duration _: TimeInterval,
        completion: @escaping @MainActor (PopoverWindowAnimationOutcome) -> Void
    ) -> Bool {
        guard canAnimate, let source = self.frame else { return false }
        animations.append(Animation(source: source, target: frame, completion: completion))
        return true
    }

    func advanceAnimation(_ index: Int, to frame: CGRect) {
        self.frame = frame
    }

    func completeAnimation(_ index: Int) {
        let animation = animations[index]
        frame = animation.target
        animation.completion(.reachedTarget)
    }

    func deliverCompletion(_ index: Int) {
        animations[index].completion(.reachedTarget)
    }

    func stopAnimation(_ index: Int) {
        animations[index].completion(.stopped)
    }
}

@Suite("App logic")
struct AppLogicTests {
    private actor SuspendedStatusFetcher {
        private var continuation: CheckedContinuation<ServiceStatus?, Never>?
        private var completedResult: ServiceStatus??
        private(set) var callCount = 0

        func fetch() async -> ServiceStatus? {
            callCount += 1
            if let completedResult { return completedResult }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(with status: ServiceStatus?) {
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: status)
            } else {
                completedResult = .some(status)
            }
        }
    }

    private struct UnusedPipeline: ClaudeMeterPipeline {
        func poll(now _: Date, kind _: RefreshKind) async throws -> ParseResult {
            ParseResult(snapshot: nil, warnings: [], errors: [], rawHash: "")
        }
    }

    @Test("Friendly account labels normalize separators")
    func friendlyAccountLabels() {
        #expect("it-oneone_build".friendlyAccountLabel == "It Oneone Build")
    }

    @Test("Codex account names prefer a non-empty override")
    func codexDisplayName() {
        let home = URL(fileURLWithPath: "/tmp/codex-work")
        #expect(
            CodexAccount(home: home, isImplicit: false, customName: "Work").displayName == "Work")
        #expect(
            CodexAccount(home: home, isImplicit: false, customName: "  ").displayName
                == "codex-work")
    }

    @Test("Provider reading state keeps value, timestamp, and error coherent")
    func providerReadingState() {
        let date = Date(timeIntervalSince1970: 123)
        let current = ReadingState<String>.current(value: "ok", polledAt: date)
        #expect(current.value == "ok")
        #expect(current.lastPolledAt == date)
        #expect(current.error == nil)
        #expect(!current.isStale)

        let stale = ReadingState<String>.stale(value: "old", polledAt: date, error: "offline")
        #expect(stale.value == "old")
        #expect(stale.lastPolledAt == date)
        #expect(stale.error == "offline")
        #expect(stale.isStale)
    }

    @Test("Chunking preserves order and the final partial chunk")
    func chunking() {
        #expect(Array(1...7).chunked(into: 3) == [[1, 2, 3], [4, 5, 6], [7]])
    }

    @MainActor
    @Test("Successful empty OAuth enrichment clears stale optional fields")
    func emptyOAuthEnrichmentClearsStaleValues() {
        var snapshot = ClaudeUsageSnapshot(
            parserVersion: "test",
            createdAt: Date(timeIntervalSince1970: 100),
            source: SourceInfo(cliPath: "statusline", command: "read"),
            account: AccountInfo(email: "person@example.com", plan: "Max"),
            limits: LimitInfo(
                currentWeekOpus: LimitWindow(percentUsed: 81),
                scopedWeekly: [
                    ScopedLimitWindow(
                        id: "seven_day_sonnet", window: LimitWindow(percentUsed: 42))
                ],
                extraUsage: ExtraUsage(isEnabled: true, usedCredits: 500)
            ),
            state: SnapshotState(status: .ok, severity: .normal)
        )
        let enrichment = OAuthPipeline.OAuthEnrichment(
            opus: nil,
            scopedWeekly: nil,
            extraUsage: nil,
            plan: nil
        )

        AppState.apply(enrichment, to: &snapshot)

        #expect(snapshot.limits.currentWeekOpus == nil)
        #expect(snapshot.limits.scopedWeekly == nil)
        #expect(snapshot.limits.extraUsage == nil)
        #expect(snapshot.account == AccountInfo(email: "person@example.com"))
    }

    @MainActor
    @Test("OAuth enrichment keeps observation time across failure and recovery")
    func oauthEnrichmentLifecycle() {
        let firstObservation = Date(timeIntervalSince1970: 100)
        let failedAttempt = Date(timeIntervalSince1970: 200)
        let recoveredObservation = Date(timeIntervalSince1970: 300)
        let initialValue = OAuthPipeline.OAuthEnrichment(
            opus: LimitWindow(percentUsed: 81),
            scopedWeekly: nil,
            extraUsage: nil,
            plan: "Max"
        )
        let recoveredValue = OAuthPipeline.OAuthEnrichment(
            opus: nil,
            scopedWeekly: nil,
            extraUsage: nil,
            plan: nil
        )

        let current = AppState.updatedOAuthEnrichmentReading(
            previous: nil,
            result: .success(initialValue),
            now: firstObservation
        )
        #expect(current.value == initialValue)
        #expect(current.lastPolledAt == firstObservation)
        #expect(current.error == nil)
        #expect(!current.isStale)

        let stale = AppState.updatedOAuthEnrichmentReading(
            previous: current,
            result: .unavailable(.networkError),
            now: failedAttempt
        )
        #expect(stale.value == initialValue)
        #expect(stale.lastPolledAt == firstObservation)
        #expect(stale.error == SourceAttempt.Reason.networkError.rawValue)
        #expect(stale.isStale)

        let recovered = AppState.updatedOAuthEnrichmentReading(
            previous: stale,
            result: .success(recoveredValue),
            now: recoveredObservation
        )
        #expect(recovered.value == recoveredValue)
        #expect(recovered.lastPolledAt == recoveredObservation)
        #expect(recovered.error == nil)
        #expect(!recovered.isStale)
    }

    @MainActor
    @Test("OAuth enrichment failure without a cache is failed, not stale")
    func oauthEnrichmentInitialFailure() {
        let failed = AppState.updatedOAuthEnrichmentReading(
            previous: nil,
            result: .unavailable(.credentialsUnavailable),
            now: Date(timeIntervalSince1970: 200)
        )

        #expect(failed.value == nil)
        #expect(failed.lastPolledAt == nil)
        #expect(failed.error == SourceAttempt.Reason.credentialsUnavailable.rawValue)
        #expect(!failed.isStale)
    }

    @Test("Energy bar pace marker stays centered and inside the track")
    func energyBarPaceMarker() {
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: -1) == 0)
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: 0.5) == 49)
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: 2) == 98)
        #expect(energyBarMarkerOffset(width: 1, expectedFraction: 0.5) == 0)
    }

    @MainActor
    private func popoverTransitionFixture(
        disclosure: Set<String> = [],
        bodyHeight: CGFloat = 400
    ) -> (PopoverTransitionCoordinator, TestPopoverWindowAdapter) {
        let adapter = TestPopoverWindowAdapter()
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: disclosure,
            windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: disclosure,
                renderSequence: 0,
                height: bodyHeight))
        return (coordinator, adapter)
    }

    @Test("Failed OAuth re-verification keeps an existing connection")
    func failedOAuthReverificationKeepsConnection() {
        #expect(
            OAuthSetupState.afterAutomaticVerificationFailure(
                oauthMode: "auto", message: "retrying") == .connectedAuto)
        #expect(
            OAuthSetupState.afterAutomaticVerificationFailure(
                oauthMode: "", message: "failed") == .error("failed"))
    }

    @Test("Disconnected OAuth setup is immediately actionable")
    func disconnectedOAuthSetupIsActionable() {
        #expect(OAuthSetupState.initial(oauthMode: "") == .promptAuto)
    }

    @Test("Stale hero does not promise available capacity")
    func staleHeroCopy() {
        #expect(HeroSummary.stale(oauthConnected: false).title == "Refresh needed")
        #expect(!HeroSummary.stale(oauthConnected: false).subtitle.contains("Plenty"))
    }

    @MainActor
    @Test("Popover transition establishes its initial baseline without animation")
    func popoverTransitionBaseline() {
        let (coordinator, adapter) = popoverTransitionFixture(disclosure: ["cursor"])

        #expect(adapter.animations.isEmpty)
        #expect(coordinator.presentation.bodyHeight == 400)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.isSettled)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("Popover disclosure growth preserves the top edge")
    func popoverTransitionGrowth() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        #expect(!coordinator.presentation.revealedCards.contains("cursor"))

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        #expect(adapter.animations.count == 1)
        #expect(adapter.animations[0].source.maxY == adapter.animations[0].target.maxY)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.presentation.bodyHeight == 400)
        #expect(coordinator.presentation.renderedBodyHeight == 500)
        #expect(!coordinator.isSettled)

        adapter.completeAnimation(0)

        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover disclosure shrink hides details before resizing")
    func popoverTransitionShrink() async throws {
        let (coordinator, adapter) = popoverTransitionFixture(
            disclosure: ["cursor"], bodyHeight: 500)
        let sequence = coordinator.desiredDisclosureChanged([])
        #expect(coordinator.presentation.revealedCards.isEmpty)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: [], renderSequence: sequence, height: 400))
        #expect(coordinator.presentation.bodyHeight == 400)
        for _ in 0..<10 where adapter.animations.isEmpty { await Task.yield() }

        let animation = try #require(adapter.animations.first)
        #expect(animation.source.maxY == animation.target.maxY)
        adapter.completeAnimation(0)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover card switching derives geometry from the replacement")
    func popoverTransitionReplacement() {
        let (coordinator, adapter) = popoverTransitionFixture(disclosure: ["cursor"])
        let sequence = coordinator.desiredDisclosureChanged(["codex:a"])
        #expect(coordinator.presentation.revealedCards.isEmpty)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["codex:a"], renderSequence: sequence, height: 400))

        #expect(adapter.animations.isEmpty)
        #expect(coordinator.presentation.revealedCards == ["codex:a"])
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Equal-height replacement preserves a moved menu-item anchor")
    func popoverTransitionEqualHeightFollowsMovedMenuItem() {
        let (coordinator, adapter) = popoverTransitionFixture(disclosure: ["cursor"])
        adapter.frame?.origin.x = 200

        let sequence = coordinator.desiredDisclosureChanged(["codex:a"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["codex:a"], renderSequence: sequence, height: 400))

        #expect(adapter.animations.isEmpty)
        #expect(adapter.frame?.minX == 200)
        #expect(adapter.frame?.maxY == 720)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover transition rejects an old equal semantic render")
    func popoverTransitionRejectsOldMeasurement() {
        let (coordinator, adapter) = popoverTransitionFixture()
        _ = coordinator.desiredDisclosureChanged(["cursor"])
        let latestSequence = coordinator.desiredDisclosureChanged([])

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 600))
        #expect(adapter.animations.isEmpty)
        #expect(coordinator.presentation.bodyHeight == 400)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: [], renderSequence: latestSequence, height: 400))
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover same-set reconciliation interrupts disclosure motion")
    func popoverTransitionReconciliation() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        #expect(adapter.animations.count == 1)

        adapter.advanceAnimation(
            0, to: CGRect(x: 100, y: 170, width: 360, height: 550))
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 550))

        #expect(coordinator.presentation.bodyHeight == 550)
        #expect(coordinator.isSettled)
        let settledFrame = adapter.frame
        adapter.deliverCompletion(0)
        #expect(adapter.frame == settledFrame)
        #expect(coordinator.presentation.bodyHeight == 550)
    }

    @MainActor
    @Test("Popover transition ignores sub-tolerance measurement noise")
    func popoverTransitionTolerance() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500.5))

        #expect(adapter.animations.count == 1)
        #expect(coordinator.presentation.bodyHeight == 400)
    }

    @MainActor
    @Test("Popover interruption retargets from the captured visible frame")
    func popoverTransitionInterruption() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let firstSequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: firstSequence, height: 500))
        let partial = CGRect(x: 100, y: 170, width: 360, height: 550)
        adapter.advanceAnimation(0, to: partial)

        let secondSequence = coordinator.desiredDisclosureChanged(["cursor", "codex:a"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor", "codex:a"],
                renderSequence: secondSequence,
                height: 600))

        #expect(adapter.animations.count == 2)
        #expect(adapter.animations[1].source == partial)
        adapter.deliverCompletion(0)
        #expect(coordinator.presentation.bodyHeight == 400)
        adapter.completeAnimation(1)
        #expect(coordinator.presentation.bodyHeight == 600)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Hidden popover changes coalesce and reattach immediately")
    func popoverTransitionHiddenLifecycle() {
        let (coordinator, adapter) = popoverTransitionFixture()
        coordinator.visibilityChanged(false)
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        #expect(adapter.animations.isEmpty)
        #expect(coordinator.isQuiescent)
        #expect(coordinator.presentation.revealedCards == ["cursor"])

        coordinator.visibilityChanged(true)
        #expect(adapter.animations.isEmpty)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("A transient lower-left reattachment cannot replace the menu-bar anchor")
    func popoverTransitionRejectsLowerLeftReattachment() throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        let anchoredFrame = try #require(adapter.frame)

        coordinator.visibilityChanged(false)
        adapter.frame = CGRect(
            x: 0,
            y: 0,
            width: anchoredFrame.width,
            height: anchoredFrame.height)
        coordinator.visibilityChanged(true)

        #expect(adapter.frame?.minX == anchoredFrame.minX)
        #expect(adapter.frame?.maxY == anchoredFrame.maxY)
    }

    @MainActor
    @Test("A stale anchor cannot cross to a side-by-side display")
    func popoverTransitionRejectsAnchorFromAnotherScreen() async throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        let initialFrameCount = adapter.immediateFrames.count
        coordinator.visibilityChanged(false)
        adapter.visibleScreenFrame = CGRect(x: 1_440, y: 0, width: 1_440, height: 720)
        adapter.frame = CGRect(x: 1_440, y: 0, width: 360, height: 220)

        coordinator.visibilityChanged(true)
        #expect(adapter.immediateFrames.count == initialFrameCount)
        #expect(coordinator.isQuiescent)

        adapter.frame = CGRect(x: 1_500, y: 500, width: 360, height: 220)
        try await Task.sleep(for: .milliseconds(30))
        #expect(coordinator.isSettled)
        #expect(adapter.frame?.minX == 1_500)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("A transient origin cannot become an animation source")
    func popoverTransitionRejectsLowerLeftAnimationSource() throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        let anchoredFrame = try #require(adapter.frame)
        adapter.frame = CGRect(
            x: 0,
            y: 0,
            width: anchoredFrame.width,
            height: anchoredFrame.height)

        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        let animation = try #require(adapter.animations.first)
        #expect(animation.source.minX == anchoredFrame.minX)
        #expect(animation.source.maxY == anchoredFrame.maxY)
    }

    @MainActor
    @Test("A valid moved anchor becomes the animation target")
    func popoverTransitionFollowsMovedMenuItem() throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        adapter.frame?.origin.x = 200

        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        let animation = try #require(adapter.animations.first)
        #expect(animation.source.minX == 200)
        #expect(animation.target.minX == 200)
        #expect(animation.target.maxY == 720)
    }

    @MainActor
    @Test("Measurement-time anchor supersedes the disclosure-time capture")
    func popoverTransitionUsesLatestAnchorBeforeAnimation() throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        adapter.frame?.origin.x = 200

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        let animation = try #require(adapter.animations.first)
        #expect(animation.source.minX == 200)
        #expect(animation.target.minX == 200)
    }

    @MainActor
    @Test("Animation completion adopts the actual moved anchor")
    func popoverTransitionCompletionFollowsMovedMenuItem() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        adapter.advanceAnimation(
            0, to: CGRect(x: 200, y: 120, width: 360, height: 600))

        adapter.deliverCompletion(0)

        #expect(adapter.frame?.minX == 200)
        #expect(adapter.frame?.maxY == 720)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("An initial transient origin waits for AppKit's menu-bar placement")
    func popoverTransitionWaitsForInitialAnchor() async throws {
        let adapter = TestPopoverWindowAdapter(
            frame: CGRect(x: 0, y: 0, width: 360, height: 220))
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 400))

        #expect(adapter.immediateFrames.isEmpty)
        #expect(coordinator.isQuiescent)

        adapter.frame = CGRect(x: 100, y: 500, width: 360, height: 220)
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.isSettled)
        #expect(adapter.frame?.minX == 100)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("Window readiness after visibility resumes reconciliation")
    func popoverTransitionWaitsForVisibleWindow() async throws {
        let adapter = TestPopoverWindowAdapter()
        adapter.isVisible = false
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 400))
        #expect(coordinator.isQuiescent)

        adapter.isVisible = true
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.isSettled)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("A delayed AppKit placement remains eligible for reconciliation")
    func popoverTransitionWaitsBeyondInitialRetryWindow() async throws {
        let adapter = TestPopoverWindowAdapter(
            frame: CGRect(x: 0, y: 0, width: 360, height: 220))
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 400))

        try await Task.sleep(for: .milliseconds(180))
        #expect(coordinator.isQuiescent)
        adapter.frame = CGRect(x: 100, y: 500, width: 360, height: 220)
        try await Task.sleep(for: .milliseconds(120))

        #expect(coordinator.isSettled)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("Hiding during growth preserves the fixed header baseline")
    func popoverTransitionHideDuringGrowth() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        adapter.advanceAnimation(
            0, to: CGRect(x: 100, y: 170, width: 360, height: 550))

        coordinator.visibilityChanged(false)
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.isQuiescent)
        coordinator.visibilityChanged(true)

        #expect(adapter.frame?.height == 600)
        #expect(adapter.frame?.maxY == 720)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Invalid geometry during growth restores the latest valid target")
    func popoverTransitionInvalidMeasurementDuringGrowth() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        adapter.advanceAnimation(
            0, to: CGRect(x: 100, y: 170, width: 360, height: 550))

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: .nan))

        #expect(adapter.frame?.height == 600)
        #expect(adapter.frame?.maxY == 720)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Hidden reattachment waits for a current correlated measurement")
    func popoverTransitionReattachmentRejectsOldMeasurement() {
        let (coordinator, adapter) = popoverTransitionFixture()
        coordinator.visibilityChanged(false)
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])

        coordinator.visibilityChanged(true)
        #expect(coordinator.isQuiescent)
        #expect(!coordinator.isSettled)
        #expect(adapter.animations.isEmpty)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        #expect(coordinator.isSettled)
        #expect(coordinator.presentation.bodyHeight == 500)
    }

    @MainActor
    @Test("Reduce Motion waits for matching layout before revealing")
    func popoverTransitionReduceMotionAwaitsMeasurement() {
        let (coordinator, _) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.reduceMotionChanged(true)

        #expect(!coordinator.presentation.revealedCards.contains("cursor"))
        #expect(coordinator.presentation.bodyHeight == 400)
        #expect(!coordinator.isSettled)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Reduce Motion settles disclosure without an animation")
    func popoverTransitionReduceMotion() {
        let (coordinator, adapter) = popoverTransitionFixture()
        coordinator.reduceMotionChanged(true)
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        #expect(adapter.animations.isEmpty)
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover body height respects the attached screen cap")
    func popoverTransitionHeightCap() {
        let adapter = TestPopoverWindowAdapter()
        adapter.visibleScreenFrame = CGRect(x: 0, y: 20, width: 1_440, height: 700)
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 1_000))

        #expect(coordinator.presentation.bodyHeight == 628)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("A live screen change reapplies the raw measurement to the new cap")
    func popoverTransitionReappliesScreenCap() {
        let adapter = TestPopoverWindowAdapter(
            frame: CGRect(x: 100, y: 680, width: 360, height: 220))
        adapter.visibleScreenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 1_000))
        #expect(coordinator.presentation.bodyHeight == 828)

        adapter.visibleScreenFrame = CGRect(x: 0, y: 0, width: 1_200, height: 700)
        adapter.frame = CGRect(x: 100, y: 480, width: 360, height: 220)
        coordinator.windowScreenChanged()

        #expect(coordinator.presentation.bodyHeight == 628)
        #expect(adapter.frame?.maxY == 700)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("A stopped window animation settles through the immediate path")
    func popoverTransitionStoppedAnimation() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        adapter.advanceAnimation(
            0, to: CGRect(x: 200, y: 170, width: 360, height: 550))

        adapter.stopAnimation(0)

        #expect(adapter.frame?.minX == 200)
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.presentation.renderedBodyHeight == 500)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Unavailable window animation falls back to immediate settlement")
    func popoverTransitionAnimationFallback() {
        let (coordinator, adapter) = popoverTransitionFixture()
        adapter.frame?.origin.x = 200
        adapter.canAnimate = false
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        #expect(adapter.animations.isEmpty)
        #expect(adapter.frame?.minX == 200)
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Memory pressure invokes rebuildable cache trimming")
    func memoryPressureTrimsCaches() {
        var trimCalls = 0
        let expected = MemoryPressureTrimSummary(costEntries: 12, activityEntries: 7)
        let monitor = MemoryPressureMonitor(
            trimCaches: {
                trimCalls += 1
                return expected
            },
            releaseFreeMallocPages: {})

        let result = monitor.handleMemoryPressureForTesting()

        #expect(trimCalls == 1)
        #expect(result == expected)
        #expect(result.total == 19)
    }

    @MainActor
    @Test("Advisory service refresh is coalesced and publishes independently")
    func serviceStatusRefreshIsIndependent() async {
        let fetcher = SuspendedStatusFetcher()
        let state = AppState(
            pipeline: UnusedPipeline(),
            serviceStatusFetcher: { await fetcher.fetch() }
        )

        state.scheduleServiceStatusRefresh(generation: 0)
        state.scheduleServiceStatusRefresh(generation: 0)

        for _ in 0..<100 {
            if await fetcher.callCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await fetcher.callCount == 1)
        #expect(state.serviceStatus == nil)

        let expected = ServiceStatus(level: .major, description: "Partial outage")
        await fetcher.finish(with: expected)
        for _ in 0..<100 {
            if state.serviceStatus != nil { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(state.serviceStatus == expected)
    }
}
