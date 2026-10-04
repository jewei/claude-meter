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

        @Test func aCancelledScanLeavesConsistentState() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let blocked = BlockedLines.make()
            // Files are read newest first: `0.jsonl` first, `199.jsonl` last. The scan stops in
            // `100.jsonl`, after some files and before others.
            for index in 0..<200 {
                try home.write(
                    line("\(index)", 1) + (index == 100 ? line(blocked, 0) : ""),
                    to: "\(index).jsonl")
                try home.touch("\(index).jsonl", at: .reference(Double(-index)))
            }
            let pool = BlockingIO(label: "test")
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(), pool: pool)
            let task = Task { try await scanner.scan([home.root()], since: rangeStart) }
            #expect(await waitUntil { BlockedLines.hasArrived(blocked) })
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            BlockedLines.open(blocked)
            #expect(await waitUntil { pool.abandonedCount == 0 })

            // The files read before the cancellation are not read again.
            let result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!result.isPartial())
            #expect(result.total() == 200)
            #expect(result.work.cacheHits == 100)
        }

        @Test func overlappingScansRunOneAtATime() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<50 { try home.write(line("\(index)", 2), to: "\(index).jsonl") }
            let scanner = CountingScanner(match: jsonl)
            async let first = scanner.scan([home.root()], since: rangeStart)
            async let second = scanner.scan([home.root()], since: rangeStart)
            async let third = scanner.scan([home.root()], since: rangeStart)
            let results = try await [first, second, third]
            #expect(results.map { $0.total() } == [100, 100, 100])
            #expect(results.map { $0.isPartial() } == [false, false, false])
            // Only the first scan in turn reads the files. Scans that overlapped would read them
            // more than once.
            #expect(results.map(\.work.parsedLines).sorted() == [0, 0, 50])
        }
    }
}

/// The queue that runs scans one at a time.
@Suite struct HistoryScanQueueTests {
    /// Waits until `count` scans wait in `queue`. Returns false after 5 s.
    private func waitForWaiters(_ count: Int, in queue: ScanQueue) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while await queue.waitingCount != count {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    @Test func aWaitingScanLeavesTheQueueWhenCancelled() async throws {
        let queue = ScanQueue()
        try await queue.enter()
        let waiting = Task { try await queue.enter() }
        #expect(await waitForWaiters(1, in: queue))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await waitForWaiters(0, in: queue))
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
        #expect(await waitForWaiters(1, in: queue))
        order.withLock { $0.append(1) }
        await queue.leave()
        try await second.value
        #expect(order.value == [1, 2])
    }

    @Test func threeOverlappingScansNeverRunTogether() async throws {
        let queue = ScanQueue()
        let inside = Locked<(now: Int, most: Int, order: [Int])>((0, 0, []))
        let gates = [Gate(), Gate(), Gate()]
        @Sendable func scan(_ index: Int) async throws {
            try await queue.enter()
            inside.withLock {
                $0.now += 1
                $0.most = max($0.most, $0.now)
                $0.order.append(index)
            }
            await gates[index].wait()
            inside.withLock { $0.now -= 1 }
            await queue.leave()
        }

        let first = Task { try await scan(0) }
        #expect(await gates[0].waitForArrivals())
        let second = Task { try await scan(1) }
        #expect(await waitForWaiters(1, in: queue))
        let third = Task { try await scan(2) }
        #expect(await waitForWaiters(2, in: queue))

        // Each scan that leaves hands the turn to one waiting scan, never to two.
        gates[0].open()
        #expect(await gates[1].waitForArrivals())
        #expect(await queue.waitingCount == 1)
        #expect(inside.value.now == 1)
        gates[1].open()
        #expect(await gates[2].waitForArrivals())
        #expect(await queue.waitingCount == 0)
        gates[2].open()
        for task in [first, second, third] { try await task.value }
        #expect(inside.value.most == 1)
        #expect(inside.value.order == [0, 1, 2])
    }
}
