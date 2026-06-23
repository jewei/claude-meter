import Foundation

/// Shared contract for all data pipelines (statusline, OAuth API, claude.ai API, etc.)
public protocol ClaudeMeterPipeline: Sendable {
    func poll(now: Date) async throws -> ParseResult
}

extension StatsCachePipeline: ClaudeMeterPipeline {}

/// Terminal fallback: serves the last persisted snapshot marked stale.
public struct CachedSnapshotPipeline: Sendable {
    public let store: SnapshotStore

    public init(store: SnapshotStore) {
        self.store = store
    }

    public func poll(now: Date) async throws -> ParseResult {
        guard var snapshot = try? store.readLatest() else {
            throw CachedSnapshotError.noSnapshot
        }
        snapshot.state.isStale = true
        return ParseResult(
            snapshot: snapshot,
            warnings: [ParseWarning(field: "cache", message: "Serving cached snapshot")],
            errors: [],
            rawHash: "",
            parserVersion: snapshot.parserVersion
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
