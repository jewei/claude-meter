import ClaudeMeterProviders
import Foundation

/// One coherent fetch lifecycle for every optional provider. Failed refreshes
/// retain the last successful value as stale data whenever one exists.
enum ReadingState<Value: Sendable>: Sendable {
    case current(value: Value, polledAt: Date)
    case stale(value: Value, polledAt: Date, error: String)
    case failed(error: String, lastPolledAt: Date?)

    var value: Value? {
        switch self {
        case .current(let value, _), .stale(let value, _, _): value
        case .failed: nil
        }
    }

    var error: String? {
        switch self {
        case .current: nil
        case .stale(_, _, let error), .failed(let error, _): error
        }
    }

    var lastPolledAt: Date? {
        switch self {
        case .current(_, let date), .stale(_, let date, _): date
        case .failed(_, let date): date
        }
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

struct CodexAccountReading: Identifiable, Sendable {
    let account: CodexAccount
    let state: ReadingState<CodexUsage>

    var id: String { account.id }
    var usage: CodexUsage? { state.value }
    var error: String? { state.error }
    var lastPolledAt: Date? { state.lastPolledAt }
    var isStale: Bool { state.isStale }
}
