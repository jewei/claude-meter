import Foundation

/// One coherent fetch lifecycle for a provider value. Failed refreshes
/// retain the last successful value as stale data whenever one exists.
public enum ReadingState<Value: Sendable>: Sendable {
    case current(value: Value, polledAt: Date)
    case stale(value: Value, polledAt: Date, error: String)
    /// Optional value holds unavailable account labels/errors, not usable observations.
    case failed(error: String, lastPolledAt: Date?, value: Value? = nil)

    public var value: Value? {
        switch self {
        case .current(let value, _), .stale(let value, _, _): value
        case .failed(_, _, let value): value
        }
    }

    public var error: String? {
        switch self {
        case .current: nil
        case .stale(_, _, let error), .failed(let error, _, _): error
        }
    }

    public var lastPolledAt: Date? {
        switch self {
        case .current(_, let date), .stale(_, let date, _): date
        case .failed(_, let date, _): date
        }
    }

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

/// Refresh eligibility is separate from the UI's age-based stale indicator.
extension ReadingState where Value == ProviderSnapshot {
    public func needsRefresh(now: Date, maxAge: TimeInterval) -> Bool {
        switch self {
        case .stale, .failed:
            return true
        case .current(_, let polledAt):
            let age = now.timeIntervalSince(polledAt)
            // A clock rollback must not suppress refresh until the clock catches up.
            return !age.isFinite || age < 0 || age >= maxAge
        }
    }
}
