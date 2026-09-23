import Darwin
import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Bounded regular-file reader")
struct BoundedRegularFileReaderTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func readsRegularFileAndAllowsConfiguredSymbolicLink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("link.json")
        try Data("payload".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(
            try BoundedRegularFileReader.read(at: link, maximumByteCount: 64)
                == Data("payload".utf8))
        #expect(throws: BoundedRegularFileReader.ReadError.self) {
            try BoundedRegularFileReader.read(
                at: link, maximumByteCount: 64, symlinkPolicy: .reject)
        }
    }

    @Test func rejectsFIFOWithoutBlocking() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("input.json")
        #expect(fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: BoundedRegularFileReader.ReadError.notRegularFile) {
            try BoundedRegularFileReader.read(at: fifo, maximumByteCount: 64)
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func rejectsOversizedFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input.json")
        try Data(repeating: 0x20, count: 65).write(to: file)

        #expect(
            throws: BoundedRegularFileReader.ReadError.tooLarge(maximumByteCount: 64)
        ) {
            try BoundedRegularFileReader.read(at: file, maximumByteCount: 64)
        }
    }

    @Test func identifiesMissingFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.json")

        do {
            _ = try BoundedRegularFileReader.read(at: missing, maximumByteCount: 64)
            Issue.record("Expected the read to fail")
        } catch {
            #expect(BoundedRegularFileReader.isMissingFileError(error))
        }
    }

    @Test func anchoredDirectoryRejectsSymbolicLinkRoot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let link = directory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: BoundedRegularFileReader.ReadError.self) {
            _ = try BoundedRegularFileReader.AnchoredDirectory(opening: link)
        }
    }

    @Test func anchoredUnlinkKeepsFileChangedAfterInspection() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("event.json")
        try Data("old".utf8).write(to: fileURL)

        let anchored = try BoundedRegularFileReader.AnchoredDirectory(opening: directory)
        let entry = try anchored.entry(named: "event.json")
        // This truncates and updates the same inode. Identity-only checks would
        // remove the new bytes even though they were never parsed.
        try Data("replacement".utf8).write(to: fileURL)

        #expect(!anchored.unlinkEntry(named: "event.json", ifUnchangedSince: entry))
        #expect(try Data(contentsOf: fileURL) == Data("replacement".utf8))
    }

}
