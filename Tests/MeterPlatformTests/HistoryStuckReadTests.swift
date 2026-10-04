import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterPlatform

extension HistoryScans {
    /// Reads that block, as on a stuck volume. Each test uses its own pool.
    @Suite struct StuckReads {
        private let jsonl = HistoryFileMatch.fileExtension("jsonl")

        @Test func aFileWhoseReadIsStuckIsSkippedUntilTheReadEnds() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let blocked = BlockedLines.make()
            try home.write(line(blocked, 1), to: "stuck.jsonl")
            try home.write(line("ok", 10), to: "ok.jsonl")
            try home.touch("stuck.jsonl", at: .reference())
            try home.touch("ok.jsonl", at: .reference(-.hours(1)))
            let pool = BlockingIO(label: "test")
            let scanner = CountingScanner(
                match: jsonl, limits: HistoryLimits(blockingTimeout: .milliseconds(100)),
                pool: pool)

            // The newest file blocks. Its read times out, and reading stops for this scan.
            let first = try await scanner.scan([home.root()], since: rangeStart)
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
            #expect(await waitUntil { pool.abandonedCount == 0 })
            let recovered = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!recovered.isPartial())
            #expect(recovered.total() == 11)
        }

        @Test func aFileThatGrowsWhileItIsReadKeepsTheNewOffset() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let blocked = BlockedLines.make()
            try home.write(line("first", 1) + line(blocked, 2), to: "live.jsonl")
            let scanner = CountingScanner(match: jsonl)
            let task = Task { try await scanner.scan([home.root()], since: rangeStart) }
            #expect(await waitUntil { BlockedLines.hasArrived(blocked) })
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
            let scanner = CountingScanner(match: jsonl)
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
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(), pool: pool)
            let roots = [home.root("one"), home.root("two", "missing")]
            let first = try await scanner.scan(roots, since: rangeStart)
            #expect(first.partialAccounts.isEmpty)

            // One stuck read fills the pool, so the root check finds no thread.
            let release = DispatchSemaphore(value: 0)
            await #expect(throws: TimeoutError.self) {
                try await pool.run(timeout: .milliseconds(20)) { _ in
                    _ = release.wait(timeout: .now() + 10)
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
            #expect(await waitUntil { pool.abandonedCount == 0 })
            let recovered = try await scanner.scan(roots, since: rangeStart)
            #expect(recovered.partialAccounts.isEmpty)
            #expect(recovered.total("one") == 10)
        }
    }
}
