import AppKit
import MeterApp
import MeterPlatform
import Observation
import SwiftUI

/// Owns the `NSStatusItem`. Its button shows ``MenuBarLabel`` as a template image with the
/// colored badge on top (``MenuBarImage``), and speaks the model's summary.
///
/// The label renders again when the model's inputs change and on a 30-second clock, so a
/// reset or an old reading shows without a refresh. A render that would show the same thing
/// does not touch the button. While the dot pulses or the loading arrow turns, a frame clock
/// draws the image again. The clocks stop while the display sleeps.
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
    private let badgeView = BadgeImageView()
    private let displaySleep = DisplaySleepMonitor()
    private var clock: Timer?
    /// Draws animation frames. Nil while the label is still.
    private var frameClock: Timer?
    private var screenChange: (any NSObjectProtocol)?
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
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            // The badge fills the button and centers its image, as the button centers the
            // ink, so the two line up at every menu-bar height.
            badgeView.frame = button.bounds
            badgeView.autoresizingMask = [.width, .height]
            button.addSubview(badgeView)
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        render()
        startClock()
        displaySleep.onSleep = { [weak self] in
            self?.stopClock()
            self?.stopFrames()
        }
        displaySleep.onWake = { [weak self] in
            self?.render()
            self?.updateFrames()
            self?.startClock()
        }
        // A display with another scale needs the image drawn for that scale.
        screenChange = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.draw() }
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
        draw()
        updateFrames()
    }

    /// Puts the shown label on the button: the ink as its image, the badge on top.
    private func draw() {
        guard let shown, let button = statusItem.button else { return }
        let label = MenuBarLabel(model: shown.model, pulseStartedAt: shown.pulseStartedAt)
        let scales = Set(NSScreen.screens.map(\.backingScaleFactor) + [2])
        guard
            let image = MenuBarImage.make(
                label, padding: Self.horizontalPadding, height: NSStatusBar.system.thickness,
                scales: scales)
        else { return }
        button.image = image.ink
        badgeView.image = image.badge
        if statusItem.length != image.ink.size.width { statusItem.length = image.ink.size.width }
    }

    /// Runs the frame clock while the label moves: the critical pulse, or the loading arrow
    /// unless Reduce Motion is on.
    private func updateFrames() {
        let interval: TimeInterval? =
            if shown?.pulseStartedAt != nil {
                Motion.pulseFrameInterval
            } else if shown?.model.icon == .loading,
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            {
                Motion.spinFrameInterval
            } else {
                nil
            }
        guard let interval else { return stopFrames() }
        guard frameClock?.timeInterval != interval else { return }
        stopFrames()
        let frameClock = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.draw() }
        }
        RunLoop.main.add(frameClock, forMode: .common)
        self.frameClock = frameClock
    }

    private func stopFrames() {
        frameClock?.invalidate()
        frameClock = nil
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

/// Shows the colored badge over the status button. It lets clicks through and stays out of
/// the accessibility tree, so the button is the one element that VoiceOver sees.
private final class BadgeImageView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not used from a nib")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
