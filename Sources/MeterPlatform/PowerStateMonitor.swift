import Foundation

/// Reports when the Mac is under strain: Low Power Mode is on, or the thermal state is serious
/// or critical. Refreshing then slows down.
///
/// The notifications come on `NotificationCenter.default`, not on the workspace center, and
/// on any thread. Each one reads both values again on the main actor.
@MainActor
public final class PowerStateMonitor {
    /// Whether the Mac is under strain.
    public struct PowerState: Sendable {
        public var isLowPowerModeEnabled: Bool
        public var thermalState: ProcessInfo.ThermalState

        public init(isLowPowerModeEnabled: Bool, thermalState: ProcessInfo.ThermalState) {
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.thermalState = thermalState
        }

        public var isConstrained: Bool {
            isLowPowerModeEnabled || thermalState == .serious || thermalState == .critical
        }

        /// The live values.
        public static func current() -> PowerState {
            PowerState(
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState)
        }
    }

    public private(set) var isConstrained: Bool
    /// Called on the main actor when ``isConstrained`` changes.
    public var onChange: (() -> Void)?

    private let read: @Sendable () -> PowerState
    private let observers: PowerObserverTokens

    /// Observes `center`, the default center by default. Tests pass their own center and
    /// reader.
    public init(
        center: NotificationCenter = .default,
        read: @escaping @Sendable () -> PowerState = PowerState.current
    ) {
        self.read = read
        isConstrained = false
        observers = PowerObserverTokens(center: center)
        let names: [Notification.Name] = [
            .NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
        ]
        for name in names {
            observers.tokens.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    Task { @MainActor in self?.update() }
                })
        }
        // Read after the observers are in place, so a change in between is not missed.
        isConstrained = read().isConstrained
    }

    private func update() {
        let constrained = read().isConstrained
        guard constrained != isConstrained else { return }
        isConstrained = constrained
        onChange?()
    }
}

/// Removes notification observers when the monitor goes away. A separate nonisolated
/// object, because a main-actor class cannot touch its state from `deinit`.
private final class PowerObserverTokens {
    let center: NotificationCenter
    var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}
