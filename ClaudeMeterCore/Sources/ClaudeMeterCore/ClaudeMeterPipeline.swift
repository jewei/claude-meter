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

/// Shared contract for the statusline, OAuth, and cached-snapshot pipelines.
public protocol ClaudeMeterPipeline: Sendable {
    func poll(now: Date, kind: RefreshKind) async throws -> ParseResult
}

extension ClaudeMeterPipeline {
    /// Convenience for callers with no particular urgency — notably the poll loop.
    public func poll(now: Date) async throws -> ParseResult {
        try await poll(now: now, kind: .background)
    }
}

/// Terminal fallback: serves the last persisted snapshot marked stale.
public struct CachedSnapshotPipeline: Sendable {
    public let store: SnapshotStore

    public init(store: SnapshotStore) {
        self.store = store
    }

    /// Reads from disk, so there is nothing for `kind` to change here.
    public func poll(now: Date, kind _: RefreshKind = .background) async throws -> ParseResult {
        let loaded: ClaudeUsageSnapshot?
        do {
            loaded = try store.readLatest()
        } catch {
            let message = DiagnosticsSanitizer.sanitize(error.localizedDescription)
            return ParseResult(
                snapshot: nil,
                warnings: [],
                errors: [ParseError("Cached snapshot could not be read: \(message)")],
                rawHash: "",
                parserVersion: "cache-1.0",
                sourceAttempts: [
                    SourceAttempt(source: .cache, outcome: .failed, reason: .cacheUnreadable)
                ]
            )
        }
        guard var snapshot = loaded else {
            return ParseResult(
                snapshot: nil,
                warnings: [],
                errors: [ParseError(CachedSnapshotError.noSnapshot.localizedDescription)],
                rawHash: "",
                parserVersion: "cache-1.0",
                sourceAttempts: [
                    SourceAttempt(source: .cache, outcome: .failed, reason: .cacheMissing)
                ]
            )
        }
        snapshot.state.isStale = true
        return ParseResult(
            snapshot: snapshot,
            warnings: [ParseWarning(field: "cache", message: "Serving cached snapshot")],
            errors: [],
            rawHash: "",
            parserVersion: snapshot.parserVersion,
            sourceAttempts: [
                SourceAttempt(source: .cache, outcome: .selected, reason: .cachedSnapshot)
            ]
        )
    }
}

extension CachedSnapshotPipeline: ClaudeMeterPipeline {}

public enum CachedSnapshotError: Error, LocalizedError {
    case noSnapshot

    public var errorDescription: String? {
        switch self {
        case .noSnapshot: "No cached snapshot available"
        }
    }
}
