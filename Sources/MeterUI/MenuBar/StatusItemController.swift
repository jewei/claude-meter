import AppKit
import MeterApp
import MeterPlatform
import Observation
import SwiftUI

/// Owns the `NSStatusItem`. Its button hosts ``MenuBarLabel`` and speaks the model's summary.
///
/// The label renders again when the model's inputs change and on a 30-second clock, so a
/// reset or an old reading shows without a refresh. A render that would show the same thing
/// does not touch the button. The clock stops while the display sleeps.
@MainActor final class StatusItemController {
    /// The clock that keeps countdown-driven state (resets, staleness) current.
    static let clockInterval: TimeInterval = 30
    /// How late the clock may fire, so the system can group its wake-ups.
    static let clockTolerance: TimeInterval = 5
    /// Space between the label and the edges of the status button.
    static let horizontalPadding: CGFloat = 5

    /// Called on every click of the status button.
    var onClick: (() -> Void)?

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let hostingView: LabelHostingView
    private let displaySleep = DisplaySleepMonitor()
    private var clock: Timer?
    private var pulse = CriticalPulse()
    private var pulseEnd: Task<Void, Never>?
    /// What the button shows now.
    private var shown: Shown?
    /// Each render tracks the model again; only the newest tracking renders on a change.
    private var tracking = 0

    /// The label state that the button shows.
    private struct Shown: Equatable {
        let model: MenuBarModel
        let pulseStartedAt: Date?
    }

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeMeter"
        hostingView = LabelHostingView(
            rootView: MenuBarLabel(model: model.menuBarModel(at: Date())))
        // Flexible margins keep the label centered when the menu bar changes height, for
        // example on a move between a notched and a plain display.
        hostingView.autoresizingMask = [.minYMargin, .maxYMargin]
        if let button = statusItem.button {
            button.addSubview(hostingView)
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        render()
        startClock()
        displaySleep.onSleep = { [weak self] in self?.stopClock() }
        displaySleep.onWake = { [weak self] in
            self?.render()
            self?.startClock()
        }
    }

    /// The status button, for positioning the popover under it.
    var button: NSStatusBarButton? { statusItem.button }

    /// Shows the button as pressed while the popover is open.
    func setHighlighted(_ highlighted: Bool) {
        statusItem.button?.highlight(highlighted)
    }

    /// Builds the model for now, tracks what it reads, and puts it on the button when it
    /// changed.
    func render() {
        let now = Date()
        tracking += 1
        let current = tracking
        let menuBar = withObservationTracking {
            model.menuBarModel(at: now)
        } onChange: { [weak self] in
            // Called before the change lands; render on the next turn of the main loop.
            Task { @MainActor [weak self] in
                guard let self, self.tracking == current else { return }
                self.render()
            }
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if pulse.update(icon: menuBar.icon, now: now, reduceMotion: reduceMotion) {
            schedulePulseEnd()
        }
        let next = Shown(model: menuBar, pulseStartedAt: pulse.runningStart(at: now))
        guard next != shown else { return }
        if next.model.accessibilityLabel != shown?.model.accessibilityLabel {
            statusItem.button?.setAccessibilityLabel(menuBar.accessibilityLabel)
        }
        shown = next
        hostingView.rootView = MenuBarLabel(model: menuBar, pulseStartedAt: next.pulseStartedAt)
        layout()
    }

    private func layout() {
        guard let button = statusItem.button else { return }
        let size = hostingView.fittingSize
        let length = ceil(size.width) + 2 * Self.horizontalPadding
        if statusItem.length != length { statusItem.length = length }
        let height = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        hostingView.frame = NSRect(
            x: Self.horizontalPadding, y: ((height - size.height) / 2).rounded(),
            width: ceil(size.width), height: size.height)
    }

    private func startClock() {
        clock?.invalidate()
        let clock = Timer(timeInterval: Self.clockInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        clock.tolerance = Self.clockTolerance
        // Common modes: the label stays current while a menu is open.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    /// Renders once more when the pulse ends, so the dot stops redrawing.
    private func schedulePulseEnd() {
        pulseEnd?.cancel()
        pulseEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CriticalPulse.duration + 0.05))
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    @objc private func buttonClicked() {
        onClick?()
    }
}

/// A hosting view that lets clicks through to the status button and stays out of the
/// accessibility tree, so the button is the one element VoiceOver sees.
///
/// It keeps the intrinsic-size option: without it, `fittingSize` is zero and the status
/// item would collapse.
final class LabelHostingView: NSHostingView<MenuBarLabel> {
    required init(rootView: MenuBarLabel) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not used from a nib")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}
