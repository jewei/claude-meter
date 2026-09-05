import AppKit
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

private actor SuspendedNotificationDelivery: NotificationDelivery {
    private var addContinuation: CheckedContinuation<Void, Never>?
    private var addStarted = false
    private var addStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingIdentifiers: Set<String> = []
    private var deliveredIdentifiers: Set<String> = []
    private var pendingRemovalCount = 0
    private var deliveredRemovalCount = 0

    func authorizationState() async -> NotificationAuthorizationState {
        .authorized
    }

    func requestAuthorization() async throws {}

    func add(_ request: NotificationDeliveryRequest) async throws {
        addStarted = true
        let waiters = addStartWaiters
        addStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        await withCheckedContinuation { continuation in
            addContinuation = continuation
        }

        // Populate both collections to prove that stale delivery cleanup covers
        // either Notification Center state.
        pendingIdentifiers.insert(request.identifier)
        deliveredIdentifiers.insert(request.identifier)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        pendingRemovalCount += 1
        pendingIdentifiers.subtract(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        deliveredRemovalCount += 1
        deliveredIdentifiers.subtract(identifiers)
    }

    func waitUntilAddStarts() async {
        guard !addStarted else { return }
        await withCheckedContinuation { continuation in
            addStartWaiters.append(continuation)
        }
    }

    func waitUntilAddStarts(for timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !addStarted, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return addStarted
    }

    func finishAdd() {
        let continuation = addContinuation
        addContinuation = nil
        continuation?.resume()
    }

    func waitUntilRetractionCompletes(for timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while pendingRemovalCount == 0 || deliveredRemovalCount == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return pendingRemovalCount > 0 && deliveredRemovalCount > 0
    }

    func state() -> (
        pending: Set<String>,
        delivered: Set<String>,
        pendingRemovals: Int,
        deliveredRemovals: Int,
        addStarted: Bool
    ) {
        (
            pendingIdentifiers,
            deliveredIdentifiers,
            pendingRemovalCount,
            deliveredRemovalCount,
            addStarted
        )
    }
}

private actor ControlledNotificationDelivery: NotificationDelivery {
    private let suspendsAdds: Bool
    private var requests: [NotificationDeliveryRequest] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var pendingIdentifiers: Set<String> = []
    private var deliveredIdentifiers: Set<String> = []

    init(suspendsAdds: Bool = true) {
        self.suspendsAdds = suspendsAdds
    }

    func authorizationState() async -> NotificationAuthorizationState { .authorized }
    func requestAuthorization() async throws {}

    func add(_ request: NotificationDeliveryRequest) async throws {
        let index = requests.count
        requests.append(request)
        if suspendsAdds {
            await withCheckedContinuation { continuations[index] = $0 }
        }
        pendingIdentifiers.insert(request.identifier)
        deliveredIdentifiers.insert(request.identifier)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        pendingIdentifiers.subtract(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        deliveredIdentifiers.subtract(identifiers)
    }

    func waitForAdds(_ count: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while requests.count < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return requests.count >= count
    }

    func finishAdd(_ index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }

    func state() -> (requests: [String], pending: Set<String>, delivered: Set<String>) {
        (requests.map(\.identifier), pendingIdentifiers, deliveredIdentifiers)
    }
}

private final class BlockingMainMeterPublication: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func publish(_: MainMeterReading?, in _: SnapshotStore) {
        entered.signal()
        release.wait()
    }

    func waitUntilEntered(for timeout: DispatchTimeInterval) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func finish() {
        release.signal()
    }
}

private actor AuthorizationRecordingDelivery: NotificationDelivery {
    private var requestCount = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func authorizationState() async -> NotificationAuthorizationState {
        .notDetermined
    }

    func requestAuthorization() async throws {
        requestCount += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func add(_: NotificationDeliveryRequest) async throws {}
    func removePendingRequests(withIdentifiers _: [String]) async {}
    func removeDeliveredNotifications(withIdentifiers _: [String]) async {}

    func waitForRequest() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    var requests: Int { requestCount }
}

private actor SuspendedAttentionEventDrainer {
    private let event: SessionEvent
    private var continuation: CheckedContinuation<[SessionEvent], Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(event: SessionEvent) {
        self.event = event
    }

    func drain() async -> [SessionEvent] {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        continuation?.resume(returning: [event])
        continuation = nil
    }
}

private actor PollRecorder {
    private var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let currentWaiters = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        for waiter in currentWaiters { waiter.continuation.resume() }
    }

    func pollCount() -> Int { count }

    func waitForPoll(_ target: Int = 1) async {
        guard count < target else { return }
        await withCheckedContinuation {
            waiters.append((target: target, continuation: $0))
        }
    }
}

private actor PollCompletionBarrier {
    private var arrivalCount = 0
    private var arrivalWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] =
        []
    private var suspended: [Int: CheckedContinuation<Void, Never>] = [:]

    func arriveAndSuspend() async {
        arrivalCount += 1
        let arrival = arrivalCount
        let ready = arrivalWaiters.filter { $0.target <= arrivalCount }
        arrivalWaiters.removeAll { $0.target <= arrivalCount }
        for waiter in ready { waiter.continuation.resume() }
        await withCheckedContinuation { suspended[arrival] = $0 }
    }

    func waitForArrivals(_ target: Int) async {
        guard arrivalCount < target else { return }
        await withCheckedContinuation {
            arrivalWaiters.append((target: target, continuation: $0))
        }
    }

    func release(_ arrival: Int) {
        suspended.removeValue(forKey: arrival)?.resume()
    }
}

private struct RecordingPipeline: ClaudeMeterPipeline {
    let recorder: PollRecorder

    func poll(now _: Date, kind _: RefreshKind) async throws -> ParseResult {
        await recorder.record()
        return ParseResult(snapshot: nil, warnings: [], errors: [], rawHash: "")
    }
}

private actor SuspendedSnapshotPipeline: ClaudeMeterPipeline {
    private let result: ParseResult
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: ClaudeUsageSnapshot) {
        result = ParseResult(
            snapshot: snapshot,
            warnings: [],
            errors: [],
            rawHash: snapshot.parserVersion,
            parserVersion: snapshot.parserVersion)
    }

    func poll(now _: Date, kind _: RefreshKind) async throws -> ParseResult {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation = $0 }
        return result
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private struct FixedSnapshotPipeline: ClaudeMeterPipeline {
    let snapshot: ClaudeUsageSnapshot

    func poll(now _: Date, kind _: RefreshKind) async throws -> ParseResult {
        ParseResult(
            snapshot: snapshot,
            warnings: [],
            errors: [],
            rawHash: snapshot.parserVersion,
            parserVersion: snapshot.parserVersion)
    }
}

private struct FixedResultPipeline: ClaudeMeterPipeline {
    let result: ParseResult

    func poll(now _: Date, kind _: RefreshKind) async throws -> ParseResult {
        result
    }
}

private struct ThrowingPipeline: ClaudeMeterPipeline {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    let message: String

    func poll(now _: Date, kind _: RefreshKind) async throws -> ParseResult {
        throw Failure(message: message)
    }
}

