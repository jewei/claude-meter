import AppKit
import MeterApp
import Observation
import SwiftUI

/// Owns the `NSStatusItem`. Its button hosts ``MenuBarLabel`` and speaks the model's summary.
///
/// The label renders again when the model's inputs change and on a 30-second clock, so a
/// reset or an old reading shows without a refresh.
@MainActor final class StatusItemController {
    /// The clock that keeps countdown-driven state (resets, staleness) current.
    static let clockInterval: TimeInterval = 30
    /// Space between the label and the edges of the status button.
    static let horizontalPadding: CGFloat = 5

    /// Called on every click of the status button.
    var onClick: (() -> Void)?

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let hostingView: LabelHostingView
    private var clock: Timer?
    private var pulse = CriticalPulse()
    private var pulseEnd: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeMeter"
        hostingView = LabelHostingView(
            rootView: MenuBarLabel(model: model.menuBarModel(at: Date())))
        if let button = statusItem.button {
            button.addSubview(hostingView)
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        render()
        observeModel()
        clock = Timer.scheduledTimer(withTimeInterval: Self.clockInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    /// The status button, for positioning the popover under it.
    var button: NSStatusBarButton? { statusItem.button }

    /// Shows the button as pressed while the popover is open.
    func setHighlighted(_ highlighted: Bool) {
        statusItem.button?.highlight(highlighted)
    }

    /// Builds the model for now and puts it on the button.
    func render() {
        let now = Date()
        let menuBar = model.menuBarModel(at: now)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if pulse.update(icon: menuBar.icon, now: now, reduceMotion: reduceMotion) {
            schedulePulseEnd()
        }
        hostingView.rootView = MenuBarLabel(
            model: menuBar, pulseStartedAt: pulse.runningStart(at: now))
        layout()
        statusItem.button?.setAccessibilityLabel(menuBar.accessibilityLabel)
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

    /// Renders once more when the pulse ends, so the dot stops redrawing.
    private func schedulePulseEnd() {
        pulseEnd?.cancel()
        pulseEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CriticalPulse.duration + 0.05))
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    /// Re-renders after any change to what the menu-bar model reads.
    private func observeModel() {
        withObservationTracking {
            _ = model.menuBarModel(at: Date())
        } onChange: { [weak self] in
            // Called before the change lands; render on the next turn of the main loop.
            Task { @MainActor [weak self] in
                self?.render()
                self?.observeModel()
            }
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
