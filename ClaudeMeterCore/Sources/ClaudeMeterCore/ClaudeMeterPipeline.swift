import Foundation

/// Shared contract for all data pipelines (stats-cache+journal, claude.ai API, etc.)
public protocol ClaudeMeterPipeline: Sendable {
    func poll(now: Date) async throws -> ParseResult
}

extension StatsCachePipeline: ClaudeMeterPipeline {}