private actor SuspendedResultPipeline: ClaudeMeterPipeline {
    private let result: ParseResult
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: ParseResult) {
        self.result = result
    }

    func poll(now _: Date, kind _: RefreshKind) async throws -> ParseResult {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation = $0 }
        return result
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@Suite("App logic", .serialized)
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

    private actor SuspendedConfigBridgeRefresher {
        private var callCount = 0
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var running: [CheckedContinuation<Void, Never>] = []

        func refresh(_: ConfigBridgeRefreshRequest) async {
            callCount += 1
            let ready = startWaiters.filter { $0.0 <= callCount }
            startWaiters.removeAll { $0.0 <= callCount }
            for waiter in ready { waiter.1.resume() }
            await withCheckedContinuation { running.append($0) }
        }

        func waitForCalls(_ count: Int) async {
            guard callCount < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        func releaseNext() {
            guard !running.isEmpty else { return }
            running.removeFirst().resume()
        }
    }

    private actor SuspendedCodexFetcher {
        private var callCount = 0
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var running: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            callCount += 1
            let ready = waiters.filter { $0.0 <= callCount }
            waiters.removeAll { $0.0 <= callCount }
            for waiter in ready { waiter.1.resume() }
            await withCheckedContinuation { running.append($0) }
        }

        func waitForCalls(_ count: Int) async {
            guard callCount < count else { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }

        func releaseAll() {
            let continuations = running
            running.removeAll()
            for continuation in continuations { continuation.resume() }
        }

        var calls: Int { callCount }
    }

    @Test("A temporary Keychain failure does not skip first-run onboarding")
    func temporaryKeychainFailureIsNotExistingUserEvidence() {
        #expect(
            !AppState.existingUserEvidenceIsPresent(
                snapshotExists: false,
                automaticOAuthAvailability: .temporarilyUnavailable,
                manualOAuthAvailability: .temporarilyUnavailable,
                cursorStateExists: false,
                codexUsageExists: false,
                codexConfigurationExists: false,
                statuslineDataDirectoryExists: false))
    }

    @Test("Confirmed OAuth credential presence skips first-run onboarding")
    func availableCredentialIsExistingUserEvidence() {
        #expect(
            AppState.existingUserEvidenceIsPresent(
                snapshotExists: false,
                automaticOAuthAvailability: .available,
                manualOAuthAvailability: .missing,
                cursorStateExists: false,
                codexUsageExists: false,
                codexConfigurationExists: false,
                statuslineDataDirectoryExists: false))
    }

    @MainActor
    @Test("First-run onboarding blocks polling until Get Started")
    func onboardingLifecycle() async throws {
        let defaults = UserDefaults.standard
        let completionKey = "hasCompletedOnboarding"
        let previousCompletion = defaults.object(forKey: completionKey)
        let previousStatusline = defaults.object(forKey: AppSettings.statuslineSourceEnabledKey)
        defer {
            if let previousCompletion {
                defaults.set(previousCompletion, forKey: completionKey)
            } else {
                defaults.removeObject(forKey: completionKey)
            }
            if let previousStatusline {
                defaults.set(previousStatusline, forKey: AppSettings.statuslineSourceEnabledKey)
            } else {
                defaults.removeObject(forKey: AppSettings.statuslineSourceEnabledKey)
            }
        }
        AppSettings.statuslineSourceEnabled = true

        let recorder = PollRecorder()
        let appState = AppState(
            pipeline: RecordingPipeline(recorder: recorder),
            serviceStatusFetcher: { nil },
            onboardingIsComplete: false)
        defer { appState.stopPolling() }

        appState.startPolling()
        try await Task.sleep(for: .milliseconds(50))
        let countBeforeStart = await recorder.pollCount()
        #expect(countBeforeStart == 0)

        appState.completeOnboarding()
        try await Timeout.run(seconds: 2) { await recorder.waitForPoll() }
        let countAfterStart = await recorder.pollCount()
        #expect(countAfterStart == 1)
        #expect(defaults.bool(forKey: completionKey))
    }

    @MainActor
    @Test("First-run onboarding delays the notification permission prompt")
    func onboardingDelaysNotificationAuthorization() async {
        let delivery = AuthorizationRecordingDelivery()
        let engine = NotificationEngine(delivery: delivery)
        let appState = AppState(
            pipeline: UnusedPipeline(),
            notificationEngine: engine,
            onboardingIsComplete: false)
        defer { appState.stopPolling() }

        await Task.yield()
        #expect(await delivery.requests == 0)

        appState.completeOnboarding()
        await delivery.waitForRequest()
        #expect(await delivery.requests == 1)
    }

    @MainActor
    @Test("Pausing cancels an attention drain before it can post")
    func pauseCancelsSuspendedAttentionDrain() async {
        let defaults = UserDefaults.standard
        let previousStop = defaults.object(forKey: AppSettings.attentionStopEnabledKey)
        let previousActive = defaults.object(forKey: AppSettings.isActiveKey)
        defer {
            if let previousStop {
                defaults.set(previousStop, forKey: AppSettings.attentionStopEnabledKey)
            } else {
                defaults.removeObject(forKey: AppSettings.attentionStopEnabledKey)
            }
            if let previousActive {
                defaults.set(previousActive, forKey: AppSettings.isActiveKey)
            } else {
                defaults.removeObject(forKey: AppSettings.isActiveKey)
            }
        }
        AppSettings.attentionStopEnabled = true

        let event = SessionEvent(
            kind: .stop,
            accountKey: "claude",
            sessionId: "session",
            cwd: nil,
            message: nil,
            capturedAt: Date())
        let drainer = SuspendedAttentionEventDrainer(event: event)
        let delivery = SuspendedNotificationDelivery()
        let state = AppState(
            pipeline: UnusedPipeline(),
            notificationEngine: NotificationEngine(delivery: delivery),
            systemIntegrationEnabled: true,
            configBridgeRefreshOperation: { _ in },
            attentionEventDrainOperation: { _, _ in await drainer.drain() })

        let watcher = state.startAttentionWatcherForTesting()
        await drainer.waitUntilStarted()
        state.setActive(false)
        await drainer.release()
        await watcher?.value

        #expect(!(await delivery.state()).addStarted)
    }

    @MainActor
    @Test("Pausing retracts an attention alert suspended in delivery")
    func pauseRetractsSuspendedAttentionAlert() async {
        let defaults = UserDefaults.standard
        let previousStop = defaults.object(forKey: AppSettings.attentionStopEnabledKey)
        let previousActive = defaults.object(forKey: AppSettings.isActiveKey)
        defer {
            if let previousStop {
                defaults.set(previousStop, forKey: AppSettings.attentionStopEnabledKey)
            } else {
                defaults.removeObject(forKey: AppSettings.attentionStopEnabledKey)
            }
            if let previousActive {
                defaults.set(previousActive, forKey: AppSettings.isActiveKey)
            } else {
                defaults.removeObject(forKey: AppSettings.isActiveKey)
            }
        }
        AppSettings.attentionStopEnabled = true

        let event = SessionEvent(
            kind: .stop,
            accountKey: "claude",
            sessionId: "session",
            cwd: nil,
            message: nil,
            capturedAt: Date())
        let drainer = SuspendedAttentionEventDrainer(event: event)
        let delivery = SuspendedNotificationDelivery()
        let state = AppState(
            pipeline: UnusedPipeline(),
            notificationEngine: NotificationEngine(delivery: delivery),
            systemIntegrationEnabled: true,
            configBridgeRefreshOperation: { _ in },
            attentionEventDrainOperation: { _, _ in await drainer.drain() })

        let watcher = state.startAttentionWatcherForTesting()
        await drainer.waitUntilStarted()
        await drainer.release()
        let didStartDelivery = await delivery.waitUntilAddStarts(for: .seconds(5))
        #expect(didStartDelivery)
        guard didStartDelivery else {
            state.setActive(false)
            await watcher?.value
            return
        }

        state.setActive(false)
        await delivery.finishAdd()
        let didRetract = await delivery.waitUntilRetractionCompletes(for: .seconds(5))
        await watcher?.value

        #expect(didRetract)
        let deliveryState = await delivery.state()
        #expect(deliveryState.pending.isEmpty)
        #expect(deliveryState.delivered.isEmpty)
        #expect(deliveryState.pendingRemovals == 1)
        #expect(deliveryState.deliveredRemovals == 1)
    }

    @MainActor
    @Test("An enabled watcher restart preserves an event already removed from disk")
    func enabledAttentionRestartPreservesInProgressDrain() async {
        let defaults = UserDefaults.standard
        let previousStop = defaults.object(forKey: AppSettings.attentionStopEnabledKey)
        let previousActive = defaults.object(forKey: AppSettings.isActiveKey)
        defer {
            if let previousStop {
                defaults.set(previousStop, forKey: AppSettings.attentionStopEnabledKey)
            } else {
                defaults.removeObject(forKey: AppSettings.attentionStopEnabledKey)
            }
            if let previousActive {
                defaults.set(previousActive, forKey: AppSettings.isActiveKey)
            } else {
                defaults.removeObject(forKey: AppSettings.isActiveKey)
            }
        }
        AppSettings.attentionStopEnabled = true

        let event = SessionEvent(
            kind: .stop,
            accountKey: "claude",
            sessionId: "session",
            cwd: nil,
            message: nil,
            capturedAt: Date())
        let drainer = SuspendedAttentionEventDrainer(event: event)
        let delivery = SuspendedNotificationDelivery()
        let state = AppState(
            pipeline: UnusedPipeline(),
            notificationEngine: NotificationEngine(delivery: delivery),
            systemIntegrationEnabled: true,
            configBridgeRefreshOperation: { _ in },
            attentionEventDrainOperation: { _, _ in await drainer.drain() })
        defer { state.setActive(false) }

        state.startAttentionWatcherForTesting()
        await drainer.waitUntilStarted()
        state.startAttentionWatcherForTesting()
        await drainer.release()

        let didStartDelivery = await delivery.waitUntilAddStarts(for: .seconds(5))
        if didStartDelivery { await delivery.finishAdd() }
        #expect(didStartDelivery)
    }

    @MainActor
    @Test("A cancelled poll cycle cannot clear a newer cycle's loading state")
    func cancelledPollCycleDoesNotOwnNewLoadingState() async throws {
        let defaults = UserDefaults.standard
        let sourceKeys = [
            AppSettings.statuslineSourceEnabledKey,
            AppSettings.oauthSourceEnabledKey,
            AppSettings.cursorSourceEnabledKey,
            AppSettings.codexSourceEnabledKey,
            AppSettings.grokSourceEnabledKey,
        ]
        let previousValues = sourceKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(sourceKeys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        AppSettings.statuslineSourceEnabled = true
        AppSettings.oauthSourceEnabled = false
        AppSettings.cursorSourceEnabled = false
        AppSettings.codexSourceEnabled = false
        AppSettings.grokSourceEnabled = false

        let recorder = PollRecorder()
        let barrier = PollCompletionBarrier()
        let appState = AppState(
            pipeline: RecordingPipeline(recorder: recorder),
            serviceStatusFetcher: { nil },
            pollCompletionBarrier: { await barrier.arriveAndSuspend() })
        defer {
            appState.stopPolling()
            Task {
                await barrier.release(1)
                await barrier.release(2)
                await barrier.release(3)
            }
        }

        appState.startPolling()
        try await Timeout.run(seconds: 2) { await barrier.waitForArrivals(1) }
        appState.stopPolling()
        appState.startPolling()
        try await Timeout.run(seconds: 2) { await barrier.waitForArrivals(2) }

        await barrier.release(1)
        try await Task.sleep(for: .milliseconds(25))
        #expect(appState.isLoading)

        appState.refreshNow()
        try await Task.sleep(for: .milliseconds(25))
        #expect(await recorder.pollCount() == 2)

        await barrier.release(2)
        try await Timeout.run(seconds: 2) { await barrier.waitForArrivals(3) }
        #expect(await recorder.pollCount() == 3)
        await barrier.release(3)
    }

    @MainActor
    @Test("A cancelled old poll cannot overwrite a newer persisted snapshot")
    func cancelledOldPollCannotOverwriteNewerPersistedSnapshot() async throws {
        let defaults = UserDefaults.standard
        let sourceKeys = [
            AppSettings.statuslineSourceEnabledKey,
            AppSettings.oauthSourceEnabledKey,
            AppSettings.cursorSourceEnabledKey,
            AppSettings.codexSourceEnabledKey,
            AppSettings.grokSourceEnabledKey,
        ]
        let previousValues = sourceKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(sourceKeys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        AppSettings.statuslineSourceEnabled = true
        AppSettings.oauthSourceEnabled = false
        AppSettings.cursorSourceEnabled = false
        AppSettings.codexSourceEnabled = false
        AppSettings.grokSourceEnabled = false

        func snapshot(_ version: String, percent: Double) -> ClaudeUsageSnapshot {
            ClaudeUsageSnapshot(
                parserVersion: version,
                createdAt: Date(),
                lastSuccessfulPollAt: Date(),
                source: SourceInfo(cliPath: "/test", command: version),
                limits: LimitInfo(
                    currentSession: LimitWindow(percentUsed: percent)),
                state: SnapshotState(status: .ok, severity: .normal))
        }

        let oldPipeline = SuspendedSnapshotPipeline(snapshot: snapshot("old", percent: 10))
        let state = AppState(
            pipeline: oldPipeline,
            serviceStatusFetcher: { nil },
            oauthEnrichmentFetcher: { _ in .unavailable(.notConnected) })
        defer {
            state.stopPolling()
            Task { await oldPipeline.release() }
        }

        state.startPolling()
        await oldPipeline.waitUntilStarted()
        state.stopPolling()
        state.pipeline = FixedSnapshotPipeline(snapshot: snapshot("new", percent: 90))
        state.startPolling()

        for _ in 0..<200 where state.snapshot?.parserVersion != "new" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(state.snapshot?.parserVersion == "new")
        #expect(state.persistedSnapshotForTesting()?.parserVersion == "new")

        await oldPipeline.release()
        for _ in 0..<20 { await Task.yield() }

        #expect(state.snapshot?.parserVersion == "new")
        #expect(state.persistedSnapshotForTesting()?.parserVersion == "new")
    }

    @MainActor
    @Test("Test polls use an explicit cost scanner or an empty default", arguments: [true, false])
    func testPollCostScannerIsExplicit(usesInjectedScan: Bool) async throws {
        let defaults = UserDefaults.standard
        let sourceKeys = [
            AppSettings.statuslineSourceEnabledKey,
            AppSettings.oauthSourceEnabledKey,
            AppSettings.cursorSourceEnabledKey,
            AppSettings.codexSourceEnabledKey,
            AppSettings.grokSourceEnabledKey,
        ]
        let previousValues = sourceKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(sourceKeys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        AppSettings.statuslineSourceEnabled = true
        AppSettings.oauthSourceEnabled = false
        AppSettings.cursorSourceEnabled = false
        AppSettings.codexSourceEnabled = false
        AppSettings.grokSourceEnabled = false
        let now = Date()
        let snapshot = ClaudeUsageSnapshot(
            parserVersion: "test-scanner", createdAt: now, lastSuccessfulPollAt: now,
            source: SourceInfo(cliPath: "/test", command: "test"),
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 42)),
            models: [ModelUsage(name: "old-model")],
            state: SnapshotState(status: .ok, severity: .normal))
        let expectedModels = usesInjectedScan ? [ModelUsage(name: "test-model")] : []
        let completion = PollRecorder()
        let state: AppState
        if usesInjectedScan {
            state = AppState(
                pipeline: FixedSnapshotPipeline(snapshot: snapshot),
                costUsageScanner: { _, _ in
                    CostUsageResult(models: expectedModels, isPartialEstimate: true)
                },
                pollCompletionBarrier: { await completion.record() })
        } else {
            state = AppState(
                pipeline: FixedSnapshotPipeline(snapshot: snapshot),
                pollCompletionBarrier: { await completion.record() })
        }
        defer { state.stopPolling() }
        state.startPolling()
        try await Timeout.run(seconds: 2) { await completion.waitForPoll() }
        #expect(state.snapshot?.models == expectedModels)
        #expect(state.persistedSnapshotForTesting()?.models == expectedModels)
        #expect(state.snapshot?.limits.currentSession.percentUsed == 42)
        #expect(state.costScanPartial == usesInjectedScan)
    }

    @MainActor
    @Test("Fatal and thrown Claude poll failures persist sanitized diagnostics")
    func claudePollFailuresPersistSanitizedDiagnostics() async throws {
        let defaults = UserDefaults.standard
        let sourceKeys = [
            AppSettings.statuslineSourceEnabledKey,
            AppSettings.oauthSourceEnabledKey,
            AppSettings.cursorSourceEnabledKey,
            AppSettings.codexSourceEnabledKey,
            AppSettings.grokSourceEnabledKey,
        ]
        let previousValues = sourceKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(sourceKeys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        AppSettings.statuslineSourceEnabled = true
        AppSettings.oauthSourceEnabled = false
        AppSettings.cursorSourceEnabled = false
        AppSettings.codexSourceEnabled = false
        AppSettings.grokSourceEnabled = false

        let fatalMessage = "Bearer sk-ant-fatal at /Users/alice/private"
        let thrownMessage = "access_token: oidc-thrown for person@example.com"
        let cases: [(pipeline: any ClaudeMeterPipeline, message: String)] = [
            (
                FixedResultPipeline(
                    result: ParseResult(
                        snapshot: nil,
                        warnings: [],
                        errors: [ParseError(fatalMessage)],
                        rawHash: "")),
                fatalMessage
            ),
            (ThrowingPipeline(message: thrownMessage), thrownMessage),
        ]

        for testCase in cases {
            let completion = PollRecorder()
            let state = AppState(
                pipeline: testCase.pipeline,
                serviceStatusFetcher: { nil },
                oauthEnrichmentFetcher: { _ in .unavailable(.notConnected) },
                pollCompletionBarrier: { await completion.record() })
            state.startPolling()
            try await Timeout.run(seconds: 2) { await completion.waitForPoll() }

            let expected = DiagnosticsSanitizer.sanitize(testCase.message)
            #expect(state.lastError == expected)
            #expect(state.persistedLastErrorForTesting()?.message == expected)
            #expect(!expected.contains("sk-ant-fatal"))
            #expect(!expected.contains("oidc-thrown"))

            state.stopPolling()
            state.pipeline = FixedSnapshotPipeline(
                snapshot: ClaudeUsageSnapshot(
                    parserVersion: "recovered",
                    createdAt: Date(),
                    lastSuccessfulPollAt: Date(),
                    source: SourceInfo(cliPath: "/test", command: "success"),
                    limits: LimitInfo(currentSession: LimitWindow(percentUsed: 20)),
                    state: SnapshotState(status: .ok, severity: .normal)))
            state.startPolling()
            try await Timeout.run(seconds: 2) { await completion.waitForPoll(2) }

            #expect(state.lastError == nil)
            #expect(state.persistedLastErrorForTesting() == nil)
            state.stopPolling()
        }
    }

    @MainActor
    @Test("Stale Claude polls cannot write or clear persisted errors")
    func staleClaudePollCannotPersistError() async throws {
        let defaults = UserDefaults.standard
        let sourceKeys = [
            AppSettings.statuslineSourceEnabledKey,
            AppSettings.oauthSourceEnabledKey,
            AppSettings.cursorSourceEnabledKey,
            AppSettings.codexSourceEnabledKey,
            AppSettings.grokSourceEnabledKey,
        ]
        let previousValues = sourceKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(sourceKeys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        AppSettings.statuslineSourceEnabled = true
        AppSettings.oauthSourceEnabled = false
        AppSettings.cursorSourceEnabled = false
        AppSettings.codexSourceEnabled = false
        AppSettings.grokSourceEnabled = false

        let pipeline = SuspendedResultPipeline(
            result: ParseResult(
                snapshot: nil,
                warnings: [],
                errors: [ParseError("Bearer stale-secret")],
                rawHash: ""))
        let staleSuccessPipeline = SuspendedResultPipeline(
            result: ParseResult(
                snapshot: ClaudeUsageSnapshot(
                    parserVersion: "stale-success",
                    createdAt: Date(),
                    lastSuccessfulPollAt: Date(),
                    source: SourceInfo(cliPath: "/test", command: "stale-success"),
                    limits: LimitInfo(currentSession: LimitWindow(percentUsed: 20)),
                    state: SnapshotState(status: .ok, severity: .normal)),
                warnings: [],
                errors: [],
                rawHash: ""))
        let completion = PollRecorder()
        let state = AppState(
            pipeline: pipeline,
            serviceStatusFetcher: { nil },
            oauthEnrichmentFetcher: { _ in .unavailable(.notConnected) },
            pollCompletionBarrier: { await completion.record() })
        defer {
            state.stopPolling()
            Task {
                await pipeline.release()
                await staleSuccessPipeline.release()
            }
        }

        state.startPolling()
        try await Timeout.run(seconds: 2) { await pipeline.waitUntilStarted() }
        state.stopPolling()
        await pipeline.release()
        try await Timeout.run(seconds: 2) { await completion.waitForPoll() }

        #expect(state.lastError == nil)
        #expect(state.persistedLastErrorForTesting() == nil)

        let currentMessage = "access_token: oidc-current"
        state.pipeline = FixedResultPipeline(
            result: ParseResult(
                snapshot: nil,
                warnings: [],
                errors: [ParseError(currentMessage)],
                rawHash: ""))
        state.startPolling()
        try await Timeout.run(seconds: 2) { await completion.waitForPoll(2) }
        let persistedMessage = DiagnosticsSanitizer.sanitize(currentMessage)
        #expect(state.persistedLastErrorForTesting()?.message == persistedMessage)

        state.stopPolling()
        state.pipeline = staleSuccessPipeline
        state.startPolling()
        try await Timeout.run(seconds: 2) { await staleSuccessPipeline.waitUntilStarted() }
        state.stopPolling()
        await staleSuccessPipeline.release()
        try await Timeout.run(seconds: 2) { await completion.waitForPoll(3) }

        #expect(state.lastError == persistedMessage)
        #expect(state.persistedLastErrorForTesting()?.message == persistedMessage)
    }

    @Test("A complete empty cost scan clears prior account usage")
    func completeEmptyCostScanClearsPriorUsage() {
        var snapshot = ClaudeUsageSnapshot(
            parserVersion: "test-1.0",
            createdAt: Date(timeIntervalSince1970: 100),
            source: SourceInfo(cliPath: "/test", command: "test"),
            limits: LimitInfo(),
            models: [ModelUsage(name: "claude-sonnet")],
            state: SnapshotState(status: .ok, severity: .normal))

        #expect(
            AppState.applyCostModels(
                CostUsageResult(models: [], isPartialEstimate: false),
                to: &snapshot))
        #expect(snapshot.models.isEmpty)

        snapshot.models = [ModelUsage(name: "claude-sonnet")]
        #expect(
            !AppState.applyCostModels(
                CostUsageResult(models: [], isPartialEstimate: true),
                to: &snapshot))
        #expect(snapshot.models.map(\.name) == ["claude-sonnet"])
    }

    @Test("Friendly account labels normalize separators")
    func friendlyAccountLabels() {
        #expect("it-oneone_build".friendlyAccountLabel == "It Oneone Build")
    }

    @MainActor
    @Test("Pausing a test meter preserves the installed meter's activation setting")
    func testMeterActivationIsIsolated() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.isActiveKey)
        let savedActive = previous as? NSNumber
        defer {
            if defaults.object(forKey: AppSettings.isActiveKey) as? NSNumber != savedActive {
                if let previous {
                    defaults.set(previous, forKey: AppSettings.isActiveKey)
                } else {
                    defaults.removeObject(forKey: AppSettings.isActiveKey)
                }
            }
        }
        let state = AppState(pipeline: UnusedPipeline())

        state.setActive(false)

        #expect(!state.isActive)
        #expect(defaults.object(forKey: AppSettings.isActiveKey) as? NSNumber == savedActive)
    }

    @Test("Forecast menu-bar text pairs nearest energy with run-out time")
    func forecastMenuBarText() {
        let now = Date(timeIntervalSince1970: 1_782_269_456)
        let limits = LimitInfo(
            currentSession: LimitWindow(
                percentUsed: 80,
                resetsAt: now.addingTimeInterval(2.5 * 3600)))

        #expect(
            MenuBarText.forecast(
                consideredLimits: [limits],
                progression: .left,
                now: now)
                == "20% · out 38m")
        #expect(
            MenuBarText.forecast(
                consideredLimits: [limits],
                progression: .used,
                now: now)
                == "80% · out 38m")
    }

    @Test("Forecast menu-bar text falls back to nearest percentage")
    func forecastMenuBarFallback() {
        let now = Date(timeIntervalSince1970: 1_782_269_456)
        let limits = LimitInfo(
            currentSession: LimitWindow(
                percentUsed: 20,
                resetsAt: now.addingTimeInterval(2.5 * 3600)))

        #expect(
            MenuBarText.forecast(
                consideredLimits: [limits],
                progression: .left,
                now: now)
                == "80%")
    }

    @Test("Spoken menu-bar text names the window, progression, and overall severity")
    func spokenMenuBarQuota() {
        let now = Date(timeIntervalSince1970: 1_782_269_456)
        let reading = MainMeterReading(
            provider: .codex, accountID: "test", accountLabel: "Test",
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 30),
                currentWeekAllModels: LimitWindow(percentUsed: 96)), observedAt: now)
        for progression in AppGroupConfig.ProgressionMode.allCases {
            for selection in AppGroupConfig.MenuBarWindow.allCases {
                let text = MenuBarText.accessibilitySummary(
                    provider: .codex, reading: reading, progression: progression,
                    selection: selection, isActive: true, isStale: false, isLoading: false,
                    severity: .critical, now: now)
                #expect(text.hasPrefix("Claude Meter. Codex."))
                #expect(text.contains("Overall quota is critical."))
                if selection == .fiveHour || selection == .both {
                    #expect(
                        text.contains(
                            progression == .left
                                ? "Session 70 percent left." : "Session 30 percent used."))
                }
                if selection != .fiveHour {
                    #expect(
                        text.contains(
                            progression == .left
                                ? "Weekly 4 percent left." : "Weekly 96 percent used."))
                }
            }
        }
    }

    @Test("Spoken menu-bar states never describe stale or paused usage as current")
    func spokenMenuBarStates() {
        let now = Date()
        let reading = MainMeterReading(
            provider: .claude, accountID: "test", accountLabel: "Test",
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 30)), observedAt: now)
        func summary(
            active: Bool = true, stale: Bool = false, loading: Bool = false,
            value: MainMeterReading? = nil, provider: MainMeterProvider = .claude
        ) -> String {
            MenuBarText.accessibilitySummary(
                provider: provider, reading: value, progression: .left, selection: .both,
                isActive: active, isStale: stale, isLoading: loading, severity: .normal, now: now)
        }
        #expect(summary(active: false, value: reading) == "Claude Meter. Claude. Paused.")
        #expect(summary(stale: true, value: reading) == "Claude Meter. Claude. Data is stale.")
        #expect(
            summary(stale: true, loading: true, value: reading)
                == "Claude Meter. Claude. Data is stale. Refreshing.")
        #expect(summary(loading: true) == "Claude Meter. Claude. Loading.")
        #expect(summary() == "Claude Meter. Claude. Usage unavailable.")
        #expect(
            summary(value: reading, provider: .codex) == "Claude Meter. Codex. Usage unavailable.")
        #expect(summary(value: reading).contains("Weekly unavailable."))
        #expect(summary(loading: true, value: reading).hasSuffix("Refreshing."))
    }

    @Test("Spoken menu-bar forecast includes its meaning and clears an expired forecast")
    func spokenMenuBarForecast() {
        let now = Date(timeIntervalSince1970: 1_782_269_456)
        let reset = now.addingTimeInterval(2.5 * 3600)
        let reading = MainMeterReading(
            provider: .claude, accountID: "test", accountLabel: "Test",
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 80, resetsAt: reset)),
            observedAt: now)
        func summary(_ time: Date) -> String {
            MenuBarText.accessibilitySummary(
                provider: .claude, reading: reading, progression: .left, selection: .forecast,
                isActive: true, isStale: false, isLoading: false, severity: .warning, now: time)
        }
        #expect(summary(now).contains("May run out in 38m."))
        #expect(!summary(reset).contains("May run out"))
        #expect(summary(reset).contains("Session 100 percent left."))
    }

    @Test("Native menu-bar accessibility updates without changing visible text")
    @MainActor
    func nativeMenuBarAccessibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [], backing: .buffered, defer: true)
        let container = NSView()
        let button = NSStatusBarButton(frame: .zero)
        let otherButton = NSButton(title: "Other", target: nil, action: nil)
        button.title = "42%"
        container.addSubview(otherButton)
        container.addSubview(button)
        window.contentView = container

        let summary = "Claude Meter. Claude. Session 42 percent left."
        #expect(MenuBarAccessibility.update(summary, in: [window]))
        #expect(button.accessibilityTitle() == summary)
        #expect(button.title == "42%")
        #expect(otherButton.accessibilityTitle() != summary)

        let paused = "Claude Meter. Claude. Paused."
        #expect(MenuBarAccessibility.update(paused, in: [window]))
        #expect(button.accessibilityTitle() == paused)
        #expect(!MenuBarAccessibility.update(paused, in: []))
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

    @Test("Codex refresh failure is separate from observation age")
    func codexRefreshFailureIsSeparateFromObservationAge() {
        let suiteName = "CodexFreshness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(180.0, forKey: AppGroupConfig.staleAfterSecondsKey)
        let success = Date(timeIntervalSince1970: 100)
        let reading = CodexAccountReading(
            account: CodexAccount(
                home: URL(fileURLWithPath: "/tmp/codex"),
                isImplicit: true,
                customName: nil),
            state: .stale(
                value: codexUsage(accountEmail: nil),
                polledAt: success,
                error: "offline"),
            lastAttemptAt: Date(timeIntervalSince1970: 110))

        #expect(reading.latestAttemptFailed)
        #expect(
            !reading.observationIsStale(
                asOf: Date(timeIntervalSince1970: 200),
                shared: nil,
                defaults: defaults))
        #expect(
            reading.observationIsStale(
                asOf: Date(timeIntervalSince1970: 281),
                shared: nil,
                defaults: defaults))
    }

    @MainActor
    @Test("Codex last-good store survives relaunch without account email")
    func codexLastGoodStore() {
        let suiteName = "CodexReadingStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CodexReadingStore(defaults: defaults)
        let account = CodexAccount(
            home: URL(fileURLWithPath: "/tmp/codex-work"),
            isImplicit: false,
            customName: "Work")
        let success = Date(timeIntervalSince1970: 123)
        var usage = codexUsage(accountEmail: "person@example.com")
        usage.rateLimitResets = CodexRateLimitResets(
            availableCount: 3,
            credits: [
                CodexRateLimitResetCredit(
                    title: "Full reset", expiresAt: success.addingTimeInterval(86400))
            ])
        let reading = CodexAccountReading(
            account: account,
            state: .current(
                value: usage,
                polledAt: success),
            lastAttemptAt: success)

        store.save([reading])
        let restored = store.restore(accounts: [account])

        #expect(restored.count == 1)
        #expect(restored.first?.lastSuccessfulAt == success)
        #expect(restored.first?.lastAttemptAt == nil)
        #expect(restored.first?.usage?.accountEmail == nil)
        #expect(restored.first?.usage?.maskedAccountEmail == nil)
        #expect(restored.first?.usage?.authMode == .chatGPT)
        let card = restored.first.flatMap(PopoverView.codexAccountModel)
        #expect(card?.rateLimitResets?.availableCount == 3)
        #expect(card?.rateLimitResets?.credits == usage.rateLimitResets?.credits)
    }

    @MainActor
    @Test("A corrupt archived Codex reset cannot reach ISO-8601 persistence")
    func corruptCodexArchiveDateIsSanitized() throws {
        let suiteName = "CodexReadingDateStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CodexReadingStore(defaults: defaults)
        let account = CodexAccount(
            home: URL(fileURLWithPath: "/tmp/codex-date"),
            isImplicit: true,
            customName: nil)
        let observedAt = Date(timeIntervalSince1970: 100)
        let usage = CodexUsage(
            primaryWindow: CodexLimitWindow(
                kind: .primary,
                usedPercent: 20,
                resetAt: Date(timeIntervalSince1970: 200),
                durationSeconds: 18_000,
                rawLabel: nil),
            secondaryWindow: nil,
            usageCredits: nil,
            accountEmail: nil,
            plan: "plus",
            source: .appServer,
            updatedAt: observedAt)
        store.save([
            CodexAccountReading(
                account: account,
                state: .current(value: usage, polledAt: observedAt))
        ])

        let key = "codexLastGoodReadings.v1"
        let data = try #require(defaults.data(forKey: key))
        var archive = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(archive["entries"] as? [String: Any])
        var entry = try #require(entries[account.id] as? [String: Any])
        var archivedUsage = try #require(entry["usage"] as? [String: Any])
        var primary = try #require(archivedUsage["primaryWindow"] as? [String: Any])
        primary["resetAt"] = 1e308
        archivedUsage["primaryWindow"] = primary
        entry["usage"] = archivedUsage
        entries[account.id] = entry
        archive["entries"] = entries
        defaults.set(try JSONSerialization.data(withJSONObject: archive), forKey: key)

        let restored = try #require(store.restore(accounts: [account]).first)
        #expect(restored.usage?.primaryWindow?.resetAt == nil)
        let mainMeter = try #require(AppState.codexMainMeterReading(restored))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexDatePersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotStore = SnapshotStore(directory: directory)
        try snapshotStore.writeMainMeter(mainMeter)
        #expect(try snapshotStore.readMainMeter() == mainMeter)
    }

    @Test("Codex readings normalize into the shared main-meter model")
    func codexMainMeterMapping() throws {
        let observedAt = Date(timeIntervalSince1970: 123)
        let reading = CodexAccountReading(
            account: CodexAccount(
                home: URL(fileURLWithPath: "/tmp/codex-work"),
                isImplicit: false,
                customName: "Pi"),
            state: .current(
                value: codexUsage(accountEmail: "person@example.com"),
                polledAt: observedAt))

        let meter = try #require(AppState.codexMainMeterReading(reading))
        #expect(meter.provider == .codex)
        #expect(meter.accountLabel == "Pi")
        #expect(meter.plan == "Plus")
        #expect(meter.sessionLabel == "5h")
        #expect(meter.limits.currentSession.percentUsed == 25)
        #expect(meter.observedAt == observedAt)
    }

    @Test("A seven-day Codex primary window normalizes as weekly")
    func codexWeeklyPrimaryMapping() throws {
        let observedAt = Date(timeIntervalSince1970: 123)
        let usage = CodexUsage(
            primaryWindow: CodexLimitWindow(
                kind: .primary,
                usedPercent: 18,
                resetAt: Date(timeIntervalSince1970: 456),
                durationSeconds: 7 * 24 * 60 * 60,
                rawLabel: nil),
            secondaryWindow: nil,
            usageCredits: nil,
            accountEmail: nil,
            plan: "prolite",
            authMode: .chatGPT,
            source: .directOAuth,
            updatedAt: observedAt)
        let reading = CodexAccountReading(
            account: CodexAccount(
                home: URL(fileURLWithPath: "/tmp/codex"),
                isImplicit: true,
                customName: nil),
            state: .current(value: usage, polledAt: observedAt))

        let meter = try #require(AppState.codexMainMeterReading(reading))

        #expect(meter.limits.currentSession.percentUsed == nil)
        #expect(meter.limits.currentWeekAllModels.percentUsed == 18)
        #expect(meter.weeklyLabel == "Weekly")
    }

    @Test("Startup compares the current selection with the persisted publication")
    func startupMainMeterTransition() {
        func reading(_ id: String) -> MainMeterReading {
            MainMeterReading(
                provider: .claude,
                accountID: id,
                accountLabel: id,
                limits: LimitInfo(currentSession: LimitWindow(percentUsed: 20)),
                observedAt: Date(timeIntervalSince1970: 100))
        }
        let published = reading("before-reset")
        let current = reading("after-reset")

        let changed = AppState.startupMainMeterTransition(
            previousPublished: published,
            current: current)
        #expect(changed.bumpRevision)
        #expect(changed.reloadWidget)
        #expect(!changed.allowsPersistedRecovery)

        let unchanged = AppState.startupMainMeterTransition(
            previousPublished: current,
            current: current)
        #expect(!unchanged.bumpRevision)
        #expect(!unchanged.reloadWidget)
        #expect(unchanged.allowsPersistedRecovery)
    }

    @Test("Notification baselines never cross main-meter identities")
    func notificationBaselinesStayWithinIdentity() {
        func reading(_ provider: MainMeterProvider, _ accountID: String) -> MainMeterReading {
            MainMeterReading(
                provider: provider,
                accountID: accountID,
                accountLabel: accountID,
                limits: LimitInfo(currentSession: LimitWindow(percentUsed: 20)),
                observedAt: Date(timeIntervalSince1970: 100))
        }
        let codex = reading(.codex, "codex")

        let switched = NotificationPolicy.mainMeterBaselines(
            reading: codex,
            previous: codex,
            notificationIdentity: nil,
            allowsPersistedRecovery: false)
        #expect(switched.escalation == nil)
        #expect(switched.recovery == nil)

        let relaunched = NotificationPolicy.mainMeterBaselines(
            reading: codex,
            previous: codex,
            notificationIdentity: nil,
            allowsPersistedRecovery: true)
        #expect(relaunched.escalation == nil)
        #expect(relaunched.recovery?.stableIdentity == codex.stableIdentity)

        let continuing = NotificationPolicy.mainMeterBaselines(
            reading: codex,
            previous: codex,
            notificationIdentity: codex.stableIdentity,
            allowsPersistedRecovery: false)
        #expect(continuing.escalation?.stableIdentity == codex.stableIdentity)
        #expect(continuing.recovery?.stableIdentity == codex.stableIdentity)
    }

    @Test("Disabling a Claude account preserves its exact main-meter pin")
    func disablingClaudeAccountPreservesPin() {
        let suiteName = "AccountTracking-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("claude-work", forKey: AppGroupConfig.menuBarAccountKey)

        let disabled = AccountTrackingPolicy.updating(
            disabledKeys: [], accountID: "claude-work", enabled: false)

        #expect(disabled == ["claude-work"])
        #expect(defaults.string(forKey: AppGroupConfig.menuBarAccountKey) == "claude-work")
    }

    @Test("Account card style applies equally to Claude and Codex")
    func accountCardStyleAppliesToEveryMainProvider() {
        for provider in MainMeterProvider.allCases {
            #expect(
                PopoverView.accountCardStyle(requested: .rings, provider: provider) == .rings)
            #expect(PopoverView.accountCardStyle(requested: .bars, provider: provider) == .bars)
        }
    }

    @Test("Relative update labels clamp external dates")
    func relativeUpdateLabelsClampExternalDates() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(PopoverView.updatedText(lastPollAt: nil, now: now) == "Not yet polled")
        #expect(
            PopoverView.updatedText(lastPollAt: now.addingTimeInterval(60), now: now)
                == "Just now")
        #expect(
            PopoverView.updatedText(
                lastPollAt: Date(timeIntervalSinceReferenceDate: .nan), now: now)
                == "Just now")
        #expect(
            PopoverView.updatedText(
                lastPollAt: Date(
                    timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude),
                now: now)
                == "\(Int.max / 60)m ago")

        #expect(
            AdvancedSettingsTab.lastCheckedText(
                date: now.addingTimeInterval(60), now: now)
                == "Last checked just now")
        #expect(
            AdvancedSettingsTab.lastCheckedText(
                date: Date(timeIntervalSinceReferenceDate: .nan), now: now)
                == "Last checked just now")
        #expect(
            AdvancedSettingsTab.lastCheckedText(
                date: Date(
                    timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude),
                now: now)
                == "Last checked \(Int.max / 86_400)d ago")
    }

    @Test("Secondary provider badge follows the nearest-limit account")
    func secondaryProviderPlanFollowsNearestLimit() {
        let models = [
            AccountCardModel(
                id: "roomy", label: "Roomy", plan: "Pro", subtitle: nil,
                session: LimitWindow(percentUsed: 10),
                week: LimitWindow(percentUsed: 20), opus: nil),
            AccountCardModel(
                id: "nearest", label: "Nearest", plan: "Max 5x", subtitle: nil,
                session: LimitWindow(percentUsed: 80),
                week: LimitWindow(percentUsed: 70), opus: nil),
        ]

        #expect(
            PopoverView.secondaryProviderPlan(
                from: models,
                asOf: Date(timeIntervalSince1970: 100)) == "Max 5x")
    }

    @Test("Secondary providers do not present unknown limits as full")
    func unknownSecondaryProviderPresentation() {
        let models = [
            AccountCardModel(
                id: "unknown",
                label: "Unknown",
                plan: "Pro",
                subtitle: nil,
                session: LimitWindow(),
                week: LimitWindow(),
                opus: nil)
        ]
        let now = Date(timeIntervalSince1970: 100)

        let presentation = PopoverView.secondaryProviderPresentation(
            from: models,
            showsUsage: false,
            thresholds: UsageThresholds(),
            asOf: now)

        #expect(models[0].bindingLeft(now) == nil)
        #expect(presentation.model == nil)
        #expect(presentation.displayedPercent == nil)
        #expect(presentation.band == .unknown)
        #expect(PopoverView.secondaryProviderPlan(from: models, asOf: now) == nil)
    }

    @Test("Claude account cards keep scoped limits with an active overlay")
    func claudeAccountScopedLimitMapping() {
        let accountScoped = [
            ScopedLimitWindow(
                id: "account",
                window: LimitWindow(percentUsed: 40))
        ]
        let topLevelScoped = [
            ScopedLimitWindow(
                id: "top-level",
                window: LimitWindow(percentUsed: 70))
        ]
        let active = AccountUsage(
            id: "active",
            label: "Active",
            limits: LimitInfo(scopedWeekly: accountScoped),
            severity: .normal,
            isActive: true)
        let inactive = AccountUsage(
            id: "inactive",
            label: "Inactive",
            limits: LimitInfo(scopedWeekly: accountScoped),
            severity: .normal,
            isActive: false)

        #expect(
            PopoverView.scopedLimits(
                for: active,
                topLevel: LimitInfo(scopedWeekly: topLevelScoped)
            ).map(\.id)
                == ["top-level"])
        #expect(
            PopoverView.scopedLimits(for: active, topLevel: LimitInfo()).map(\.id)
                == ["account"])
        #expect(
            PopoverView.scopedLimits(
                for: inactive,
                topLevel: LimitInfo(scopedWeekly: topLevelScoped)
            ).map(\.id)
                == ["account"])
    }

    @Test("Color slider accessibility adjustments use its step and bounds")
    func colorSliderAccessibilityAdjustment() {
        #expect(
            ColorSlider.adjustedValue(
                80,
                direction: .increment,
                range: 50...90,
                step: 5) == 85)
        #expect(
            ColorSlider.adjustedValue(
                90,
                direction: .increment,
                range: 50...90,
                step: 5) == 90)
        #expect(
            ColorSlider.adjustedValue(
                50,
                direction: .decrement,
                range: 50...90,
                step: 5) == 50)
        #expect(
            ColorSlider.adjustedValue(
                .nan,
                direction: .increment,
                range: 50...90,
                step: 5) == 55)
        #expect(ColorSlider.fraction(for: 80, range: 80...80) == 0)
        #expect(ColorSlider.snappedValue(83, range: 50...90, step: 0) == 83)
        #expect(ColorSlider.snappedValue(83, range: 50...90, step: .nan) == 83)
    }

    @Test("Failed secondary provider state remains renderable without claiming cached data")
    func failedSecondaryProviderPresentation() {
        #expect(
            PopoverView.shouldRenderProviderSections(
                hasAnyData: false,
                hasCodexLifecycle: true))
        #expect(
            PopoverView.secondaryProviderDetail(
                hasError: true,
                isStale: false,
                accountCount: 0) == "Refresh failed · no usage data")
        #expect(
            PopoverView.secondaryProviderDetail(
                hasError: true,
                isStale: false,
                accountCount: 1) == "Refresh failed · showing last known data")
    }

    @Test("Chunking preserves order and the final partial chunk")
    func chunking() {
        #expect(Array(1...7).chunked(into: 3) == [[1, 2, 3], [4, 5, 6], [7]])
    }

    @Test("Partial account OAuth success keeps other last-good readings")
    func partialAccountOAuthSuccessKeepsCache() {
        func reading(_ key: String, _ used: Double) -> OAuthAccountReading {
            OAuthAccountReading(
                accountKey: key,
                label: key,
                email: nil,
                plan: nil,
                organizationId: nil,
                limits: LimitInfo(currentSession: LimitWindow(percentUsed: used)),
                severity: .normal,
                fetchedAt: Date(timeIntervalSince1970: used))
        }

        let merged = AppState.mergedCachedAccountReadings(
            previous: [reading("a", 10), reading("b", 20), reading("removed", 30)],
            successful: [reading("a", 80)],
            validAccountKeys: ["a", "b"])

        #expect(merged.map(\.accountKey) == ["a", "b"])
        #expect(merged[0].limits.currentSession.percentUsed == 80)
        #expect(merged[1].limits.currentSession.percentUsed == 20)
    }

    @Test("Disabled Claude accounts stay out of cached OAuth fallback")
    func disabledClaudeAccountsStayOutOfCachedOAuthFallback() {
        func reading(_ key: String) -> OAuthAccountReading {
            OAuthAccountReading(
                accountKey: key,
                label: key,
                email: nil,
                plan: nil,
                organizationId: nil,
                limits: LimitInfo(),
                severity: .normal,
                fetchedAt: Date())
        }

        let filtered = AppState.enabledCachedAccountReadings(
            [reading("claude"), reading("work"), reading("personal")],
            disabledKeys: ["claude", "work"])

        #expect(filtered.map(\.accountKey) == ["claude", "personal"])
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

        AppState.apply(enrichment, to: &snapshot, sourceAccountKey: "claude")

        #expect(snapshot.limits.currentWeekOpus == nil)
        #expect(snapshot.limits.scopedWeekly == nil)
        #expect(snapshot.limits.extraUsage == nil)
        #expect(snapshot.account == AccountInfo(email: "person@example.com"))
    }

    @Test("Direct OAuth observation time uses the successful snapshot time")
    func directOAuthDetailsObservationTime() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let successfulAt = Date(timeIntervalSince1970: 200)
        let snapshot = ClaudeUsageSnapshot(
            parserVersion: "test",
            createdAt: createdAt,
            lastSuccessfulPollAt: successfulAt,
            source: SourceInfo(cliPath: "api.anthropic.com", command: "usage"),
            limits: LimitInfo(),
            state: SnapshotState(status: .ok, severity: .normal))

        #expect(
            AppState.topLevelOAuthDetailsObservedAt(
                for: snapshot,
                enrichmentObservedAt: Date(timeIntervalSince1970: 300)) == successfulAt)

        var snapshotWithoutSuccessTime = snapshot
        snapshotWithoutSuccessTime.lastSuccessfulPollAt = nil
        #expect(
            AppState.topLevelOAuthDetailsObservedAt(
                for: snapshotWithoutSuccessTime,
                enrichmentObservedAt: nil) == createdAt)

        var statuslineSnapshot = snapshot
        statuslineSnapshot.source = SourceInfo(cliPath: "statusline", command: "read")
        let enrichmentAt = Date(timeIntervalSince1970: 300)
        #expect(
            AppState.topLevelOAuthDetailsObservedAt(
                for: statuslineSnapshot,
                enrichmentObservedAt: enrichmentAt) == enrichmentAt)
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

    @MainActor
    @Test("Cached OAuth limits become unknown after their reset")
    func cachedOAuthEnrichmentClearsExpiredLimits() {
        let observedAt = Date(timeIntervalSince1970: 100)
        let resetAt = Date(timeIntervalSince1970: 150)
        let enrichment = OAuthPipeline.OAuthEnrichment(
            opus: LimitWindow(percentUsed: 80, resetsAt: resetAt),
            scopedWeekly: [
                ScopedLimitWindow(
                    id: "seven_day_sonnet",
                    window: LimitWindow(percentUsed: 65, resetsAt: resetAt)),
                ScopedLimitWindow(
                    id: "seven_day_cowork",
                    window: LimitWindow(
                        percentUsed: 25,
                        resetsAt: Date(timeIntervalSince1970: 300))),
            ],
            extraUsage: ExtraUsage(isEnabled: true, usedCredits: 500),
            plan: "Max")
        let cached: ReadingState<OAuthPipeline.OAuthEnrichment> = .stale(
            value: enrichment,
            polledAt: observedAt,
            error: "offline")

        let resolved = AppState.resolvedOAuthEnrichmentReading(
            cached, asOf: Date(timeIntervalSince1970: 200))

        #expect(resolved.value?.opus == nil)
        #expect(resolved.value?.scopedWeekly?.map(\.id) == ["seven_day_cowork"])
        #expect(resolved.value?.extraUsage == enrichment.extraUsage)
        #expect(resolved.value?.plan == "Max")
        #expect(resolved.lastPolledAt == observedAt)
        #expect(resolved.isStale == true)
    }

    @MainActor
    @Test(
        "OAuth details require the same source account",
        arguments: [nil, "claude", "claude-work"] as [String?])
    func oauthEnrichmentRequiresMatchingAccount(sourceAccountKey: String?) {
        let now = Date(timeIntervalSince1970: 200)
        let limits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 30),
            currentWeekOpus: LimitWindow(percentUsed: 20))
        let account = AccountInfo(plan: "Pro")
        var snapshot = ClaudeUsageSnapshot(
            parserVersion: "statusline", createdAt: now, lastSuccessfulPollAt: now,
            source: SourceInfo(cliPath: "statusline", command: "statusline"),
            account: account, limits: limits,
            state: SnapshotState(status: .ok, severity: .normal),
            accounts: [
                AccountUsage(
                    id: "claude-work", label: "Work", account: account, limits: limits,
                    lastSuccessfulPollAt: now, severity: .normal, isActive: true)
            ])
        let original = snapshot
        let enrichment = OAuthPipeline.OAuthEnrichment(
            opus: LimitWindow(percentUsed: 99), scopedWeekly: nil, extraUsage: nil, plan: "Max")
        let applied = AppState.apply(
            enrichment, to: &snapshot, sourceAccountKey: sourceAccountKey)
        #expect(applied == (sourceAccountKey == "claude-work"))
        if applied {
            #expect(snapshot.limits.currentWeekOpus?.percentUsed == 99)
            #expect(snapshot.account?.plan == "Max")
        } else {
            #expect(snapshot == original)
        }
    }

    @Test("Energy bar pace marker stays centered and inside the track")
    func energyBarPaceMarker() {
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: -1) == 0)
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: 0.5) == 49)
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: 2) == 98)
        #expect(energyBarMarkerOffset(width: 1, expectedFraction: 0.5) == 0)
    }

    @Test("Clipboard diagnostics sanitize the complete text")
    func clipboardDiagnosticsSanitization() {
        let text =
            "Account: user@example.com\nHome: /Users/example/private\nCookie: sessionKey=secret"
        let sanitized = sanitizeDiagnosticsForClipboard(text)

        #expect(!sanitized.contains("user@example.com"))
        #expect(!sanitized.contains("/Users/example/private"))
        #expect(!sanitized.contains("sessionKey=secret"))
        #expect(sanitized.contains("[redacted]"))
    }

    @Test("Notification observations require the same generation and meter revision")
    func notificationTargetMustRemainCurrent() {
        let expected = MainMeterReading(
            provider: .claude,
            accountID: "claude",
            accountLabel: "Claude",
            limits: LimitInfo(),
            observedAt: Date(),
            selectionRevision: 4)
        var changedRevision = expected
        changedRevision.selectionRevision = 5

        #expect(
            AppState.notificationTargetMatches(
                expected: expected,
                expectedGeneration: 8,
                current: expected,
                currentGeneration: 8))
        #expect(
            !AppState.notificationTargetMatches(
                expected: expected,
                expectedGeneration: 8,
                current: changedRevision,
                currentGeneration: 8))
        #expect(
            !AppState.notificationTargetMatches(
                expected: expected,
                expectedGeneration: 8,
                current: expected,
                currentGeneration: 9))
    }

    @Test("Invalidation retracts a notification whose add was suspended")
    func notificationInvalidationRetractsSuspendedAdd() async {
        let suiteName = "NotificationInvalidation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let delivery = SuspendedNotificationDelivery()
        let engine = NotificationEngine(defaults: defaults, delivery: delivery)
        let now = Date()
        let resetAt = now.addingTimeInterval(3_600)

        func reading(percentUsed: Double) -> MainMeterReading {
            MainMeterReading(
                provider: .codex,
                accountID: "work",
                accountLabel: "Work",
                limits: LimitInfo(
                    currentSession: LimitWindow(
                        percentUsed: percentUsed,
                        resetsAt: resetAt)),
                observedAt: now,
                selectionRevision: 7)
        }

        let task = Task {
            let lease = engine.quotaLease()
            await engine.process(
                reading: reading(percentUsed: 85),
                previous: reading(percentUsed: 70),
                recoveryBaseline: nil,
                isStale: false,
                expectedRevision: lease)
        }

        await delivery.waitUntilAddStarts()
        engine.pollFailed()
        await delivery.finishAdd()
        await task.value

        let state = await delivery.state()
        #expect(state.pending.isEmpty)
        #expect(state.delivered.isEmpty)
        #expect(state.pendingRemovals == 1)
        #expect(state.deliveredRemovals == 1)
        let persistedDefaults = UserDefaults(suiteName: suiteName)!
        #expect(
            (persistedDefaults.stringArray(forKey: "com.claudemeter.notif.firedKeys") ?? []).isEmpty
        )
    }

    @Test("Old notification cleanup cannot remove a newer alert for the same quota cycle")
    func oldNotificationCleanupKeepsNewerAlert() async {
        let suiteName = "OverlappingNotifications-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let delivery = ControlledNotificationDelivery()
        let engine = NotificationEngine(defaults: defaults, delivery: delivery)
        let now = Date()
        let resetAt = now.addingTimeInterval(3_600)

        func reading(percentUsed: Double) -> MainMeterReading {
            MainMeterReading(
                provider: .codex,
                accountID: "work",
                accountLabel: "Work",
                limits: LimitInfo(
                    currentSession: LimitWindow(percentUsed: percentUsed, resetsAt: resetAt)),
                observedAt: now)
        }

        let oldLease = engine.quotaLease()
        let oldTask = Task {
            await engine.process(
                reading: reading(percentUsed: 85), previous: reading(percentUsed: 70),
                recoveryBaseline: nil, isStale: false, expectedRevision: oldLease)
        }
        let oldStarted = await delivery.waitForAdds(1)
        #expect(oldStarted)
        guard oldStarted else {
            oldTask.cancel()
            return
        }
        engine.notificationSettingsChanged()
        let newLease = engine.quotaLease()
        let newTask = Task {
            await engine.process(
                reading: reading(percentUsed: 85), previous: reading(percentUsed: 70),
                recoveryBaseline: nil, isStale: false, expectedRevision: newLease)
        }
        let newStarted = await delivery.waitForAdds(2)
        #expect(newStarted)
        guard newStarted else {
            newTask.cancel()
            await delivery.finishAdd(0)
            await oldTask.value
            return
        }
        await delivery.finishAdd(1)
        await newTask.value
        await delivery.finishAdd(0)
        await oldTask.value

        let state = await delivery.state()
        #expect(state.pending == [state.requests[1]])
        #expect(state.delivered == [state.requests[1]])
        let persistedDefaults = UserDefaults(suiteName: suiteName)!
        #expect(
            persistedDefaults.stringArray(forKey: "com.claudemeter.notif.firedKeys")?.count == 1)
    }

    @MainActor
    @Test("Optional source changes revoke a suspended quota observation")
    func optionalSourceChangeRevokesSuspendedQuotaObservation() async {
        let suiteName = "OptionalSourceNotification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let delivery = ControlledNotificationDelivery()
        let engine = NotificationEngine(defaults: defaults, delivery: delivery)
        let state = AppState(
            pipeline: UnusedPipeline(), notificationEngine: engine,
            onboardingIsComplete: false)
        let now = Date()
        let resetAt = now.addingTimeInterval(3_600)
        func reading(_ percentUsed: Double) -> MainMeterReading {
            MainMeterReading(
                provider: .claude, accountID: "claude", accountLabel: "Claude",
                limits: LimitInfo(
                    currentSession: LimitWindow(percentUsed: percentUsed, resetsAt: resetAt)),
                observedAt: now)
        }
        let lease = engine.quotaLease()
        let task = Task {
            await engine.process(
                reading: reading(85), previous: reading(70), recoveryBaseline: nil,
                isStale: false, expectedRevision: lease)
        }
        let started = await delivery.waitForAdds(1)
        #expect(started)
        guard started else {
            task.cancel()
            return
        }
        state.setCursorSourceEnabled(false)
        await delivery.finishAdd(0)
        await task.value
        let delivered = await delivery.state()
        #expect(delivered.pending.isEmpty)
        #expect(delivered.delivered.isEmpty)
        let persistedDefaults = UserDefaults(suiteName: suiteName)!
        #expect(
            (persistedDefaults.stringArray(forKey: "com.claudemeter.notif.firedKeys") ?? [])
                .isEmpty)
    }

    @Test("Notification thresholds come from the injected settings", arguments: [true, false])
    func notificationThresholdsUseInjectedDefaults(shouldAlert: Bool) async {
        let suiteName = "InjectedNotificationThresholds-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set(shouldAlert ? 60.0 : 80.0, forKey: "warningThresholdPercent")
        defaults.set(shouldAlert ? 70.0 : 95.0, forKey: "criticalThresholdPercent")
        let delivery = ControlledNotificationDelivery(suspendsAdds: false)
        let engine = NotificationEngine(defaults: defaults, delivery: delivery)
        let now = Date()
        let resetAt = now.addingTimeInterval(3_600)
        func reading(_ percentUsed: Double) -> MainMeterReading {
            MainMeterReading(
                provider: .codex, accountID: "test", accountLabel: "Test",
                limits: LimitInfo(
                    currentSession: LimitWindow(percentUsed: percentUsed, resetsAt: resetAt)),
                observedAt: now)
        }
        await engine.process(
            reading: reading(75), previous: reading(55), recoveryBaseline: nil,
            isStale: false, expectedRevision: engine.quotaLease())
        let state = await delivery.state()
        #expect(state.delivered.count == (shouldAlert ? 1 : 0))
    }

    @Test("Concurrent notification observations submit one alert per quota cycle")
    func concurrentNotificationsSharePendingDelivery() async {
        let suiteName = "ConcurrentNotifications-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let delivery = ControlledNotificationDelivery()
        let engine = NotificationEngine(defaults: defaults, delivery: delivery)
        let now = Date()
        let resetAt = now.addingTimeInterval(3_600)
        func reading(_ percentUsed: Double) -> MainMeterReading {
            MainMeterReading(
                provider: .codex, accountID: "test", accountLabel: "Test",
                limits: LimitInfo(
                    currentSession: LimitWindow(percentUsed: percentUsed, resetsAt: resetAt)),
                observedAt: now)
        }
        let lease = engine.quotaLease()
        let first = Task {
            await engine.process(
                reading: reading(85), previous: reading(70), recoveryBaseline: nil,
                isStale: false, expectedRevision: lease)
        }
        let started = await delivery.waitForAdds(1)
        #expect(started)
        guard started else {
            first.cancel()
            return
        }
        await engine.process(
            reading: reading(85), previous: reading(70), recoveryBaseline: nil,
            isStale: false, expectedRevision: lease)
        await delivery.finishAdd(0)
        await first.value
        let state = await delivery.state()
        #expect(state.requests.count == 1)
        #expect(state.delivered.count == 1)
    }

    @MainActor
    @Test("A meter selection change invalidates a suspended alert before publication")
    func meterSelectionInvalidatesAlertBeforePublication() async {
        let suiteName = "MeterSelectionInvalidation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let delivery = SuspendedNotificationDelivery()
        let engine = NotificationEngine(defaults: defaults, delivery: delivery)
        let publication = BlockingMainMeterPublication()
        let state = AppState(
            pipeline: UnusedPipeline(),
            notificationEngine: engine,
            mainMeterPublicationOperation: { reading, store in
                publication.publish(reading, in: store)
            })
        let now = Date()
        let resetAt = now.addingTimeInterval(3_600)

        let currentReading = MainMeterReading(
            provider: .codex,
            accountID: "work",
            accountLabel: "Work",
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 85, resetsAt: resetAt)),
            observedAt: now,
            selectionRevision: 7)
        let previousReading = MainMeterReading(
            provider: .codex,
            accountID: "work",
            accountLabel: "Work",
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 70, resetsAt: resetAt)),
            observedAt: now,
            selectionRevision: 7)
        let lease = engine.quotaLease()
        let notificationTask = Task.detached {
            await engine.process(
                reading: currentReading,
                previous: previousReading,
                recoveryBaseline: nil,
                isStale: false,
                expectedRevision: lease)
        }
        let didStartDelivery = await delivery.waitUntilAddStarts(for: .seconds(5))
        #expect(didStartDelivery)
        guard didStartDelivery else {
            notificationTask.cancel()
            return
        }

        let publicationFinisher = Task.detached {
            let didEnterPublication = publication.waitUntilEntered(for: .seconds(5))
            guard didEnterPublication else {
                publication.finish()
                await delivery.finishAdd()
                notificationTask.cancel()
                await notificationTask.value
                return false
            }
            await delivery.finishAdd()
            await notificationTask.value
            publication.finish()
            return true
        }
        state.mainMeterSelectionChanged()
        let didEnterPublication = await publicationFinisher.value

        #expect(didEnterPublication)
        let deliveryState = await delivery.state()
        #expect(deliveryState.pending.isEmpty)
        #expect(deliveryState.delivered.isEmpty)
        #expect(deliveryState.pendingRemovals == 1)
        #expect(deliveryState.deliveredRemovals == 1)
        let persistedDefaults = UserDefaults(suiteName: suiteName)!
        #expect(
            (persistedDefaults.stringArray(forKey: "com.claudemeter.notif.firedKeys") ?? [])
                .isEmpty)
    }

    @MainActor
    @Test("Disabling the selected Codex source invalidates an alert before publication")
    func disablingSelectedCodexSourceInvalidatesAlertBeforePublication() async {
        let defaults = UserDefaults.standard
        let shared = AppGroupConfig.sharedDefaults
        let providerKey = AppGroupConfig.mainMeterProviderKey
        let revisionKey = AppGroupConfig.mainMeterRevisionKey
        let previousProvider = defaults.object(forKey: providerKey)
        let previousSharedProvider = shared?.object(forKey: providerKey)
        let previousRevision = defaults.object(forKey: revisionKey)
        let previousSharedRevision = shared?.object(forKey: revisionKey)
        let previousCodexSource = defaults.object(forKey: AppSettings.codexSourceEnabledKey)
        defer {
            if let previousProvider {
                defaults.set(previousProvider, forKey: providerKey)
            } else {
                defaults.removeObject(forKey: providerKey)
            }
            if let previousSharedProvider {
                shared?.set(previousSharedProvider, forKey: providerKey)
            } else {
                shared?.removeObject(forKey: providerKey)
            }
            if let previousRevision {
                defaults.set(previousRevision, forKey: revisionKey)
            } else {
                defaults.removeObject(forKey: revisionKey)
            }
            if let previousSharedRevision {
                shared?.set(previousSharedRevision, forKey: revisionKey)
            } else {
                shared?.removeObject(forKey: revisionKey)
            }
            if let previousCodexSource {
                defaults.set(previousCodexSource, forKey: AppSettings.codexSourceEnabledKey)
            } else {
                defaults.removeObject(forKey: AppSettings.codexSourceEnabledKey)
            }
        }
        defaults.set(MainMeterProvider.codex.rawValue, forKey: providerKey)
        shared?.set(MainMeterProvider.codex.rawValue, forKey: providerKey)
        AppSettings.codexSourceEnabled = false

        let suiteName = "CodexDisableInvalidation-\(UUID().uuidString)"
        let notificationDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        notificationDefaults.set(true, forKey: "enableNotifications")
        let delivery = SuspendedNotificationDelivery()
        let engine = NotificationEngine(defaults: notificationDefaults, delivery: delivery)
        let publication = BlockingMainMeterPublication()
        let state = AppState(
            pipeline: UnusedPipeline(),
            notificationEngine: engine,
            mainMeterPublicationOperation: { reading, store in
                publication.publish(reading, in: store)
            })
        let now = Date()
        let resetAt = now.addingTimeInterval(3_600)
        let currentReading = MainMeterReading(
            provider: .codex,
            accountID: "work",
            accountLabel: "Work",
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 85, resetsAt: resetAt)),
            observedAt: now,
            selectionRevision: 7)
        let previousReading = MainMeterReading(
            provider: .codex,
            accountID: "work",
            accountLabel: "Work",
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 70, resetsAt: resetAt)),
            observedAt: now,
            selectionRevision: 7)
        let lease = engine.quotaLease()
        let notificationTask = Task.detached {
            await engine.process(
                reading: currentReading,
                previous: previousReading,
                recoveryBaseline: nil,
                isStale: false,
                expectedRevision: lease)
        }
        let didStartDelivery = await delivery.waitUntilAddStarts(for: .seconds(5))
        #expect(didStartDelivery)
        guard didStartDelivery else {
            notificationTask.cancel()
            return
        }

        let publicationFinisher = Task.detached {
            let didEnterPublication = publication.waitUntilEntered(for: .seconds(5))
            guard didEnterPublication else {
                publication.finish()
                await delivery.finishAdd()
                notificationTask.cancel()
                await notificationTask.value
                return false
            }
            await delivery.finishAdd()
            await notificationTask.value
            publication.finish()
            return true
        }
        state.setCodexSourceEnabled(false)
        let didEnterPublication = await publicationFinisher.value

        #expect(didEnterPublication)
        let deliveryState = await delivery.state()
        #expect(deliveryState.pending.isEmpty)
        #expect(deliveryState.delivered.isEmpty)
        #expect(deliveryState.pendingRemovals == 1)
        #expect(deliveryState.deliveredRemovals == 1)
    }

    @Test("A queued quota alert keeps its original observation revision")
    func queuedQuotaAlertCannotAdoptANewerRevision() async {
        let delivery = SuspendedNotificationDelivery()
        let engine = NotificationEngine(delivery: delivery)
        let resetAt = Date().addingTimeInterval(3_600)

        func reading(percentUsed: Double) -> MainMeterReading {
            MainMeterReading(
                provider: .claude,
                accountID: "claude",
                accountLabel: "Claude",
                limits: LimitInfo(
                    currentSession: LimitWindow(
                        percentUsed: percentUsed,
                        resetsAt: resetAt)),
                observedAt: Date(),
                selectionRevision: 1)
        }

        let lease = engine.quotaLease()
        // The selected meter changes before the queued actor call starts.
        engine.pollFailed()
        await engine.process(
            reading: reading(percentUsed: 85),
            previous: reading(percentUsed: 70),
            recoveryBaseline: nil,
            isStale: false,
            expectedRevision: lease)

        let state = await delivery.state()
        #expect(!state.addStarted)
        #expect(state.pending.isEmpty)
        #expect(state.delivered.isEmpty)
    }

    @Test("A quota poll failure does not retract a suspended update alert")
    func quotaPollFailureKeepsSuspendedUpdateAlert() async {
        let suiteName = "QuotaFailureUpdate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaults.set(true, forKey: "enableNotifications")
        let delivery = SuspendedNotificationDelivery()
        let engine = NotificationEngine(defaults: defaults, delivery: delivery)
        let task = Task {
            await engine.postUpdateAvailable(version: "99.1")
        }

        let didStart = await delivery.waitUntilAddStarts(for: .seconds(5))
        #expect(didStart)
        guard didStart else { return }
        engine.pollFailed()
        await delivery.finishAdd()
        await task.value

        let state = await delivery.state()
        #expect(state.pending.count == 1)
        #expect(state.pending.first?.hasPrefix("com.claudemeter.update.99.1.") == true)
        #expect(state.delivered == state.pending)
        #expect(state.pendingRemovals == 0)
        #expect(state.deliveredRemovals == 0)
    }

    @Test("A notification setting change retracts a suspended update alert")
    func notificationSettingChangeRetractsSuspendedUpdateAlert() async {
        let suiteName = "SettingsChangeUpdate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaults.set(true, forKey: "enableNotifications")
        let delivery = SuspendedNotificationDelivery()
        let engine = NotificationEngine(defaults: defaults, delivery: delivery)
        let task = Task {
            await engine.postUpdateAvailable(version: "99.2")
        }

        let didStart = await delivery.waitUntilAddStarts(for: .seconds(5))
        #expect(didStart)
        guard didStart else { return }
        engine.notificationSettingsChanged()
        await delivery.finishAdd()
        await task.value

        let state = await delivery.state()
        #expect(state.pending.isEmpty)
        #expect(state.delivered.isEmpty)
        #expect(state.pendingRemovals == 1)
        #expect(state.deliveredRemovals == 1)
    }

    @Test("Attention setting invalidation retracts a suspended alert")
    func attentionInvalidationRetractsSuspendedAdd() async {
        let delivery = SuspendedNotificationDelivery()
        let engine = NotificationEngine(delivery: delivery)
        let event = SessionEvent(
            kind: .stop,
            accountKey: "claude",
            sessionId: "session",
            cwd: "/tmp/project",
            message: nil,
            capturedAt: Date())
        let lease = engine.attentionLease()
        let task = Task {
            await engine.postAttention(
                event: event,
                accountLabel: "Default",
                expectedRevision: lease)
        }

        await delivery.waitUntilAddStarts()
        engine.attentionSettingsChanged()
        await delivery.finishAdd()
        await task.value

        let state = await delivery.state()
        #expect(state.pending.isEmpty)
        #expect(state.delivered.isEmpty)
        #expect(state.pendingRemovals == 1)
        #expect(state.deliveredRemovals == 1)
    }

    @Test("A queued attention alert keeps its original setting revision")
    func queuedAttentionAlertCannotAdoptANewerRevision() async {
        let delivery = SuspendedNotificationDelivery()
        let engine = NotificationEngine(delivery: delivery)
        let event = SessionEvent(
            kind: .notification,
            accountKey: "claude",
            sessionId: "session",
            cwd: "/tmp/project",
            message: "Waiting",
            capturedAt: Date())
        let lease = engine.attentionLease()

        // The setting changes before the queued actor call starts.
        engine.attentionSettingsChanged()
        await engine.postAttention(
            event: event,
            accountLabel: "Default",
            expectedRevision: lease)

        let state = await delivery.state()
        #expect(!state.addStarted)
        #expect(state.pending.isEmpty)
        #expect(state.delivered.isEmpty)
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

    @Test("OAuth verification cannot apply after source disable")
    func disabledOAuthSourceRejectsVerificationResult() {
        #expect(
            OAuthSetupState.canApplyVerificationResult(
                expectedGeneration: 4,
                currentGeneration: 4,
                sourceIsEnabled: true,
                taskIsCancelled: false))
        #expect(
            !OAuthSetupState.canApplyVerificationResult(
                expectedGeneration: 4,
                currentGeneration: 4,
                sourceIsEnabled: false,
                taskIsCancelled: false))
        #expect(
            !OAuthSetupState.canApplyVerificationResult(
                expectedGeneration: 4,
                currentGeneration: 5,
                sourceIsEnabled: true,
                taskIsCancelled: false))
        #expect(
            !OAuthSetupState.canApplyVerificationResult(
                expectedGeneration: 4,
                currentGeneration: 4,
                sourceIsEnabled: true,
                taskIsCancelled: true))
    }

    @Test("Stale hero does not promise available capacity")
    func staleHeroCopy() {
        let stale = HeroSummary.stale(
            providerName: "Codex", recovery: "Codex data is out of date")
        #expect(stale.title == "Refresh needed")
        #expect(!stale.subtitle.contains("Plenty"))
    }

    @Test("Hero does not call mixed full and unknown accounts all fresh")
    func mixedFullAndUnknownHeroCopy() {
        let now = Date(timeIntervalSince1970: 100)
        let models = [
            AccountCardModel(
                id: "full",
                label: "Full",
                plan: nil,
                subtitle: nil,
                session: LimitWindow(percentUsed: 0),
                week: LimitWindow(percentUsed: 0),
                opus: nil),
            AccountCardModel(
                id: "unknown",
                label: "Unknown",
                plan: nil,
                subtitle: nil,
                session: LimitWindow(),
                week: LimitWindow(),
                opus: nil),
        ]

        let hero = HeroSummary.make(models: models, thresholds: .default, now: now)

        #expect(hero.subtitle == "1 fresh · 1 warming up")
    }

    @Test("Hero calls all known full accounts fresh")
    func allFullHeroCopy() {
        let now = Date(timeIntervalSince1970: 100)
        let models = ["one", "two"].map {
            AccountCardModel(
                id: $0,
                label: $0,
                plan: nil,
                subtitle: nil,
                session: LimitWindow(percentUsed: 0),
                week: LimitWindow(percentUsed: 0),
                opus: nil)
        }

        let hero = HeroSummary.make(models: models, thresholds: .default, now: now)

        #expect(hero.subtitle == "All 2 accounts fresh 🎉")
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
        for _ in 0..<100 where !coordinator.isSettled {
            try await Task.sleep(for: .milliseconds(5))
        }
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
        for _ in 0..<100 where !coordinator.isSettled {
            try await Task.sleep(for: .milliseconds(5))
        }

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
        for _ in 0..<100 where !coordinator.isSettled {
            try await Task.sleep(for: .milliseconds(5))
        }

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

    @MainActor
    @Test("Bridge refresh requests keep one running task and one rerun")
    func bridgeRefreshIsBoundedlyCoalesced() async {
        let refresher = SuspendedConfigBridgeRefresher()
        let state = AppState(
            pipeline: UnusedPipeline(),
            systemIntegrationEnabled: true,
            configBridgeRefreshOperation: { request in
                await refresher.refresh(request)
            })

        for _ in 0..<20 { state.refreshConfigBridgesForTesting() }
        await refresher.waitForCalls(1)
        #expect(state.configRefreshOperationCount == 1)

        await refresher.releaseNext()
        await refresher.waitForCalls(2)
        #expect(state.configRefreshOperationCount == 2)

        for _ in 0..<20 { state.refreshConfigBridgesForTesting() }
        #expect(state.configRefreshOperationCount == 2)
        await refresher.releaseNext()
        await refresher.waitForCalls(3)
        #expect(state.configRefreshOperationCount == 3)
        await refresher.releaseNext()
    }

    @Test("Codex account polling has one total deadline")
    func codexAccountsUseOneTotalDeadline() async {
        let accounts = (0..<4).map { index in
            CodexAccount(
                home: URL(fileURLWithPath: "/tmp/codex-\(index)"),
                isImplicit: index == 0,
                customName: nil)
        }
        let priorDate = Date(timeIntervalSince1970: 100)
        let prior = CodexAccountReading(
            account: accounts[0],
            state: .current(
                value: codexUsage(accountEmail: nil),
                polledAt: priorDate))
        let fetcher = SuspendedCodexFetcher()
        let budget = Timeout.TaskBudget(limit: 3)
        let startedAt = Date()
        let task = Task {
            await AppState.fetchCodexAccountReadings(
                accounts: accounts,
                previous: [accounts[0].id: prior],
                mode: .auto,
                now: Date(),
                perAccountTimeoutSeconds: 1,
                totalTimeoutSeconds: 0.05,
                budget: budget
            ) { _, _, _ in
                await fetcher.suspend()
                return CodexUsage(
                    primaryWindow: nil,
                    secondaryWindow: nil,
                    usageCredits: CodexCredits(remaining: 1),
                    accountEmail: nil,
                    plan: nil,
                    source: .appServer,
                    updatedAt: Date())
            }
        }

        await fetcher.waitForCalls(3)
        let readings = await task.value
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(readings.count == 4)
        #expect(await fetcher.calls == 3)
        #expect(elapsed < 0.5)
        #expect(readings[0].state.isStale)
        #expect(readings[0].lastSuccessfulAt == priorDate)
        #expect(readings.dropFirst().allSatisfy { $0.usage == nil })
        #expect(readings.allSatisfy { $0.error?.contains("Timed out") == true })
        await fetcher.releaseAll()
    }

    private func codexUsage(accountEmail: String?) -> CodexUsage {
        CodexUsage(
            primaryWindow: CodexLimitWindow(
                kind: .primary,
                usedPercent: 25,
                resetAt: nil,
                durationSeconds: 18_000,
                rawLabel: nil),
            secondaryWindow: nil,
            usageCredits: nil,
            accountEmail: accountEmail,
            plan: "plus",
            authMode: .chatGPT,
            source: .appServer,
            updatedAt: Date(timeIntervalSince1970: 100))
    }
}
