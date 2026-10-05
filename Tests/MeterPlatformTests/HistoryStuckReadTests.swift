import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterPlatform

extension HistoryScans {
    /// Reads that block, as on a stuck volume. Each test uses its own pool.
    ///
    /// No step depends on time: a stuck read waits at a gate that opens only when the test
    /// says, its time limit ends only when the test says (``ManualTimeLimits``), and every
    /// other call has a limit far above what a loaded machine needs.
    @Suite struct StuckReads {
        private let jsonl = HistoryFileMatch.fileExtension("jsonl")
        /// For the pools with real time limits.
        private let patient = HistoryLimits(blockingTimeout: .seconds(120))

        @Test func aFileWhoseReadIsStuckIsSkippedUntilTheReadEnds() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let blocked = BlockedLines.make()
            try home.write(line(blocked, 1), to: "stuck.jsonl")
            try home.write(line("ok", 10), to: "ok.jsonl")
            try home.touch("stuck.jsonl", at: .reference())
            try home.touch("ok.jsonl", at: .reference(-.hours(1)))
            let timeLimits = ManualTimeLimits()
            let pool = BlockingIO(label: "test", timeLimit: timeLimits.timeLimit)
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(), pool: pool)

            // The newest file blocks. When its read times out, reading stops for this scan.
            let scan = Task { try await scanner.scan([home.root()], since: rangeStart) }
            #expect(await waitUntil(limit: .seconds(60)) { BlockedLines.hasArrived(blocked) })
            timeLimits.expire { $0.hasSuffix("/stuck.jsonl") }
            let first = try await scan.value
            #expect(first.isPartial())
            #expect(first.total() == 0)
            #expect(pool.abandonedCount == 1)

            // The stuck file is skipped, the other file counts, and no thread is abandoned.
            for _ in 0..<3 {
                let skipped = try await scanner.scan([home.root()], since: rangeStart)
                #expect(skipped.isPartial())
                #expect(skipped.total() == 10)
                #expect(pool.abandonedCount == 1)
            }

