import Foundation

/// Waits until `condition` is true, polling every millisecond. Returns false after `limit`.
///
/// Use it for state that background threads or the main actor change, instead of a fixed
/// sleep that a loaded machine can miss. It runs on the caller's actor, so `condition` can
/// read main-actor state.
@discardableResult
public func waitUntil(
    limit: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}
