import AppKit

/// Tracks display/system sleep and wake for RefreshScheduler.
/// AppKit notifications and scheduler callbacks run on MainActor.
@MainActor
final class PowerMonitor {
    /// Whether the display (or whole system) is currently asleep. While `true`
    /// the poll loop parks. `screensDidSleep` is the important one: it fires when
    /// the display idles off while the Mac keeps running — exactly when an
    /// unattended poll loop would keep doing pointless work.
    private(set) var isDisplayAsleep = false

    /// Invoked on the main actor when the display/system wakes from sleep, so the
    /// scheduler can check freshness and resume its timer.
    var onWake: (() -> Void)?

    /// Invoked on the main actor when the display goes to sleep. The poll loop
    /// parks, so anything the app keeps resident for polling can be released.
    var onDisplaySleep: (() -> Void)?

    /// Observer tokens live in a plain (non-isolated) holder so they can be
    /// removed from its nonisolated `deinit` — a `@MainActor` class can't touch
    /// non-`Sendable` isolated state from its own nonisolated deinit (Swift 6).
    private let observers = ObserverBag()

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification] {
            observers.tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.isDisplayAsleep else { return }
                        self.isDisplayAsleep = true
                        self.onDisplaySleep?()
                    }
                })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleWake() }
                })
        }
    }

    private func handleWake() {
        // Only fire onWake on an actual asleep→awake transition; the redundant
        // wake notifications (system + screens) otherwise double-trigger.
        guard isDisplayAsleep else { return }
        isDisplayAsleep = false
        onWake?()
    }
}

/// Holds `NSWorkspace` observer tokens and removes them on dealloc. Kept as a
/// plain class (not `@MainActor`) so its `deinit` can run the cleanup; tokens
/// are only mutated during `PowerMonitor.init` on the main actor.
private final class ObserverBag {
    var tokens: [NSObjectProtocol] = []

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
    }
}
