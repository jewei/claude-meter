import AppKit
import Combine
import SwiftUI

struct CorrelatedBodyMeasurement: Equatable {
    let disclosure: Set<String>
    let renderSequence: UInt64
    let height: CGFloat
}

private struct CorrelatedBodyMeasurementKey: PreferenceKey {
    static let defaultValue: [CorrelatedBodyMeasurement] = []

    static func reduce(
        value: inout [CorrelatedBodyMeasurement],
        nextValue: () -> [CorrelatedBodyMeasurement]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct PopoverRevealedCardsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

private struct PopoverDisclosureAnimationsDisabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    fileprivate var popoverRevealedCards: Set<String> {
        get { self[PopoverRevealedCardsKey.self] }
        set { self[PopoverRevealedCardsKey.self] = newValue }
    }

    fileprivate var popoverDisclosureAnimationsDisabled: Bool {
        get { self[PopoverDisclosureAnimationsDisabledKey.self] }
        set { self[PopoverDisclosureAnimationsDisabledKey.self] = newValue }
    }
}

private struct PopoverDisclosureModifier: ViewModifier {
    @Environment(\.popoverRevealedCards) private var revealedCards
    @Environment(\.popoverDisclosureAnimationsDisabled) private var animationsDisabled
    let id: String

    func body(content: Content) -> some View {
        content
            .mask(alignment: .top) {
                Rectangle()
                    .scaleEffect(
                        y: revealedCards.contains(id) ? 1 : 0,
                        anchor: .top)
            }
            .transaction { transaction in
                if animationsDisabled {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

extension View {
    /// Marks conditionally rendered provider details. The ID must be stable,
    /// canonical, and unique among rendered cards. The transition body decides
    /// clipping; the caller remains responsible for whether the details exist.
    func popoverDisclosure(id: String) -> some View {
        modifier(PopoverDisclosureModifier(id: id))
    }
}

enum PopoverWindowAnimationOutcome {
    case reachedTarget
    case stopped
}

@MainActor
protocol PopoverWindowAdapter: AnyObject {
    var isVisible: Bool { get }
    var frame: CGRect? { get }
    var visibleScreenFrame: CGRect? { get }

    /// Invalidates and stops the current driver, restores the frame that was
    /// applied before stopping, and returns that actual presentation frame.
    func interruptAndCapturePresentation() -> CGRect?
    func setFrameImmediately(_ frame: CGRect, display: Bool)
    func animateFrame(
        to frame: CGRect,
        duration: TimeInterval,
        completion: @escaping @MainActor (PopoverWindowAnimationOutcome) -> Void
    ) -> Bool
}

@MainActor
private final class AppKitPopoverWindowAdapter: NSObject, PopoverWindowAdapter,
    NSAnimationDelegate
{
    private weak var window: NSWindow?
    private var animation: NSViewAnimation?
    private var activeAnimationID: ObjectIdentifier?
    private var completion: (@MainActor (PopoverWindowAnimationOutcome) -> Void)?
    var screenChanged: (@MainActor () -> Void)?

    init(window: NSWindow) {
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isVisible: Bool { window?.isVisible == true }
    var frame: CGRect? { window?.frame }
    var visibleScreenFrame: CGRect? { window?.screen?.visibleFrame }

    func wraps(_ candidate: NSWindow) -> Bool {
        window === candidate
    }

    func interruptAndCapturePresentation() -> CGRect? {
        guard let window else {
            invalidateAnimation()
            return nil
        }

        let captured = window.frame
        let oldAnimation = animation
        invalidateAnimation()
        oldAnimation?.stop()
        // A nonblocking prototype on arm64 macOS 15.7.9 (24G830) observed the
        // frame unchanged both immediately and 50 ms after `stop()`, while Apple's
        // documentation describes end-frame behavior. Restore in this actor turn
        // so callers get one contract on either behavior.
        window.setFrame(captured, display: false)
        return captured
    }

    func setFrameImmediately(_ frame: CGRect, display: Bool) {
        _ = interruptAndCapturePresentation()
        window?.setFrame(frame, display: display)
    }

    func animateFrame(
        to frame: CGRect,
        duration: TimeInterval,
        completion: @escaping @MainActor (PopoverWindowAnimationOutcome) -> Void
    ) -> Bool {
        guard let window, window.isVisible else { return false }

        let attributes: [NSViewAnimation.Key: Any] = [
            .target: window,
            .startFrame: NSValue(rect: window.frame),
            .endFrame: NSValue(rect: frame),
        ]
        let animation = NSViewAnimation(viewAnimations: [attributes])
        animation.duration = duration
        animation.animationCurve = .easeInOut
        animation.animationBlockingMode = .nonblocking
        animation.delegate = self

        self.animation = animation
        activeAnimationID = ObjectIdentifier(animation)
        self.completion = completion
        animation.start()
        return true
    }

    @objc nonisolated private func windowDidChangeScreen(_: Notification) {
        Task { @MainActor [weak self] in self?.screenChanged?() }
    }

    nonisolated func animationDidEnd(_ animation: NSAnimation) {
        let id = ObjectIdentifier(animation)
        Task { @MainActor [weak self] in
            self?.animationFinished(id: id, outcome: .reachedTarget)
        }
    }

    nonisolated func animationDidStop(_ animation: NSAnimation) {
        let id = ObjectIdentifier(animation)
        Task { @MainActor [weak self] in
            self?.animationFinished(id: id, outcome: .stopped)
        }
    }

    private func animationFinished(
        id: ObjectIdentifier,
        outcome: PopoverWindowAnimationOutcome
    ) {
        guard id == activeAnimationID else { return }
        let callback = completion
        invalidateAnimation()
        callback?(outcome)
    }

    private func invalidateAnimation() {
        animation?.delegate = nil
        animation = nil
        activeAnimationID = nil
        completion = nil
    }
}

@MainActor
private final class PopoverWindowCaptureView: NSView {
    var windowChanged: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

private struct PopoverWindowCapture: NSViewRepresentable {
    let windowChanged: @MainActor (NSWindow?) -> Void

    func makeNSView(context _: Context) -> PopoverWindowCaptureView {
        let view = PopoverWindowCaptureView()
        view.windowChanged = windowChanged
        return view
    }

    func updateNSView(_ view: PopoverWindowCaptureView, context _: Context) {
        view.windowChanged = windowChanged
        if view.window != nil { windowChanged(view.window) }
    }
}

struct PopoverTransitionPresentation: Equatable {
    /// Height that participates in SwiftUI fitting-size negotiation.
    var bodyHeight: CGFloat
    /// Full viewport drawn into AppKit's progressively growing window.
    var renderedBodyHeight: CGFloat
    var revealedCards: Set<String>
    var disablesDisclosureAnimations: Bool
}

@MainActor
final class PopoverTransitionCoordinator: ObservableObject {
    private struct Baseline {
        var frame: CGRect
        var bodyHeight: CGFloat

        var nonBodyHeight: CGFloat { frame.height - bodyHeight }

        func targetFrame(bodyHeight: CGFloat) -> CGRect {
            let targetHeight = nonBodyHeight + bodyHeight
            return CGRect(
                x: frame.minX,
                y: frame.maxY - targetHeight,
                width: frame.width,
                height: targetHeight)
        }
    }

    private enum TransitionPhase {
        case idle
        case animating
    }

    private static let minimumBodyHeight: CGFloat = 120
    private static let fallbackScreenHeight: CGFloat = 900
    private static let screenMarginAndHeader: CGFloat = 72
    private static let tolerance: CGFloat = 0.5
    private static let anchorTolerance: CGFloat = 32
    private static let duration: TimeInterval = 0.18

    @Published private(set) var presentation: PopoverTransitionPresentation
    private(set) var isSettled = false
    private(set) var isQuiescent = true

    private var latestDesired: Set<String>
    private var settledDisclosure: Set<String>
    private var renderSequence: UInt64 = 0
    private var epoch: UInt64 = 0
    private var latestRawMeasurement: CorrelatedBodyMeasurement?
    private var latestValidMeasurement: CorrelatedBodyMeasurement?
    private var acceptedTargetHeight: CGFloat?
    private var clippedInsertions: Set<String> = []
    private var pendingReplacement = false
    private var pendingStartFrame: CGRect?
    private var transitionPhase = TransitionPhase.idle
    private var deferredResize: Task<Void, Never>?
    private var deferredAnchorReconciliation: Task<Void, Never>?
    private var baseline: Baseline?
    private var lastAnchoredFrame: CGRect?
    private var lastAnchoredScreenFrame: CGRect?
    /// Fixed header plus window insets. Kept while quiescent so an interrupted
    /// frame can never be mistaken for a new header contribution.
    private var fixedNonBodyHeight: CGFloat?
    private var isPopoverVisible = false
    private var reduceMotion = false
    private var windowAdapter: (any PopoverWindowAdapter)?
    private let acceptsCapturedWindow: Bool

    init(
        initialDesiredDisclosure: Set<String>,
        windowAdapter: (any PopoverWindowAdapter)? = nil
    ) {
        latestDesired = initialDesiredDisclosure
        settledDisclosure = initialDesiredDisclosure
        presentation = PopoverTransitionPresentation(
            bodyHeight: Self.minimumBodyHeight,
            renderedBodyHeight: Self.minimumBodyHeight,
            revealedCards: initialDesiredDisclosure,
            disablesDisclosureAnimations: true)
        self.windowAdapter = windowAdapter
        acceptsCapturedWindow = windowAdapter == nil
    }

    @discardableResult
    func desiredDisclosureChanged(_ desired: Set<String>) -> UInt64 {
        guard desired != latestDesired else { return renderSequence }

        invalidateCurrentTransition(capturePresentation: true)
        let removed = latestDesired.subtracting(desired)
        let inserted = desired.subtracting(latestDesired)
        clippedInsertions.subtract(removed)
        clippedInsertions.formUnion(inserted)
        presentation.disablesDisclosureAnimations = true
        presentation.revealedCards.subtract(removed)
        presentation.revealedCards.formIntersection(desired)

        latestDesired = desired
        renderSequence &+= 1
        pendingReplacement = true
        acceptedTargetHeight = nil
        isSettled = false

        if !canPresentInWindow {
            clippedInsertions.removeAll()
            revealLatestDisclosure(animated: false)
        }
        return renderSequence
    }

    func bodyMeasured(_ measurement: CorrelatedBodyMeasurement) {
        guard measurement.disclosure == latestDesired,
            measurement.renderSequence == renderSequence
        else { return }
        guard measurement.height.isFinite, measurement.height > 0 else {
            if let latestValidMeasurement,
                measurementIsCurrent(latestValidMeasurement),
                canPresentInWindow
            {
                settleImmediately(using: latestValidMeasurement)
            } else {
                becomeQuiescent(clearMeasurement: false)
            }
            return
        }

        latestRawMeasurement = measurement
        let normalized = normalizedHeight(measurement.height)
        let normalizedMeasurement = CorrelatedBodyMeasurement(
            disclosure: measurement.disclosure,
            renderSequence: measurement.renderSequence,
            height: normalized)

        if let acceptedTargetHeight,
            abs(acceptedTargetHeight - normalized) <= Self.tolerance
        {
            return
        }

        latestValidMeasurement = normalizedMeasurement

        if transitionPhase == .animating, acceptedTargetHeight != nil {
            // A materially different measurement for the same semantic render is
            // reconciliation, not another disclosure transition.
            settleImmediately(using: normalizedMeasurement)
            return
        }

        guard canPresentInWindow else {
            settleWithoutWindow(using: normalizedMeasurement)
            if isPopoverVisible { scheduleAnchorReconciliation() }
            return
        }

        guard baseline != nil else {
            establishBaseline(using: normalizedMeasurement)
            return
        }

        if pendingReplacement && canAnimateDisclosure {
            beginDisclosureTransition(using: normalizedMeasurement)
        } else {
            settleImmediately(using: normalizedMeasurement)
        }
    }

    func visibilityChanged(_ visible: Bool) {
        guard visible != isPopoverVisible else { return }
        isPopoverVisible = visible
        if visible {
            reconcileAvailablePresentation()
            if !isSettled { scheduleAnchorReconciliation() }
        } else {
            becomeQuiescent(clearMeasurement: false)
        }
    }

    func reduceMotionChanged(_ enabled: Bool) {
        guard enabled != reduceMotion else { return }
        reduceMotion = enabled
        if enabled, let measurement = currentNormalizedMeasurement() {
            latestValidMeasurement = measurement
            settleImmediately(using: measurement)
        }
    }

    func capturedWindowChanged(_ window: NSWindow?) {
        guard acceptsCapturedWindow else { return }
        if let window {
            if let current = windowAdapter as? AppKitPopoverWindowAdapter,
                current.wraps(window)
            {
                return
            }
            invalidateCurrentTransition(capturePresentation: false)
            let adapter = AppKitPopoverWindowAdapter(window: window)
            adapter.screenChanged = { [weak self] in self?.windowScreenChanged() }
            windowAdapter = adapter
            baseline = nil
            lastAnchoredFrame = nil
            lastAnchoredScreenFrame = nil
            reconcileAvailablePresentation()
            if !isSettled { scheduleAnchorReconciliation() }
        } else {
            let detachedAdapter = windowAdapter
            _ = detachedAdapter?.interruptAndCapturePresentation()
            windowAdapter = nil
            lastAnchoredFrame = nil
            lastAnchoredScreenFrame = nil
            becomeQuiescent(clearMeasurement: false)
        }
    }

    func windowScreenChanged() {
        guard isPopoverVisible else { return }
        invalidateCurrentTransition(capturePresentation: true)
        baseline = nil
        reconcileAvailablePresentation()
        if !isSettled { scheduleAnchorReconciliation() }
    }

    private var canPresentInWindow: Bool {
        isPopoverVisible && windowAdapter?.isVisible == true && windowAdapter?.frame != nil
    }

    private var canAnimateDisclosure: Bool {
        canPresentInWindow && baseline != nil && !reduceMotion
    }

    private func normalizedHeight(_ height: CGFloat) -> CGFloat {
        let screenHeight =
            windowAdapter?.visibleScreenFrame?.height
            ?? (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height
            ?? Self.fallbackScreenHeight
        let maximum = max(560, screenHeight - Self.screenMarginAndHeader)
        return min(max(height, Self.minimumBodyHeight), maximum)
    }

    private func establishBaseline(using measurement: CorrelatedBodyMeasurement) {
        guard let adapter = windowAdapter, let frame = adapter.frame else {
            settleWithoutWindow(using: measurement)
            return
        }
        guard let anchorFrame = resolvedAnchorFrame(current: frame, adapter: adapter) else {
            settleWithoutWindow(using: measurement)
            scheduleAnchorReconciliation()
            return
        }

        let nonBodyHeight =
            fixedNonBodyHeight ?? (anchorFrame.height - presentation.bodyHeight)
        let provisionalFrame = CGRect(
            x: anchorFrame.minX,
            y: anchorFrame.maxY - (nonBodyHeight + presentation.bodyHeight),
            width: anchorFrame.width,
            height: nonBodyHeight + presentation.bodyHeight)
        let provisional = Baseline(
            frame: provisionalFrame,
            bodyHeight: presentation.bodyHeight)
        let target = provisional.targetFrame(bodyHeight: measurement.height)
        adapter.setFrameImmediately(target, display: true)
        pendingStartFrame = nil
        presentation.bodyHeight = measurement.height
        presentation.renderedBodyHeight = measurement.height
        revealLatestDisclosure(animated: false)
        clippedInsertions.removeAll()
        baseline = Baseline(frame: target, bodyHeight: measurement.height)
        rememberAnchor(target, adapter: adapter)
        fixedNonBodyHeight = target.height - measurement.height
        settledDisclosure = latestDesired
        acceptedTargetHeight = measurement.height
        pendingReplacement = false
        finishReconciliation()
    }

    private func beginDisclosureTransition(using measurement: CorrelatedBodyMeasurement) {
        guard let baseline, let adapter = windowAdapter else {
            settleWithoutWindow(using: measurement)
            return
        }

        // The anchor can move between the disclosure action and its correlated
        // layout measurement. Prefer the frame visible now; the earlier capture
        // is only a fallback when AppKit can no longer provide one.
        let capturedSource =
            adapter.interruptAndCapturePresentation() ?? adapter.frame ?? pendingStartFrame
        guard let capturedSource,
            let source = resolvedAnchorFrame(current: capturedSource, adapter: adapter)
        else {
            settleWithoutWindow(using: measurement)
            scheduleAnchorReconciliation()
            return
        }
        if source != capturedSource {
            adapter.setFrameImmediately(source, display: false)
        }
        let targetHeight = baseline.nonBodyHeight + measurement.height
        let target = CGRect(
            x: source.minX,
            y: source.maxY - targetHeight,
            width: source.width,
            height: targetHeight)

        acceptedTargetHeight = measurement.height
        pendingReplacement = false
        pendingStartFrame = source

        guard abs(target.height - source.height) > Self.tolerance else {
            settleImmediately(using: measurement)
            return
        }

        epoch &+= 1
        let transitionEpoch = epoch
        let growing = target.height > source.height
        transitionPhase = .animating
        isQuiescent = false

        if growing {
            presentation.renderedBodyHeight = measurement.height
            revealLatestDisclosure(animated: true)
            startWindowAnimation(
                from: source,
                to: target,
                measurement: measurement,
                epoch: transitionEpoch)
        } else {
            // Commit the smaller fitting size first. Restore the captured visible
            // frame on the next actor turn before AppKit starts shrinking.
            presentation.bodyHeight = measurement.height
            presentation.renderedBodyHeight = measurement.height
            deferredResize = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.epoch == transitionEpoch else { return }
                adapter.setFrameImmediately(source, display: false)
                self.revealLatestDisclosure(animated: true)
                self.startWindowAnimation(
                    from: source,
                    to: target,
                    measurement: measurement,
                    epoch: transitionEpoch)
            }
        }
    }

    private func startWindowAnimation(
        from _: CGRect,
        to target: CGRect,
        measurement: CorrelatedBodyMeasurement,
        epoch transitionEpoch: UInt64
    ) {
        guard let adapter = windowAdapter else {
            settleWithoutWindow(using: measurement)
            return
        }
        let started = adapter.animateFrame(
            to: target,
            duration: Self.duration
        ) { [weak self] outcome in
            guard let self, self.epoch == transitionEpoch else { return }
            switch outcome {
            case .reachedTarget:
                self.completeTransition(
                    measurement: measurement,
                    targetHeight: target.height)
            case .stopped:
                self.settleImmediately(using: measurement)
            }
        }
        if !started { settleImmediately(using: measurement) }
    }

    private func completeTransition(
        measurement: CorrelatedBodyMeasurement,
        targetHeight: CGFloat
    ) {
        guard let adapter = windowAdapter, let frame = adapter.frame,
            let anchoredFrame = resolvedAnchorFrame(current: frame, adapter: adapter)
        else {
            settleWithoutWindow(using: measurement)
            scheduleAnchorReconciliation()
            return
        }
        let committedFrame = CGRect(
            x: anchoredFrame.minX,
            y: anchoredFrame.maxY - targetHeight,
            width: anchoredFrame.width,
            height: targetHeight)
        if committedFrame != frame {
            adapter.setFrameImmediately(committedFrame, display: true)
        }
        presentation.bodyHeight = measurement.height
        presentation.renderedBodyHeight = measurement.height
        revealLatestDisclosure(animated: false)
        clippedInsertions.removeAll()
        baseline = Baseline(frame: committedFrame, bodyHeight: measurement.height)
        rememberAnchor(committedFrame, adapter: adapter)
        fixedNonBodyHeight = targetHeight - measurement.height
        settledDisclosure = latestDesired
        transitionPhase = .idle
        deferredResize = nil
        pendingStartFrame = nil
        finishReconciliation()
    }

    private func settleImmediately(using measurement: CorrelatedBodyMeasurement) {
        invalidateCurrentTransition(capturePresentation: true)
        if canPresentInWindow, baseline == nil {
            establishBaseline(using: measurement)
            return
        }
        presentation.bodyHeight = measurement.height
        presentation.renderedBodyHeight = measurement.height
        revealLatestDisclosure(animated: false)
        clippedInsertions.removeAll()
        acceptedTargetHeight = measurement.height
        pendingReplacement = false

        guard canPresentInWindow, let adapter = windowAdapter else {
            baseline = nil
            settledDisclosure = latestDesired
            finishReconciliation()
            isSettled = false
            isQuiescent = true
            return
        }

        guard let existingBaseline = baseline,
            let capturedFrame = pendingStartFrame ?? adapter.frame,
            let anchoredFrame = resolvedAnchorFrame(current: capturedFrame, adapter: adapter)
        else {
            settleWithoutWindow(using: measurement)
            scheduleAnchorReconciliation()
            return
        }
        let targetHeight = existingBaseline.nonBodyHeight + measurement.height
        let target = CGRect(
            x: anchoredFrame.minX,
            y: anchoredFrame.maxY - targetHeight,
            width: anchoredFrame.width,
            height: targetHeight)
        adapter.setFrameImmediately(target, display: true)
        pendingStartFrame = nil
        baseline = Baseline(frame: target, bodyHeight: measurement.height)
        rememberAnchor(target, adapter: adapter)
        fixedNonBodyHeight = target.height - measurement.height
        settledDisclosure = latestDesired
        finishReconciliation()
    }

    private func settleWithoutWindow(using measurement: CorrelatedBodyMeasurement) {
        invalidateCurrentTransition(capturePresentation: false)
        latestValidMeasurement = measurement
        acceptedTargetHeight = measurement.height
        presentation.bodyHeight = measurement.height
        presentation.renderedBodyHeight = measurement.height
        revealLatestDisclosure(animated: false)
        clippedInsertions.removeAll()
        pendingReplacement = false
        pendingStartFrame = nil
        settledDisclosure = latestDesired
        baseline = nil
        isSettled = false
        isQuiescent = true
    }

    private func revealLatestDisclosure(animated: Bool) {
        presentation.disablesDisclosureAnimations = !animated
        let animation: Animation? = animated ? .easeInOut(duration: Self.duration) : nil
        withAnimation(animation) {
            presentation.revealedCards = latestDesired
        }
    }

    private func invalidateCurrentTransition(capturePresentation: Bool) {
        epoch &+= 1
        deferredResize?.cancel()
        deferredResize = nil
        deferredAnchorReconciliation?.cancel()
        deferredAnchorReconciliation = nil
        if capturePresentation {
            pendingStartFrame = windowAdapter?.interruptAndCapturePresentation()
        } else {
            _ = windowAdapter?.interruptAndCapturePresentation()
            pendingStartFrame = nil
        }
        transitionPhase = .idle
    }

    private func becomeQuiescent(clearMeasurement: Bool) {
        invalidateCurrentTransition(capturePresentation: false)
        clippedInsertions.removeAll()
        revealLatestDisclosure(animated: false)
        baseline = nil
        if let latestValidMeasurement,
            measurementIsCurrent(latestValidMeasurement),
            !clearMeasurement
        {
            acceptedTargetHeight = latestValidMeasurement.height
            presentation.bodyHeight = latestValidMeasurement.height
            presentation.renderedBodyHeight = latestValidMeasurement.height
            settledDisclosure = latestDesired
            pendingReplacement = false
        } else {
            acceptedTargetHeight = nil
            pendingReplacement = latestDesired != settledDisclosure
        }
        isSettled = false
        isQuiescent = true
        if clearMeasurement {
            latestRawMeasurement = nil
            latestValidMeasurement = nil
        }
    }

    private func reconcileAvailablePresentation() {
        guard canPresentInWindow, let measurement = currentNormalizedMeasurement() else { return }
        latestValidMeasurement = measurement
        baseline = nil
        establishBaseline(using: measurement)
    }

    private func currentNormalizedMeasurement() -> CorrelatedBodyMeasurement? {
        guard let latestRawMeasurement, measurementIsCurrent(latestRawMeasurement) else {
            return nil
        }
        return CorrelatedBodyMeasurement(
            disclosure: latestRawMeasurement.disclosure,
            renderSequence: latestRawMeasurement.renderSequence,
            height: normalizedHeight(latestRawMeasurement.height))
    }

    private func resolvedAnchorFrame(
        current: CGRect,
        adapter: any PopoverWindowAdapter
    ) -> CGRect? {
        guard let screen = adapter.visibleScreenFrame else {
            return nil
        }
        if abs(current.maxY - screen.maxY) <= Self.anchorTolerance {
            return current
        }
        if let lastAnchoredFrame, let lastAnchoredScreenFrame,
            sameScreen(screen, lastAnchoredScreenFrame),
            abs(lastAnchoredFrame.maxY - screen.maxY) <= Self.anchorTolerance
        {
            return lastAnchoredFrame
        }
        return nil
    }

    private func rememberAnchor(_ frame: CGRect, adapter: any PopoverWindowAdapter) {
        lastAnchoredFrame = frame
        lastAnchoredScreenFrame = adapter.visibleScreenFrame
    }

    private func sameScreen(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= Self.tolerance
            && abs(lhs.minY - rhs.minY) <= Self.tolerance
            && abs(lhs.width - rhs.width) <= Self.tolerance
            && abs(lhs.height - rhs.height) <= Self.tolerance
    }

    private func scheduleAnchorReconciliation() {
        guard deferredAnchorReconciliation == nil else { return }
        let reconciliationEpoch = epoch
        deferredAnchorReconciliation = Task { @MainActor [weak self] in
            var attempt = 0
            while true {
                let delay: Duration = attempt < 12 ? .milliseconds(10) : .milliseconds(100)
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.epoch == reconciliationEpoch,
                    self.isPopoverVisible
                else { return }
                attempt += 1
                guard self.canPresentInWindow,
                    let adapter = self.windowAdapter,
                    let frame = adapter.frame,
                    self.resolvedAnchorFrame(current: frame, adapter: adapter) != nil,
                    self.currentNormalizedMeasurement() != nil
                else { continue }
                self.deferredAnchorReconciliation = nil
                self.reconcileAvailablePresentation()
                return
            }
        }
    }

    private func measurementIsCurrent(_ measurement: CorrelatedBodyMeasurement) -> Bool {
        measurement.disclosure == latestDesired
            && measurement.renderSequence == renderSequence
    }

    private func finishReconciliation() {
        isSettled = settlementPredicate
        isQuiescent = !isSettled
    }

    /// One authoritative settlement predicate. Mechanical callbacks only update
    /// facts and then reconcile through this predicate.
    private var settlementPredicate: Bool {
        guard let baseline, let adapterFrame = windowAdapter?.frame,
            settledDisclosure == latestDesired,
            let acceptedTargetHeight,
            abs(presentation.bodyHeight - acceptedTargetHeight) <= Self.tolerance,
            abs(presentation.renderedBodyHeight - acceptedTargetHeight) <= Self.tolerance,
            abs(adapterFrame.height - baseline.frame.height) <= Self.tolerance,
            abs(adapterFrame.minX - baseline.frame.minX) <= Self.tolerance,
            abs(adapterFrame.maxY - baseline.frame.maxY) <= Self.tolerance,
            clippedInsertions.isEmpty,
            presentation.disablesDisclosureAnimations,
            transitionPhase == .idle,
            deferredResize == nil
        else { return false }
        return true
    }
}

/// SwiftUI façade for the popover's variable-height region. It observes and
/// applies presentation state; the coordinator decides that state.
struct PopoverTransitionBody<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.popoverIsVisible) private var isPopoverVisible
    @StateObject private var coordinator: PopoverTransitionCoordinator
    @State private var renderSequence: UInt64 = 0

    private let desiredExpandedCards: Set<String>
    private let content: Content

    init(
        desiredExpandedCards: Set<String>,
        @ViewBuilder content: () -> Content
    ) {
        self.desiredExpandedCards = desiredExpandedCards
        self.content = content()
        _coordinator = StateObject(
            wrappedValue: PopoverTransitionCoordinator(
                initialDesiredDisclosure: desiredExpandedCards))
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .environment(
                    \.popoverRevealedCards,
                    coordinator.presentation.revealedCards
                )
                .environment(
                    \.popoverDisclosureAnimationsDisabled,
                    coordinator.presentation.disablesDisclosureAnimations
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CorrelatedBodyMeasurementKey.self,
                            value: [
                                CorrelatedBodyMeasurement(
                                    disclosure: desiredExpandedCards,
                                    renderSequence: renderSequence,
                                    height: proxy.size.height)
                            ])
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: coordinator.presentation.renderedBodyHeight)
        // Keep fitting size at the settled height while the larger ScrollView
        // draws into AppKit's progressively growing window.
        .frame(height: coordinator.presentation.bodyHeight, alignment: .top)
        .background(
            PopoverWindowCapture { window in
                coordinator.capturedWindowChanged(window)
            }
        )
        .onPreferenceChange(CorrelatedBodyMeasurementKey.self) { measurements in
            guard
                let measurement = measurements.last(where: {
                    $0.disclosure == desiredExpandedCards
                        && $0.renderSequence == renderSequence
                })
            else { return }
            coordinator.bodyMeasured(measurement)
        }
        .onChange(of: desiredExpandedCards) { _, desired in
            renderSequence = coordinator.desiredDisclosureChanged(desired)
        }
        .onChange(of: isPopoverVisible, initial: true) { _, visible in
            coordinator.visibilityChanged(visible)
        }
        .onChange(of: reduceMotion, initial: true) { _, enabled in
            coordinator.reduceMotionChanged(enabled)
        }
    }
}