            BlockedLines.open(blocked)
            #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
            let recovered = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!recovered.isPartial())
            #expect(recovered.total() == 11)
        }

        @Test func aFolderWhoseListingTimesOutIsSkippedAndDiscoveryGoesOn() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            // Discovery lists folders in name order, so the slow folder comes first.
            try home.write(line("slow", 2), to: "a-slow/two.jsonl")
            try home.write(line("b", 1), to: "b/one.jsonl")
            try home.write(line("c", 4), to: "c/three.jsonl")
            let blocked = BlockedLines.make()
            let listing: DirectoryListing.Function = {
                path, position, cancellation throws(DirectoryListing.ListingError) in
                if path.hasSuffix("/a-slow") { BlockedLines.wait(blocked) }
                return try DirectoryListing.standard(path, position, cancellation)
            }
            let timeLimits = ManualTimeLimits()
            let pool = BlockingIO(label: "test", timeLimit: timeLimits.timeLimit)
            let scanner = CountingScanner(
                match: jsonl, limits: HistoryLimits(), pool: pool, listing: listing)

            // The page that waits for the slow folder times out while it waits there.
            let scan = Task { try await scanner.scan([home.root()], since: rangeStart) }
            #expect(await waitUntil(limit: .seconds(60)) { BlockedLines.hasArrived(blocked) })
            timeLimits.expire { $0.hasSuffix("/discovery") }
            let first = try await scan.value
            #expect(first.isPartial())
            BlockedLines.open(blocked)
            #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })

            // The sweep goes on past the slow folder, which stays partial until a sweep lists
            // it. Before the fix, every page waited for the same folder again.
            let past = try await scanner.scan([home.root()], since: rangeStart)
            #expect(past.total() == 5)
            #expect(past.isPartial())
            let listed = try await scanner.scanUntilComplete([home.root()])
            #expect(!listed.isPartial())
            #expect(listed.total() == 7)
        }

        @Test func aLargeFolderIsListedInChunks() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<7 { try home.write(line("\(index)", 10), to: "\(index).jsonl") }
            try home.write(line("deep", 100), to: "sub/deep.jsonl")
            let scanner = CountingScanner(
                match: jsonl,
                limits: HistoryLimits(directoryEntries: 3, blockingTimeout: .seconds(120)),
                pool: .history,
                listing: DirectoryListing.chunks(of: 2))
            let result = try await scanner.scanUntilComplete([home.root()])
            #expect(!result.isPartial())
            #expect(result.total() == 170)
        }

        @Test func aFileThatGrowsWhileItIsReadKeepsTheNewOffset() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let blocked = BlockedLines.make()
            try home.write(line("first", 1) + line(blocked, 2), to: "live.jsonl")
            let scanner = CountingScanner(match: jsonl, limits: patient)
            let task = Task { try await scanner.scan([home.root()], since: rangeStart) }
            #expect(await waitUntil(limit: .seconds(60)) { BlockedLines.hasArrived(blocked) })
            // The session appends while the scan reads.
            try home.append(line("appended", 4), to: "live.jsonl")
            BlockedLines.open(blocked)
            let during = try await task.value
            #expect(during.total() == 3)

            let next = try await scanner.scan([home.root()], since: rangeStart)
            #expect(next.total() == 7)
            #expect(next.work.parsedLines == 1)
            #expect(!next.isPartial())
        }

        @Test func aFinalLineWithoutALineFeedStaysPartial() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("done", 5) + #"{"id":"open","count":9}"#, to: "open.jsonl")
            let scanner = CountingScanner(match: jsonl, limits: patient)
            for _ in 0..<3 {
                let result = try await scanner.scan([home.root()], since: rangeStart)
                #expect(result.isPartial())
                #expect(result.total() == 5)
                #expect(result.work.parsedLines <= 1)
            }
        }

        @Test func aRootCheckWithoutAThreadKeepsTheLastFilesAsPartial() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 10), to: "a.jsonl")
            let pool = BlockingIO(label: "test", capacity: 1)
            let scanner = CountingScanner(match: jsonl, limits: patient, pool: pool)
            let roots = [home.root("one"), home.root("two", "missing")]
            let first = try await scanner.scan(roots, since: rangeStart)
            #expect(first.partialAccounts.isEmpty)

            // One stuck read fills the pool, so the root check finds no thread. The read waits
            // until the test releases it, however long the scans take.
            let release = DispatchSemaphore(value: 0)
            await #expect(throws: TimeoutError.self) {
                try await pool.run(timeout: .milliseconds(20)) { _ in
                    _ = release.wait(timeout: .now() + 600)
                }
            }
            let full = try await scanner.scan(roots, since: rangeStart)
            #expect(full.accounts == ["one", "two"])
            #expect(full.partialAccounts == ["one", "two"])
            #expect(full.total("one") == 10)

            // Other roots than the saved ones have no saved files.
            let other = try await scanner.scan([home.root("three")], since: rangeStart)
            #expect(other.accounts == ["three"])
            #expect(other.files.isEmpty)
            #expect(other.partialAccounts == ["three"])

            release.signal()
            #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
            let recovered = try await scanner.scan(roots, since: rangeStart)
            #expect(recovered.partialAccounts.isEmpty)
            #expect(recovered.total("one") == 10)
        }
    }
}

/// Time limits that end only when a test says, so load on the machine cannot make a call
/// time out.
final class ManualTimeLimits: Sendable {
    private let pending = Locked<[(key: String?, expire: @Sendable () -> Void)]>([])

    var timeLimit: BlockingIO.TimeLimit {
        { [pending] _, key, expire in pending.withLock { $0.append((key, expire)) } }
    }

    /// Ends the waits of the calls whose key matches, as if their time limit passed. A call
    /// that already ended is not changed.
    func expire(where matches: (String) -> Bool) {
        let all = pending.withLock { pending in
            defer { pending = [] }
            return pending
        }
        let due = all.filter { $0.key.map(matches) ?? false }
        let rest = all.filter { !($0.key.map(matches) ?? false) }
        pending.withLock { $0 += rest }
        for call in due { call.expire() }
    }
}
