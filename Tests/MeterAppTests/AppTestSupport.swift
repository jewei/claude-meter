import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport

@testable import MeterApp

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

/// A display that tests put to sleep and wake by hand.
@MainActor
final class FakeDisplay: DisplayStateMonitoring {
    var isDisplayAsleep = false
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    func sleep() {
        isDisplayAsleep = true
        onSleep?()
    }

    func wake() {
        isDisplayAsleep = false
        onWake?()
    }
}
