import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

extension HistoryScans {
    /// One history read scans again while scans stop at a budget, within its catch-up time, so
    /// a launch counts all history at once instead of one scan's share for each refresh.
    @Suite struct CatchUp {
        /// Five files of 20 lines each, about 1,850 bytes per file.
        private func writeFiles(in home: TemporaryDirectory) throws {
            for file in 0..<5 {
                let lines = (0..<20).map { line("\(file)-\($0)", 1, padding: 60) }
                try home.write(lines.joined(), to: "\(file).jsonl")
            }
        }

        @Test func oneReadCountsWhatTakesManyScans() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try writeFiles(in: home)
            let limits = HistoryLimits(scanBytes: 1_500, fileBytes: 1_000)

            let single = try await CountingScanner(match: .fileExtension("jsonl"), limits: limits)
                .scan([home.root()], since: rangeStart)
            #expect(single.isPartial())
            #expect(single.work.readStoppedAtBudget)

            let caughtUp = try await CountingScanner(match: .fileExtension("jsonl"), limits: limits)
                .catchUp([home.root()], since: rangeStart)
            #expect(!caughtUp.isPartial())
            #expect(caughtUp.total() == 100)
            #expect(!caughtUp.work.readStoppedAtBudget)
            #expect(caughtUp.work.bytesRead <= 1_500)
        }

        @Test func theCatchUpTimeEndsTheRead() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try writeFiles(in: home)
            let limits = HistoryLimits(scanBytes: 1_500, fileBytes: 1_000, catchUpTime: .zero)
            let result = try await CountingScanner(match: .fileExtension("jsonl"), limits: limits)
                .catchUp([home.root()], since: rangeStart)
            #expect(result.isPartial())
            #expect(result.total() < 100)
        }

        @Test func discoveryIsFollowedUntilOneSweepCompletes() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for file in 0..<30 { try home.write(line("\(file)", 1), to: "\(file).jsonl") }
            let limits = HistoryLimits(directoryEntries: 4, catchUpTime: .seconds(60))
            let scanner = CountingScanner(match: .fileExtension("jsonl"), limits: limits)
            let clock = ContinuousClock()
            let started = clock.now
            let first = try await scanner.catchUp([home.root()], since: rangeStart)
            #expect(!first.isPartial())
            #expect(first.total() == 30)
            #expect(first.work.completedSweep)
            // The next read starts a new sweep. It stops after that sweep, not at the time.
            let second = try await scanner.catchUp([home.root()], since: rangeStart)
            #expect(second.work.completedSweep)
            #expect(second.total() == 30)
            #expect(started.duration(to: clock.now) < .seconds(10))
        }

        /// Partial history that another scan cannot help, such as a session that is still
        /// writing its last line, ends the read at once.
        @Test func historyThatIsPartialForOtherReasonsIsScannedOnce() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("a", 1) + String(line("b", 2).dropLast()), to: "one.jsonl")
            let limits = HistoryLimits(catchUpTime: .seconds(60))
            let scanner = CountingScanner(match: .fileExtension("jsonl"), limits: limits)
            let clock = ContinuousClock()
            let started = clock.now
            let result = try await scanner.catchUp([home.root()], since: rangeStart)
            #expect(result.isPartial())
            #expect(!result.work.readStoppedAtBudget)
            #expect(!result.work.discoveryStoppedAtBudget)
            #expect(started.duration(to: clock.now) < .seconds(10))
        }
    }
}
