import Foundation
import Network

/// Connectivity-awareness source for the background poll loop. Watches for the
/// network coming back (unsatisfied → satisfied) so the loop can refresh the
/// menu-bar number immediately instead of waiting out the remaining interval —
/// the connectivity analogue of `PowerMonitor.onWake`. After a Wi-Fi drop, a
/// network switch, or a VPN flap the data would otherwise stay stale for up to a
/// full poll interval.
///
/// `@MainActor` because it feeds `AppState`'s loop; `NWPathMonitor` reports on its
/// own background queue, so the handler hops to the main actor before firing.
/// `Network` lives here in the app target, never in `ClaudeMeterCore`.
@MainActor
final class NetworkMonitor {
    /// Invoked on the main actor when connectivity is regained after having been
    /// lost, so the loop can refresh promptly.
    var onReconnect: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.jewei.claudemeter.network-monitor")

    /// Tracks the last known reachability so we only fire on an actual
    /// lost → regained transition, not on the initial `.satisfied` callback or
    /// repeated satisfied updates (interface changes while already online).
    private var wasSatisfied = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handlePath(satisfied: satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func handlePath(satisfied: Bool) {
        defer { wasSatisfied = satisfied }
        guard satisfied, !wasSatisfied else { return }
        onReconnect?()
    }
}
