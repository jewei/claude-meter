import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterPlatform

extension HistoryScans {
    /// Cancellation and overlapping scans.
    @Suite struct Cancellation {
        private let jsonl = HistoryFileMatch.fileExtension("jsonl")

        @Test func cancellationDuringAScanKeepsItsProgress() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let blocked = BlockedLines.make()
            // Discovery visits names in order, three per scan: `0`, `1`, and `2` first.
            try home.write(line(blocked, 1), to: "0.jsonl")
            try home.touch("0.jsonl", at: .reference(-.days(1)))
            for index in 1..<6 {
                try home.write(line("\(index)", 10), to: "\(index).jsonl")
                try home.touch("\(index).jsonl", at: .reference())
            }
            let pool = BlockingIO(label: "test")
            let scanner = CountingScanner(
                match: jsonl, limits: HistoryLimits(directoryEntries: 3), pool: pool)

            // The oldest file is read last, after `1` and `2`. Cancel while it blocks.
            let task = Task { try await scanner.scan([home.root()], since: rangeStart) }
            #expect(await waitUntil { BlockedLines.hasArrived(blocked) })
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            BlockedLines.open(blocked)
            #expect(await waitUntil { pool.abandonedCount == 0 })

            // Discovery continues after the first three entries, and the files read before
            // the cancellation are not read again.
            let next = try await scanner.scan([home.root()], since: rangeStart)
            #expect(next.work.directoryEntries == 3)
            #expect(next.work.cacheHits == 2)
            #expect(next.total() == 51)
        }

        @Test func aScanCancelledBetweenFilesLeavesConsistentState() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<200 { try home.write(line("\(index)", 1), to: "\(index).jsonl") }
            let scanner = CountingScanner(match: jsonl)
            let task = Task { try await scanner.scan([home.root()], since: rangeStart) }
            await Task.yield()
            task.cancel()
            // The scan either finished first or stopped at a cancellation check.
            if case .failure(let error) = await task.result {
                #expect(error is CancellationError)
            }
            let result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!result.isPartial())
            #expect(result.total() == 200)
        }

        @Test func overlappingScansRunOneAtATime() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<50 { try home.write(line("\(index)", 2), to: "\(index).jsonl") }
            let scanner = CountingScanner(match: jsonl)
            async let first = scanner.scan([home.root()], since: rangeStart)
            async let second = scanner.scan([home.root()], since: rangeStart)
            let results = try await [first, second]
            #expect(results.map { $0.total() } == [100, 100])
            #expect(results.map { $0.isPartial() } == [false, false])
            #expect(results.map(\.work.parsedLines).sorted() == [0, 50])
        }
    }
}

/// The queue that runs scans one at a time.
@Suite struct HistoryScanQueueTests {
    @Test func aWaitingScanLeavesTheQueueWhenCancelled() async throws {
        let queue = ScanQueue()
        try await queue.enter()
        let waiting = Task { try await queue.enter() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await queue.leave()
        try await queue.enter()
        await queue.leave()
    }

    @Test func theQueueHandsTheTurnToTheNextScanInOrder() async throws {
        let queue = ScanQueue()
        let order = Locked<[Int]>([])
        try await queue.enter()
        let second = Task {
            try await queue.enter()
            order.withLock { $0.append(2) }
            await queue.leave()
        }
        try await Task.sleep(for: .milliseconds(20))
        order.withLock { $0.append(1) }
        await queue.leave()
        try await second.value
        #expect(order.value == [1, 2])
    }
}
