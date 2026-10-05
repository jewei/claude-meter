import Darwin
import Foundation
import MeterTestSupport
import Testing

@testable import MeterPlatform

/// The pure discovery walk, driven by fake listings.
@Suite struct HistoryDiscoveryCursorTests {
    private typealias Entry = DirectoryListing.Entry
    private typealias Chunk = DirectoryListing.Chunk
    private typealias Location = DiscoveryCursor.Location

    private static let tree: [String: [Entry]] = [
        "/a": [
            Entry(name: "1.jsonl", kind: .regularFile), Entry(name: "2.jsonl", kind: .regularFile),
            Entry(name: "sub", kind: .directory),
        ],
        "/a/sub": [Entry(name: "3.jsonl", kind: .regularFile)],
        "/b": [Entry(name: "x.jsonl", kind: .regularFile)],
    ]

    /// Lists `tree` in chunks of `size` entries.
    private static func listing(chunk size: Int) -> DiscoveryCursor.Listing {
        { location, position throws(DirectoryListing.ListingError) in
            if location.directory == "/blocked" { throw .unreadable(errno: EACCES) }
            guard let entries = tree[location.directory] else { throw .missing }
            let start = position?.offset ?? 0
            let end = min(entries.count, start + size)
            return Chunk(
                entries: Array(entries[start..<end]),
                next: end < entries.count ? DirectoryListing.Position(offset: end) : nil)
        }
    }

    private func walk(
        _ cursor: inout DiscoveryCursor, chunk: Int = 100, steps: Int = 100
    ) -> [String] {
        var paths: [String] = []
        for _ in 0..<steps {
            guard let entry = cursor.next(listing: Self.listing(chunk: chunk)) else { break }
            paths.append(entry.path)
        }
        return paths
    }

    @Test(arguments: [1, 2, 100])
    func takesOneEntryFromEachRootInTurn(chunk: Int) {
        var cursor = DiscoveryCursor(roots: ["/a", "/b"])
        #expect(
            walk(&cursor, chunk: chunk)
                == ["/a/1.jsonl", "/b/x.jsonl", "/a/2.jsonl", "/a/sub", "/a/sub/3.jsonl"])
        #expect(cursor.isComplete)
        #expect(cursor.failedRoots.isEmpty)
    }

    @Test(arguments: [1, 100])
    func resumesWhereItStopped(chunk: Int) {
        var cursor = DiscoveryCursor(roots: ["/a"])
        #expect(walk(&cursor, chunk: chunk, steps: 2) == ["/a/1.jsonl", "/a/2.jsonl"])
        #expect(!cursor.isComplete)
        #expect(walk(&cursor, chunk: chunk) == ["/a/sub", "/a/sub/3.jsonl"])
        #expect(cursor.isComplete)
    }

    @Test func anUnreadableDirectoryMarksItsRootAndTheWalkGoesOn() {
        var cursor = DiscoveryCursor(roots: ["/blocked", "/a", "/missing"])
        #expect(walk(&cursor).count == 4)
        #expect(cursor.isComplete)
        #expect(cursor.failedRoots == [0])
    }

    @Test func aSkippedDirectoryIsLeftOutAndItsRootFails() {
        // Skipped before the walk reaches it.
        var ahead = DiscoveryCursor(roots: ["/a", "/b"])
        ahead.skip(Location(directory: "/a/sub", root: 0))
        #expect(walk(&ahead, chunk: 1) == ["/a/1.jsonl", "/b/x.jsonl", "/a/2.jsonl", "/a/sub"])
        #expect(ahead.isComplete)
        #expect(ahead.failedRoots == [0])

        // Skipped while the walk is inside it, with chunks of it still unread.
        var inside = DiscoveryCursor(roots: ["/a", "/b"])
        #expect(walk(&inside, chunk: 1, steps: 1) == ["/a/1.jsonl"])
        inside.skip(Location(directory: "/a", root: 0))
        #expect(walk(&inside, chunk: 1) == ["/b/x.jsonl"])
        #expect(inside.isComplete)
        #expect(inside.failedRoots == [0])
    }

    @Test func aCancelledListingResumesAtTheSameChunk() {
        var cursor = DiscoveryCursor(roots: ["/a", "/b"])
        let cancelled: DiscoveryCursor.Listing = { _, _ throws(DirectoryListing.ListingError) in
            throw .cancelled
        }
        #expect(walk(&cursor, chunk: 1, steps: 2) == ["/a/1.jsonl", "/b/x.jsonl"])
        #expect(cursor.next(listing: cancelled) == nil)
        #expect(!cursor.isComplete)
        #expect(cursor.failedRoots.isEmpty)
        #expect(walk(&cursor, chunk: 1) == ["/a/2.jsonl", "/a/sub", "/a/sub/3.jsonl"])
        #expect(cursor.isComplete)
    }

    @Test func aFolderThatChangedDuringItsListingIsRecorded() {
        var cursor = DiscoveryCursor(roots: ["/a", "/b"])
        let listing: DiscoveryCursor.Listing = {
            location, position throws(DirectoryListing.ListingError) in
            var chunk = try Self.listing(chunk: 1)(location, position)
            chunk.changed = location.directory == "/a" && position != nil
            return chunk
        }
        while cursor.next(listing: listing) != nil {}
        #expect(cursor.isComplete)
        #expect(cursor.changedFolders == ["/a"])
    }
}

