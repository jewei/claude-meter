import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterPlatform

extension HistoryScans {
    /// A line over the line limit is skipped unparsed. It makes its file partial only when it
    /// could hold a record: it has the parser's record marker, or the parser has none.
    @Suite struct LongLines {
        private let limits = HistoryLimits(lineBytes: 1_000)

        @Test func aLongLineWithoutTheMarkerLeavesTheFileComplete() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 1) + note(padding: 5_000) + line("b", 2), to: "one.jsonl")
            let scanner = MarkedScanner(match: .fileExtension("jsonl"), limits: limits)
            let result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(result.total() == 3)
            #expect(!result.isPartial())
            try home.append(line("c", 4), to: "one.jsonl")
            let next = try await scanner.scan([home.root()], since: rangeStart)
            #expect(next.total() == 7)
            #expect(!next.isPartial())
            #expect(next.work.bytesRead < 2_048)
        }

        @Test func aLongLineWithTheMarkerMakesTheFilePartial() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let long = line("long", 1_000, padding: 5_000)
            try home.write(line("a", 1) + long + line("b", 2), to: "one.jsonl")
            let scanner = MarkedScanner(match: .fileExtension("jsonl"), limits: limits)
            let result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(result.total() == 3)
            #expect(result.isPartial())
        }

        /// The marker starts 3 bytes before the end of the first read chunk, so neither chunk
        /// holds all of it.
        @Test func aMarkerSplitBetweenTwoReadsIsFound() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let prefix = #"{"id":"long","pad":""#
            let padding = HistoryLimits.chunkBytes - 3 - prefix.utf8.count - 2
            let long = prefix + String(repeating: "x", count: padding) + #"","count":5}"# + "\n"
            let marker = Array(#""count""#.utf8)
            let split = HistoryLimits.chunkBytes - 3
            #expect(Array(Array(long.utf8)[split..<split + marker.count]) == marker)
            try home.write(long + line("a", 1), to: "one.jsonl")
            let scanner = MarkedScanner(match: .fileExtension("jsonl"), limits: limits)
            let result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(result.total() == 1)
            #expect(result.isPartial())
        }

        @Test func aLongLineStillBeingWrittenKeepsTheFilePartialUntilItEnds() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let long = note(padding: 5_000)
            try home.write(line("a", 1) + String(long.dropLast(10)), to: "one.jsonl")
            let scanner = MarkedScanner(match: .fileExtension("jsonl"), limits: limits)
            let writing = try await scanner.scan([home.root()], since: rangeStart)
            #expect(writing.total() == 1)
            #expect(writing.isPartial())
            try home.append(String(long.suffix(10)) + line("b", 2), to: "one.jsonl")
            let ended = try await scanner.scan([home.root()], since: rangeStart)
            #expect(ended.total() == 3)
            #expect(!ended.isPartial())
        }

        /// Codex and Grok name no marker, so any skipped line can hide a record.
        @Test func withoutAMarkerEveryLongLineMakesTheFilePartial() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 1) + note(padding: 5_000), to: "one.jsonl")
            let scanner = CountingScanner(match: .fileExtension("jsonl"), limits: limits)
            let result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(result.total() == 1)
            #expect(result.isPartial())
        }
    }
}
