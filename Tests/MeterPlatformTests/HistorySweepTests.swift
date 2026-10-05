import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterPlatform

extension HistoryScans {
    /// Sweeps that take several scans while files, folders, and the range start change.
    @Suite struct Sweeps {
        private let jsonl = HistoryFileMatch.fileExtension("jsonl")

        /// A later range start keeps a file that its saved date calls old: a resumed session
        /// can have written to it since (review R3-D-02).
        @Test func aLaterStartKeepsAFileThatChangedSinceItWasFound() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line("resumed-old", 100), to: "a-resumed.jsonl")
            try home.write(line("stale", 1_000), to: "b-stale.jsonl")
            for name in ["a-resumed.jsonl", "b-stale.jsonl"] {
                try home.touch(name, at: rangeStart.addingTimeInterval(60))
            }
            for index in 0..<6 { try home.write(line("\(index)", 1), to: "c-\(index).jsonl") }
            let scanner = CountingScanner(match: jsonl, limits: HistoryLimits(directoryEntries: 2))
            #expect(try await scanner.scanUntilComplete([home.root()]).total() == 1_106)

            // A new sweep passes both old files. Then the session resumes, and local midnight
            // moves the start past the saved date of its file.
            let started = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!started.isPartial())
            try home.append(line("resumed-new", 10), to: "a-resumed.jsonl")
            let later = rangeStart.addingTimeInterval(3_600)
            let next = try await scanner.scan([home.root()], since: later)
            #expect(!next.isPartial())
            #expect(next.total() == 1_116)
            #expect(next.work.parsedLines == 1)

            // Sweeps under the new start find the resumed file by its date on disk, and leave
            // out the file that is really old.
            var result = next
            for _ in 0..<12 { result = try await scanner.scan([home.root()], since: later) }
            #expect(!result.isPartial())
            #expect(result.total() == 116)
            #expect(!result.files.contains { $0.path.hasSuffix("b-stale.jsonl") })
        }

        /// A folder with more entries than one scan visits, and a new file before each scan,
        /// is still walked to its end (review R3-D-03).
        @Test func aLargeFolderThatChangesBetweenScansIsWalkedToItsEnd() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            for index in 0..<60 { try home.write(line("old-\(index)", 1), to: "\(index).jsonl") }
            let scanner = CountingScanner(
                match: jsonl, limits: HistoryLimits(directoryEntries: 20),
                pool: BlockingIO(label: "test"), listing: DirectoryListing.chunks(of: 10))
            var result = try await scanner.scan([home.root()], since: rangeStart)
            for index in 0..<10 where result.isPartial() {
                try home.write(line("new-\(index)", 1_000), to: "new-\(index).jsonl")
                result = try await scanner.scan([home.root()], since: rangeStart)
            }
            #expect(!result.isPartial())
            // Every old file counts. A new file counts when the walk had not passed its place.
            #expect(result.total() % 1_000 == 60)
        }

        /// A removed file can move another one before the listing position, so the sweep does
        /// not see it. The completed sweep keeps that file from the earlier inventory, and the
        /// removed file leaves.
        @Test func aFileThatAChangeMovedBeforeThePositionStays() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let names = ["a", "b", "c", "d", "e", "f"]
            for (index, name) in names.enumerated() {
                try home.write(line(name, index + 1), to: "\(name).jsonl")
            }
            let order = Locked((names: names.map { "\($0).jsonl" }, version: 0))
            let scanner = CountingScanner(
                match: jsonl, limits: HistoryLimits(directoryEntries: 2),
                pool: BlockingIO(label: "test"), listing: Self.listing(order))
            #expect(try await scanner.scanUntilComplete([home.root()]).total() == 21)

            // The new sweep lists `a` and `b`. Then `a` goes, and `c` moves to the position
            // that the sweep has passed.
            let started = try await scanner.scan([home.root()], since: rangeStart)
            #expect(!started.isPartial())
            try FileManager.default.removeItem(at: home.path("a.jsonl"))
            order.withLock { $0 = (Array($0.names.dropFirst()), $0.version + 1) }

            // `c` counts in every scan, also after the sweep that did not see it completed.
            var result = started
            for _ in 0..<6 {
                result = try await scanner.scan([home.root()], since: rangeStart)
                #expect(result.files.contains { $0.path.hasSuffix("/c.jsonl") })
            }
            #expect(!result.isPartial())
            #expect(result.total() == 20)
            #expect(!result.files.contains { $0.path.hasSuffix("/a.jsonl") })
        }

        /// Lists `order` in chunks of 2 entries. A new version is a changed folder.
        private static func listing(
            _ order: Locked<(names: [String], version: Int)>
        ) -> DirectoryListing.Function {
            { _, position, _ throws(DirectoryListing.ListingError) in
                let (names, version) = order.value
                let stamp = DirectoryListing.Stamp(
                    device: 0, inode: 0, seconds: version, nanoseconds: 0)
                let start = min(position?.offset ?? 0, names.count)
                let end = min(names.count, start + 2)
                return DirectoryListing.Chunk(
                    entries: names[start..<end].map { .init(name: $0, kind: .regularFile) },
                    next: end < names.count ? .init(offset: end, stamp: stamp) : nil,
                    changed: position?.stamp.map { $0 != stamp } ?? false)
            }
        }
    }
}
