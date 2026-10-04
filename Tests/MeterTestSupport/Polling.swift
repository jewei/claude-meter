import Foundation

/// Waits until `condition` is true, polling every millisecond. Returns false after `limit`.
///
/// Use it for state that background threads change, instead of a fixed sleep that a loaded
/// machine can miss.
@discardableResult
public func waitUntil(
    limit: Duration = .seconds(5), _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}
