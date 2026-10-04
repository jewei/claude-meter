import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterPlatform

extension HistoryScans {
    /// Cancellation and overlapping scans.
    @Suite struct Cancellation {
        private let jsonl = HistoryFileMatch.fileExtension("jsonl")

        @Test func cancellationKeepsDiscoveryProgress() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<5 { try home.write(line("\(index)", 10), to: "\(index).jsonl") }
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(directoryEntries: 1))
            _ = try await scanner.scan([home.root()], since: rangeStart)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await scanner.scan([home.root()], since: rangeStart)
            }
            await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
            let result = try await scanner.scanUntilComplete([home.root()])
            #expect(!result.isPartial())
            #expect(result.total() == 50)
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

/// The pure discovery walk, driven by fake listings.
@Suite struct HistoryDiscoveryCursorTests {
    private typealias Entry = DirectoryListing.Entry

    private let tree: [String: [Entry]] = [
        "/a": [
            Entry(name: "1.jsonl", kind: .regularFile), Entry(name: "2.jsonl", kind: .regularFile),
            Entry(name: "sub", kind: .directory),
        ],
        "/a/sub": [Entry(name: "3.jsonl", kind: .regularFile)],
        "/b": [Entry(name: "x.jsonl", kind: .regularFile)],
    ]

    private func listing(_ path: String) throws(DirectoryListing.ListingError) -> [Entry] {
        if path == "/blocked" { throw .unreadable(errno: EACCES) }
        guard let entries = tree[path] else { throw .missing }
        return entries
    }

    private func walk(_ cursor: inout DiscoveryCursor, steps: Int = 100) -> [String] {
        var paths: [String] = []
        for _ in 0..<steps {
            guard let entry = cursor.next(listing: listing) else { break }
            paths.append(entry.path)
        }
        return paths
    }

    @Test func takesOneEntryFromEachRootInTurn() {
        var cursor = DiscoveryCursor(roots: ["/a", "/b"])
        #expect(
            walk(&cursor) == ["/a/1.jsonl", "/b/x.jsonl", "/a/2.jsonl", "/a/sub", "/a/sub/3.jsonl"])
        #expect(cursor.isComplete)
        #expect(cursor.failedRoots.isEmpty)
    }

    @Test func resumesWhereItStopped() {
        var cursor = DiscoveryCursor(roots: ["/a"])
        #expect(walk(&cursor, steps: 2) == ["/a/1.jsonl", "/a/2.jsonl"])
        #expect(!cursor.isComplete)
        #expect(walk(&cursor) == ["/a/sub", "/a/sub/3.jsonl"])
        #expect(cursor.isComplete)
    }

    @Test func anUnreadableDirectoryMarksItsRootAndTheWalkGoesOn() {
        var cursor = DiscoveryCursor(roots: ["/blocked", "/a", "/missing"])
        #expect(walk(&cursor).count == 4)
        #expect(cursor.isComplete)
        #expect(cursor.failedRoots == [0])
    }
}
