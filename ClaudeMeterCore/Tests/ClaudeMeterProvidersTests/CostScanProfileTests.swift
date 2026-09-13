import Foundation
import Testing

@testable import ClaudeMeterProviders

/// Opt-in synthetic measurement. No user transcripts, credentials, or network.
@Suite(.serialized)
struct CostScanProfileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_METER_PROFILE_APPEND"] == "1"))
    func activeTranscriptAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("session.jsonl")
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let padding = String(repeating: "x", count: 500)
        func line(_ index: Int) -> String {
            "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"requestId\":\"r\(index)\",\"message\":{\"id\":\"m\(index)\",\"model\":\"claude-sonnet-4-6\",\"content\":\"\(padding)\",\"usage\":{\"input_tokens\":100}}}\n"
        }
        let initialRecords = 15_000
        let data = Data((0..<initialRecords).map(line).joined().utf8)
        try data.write(to: file)
        let work = CostUsageScanner.WorkRecorder()
        let scanner = CostUsageScanner(
            projectsPaths: [root], pricing: .current, cache: CostUsageCache(),
            calendar: .current, workRecorder: work)
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let cold = clock.measure { _ = scanner.scan(now: now) }
        let warm = clock.measure { _ = scanner.scan(now: now) }
        var appended: [Double] = []
        var appendedBytes: [Int] = []
        var verifiedBytes: [UInt64] = []
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for batch in 0..<3 {
            let start = initialRecords + batch * 100
            try handle.write(contentsOf: Data((start..<(start + 100)).map(line).joined().utf8))
            let before = work.snapshot()
            let elapsed = clock.measure {
                let result = scanner.scan(now: now)
                #expect(result.models.first?.inputTokens == (start + 100) * 100)
                #expect(!result.isPartialEstimate)
            }
            appended.append(seconds(elapsed))
            appendedBytes.append(work.snapshot().parsedBytes - before.parsedBytes)
            verifiedBytes.append(work.snapshot().prefixBytesRead - before.prefixBytesRead)
        }
        let report: [String: Any] = [
            "initialBytes": data.count, "initialRecords": initialRecords,
            "coldSeconds": seconds(cold), "warmSeconds": seconds(warm),
            "appendSeconds": appended, "appendParsedBytes": appendedBytes,
            "appendVerifiedBytes": verifiedBytes,
        ]
        if let path = ProcessInfo.processInfo.environment["CLAUDE_METER_APPEND_PROFILE_OUTPUT"] {
            try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: URL(fileURLWithPath: path))
        }
    }

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
