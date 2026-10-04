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

    @Test func reportsLaunchFailures() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/nonexistent/codex"), arguments: [], environment: [:])
        #expect(throws: LineProcess.ProcessError.self) { try process.start() }
        var iterator = process.lines.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("The lines did not fail.")
        } catch let error as LineProcess.ProcessError {
            guard case .launchFailed = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        }
        #expect(throws: LineProcess.ProcessError.notRunning) { try process.send(Data("x".utf8)) }
        try await expectReturnsQuickly { await process.stop() }
    }

    @Test func stopBeforeStartReturns() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:])
        try await expectReturnsQuickly { await process.stop() }
        try await expectReturnsQuickly { await process.stop() }
    }

    @Test func sendAfterStopThrows() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        try process.start()
        await process.stop()
        #expect(throws: LineProcess.ProcessError.notRunning) { try process.send(Data("late".utf8)) }
    }

    @Test func aWriteToAClosedPipeThrowsInsteadOfSignaling() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec 0<&-; sleep 5"],
            environment: [:])
        try process.start()
        try await Task.sleep(for: .milliseconds(200))
        // Without F_SETNOSIGPIPE this write would kill the test process with SIGPIPE.
        #expect(throws: LineProcess.ProcessError.notRunning) { try process.send(Data("x".utf8)) }
        await process.stop()
    }

    @Test func aChildThatStopsReadingCannotBlockTheWriter() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:])
        try process.start()
        let line = Data(repeating: 0x61, count: 64 * 1024)
        try await expectReturnsQuickly {
            #expect(throws: LineProcess.ProcessError.inputBlocked) {
                for _ in 0..<64 { try process.send(line) }
            }
        }
        await process.stop()
    }

    @Test func joinsALineSplitAcrossWritesAndFinishesAtEndOfFile() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'fir'; sleep 0.1; printf 'st\\nsecond\\n'"], environment: [:])
        try process.start()
        var lines: [String] = []
        for try await line in process.lines {
            process.didConsume(line)
            lines.append(String(decoding: line, as: UTF8.self))
        }
        #expect(lines == ["first", "second"])
        await process.stop()
    }

    @Test func limitsTheUnreadBacklogUntilLinesAreConsumed() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:],
            maxLineBytes: 8, maxBacklogBytes: 10)
        try process.start()
        var iterator = process.lines.makeAsyncIterator()
        try process.send(Data("12345".utf8))
        let first = try #require(try await iterator.next())
        process.didConsume(first)
        try process.send(Data("12345".utf8))
        try process.send(Data("67890".utf8))
        _ = try await iterator.next()
        _ = try await iterator.next()
        // 10 unread bytes are within the limit; one more line is not.
        try process.send(Data("x".utf8))
        await #expect(throws: LineProcess.ProcessError.backlogTooLarge(limit: 10)) {
            _ = try await iterator.next()
        }
        await process.stop()
    }

    private func expectReturnsQuickly(
        _ work: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await work()
        #expect(clock.now - start < .seconds(1), sourceLocation: sourceLocation)
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
