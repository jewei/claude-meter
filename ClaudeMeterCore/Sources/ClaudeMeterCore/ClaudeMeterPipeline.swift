import Foundation

/// Shared contract for the statusline, OAuth, and cached-snapshot pipelines.
public protocol ClaudeMeterPipeline: Sendable {
    func poll(now: Date) async throws -> ParseResult
}

/// Terminal fallback: serves the last persisted snapshot marked stale.
public struct CachedSnapshotPipeline: Sendable {
    public let store: SnapshotStore

    public init(store: SnapshotStore) {
        self.store = store
    }

    public func poll(now: Date) async throws -> ParseResult {
        guard var snapshot = try? store.readLatest() else {
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
