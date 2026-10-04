import Foundation
import Testing

@testable import MeterPlatform

@Suite struct LineProcessTests {
    @Test func exchangesLines() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:])
        try process.start()
        try process.send(Data("first".utf8))
        try process.send(Data("second".utf8))
        var iterator = process.lines.makeAsyncIterator()
        #expect(try await iterator.next() == Data("first".utf8))
        #expect(try await iterator.next() == Data("second".utf8))
        await process.stop()
    }

    @Test func rejectsLongLines() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:],
            maxLineBytes: 8)
        try process.start()
        try process.send(Data("123456789".utf8))
        var iterator = process.lines.makeAsyncIterator()
        await #expect(throws: LineProcess.ProcessError.lineTooLong(limit: 8)) {
            _ = try await iterator.next()
        }
        await process.stop()
    }

    @Test func killsAProcessThatIgnoresTerminate() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"], environment: [:])
        try process.start()
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        await process.stop()
        #expect(clock.now - start < .seconds(3))
        #expect(kill(process.processIdentifier, 0) != 0)
    }

    @Test func reportsLaunchFailures() {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/nonexistent/codex"), arguments: [], environment: [:])
        #expect(throws: LineProcess.ProcessError.self) { try process.start() }
    }

    @Test func sendAfterExitThrowsInsteadOfSignaling() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        try process.start()
        await process.stop()
        #expect(throws: (any Error).self) { try process.send(Data("late".utf8)) }
    }
}

@Suite struct LogFileTests {
    @Test func createsPrivateFilesAndDeletesThemWhenDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeMeterLogs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LogFile(directory: directory)
        file.setEnabled(true)
        file.append("line one")
        file.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.current.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
        #expect(try String(contentsOf: file.current, encoding: .utf8).contains("line one"))

        file.setEnabled(false)
        file.flush()
        #expect(!FileManager.default.fileExists(atPath: file.current.path))
    }

    @Test func rotatesOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeMeterLogs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LogFile(directory: directory, rotationBytes: 64)
        file.setEnabled(true)
        for index in 0..<10 { file.append("entry number \(index) with padding") }
        file.flush()
        #expect(FileManager.default.fileExists(atPath: file.previous.path))
        let current = try Data(contentsOf: file.current)
        #expect(current.count < 128)
    }
}
