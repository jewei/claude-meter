import Foundation
import MeterTestSupport
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

    @Test func keepsTheLastErrorLineRedacted() async throws {
        let script = """
            echo first >&2; echo 'token sk-ant-oat01-secret failed for me@example.com ' >&2
            echo >&2; exit 3
            """
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: [:])
        try process.start()
        for try await _ in process.lines {}
        await process.stop()
        #expect(process.lastErrorLine == "token [redacted] failed for [redacted]")
    }

    @Test func keepsOnlyTheEndOfALongErrorOutput() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 500 ]; do echo line $i >&2; i=$((i+1)); done"],
            environment: [:])
        try process.start()
        for try await _ in process.lines {}
        await process.stop()
        #expect(process.lastErrorLine == "line 499")
        #expect(LineProcess.errorTailBytes == 2_048)
    }

    @Test func aChildWithoutErrorOutputHasNoErrorLine() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        try process.start()
        await process.stop()
        #expect(process.lastErrorLine == nil)
    }

    @Test func stopEndsTheChildsOwnChildrenToo() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & echo $!; wait"], environment: [:])
        try process.start()
        #expect(getpgid(process.processIdentifier) == process.processIdentifier)
        var iterator = process.lines.makeAsyncIterator()
        let line = try #require(try await iterator.next())
        let grandchild = try #require(Int32(String(decoding: line, as: UTF8.self)))
        #expect(kill(grandchild, 0) == 0)
        await process.stop()
        #expect(await waitUntil { kill(grandchild, 0) != 0 })
    }

    @Test func stopFinishesTheLines() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:])
        try process.start()
        let reader = Task {
            var count = 0
            for try await _ in process.lines { count += 1 }
            return count
        }
        await process.stop()
        #expect(try await reader.value == 0)
    }

    @Test func readsALongLineInManyChunks() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a; echo; echo end"],
            environment: [:])
        try process.start()
        var lines: [Data] = []
        for try await line in process.lines {
            process.didConsume(line)
            lines.append(line)
        }
        await process.stop()
        #expect(lines.map(\.count) == [300_000, 3])
        #expect(lines.first?.allSatisfy { $0 == 0x61 } == true)
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
