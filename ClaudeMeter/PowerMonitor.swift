import AppKit
import IOKit.ps

/// Energy-awareness source for the background poll loop. Tracks display/system
/// sleep so the loop can pause while the user is away — no poll, no network, no
/// disk scan — and refresh immediately on wake, and reports battery power so the
/// loop can stretch its cadence to reduce drain while unplugged.
///
/// `@MainActor` because it feeds `AppState`'s loop and mutates `isDisplayAsleep`
/// from main-thread `NSWorkspace` notifications. AppKit/IOKit live here in the
/// app target, never in `ClaudeMeterCore` (which forbids AppKit).
@MainActor
final class PowerMonitor {
    /// Whether the display (or whole system) is currently asleep. While `true`
    /// the poll loop parks. `screensDidSleep` is the important one: it fires when
    /// the display idles off while the Mac keeps running — exactly when an
    /// unattended poll loop would keep doing pointless work.
    private(set) var isDisplayAsleep = false

    /// Invoked on the main actor when the display/system wakes from sleep, so the
    /// loop can refresh the menu-bar number promptly instead of waiting out the
    /// remaining interval.
    var onWake: (() -> Void)?

    /// Observer tokens live in a plain (non-isolated) holder so they can be
    /// removed from its nonisolated `deinit` — a `@MainActor` class can't touch
    /// non-`Sendable` isolated state from its own nonisolated deinit (Swift 6).
    private let observers = ObserverBag()

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification] {
            observers.tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.isDisplayAsleep = true }
                })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleWake() }
                })
        }
    }

    /// Whether the machine is currently running on battery power. Read on demand
    /// (the read is cheap and there is no AC/battery notification to observe).
    var isOnBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else {
            return false
        }
        return (sourceType as String) == kIOPSBatteryPowerValue
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
