import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport

/// A clock that tests move by hand. Starts at `Date.reference()`.
final class TestClock: Sendable {
    private let date = Locked(Date.reference())
    private let zone = Locked(Calendar.fixed())

    var now: Date { date.value }
    var calendar: Calendar { zone.value }

    func advance(_ seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    func setTimeZone(_ identifier: String) {
        zone.withLock { $0 = Calendar.fixed(identifier) }
    }
}

/// Polls `condition` until it holds. Returns false after `limit`. Use it for positive checks
/// in place of fixed sleeps, so a busy machine cannot fail a test.
@MainActor
func waitUntil(
    limit: Duration = .seconds(5), _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

extension ProviderTokenHistory {
    /// An empty history observed at `now` in the time zone of `calendar`.
    static func sample(
        _ provider: ProviderID, now: Date, calendar: Calendar = .fixed()
    ) -> ProviderTokenHistory {
        ProviderTokenHistory(
            provider: provider, source: .thisMac, accounts: [:], coverageStart: now,
            observedAt: now, timeZoneID: calendar.timeZone.identifier)
    }
}
