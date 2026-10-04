import Foundation
import MeterDomain
import MeterPlatform

/// Blocks every Claude usage request after HTTP 429 until the server's deadline.
///
/// One gate serves refreshes, every account, and Settings verification. A block is never
/// shortened by a later, shorter 429. The deadline survives relaunch in the key-value store;
/// loading it never extends it, and a record that implies more than 24 hours is rejected.
final class RateLimitGate: Sendable {
    static let storageKey = "claude.rateLimitedUntil"
    /// The block when `Retry-After` is missing, invalid, zero, or in the past.
    static let defaultBlock: TimeInterval = 60
    /// A safety cap, so a wrong server value cannot stop usage checks for the life of the app.
    static let maximumBlock: TimeInterval = 24 * 60 * 60

    private struct Record: Codable, Equatable {
        let recordedAt: Date
        let until: Date

        func isValid(at now: Date) -> Bool {
            let length = until.timeIntervalSince(recordedAt)
            let remaining = until.timeIntervalSince(now)
            return DateBounds.contains(recordedAt) && DateBounds.contains(until)
                && DateBounds.contains(now) && length > 0 && length <= RateLimitGate.maximumBlock
                && remaining <= RateLimitGate.maximumBlock
        }
    }

    private let store: any KeyValueStore
    private let record: Locked<Record?>
    private let log = Log(.claude)

    /// Loads a stored deadline. An invalid or expired record is removed.
    init(store: any KeyValueStore, now: Date) {
        self.store = store
        let stored = store.value(Record.self, forKey: Self.storageKey)
        if let stored, stored.isValid(at: now), stored.until > now {
            record = Locked(stored)
        } else {
            record = Locked(nil)
            if store.data(forKey: Self.storageKey) != nil {
                store.set(nil, forKey: Self.storageKey)
            }
        }
    }

    /// The deadline of the active block, or nil when requests may go out. Clears a block that
    /// has ended or became invalid after a clock change.
    func blockedUntil(now: Date) -> Date? {
        let store = store
        return record.withLock { record -> Date? in
            guard let current = record else { return nil }
            if current.isValid(at: now), now < current.until { return current.until }
            record = nil
            store.set(nil, forKey: Self.storageKey)
            return nil
        }
    }

    /// Starts or extends a block after HTTP 429. Returns the deadline now in force.
    @discardableResult
    func recordRateLimit(retryAfter header: String?, now: Date) -> Date? {
        let requested = RetryAfter.delay(header, now: now) ?? Self.defaultBlock
        let candidate = Record(
            recordedAt: now, until: now.addingTimeInterval(min(requested, Self.maximumBlock)))
        guard candidate.isValid(at: now) else { return blockedUntil(now: now) }
        let store = store
        let engaged = record.withLock { record -> Bool in
            if let current = record, current.isValid(at: now), current.until >= candidate.until {
                return false
            }
            record = candidate
            store.setValue(candidate, forKey: Self.storageKey)
            return true
        }
        if engaged {
            log.warning(
                "Claude rate-limit gate engaged for \(Int(candidate.until.timeIntervalSince(now))) s"
            )
        }
        return blockedUntil(now: now)
    }
}
