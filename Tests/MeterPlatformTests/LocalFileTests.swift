import Darwin
import Foundation
import MeterPlatform
import MeterTestSupport
import Testing

@Suite struct LocalFileTests {
    @Test func readsARegularFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = try directory.write("hello", to: "auth.json")
        #expect(try LocalFile.read(file, maxBytes: 100) == Data("hello".utf8))
        #expect(try LocalFile.read(file, maxBytes: 5) == Data("hello".utf8))
    }

    @Test func reportsMissingFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        #expect(throws: LocalFile.ReadError.notFound) {
            try LocalFile.read(directory.path("missing.json"), maxBytes: 100)
        }
    }

    @Test func rejectsLargeFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = try directory.write("123456", to: "big.json")
        #expect(throws: LocalFile.ReadError.tooLarge(limit: 5)) {
            try LocalFile.read(file, maxBytes: 5)
        }
    }

    @Test func rejectsAFIFOWithoutBlocking() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fifo = directory.path("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: LocalFile.ReadError.notRegularFile) {
            try LocalFile.read(fifo, maxBytes: 100)
        }
        #expect(!LocalFile.isRegularFile(fifo))
    }

    @Test func followsSymbolicLinks() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let target = try directory.write("linked", to: "target.json")
        let link = directory.path("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try LocalFile.read(link, maxBytes: 100) == Data("linked".utf8))
    }

    @Test func readsARangeOfAnOpenFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = try directory.write("0123456789", to: "log.jsonl")
        let descriptor = open(file.path, O_RDONLY)
        defer { close(descriptor) }
        #expect(try LocalFile.read(descriptor, from: 3, count: 4) == Data("3456".utf8))
        #expect(try LocalFile.read(descriptor, from: 8, count: 10) == Data("89".utf8))
    }
}