/// Chunks of a real folder.
@Suite struct DirectoryListingTests {
    private func names(
        of directory: URL, chunk size: Int, from start: DirectoryListing.Position? = nil
    ) throws -> (names: [String], calls: Int) {
        var (names, calls, position) = ([String](), 0, start)
        repeat {
            let chunk = try DirectoryListing.chunk(
                of: directory.path, from: position, maxEntries: size,
                cancellation: BlockingIO.Cancellation())
            names += chunk.entries.map(\.name)
            position = chunk.next
            calls += 1
        } while position != nil && calls < 100
        return (names, calls)
    }

    @Test func aFolderIsReadInChunksThatResume() throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        for index in 0..<5 { try home.write("", to: "\(index).jsonl") }
        try home.write("", to: ".hidden.jsonl")
        _ = try home.makeDirectory("sub")
        let listed = try names(of: home.url, chunk: 2)
        #expect(
            listed.names.sorted() == ["0.jsonl", "1.jsonl", "2.jsonl", "3.jsonl", "4.jsonl", "sub"])
        #expect(listed.calls >= 4)
    }

    /// A changed folder goes on from its position: starting again would never end in a large
    /// folder that changes more often than its listing takes (review R3-D-03).
    @Test func aFolderThatChangedBetweenChunksGoesOnFromItsPosition() throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        for index in 0..<6 { try home.write("", to: "\(index).jsonl") }
        let first = try DirectoryListing.chunk(
            of: home.url.path, from: nil, maxEntries: 4, cancellation: BlockingIO.Cancellation())
        #expect(!first.changed)
        let position = try #require(first.next)
        try home.write("", to: "new.jsonl")
        let second = try DirectoryListing.chunk(
            of: home.url.path, from: position, maxEntries: 1,
            cancellation: BlockingIO.Cancellation())
        #expect(second.changed)
        #expect(second.next?.offset == position.offset + 1)
        // The rest has at most the 5 raw entries after the position, not all 7 files again. A
        // new entry moves the others after the position, so no earlier entry is missed.
        let rest = try names(of: home.url, chunk: 3, from: position)
        #expect(rest.names.count <= 5)
        let listed = Set(first.entries.map(\.name) + rest.names)
        #expect(listed.isSuperset(of: (0..<6).map { "\($0).jsonl" }))
    }

    @Test func aCancelledListingStopsInsideTheFolder() throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        try home.write("", to: "one.jsonl")
        #expect(throws: DirectoryListing.ListingError.cancelled) {
            try DirectoryListing.chunk(
                of: home.url.path, from: nil, maxEntries: 10, cancellation: .cancelled)
        }
    }

    @Test func missingAndUnreadableFoldersHaveTheirOwnErrors() throws {
        let home = try TemporaryDirectory()
        defer {
            chmod(home.path("closed").path, 0o755)
            home.remove()
        }
        _ = try home.makeDirectory("closed")
        #expect(chmod(home.path("closed").path, 0) == 0)
        #expect(throws: DirectoryListing.ListingError.missing) {
            try DirectoryListing.chunk(
                of: home.path("missing").path, from: nil, maxEntries: 10,
                cancellation: BlockingIO.Cancellation())
        }
        #expect(throws: DirectoryListing.ListingError.unreadable(errno: EACCES)) {
            try DirectoryListing.chunk(
                of: home.path("closed").path, from: nil, maxEntries: 10,
                cancellation: BlockingIO.Cancellation())
        }
    }
}
