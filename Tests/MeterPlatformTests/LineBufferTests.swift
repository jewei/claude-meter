import Foundation
import Testing

@testable import MeterPlatform

@Suite struct LineBufferTests {
    private func lines(_ result: Result<[Data], LineProcess.ProcessError>) -> [String]? {
        guard case .success(let lines) = result else { return nil }
        return lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func splitsChunksAndJoinsALineAcrossThem() {
        var buffer = LineBuffer(maxLineBytes: 100, maxBacklogBytes: 100)
        #expect(lines(buffer.receive(Data("one\ntw".utf8))) == ["one"])
        #expect(lines(buffer.receive(Data("o\n\nthree\nfo".utf8))) == ["two", "", "three"])
        #expect(lines(buffer.receive(Data("ur\n".utf8))) == ["four"])
        // Each line counts with its newline: 4 + 4 + 1 + 6 + 5.
        #expect(buffer.backlogBytes == 20)
    }

    /// Empty lines fill the backlog too, so a child that writes only newlines is stopped.
    @Test func emptyLinesCountAgainstTheBacklog() {
        var buffer = LineBuffer(maxLineBytes: 100, maxBacklogBytes: 50)
        #expect(lines(buffer.receive(Data(repeating: 0x0A, count: 50)))?.count == 50)
        #expect(
            buffer.receive(Data([0x0A])).isFailure(.backlogTooLarge(limit: 50)))
    }

    @Test func consumedLinesFreeTheirBacklogWithTheNewline() {
        var buffer = LineBuffer(maxLineBytes: 100, maxBacklogBytes: 12)
        let first = lines(buffer.receive(Data("12345\n67890\n".utf8)))
        #expect(first == ["12345", "67890"])
        buffer.consume(Data("12345".utf8))
        #expect(buffer.backlogBytes == 6)
        #expect(lines(buffer.receive(Data("abcde\n".utf8))) == ["abcde"])
        #expect(buffer.receive(Data("x\n".utf8)).isFailure(.backlogTooLarge(limit: 12)))
    }

    @Test func aLongLineFailsWhetherItEndedOrNot() {
        var ended = LineBuffer(maxLineBytes: 4, maxBacklogBytes: 100)
        #expect(ended.receive(Data("12345\n".utf8)).isFailure(.lineTooLong(limit: 4)))
        var open = LineBuffer(maxLineBytes: 4, maxBacklogBytes: 100)
        #expect(lines(open.receive(Data("1234".utf8))) == [])
        #expect(open.receive(Data("5".utf8)).isFailure(.lineTooLong(limit: 4)))
    }

    /// 200,000 lines in one chunk: one pass, not one copy of the buffer for each line.
    @Test func manyShortLinesInOneChunk() {
        var buffer = LineBuffer(maxLineBytes: 100, maxBacklogBytes: 10_000_000)
        let chunk = Data(String(repeating: "ab\n", count: 200_000).utf8)
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = lines(buffer.receive(chunk))
        let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        #expect(result?.count == 200_000)
        #expect(result?.allSatisfy { $0 == "ab" } == true)
        #expect(elapsed < 2_000_000_000)
    }
}

extension Result where Success == [Data], Failure == LineProcess.ProcessError {
    fileprivate func isFailure(_ expected: LineProcess.ProcessError) -> Bool {
        guard case .failure(let error) = self else { return false }
        return error == expected
    }
}
