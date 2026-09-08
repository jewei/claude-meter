import Foundation
import Testing

@testable import ClaudeMeterProviders

/// Opt-in synthetic measurement. No user transcripts, credentials, or network.
@Suite(.serialized)
struct CostScanProfileTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["CLAUDE_METER_PROFILE_COST_SCAN"] == "1"),
        arguments: [50, 500])
    func warmScan(fileCount: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let requestsPerFile = 100
        for fileIndex in 0..<fileCount {
            let lines = (0..<requestsPerFile).map { request in
                "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"requestId\":\"r-\(fileIndex)-\(request)\",\"message\":{\"id\":\"m-\(fileIndex)-\(request)\",\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":100}}}\n"
            }.joined()
            try Data(lines.utf8).write(to: project.appendingPathComponent("\(fileIndex).jsonl"))
        }
        let cache = CostUsageCache()
        let scanner = CostUsageScanner(projectsPath: root, cache: cache)
        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000
                + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        }
        let cold = clock.measure { _ = scanner.scan(now: now) }
        var warm: [Double] = []
        for _ in 0..<7 {
            let elapsed = clock.measure {
                let result = scanner.scan(now: now)
                #expect(result.models.first?.inputTokens == fileCount * requestsPerFile * 100)
                #expect(!result.isPartialEstimate)
            }
            warm.append(milliseconds(elapsed))
        }
        warm.sort()
        print(
            "COST_SCAN_PROFILE files=\(fileCount) requests=\(fileCount * requestsPerFile) cold_ms=\(milliseconds(cold)) warm_median_ms=\(warm[3]) warm_max_ms=\(warm[6]) retained_bytes=\(cache.retainedByteCount)"
        )
    }
}
