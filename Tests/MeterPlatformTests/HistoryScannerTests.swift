import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

extension HistoryScans {
    /// Incremental reads of one file: resume, rebuild, and the byte, line, and record limits.
    @Suite struct Reading {
        @Test func unchangedFilesAreNotReadAgain() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 10, padding: 10_000), to: "one.jsonl")
            let scanner = CountingScanner(match: .fileExtension("jsonl"))
            let first = try await scanner.scan([home.root()], since: rangeStart)
            #expect(first.total() == 10)
            #expect(first.work.bytesRead > 10_000)
            let second = try await scanner.scan([home.root()], since: rangeStart)
            #expect(second.total() == 10)
            #expect(second.work.bytesRead == 0)
            #expect(second.work.parsedLines == 0)
            #expect(second.work.cacheHits == 1)
        }

        @Test func anEmptyFileIsCompleteAndNotACacheHit() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 10), to: "full.jsonl")
            try home.write("", to: "empty.jsonl")
            let scanner = CountingScanner(match: .fileExtension("jsonl"))
            let first = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!first.isPartial())
            #expect(first.total() == 10)
            #expect(first.work.cacheHits == 0)
            #expect(first.files.count == 2)
            let second = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!second.isPartial())
            #expect(second.work.cacheHits == 2)

            // The empty file grows later and counts.
            try home.append(line("b", 5), to: "empty.jsonl")
            let grown = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!grown.isPartial())
            #expect(grown.total() == 15)
        }

        @Test func anIncompleteFinalLineIsReadAgainLater() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 10, padding: 10_000), to: "one.jsonl")
            let scanner = CountingScanner(match: .fileExtension("jsonl"))
            _ = try await scanner.scan([home.root()], since: rangeStart)
            try home.append(String(line("b", 20).dropLast()), to: "one.jsonl")
            let waiting = try await scanner.scan([home.root()], since: rangeStart)
            #expect(waiting.total() == 10)
            #expect(waiting.isPartial())
            try home.append("\n", to: "one.jsonl")
            let complete = try await scanner.scan([home.root()], since: rangeStart)
            #expect(complete.total() == 30)
            #expect(!complete.isPartial())
            #expect(complete.work.parsedLines == 1)
            #expect(complete.work.bytesRead < 2_048)
        }

        @Test func replacedTruncatedAndRewrittenFilesAreRebuilt() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 10) + line("b", 20), to: "one.jsonl")
            let scanner = CountingScanner(match: .fileExtension("jsonl"))
            #expect(try await scanner.scan([home.root()], since: rangeStart).total() == 30)

            // Replaced: a new inode.
            try Data((line("c", 500) + line("d", 1)).utf8).write(
                to: home.path("one.jsonl"), options: .atomic)
            #expect(try await scanner.scan([home.root()], since: rangeStart).total() == 501)

            // Truncated: the same inode, smaller.
            try home.overwrite(line("e", 7), at: "one.jsonl")
            #expect(try await scanner.scan([home.root()], since: rangeStart).total() == 7)

            // Rewritten at the same size: only the stamp tells.
            try home.overwrite(line("f", 8), at: "one.jsonl")
            try home.touch("one.jsonl", at: .reference(-.hours(1)))
            #expect(try await scanner.scan([home.root()], since: rangeStart).total() == 8)

            // Emptied: no records.
            try home.overwrite("", at: "one.jsonl")
            let empty = try await scanner.scan([home.root()], since: rangeStart)
            #expect(empty.files(of: "default").allSatisfy { $0.parser.recordCount == 0 })
        }

        @Test func changedStartBytesOrAppendBoundaryRebuildAGrownFile() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let first = line("first", 1, padding: 400)
            let second = line("second", 1, padding: 400)
            try home.write(line("x", 10) + first, to: "start.jsonl")
            try home.write(second + line("y", 10), to: "boundary.jsonl")
            let scanner = CountingScanner(match: .fileExtension("jsonl"))
            #expect(try await scanner.scan([home.root()], since: rangeStart).total() == 22)

            // The first bytes change and the file grows: a rewrite, not an append.
            try home.overwrite(line("z", 20) + first + line("b", 2), at: "start.jsonl")
            // The first 256 bytes stay; only the bytes before the saved offset change.
            try home.overwrite(second + line("w", 30) + line("c", 3), at: "boundary.jsonl")
            let rebuilt = try await scanner.scan([home.root()], since: rangeStart)
            #expect(rebuilt.total() == (20 + 1 + 2) + (1 + 30 + 3))
            #expect(!rebuilt.isPartial())
        }

        @Test func theByteBudgetResumesWithoutCountingAPrefixTwice() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(
                (0..<20).map { line("\($0)", 13, padding: 60) }.joined(), to: "one.jsonl")
            let limits = HistoryLimits(scanBytes: 1_500, fileBytes: 1_000)
            let scanner = CountingScanner(match: .fileExtension("jsonl"), limits: limits)
            var result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(result.isPartial())
            var previous = result.total()
            for _ in 0..<30 where result.isPartial() {
                result = try await scanner.scan([home.root()], since: rangeStart)
                #expect(result.total() > previous)
                #expect(result.work.bytesRead <= 1_500)
                previous = result.total()
            }
            #expect(!result.isPartial())
            #expect(result.total() == 260)
        }

        @Test func aLongLineIsSkippedOnceAndMakesTheFilePartial() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let long = line("long", 1_000, padding: 5_000)
            try home.write(line("a", 1) + long + line("b", 2), to: "one.jsonl")
            let scanner = CountingScanner(
                match: .fileExtension("jsonl"), limits: HistoryLimits(lineBytes: 1_000))
            let result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(result.total() == 3)
            #expect(result.isPartial())
            try home.append(line("c", 4), to: "one.jsonl")
            let next = try await scanner.scan([home.root()], since: rangeStart)
            #expect(next.total() == 7)
            #expect(next.work.bytesRead < 2_048)
        }

        @Test func theFileRecordLimitStopsReadingThatFile() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 1) + line("b", 2) + line("c", 4), to: "one.jsonl")
            let scanner = CountingScanner(
                match: .fileExtension("jsonl"), limits: HistoryLimits(fileRecords: 2))
            let result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(result.total() == 3)
            #expect(result.isPartial())
            try home.append(line("d", 8), to: "one.jsonl")
            let next = try await scanner.scan([home.root()], since: rangeStart)
            #expect(next.total() == 3)
            #expect(next.isPartial())
        }

        @Test func theProviderRecordLimitKeepsTheNewestFiles() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<4 {
                try home.write(line("\(index)", 10 + index), to: "\(index).jsonl")
                try home.touch("\(index).jsonl", at: .reference(Double(-index)))
            }
            let scanner = CountingScanner(
                match: .fileExtension("jsonl"), limits: HistoryLimits(records: 2))
            for _ in 0..<3 {
                let result = try await scanner.scan([home.root()], since: rangeStart)
                #expect(result.total() == 10 + 11)
                #expect(result.isPartial())
                #expect(result.work.cachedRecords <= 2)
            }
        }

        @Test func malformedLinesMakeTheFilePartial() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 5) + "{broken}\n" + "\n" + line("b", 6), to: "one.jsonl")
            let result = try await CountingScanner(match: .fileExtension("jsonl"))
                .scan([home.root()], since: rangeStart)
            #expect(result.total() == 11)
            #expect(result.isPartial())
            #expect(result.work.parsedLines == 3)
        }

        @Test func aChangedRangeStartResetsTheCache() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 5), to: "one.jsonl")
            let scanner = CountingScanner(match: .fileExtension("jsonl"))
            _ = try await scanner.scan([home.root()], since: rangeStart)
            let next = try await scanner.scan(
                [home.root()], since: rangeStart.addingTimeInterval(1))
            #expect(next.total() == 5)
            #expect(next.work.cacheHits == 0)
            #expect(next.work.parsedLines == 1)
        }
    }
}
