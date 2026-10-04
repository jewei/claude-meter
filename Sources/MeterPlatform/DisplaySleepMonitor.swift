import AppKit

/// Reports when the display sleeps and wakes, so refresh work stops while nobody can see it.
///
/// `screensDidSleep` is the signal, not `willSleep`: the display often sleeps while the Mac
/// keeps running, and a system sleep can still be cancelled.
@MainActor
public final class DisplaySleepMonitor {
    public private(set) var isDisplayAsleep = false
    public var onSleep: (() -> Void)?
    public var onWake: (() -> Void)?

    private let observers = ObserverTokens()

    public init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.tokens.append(
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didSleep() }
            })
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observers.tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.didWake() }
                })
        }
    }

    private func didSleep() {
        guard !isDisplayAsleep else { return }
        isDisplayAsleep = true
        onSleep?()
    }

    private func didWake() {
        // Screens and system both report wake; act once per sleep.
        guard isDisplayAsleep else { return }
        isDisplayAsleep = false
        onWake?()
    }
}

/// Removes notification observers when the monitor goes away. A separate nonisolated
/// object, because a main-actor class cannot touch its state from `deinit`.
private final class ObserverTokens {
    var tokens: [any NSObjectProtocol] = []

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
    }
}
