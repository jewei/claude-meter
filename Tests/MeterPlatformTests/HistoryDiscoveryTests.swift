import Darwin
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

extension HistoryScans {
    /// Discovery pages, sweeps, roots, and the partial rules that follow from them.
    @Suite struct Discovery {
        private let jsonl = HistoryFileMatch.fileExtension("jsonl")

        @Test func discoveryResumesAndKeepsEarlierFilesAcrossPages() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<7 { try home.write(line("\(index)", 10), to: "\(index).jsonl") }
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(directoryEntries: 2))
            var result = try await scanner.scan([home.root()], since: rangeStart)
            #expect(result.isPartial())
            #expect(result.total() == 20)
            for _ in 0..<8 where result.isPartial() {
                let previous = result.total()
                result = try await scanner.scan([home.root()], since: rangeStart)
                #expect(result.total() >= previous)
                #expect(result.work.directoryEntries <= 2)
            }
            #expect(!result.isPartial())
            #expect(result.total() == 70)

            // The next sweep starts again. Its first page must not drop the other files.
            let next = try await scanner.scan([home.root()], since: rangeStart)
            #expect(next.isPartial())
            #expect(next.total() == 70)
            #expect(next.work.bytesRead == 0)
        }

        @Test func discoveryTakesOneEntryFromEachRootInTurn() async throws {
            let first = try TemporaryDirectory()
            let second = try TemporaryDirectory()
            defer {
                first.remove()
                second.remove()
            }
            for index in 0..<7 { try first.write(line("first-\(index)", 10), to: "\(index).jsonl") }
            try second.write(line("second", 100), to: "only.jsonl")
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(directoryEntries: 2))
            let roots = [first.root("a"), second.root("b")]
            let result = try await scanner.scan(roots, since: rangeStart)
            #expect(result.total("a") == 10)
            #expect(result.total("b") == 100)
            #expect(result.isPartial("a"))
            #expect(result.work.directoryEntries == 2)

            // A changed root list discards the cursors and records of the old roots.
            let changed = try await scanner.scan([second.root("b")], since: rangeStart)
            #expect(!changed.isPartial("b"))
            #expect(changed.total("b") == 100)
            #expect(changed.accounts == ["b"])
        }

        @Test func filesModifiedBeforeTheRangeAreSkipped() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<6 {
                try home.write(line("old-\(index)", 10), to: "\(index).jsonl")
                try home.touch("\(index).jsonl", at: rangeStart.addingTimeInterval(-60))
            }
            try home.write(line("recent", 7), to: "z.jsonl")
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(directoryEntries: 2))
            let result = try await scanner.scanUntilComplete([home.root()])
            #expect(!result.isPartial())
            #expect(result.total() == 7)
            #expect(result.files.count == 1)
        }

        @Test func onlyACompletedSweepRemovesDeletedFiles() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("kept", 10), to: "kept.jsonl")
            try home.write(line("old", 100), to: "old.jsonl")
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(directoryEntries: 1))
            #expect(try await scanner.scanUntilComplete([home.root()]).total() == 110)

            try FileManager.default.removeItem(at: home.path("old.jsonl"))
            try home.write(line("new", 20), to: "new.jsonl")
            try home.append(line("appended", 30), to: "kept.jsonl")
            // The new sweep has not reached every file yet. The deleted file fails its read, so it
            // stops counting at once, and the history stays partial.
            let incomplete = try await scanner.scan([home.root()], since: rangeStart)
            #expect(incomplete.isPartial())
            let result = try await scanner.scanUntilComplete([home.root()])
            #expect(!result.isPartial())
            #expect(result.total() == 60)
        }

        @Test func aRootReplacedAtTheSamePathResetsItsCursor() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("old-one", 100), to: "logs/one.jsonl")
            try home.write(line("old-two", 100), to: "logs/two.jsonl")
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(directoryEntries: 1))
            let root = home.root("default", "logs")
            _ = try await scanner.scan([root], since: rangeStart)
            try FileManager.default.moveItem(at: home.path("logs"), to: home.path("previous"))
            try home.write(line("new", 10), to: "logs/new.jsonl")
            let result = try await scanner.scanUntilComplete([root])
            #expect(!result.isPartial())
            #expect(result.total() == 10)
        }

        @Test func eachAccountCountsOnlyItsOwnFolders() async throws {
            let personal = try TemporaryDirectory()
            let work = try TemporaryDirectory()
            defer {
                personal.remove()
                work.remove()
            }
            try personal.write(line("personal", 1_000), to: "projects/a/session.jsonl")
            try personal.write(line("archived", 500), to: "archive/session.jsonl")
            try work.write(line("work", 10), to: "projects/b/session.jsonl")
            _ = try personal.makeDirectory("empty")
            let roots = [
                personal.root("claude", "projects"), personal.root("claude", "archive"),
                work.root("claude-work", "projects"), personal.root("claude-new", "empty"),
                personal.root("claude-missing", "missing"),
            ]
            let result = try await CountingScanner(match: jsonl).scan(roots, since: rangeStart)
            #expect(result.accounts == ["claude", "claude-work", "claude-new", "claude-missing"])
            #expect(result.total("claude") == 1_500)
            #expect(result.total("claude-work") == 10)
            #expect(result.files(of: "claude-new").isEmpty)
            #expect(result.files(of: "claude-missing").isEmpty)
            #expect(result.partialAccounts.isEmpty)
        }

        @Test func partialCoverageStaysWithTheAccountThatCausedIt() async throws {
            let personal = try TemporaryDirectory()
            let work = try TemporaryDirectory()
            defer {
                personal.remove()
                work.remove()
            }
            try personal.write(line("large", 100, padding: 2_000), to: "large.jsonl")
            try work.write(line("small", 10), to: "small.jsonl")
            let result = try await CountingScanner(
                match: jsonl, limits: HistoryLimits(lineBytes: 1_000)
            )
            .scan([personal.root("claude"), work.root("claude-work")], since: rangeStart)
            #expect(result.isPartial("claude"))
            #expect(!result.isPartial("claude-work"))
            #expect(result.total("claude-work") == 10)
        }

        @Test func theFileLimitMakesEveryAccountPartial() async throws {
            let personal = try TemporaryDirectory()
            let work = try TemporaryDirectory()
            defer {
                personal.remove()
                work.remove()
            }
            try personal.write(line("one", 1), to: "one.jsonl")
            try personal.write(line("two", 2), to: "two.jsonl")
            try work.write(line("three", 3), to: "three.jsonl")
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(files: 2))
            let roots = [personal.root("a"), work.root("b")]
            for _ in 0..<3 {
                let result = try await scanner.scan(roots, since: rangeStart)
                #expect(result.partialAccounts == ["a", "b"])
                #expect(result.files.count <= 2)
            }
        }

        @Test func linksAndSpecialFilesAreSkippedWithoutMakingHistoryPartial() async throws {
            let home = try TemporaryDirectory()
            let outside = try TemporaryDirectory()
            defer {
                home.remove()
                outside.remove()
            }
            try home.write(line("real", 5), to: "real.jsonl")
            try home.write(line("inner", 6), to: "folder.jsonl/inner.jsonl")
            let target = try outside.write(line("linked", 1_000), to: "target.jsonl")
            try FileManager.default.createSymbolicLink(
                at: home.path("link.jsonl"), withDestinationURL: target)
            try FileManager.default.createSymbolicLink(
                at: home.path("linked-folder"), withDestinationURL: outside.url)
            #expect(mkfifo(home.path("pipe.jsonl").path, 0o600) == 0)
            try home.write(line("hidden", 1_000), to: ".hidden.jsonl")
            try home.write(line("hidden-folder", 1_000), to: ".cache/file.jsonl")
            try home.write(line("other", 1_000), to: "notes.txt")

            let result = try await CountingScanner(match: jsonl).scan(
                [home.root()], since: rangeStart)
            #expect(result.total() == 11)
            #expect(!result.isPartial())
        }

        @Test func anUnreadableFolderHidesOnlyItsOwnFiles() async throws {
            let home = try TemporaryDirectory()
            defer {
                chmod(home.path("b").path, 0o755)
                home.remove()
            }
            try home.write(line("one", 1), to: "a/one.jsonl")
            try home.write(line("two", 2), to: "b/two.jsonl")
            try home.write(line("three", 4), to: "c/three.jsonl")
            #expect(chmod(home.path("b").path, 0) == 0)
            let scanner = CountingScanner(match: jsonl)
            let blocked = try await scanner.scan([home.root()], since: rangeStart)
            #expect(blocked.total() == 5)
            #expect(blocked.isPartial())

            #expect(chmod(home.path("b").path, 0o755) == 0)
            let readable = try await scanner.scan([home.root()], since: rangeStart)
            #expect(readable.total() == 7)
            #expect(!readable.isPartial())
        }

        @Test func aHardLinkInTwoRootsCountsForTheRootListedFirst() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let original = try home.write(line("shared", 9), to: "a/one.jsonl")
            _ = try home.makeDirectory("b")
            try FileManager.default.linkItem(at: original, to: home.path("b/two.jsonl"))
            try home.touch("b/two.jsonl", at: .reference())

            for (first, second) in [("a", "b"), ("b", "a")] {
                let roots = [
                    home.root(AccountID(first), first), home.root(AccountID(second), second),
                ]
                let result = try await CountingScanner(match: jsonl).scan(roots, since: rangeStart)
                #expect(result.total(AccountID(first)) == 9)
                #expect(result.files(of: AccountID(second)).isEmpty)
            }
        }

        @Test func nestedRootsGiveAFileToTheEarlierRoot() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("inner", 3), to: "outer/inner/one.jsonl")
            let outer = home.root("outer", "outer")
            let inner = home.root("inner", "outer/inner")
            let outerFirst = try await CountingScanner(match: jsonl).scan(
                [outer, inner], since: rangeStart)
            #expect(outerFirst.total("outer") == 3)
            #expect(outerFirst.files(of: "inner").isEmpty)
            let innerFirst = try await CountingScanner(match: jsonl).scan(
                [inner, outer], since: rangeStart)
            #expect(innerFirst.total("inner") == 3)
            #expect(innerFirst.files(of: "outer").isEmpty)
        }

        @Test func aRepeatedRootPathKeepsTheFirstAccount() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("one", 3), to: "one.jsonl")
            let result = try await CountingScanner(match: jsonl).scan(
                [
                    home.root("a"),
                    HistoryRoot(account: "b", directory: home.url.appending(path: ".")),
                ],
                since: rangeStart)
            #expect(result.accounts == ["a"])
            #expect(result.total("a") == 3)
        }

        @Test func aFileNameMatchSelectsOnlyThatName() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("one", 3), to: "one/updates.jsonl")
            try home.write(line("two", 4), to: "two/other.jsonl")
            let result = try await CountingScanner(match: .fileName("updates.jsonl"))
                .scan([home.root()], since: rangeStart)
            #expect(result.total() == 3)
        }
    }
}
