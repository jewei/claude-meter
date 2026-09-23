import Foundation

/// Why a poll is happening.
///
/// Only throttles that exist to spare an *external API* on idle cycles may treat
/// these differently — never correctness rules. A `.interactive` poll must not be
/// able to skip a 429 backoff, for instance: that one protects the server, not our
/// bandwidth.
public enum RefreshKind: Sendable, Equatable {
    /// The scheduled poll loop, or any refresh nobody is waiting on.
    case background
    /// The user is looking right now — they opened the popover, or asked for a
    /// refresh explicitly. Worth spending a request on.
    case interactive
}

/// Internal fetch contract retained by OAuth credential handling.
public protocol ClaudeMeterPipeline: Sendable {
    func poll(now: Date, kind: RefreshKind) async throws -> ParseResult
}

extension ClaudeMeterPipeline {
    /// Convenience for callers with no particular urgency — notably the poll loop.
    public func poll(now: Date) async throws -> ParseResult {
        try await poll(now: now, kind: .background)
    }
}
