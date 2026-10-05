import Foundation
import Testing

@testable import MeterPlatform

@Suite struct ErrorTailTests {
    private func tail(_ text: String, limit: Int) -> ErrorTail {
        var tail = ErrorTail(limit: limit)
        tail.append(Data(text.utf8))
        return tail
    }

    @Test func keepsTheLastNonEmptyLineTrimmedAndRedacted() {
        #expect(
            tail("first\n  me@example.com failed \n\n", limit: 100).lastLine == "[redacted] failed")
        #expect(tail("\n \n", limit: 100).lastLine == nil)
        #expect(ErrorTail(limit: 100).lastLine == nil)
    }

    /// A cut inside a token keeps only its end, which no rule can find. That word goes.
    @Test func aWordThatTheCutSplitIsLeftOut() {
        let token = "sk-ant-oat01-" + String(repeating: "Q", count: 100)
        let line = tail("error: \(token) failed here", limit: 60).lastLine
        #expect(line == "failed here")
        #expect(tail("error: \(token)", limit: 60).lastLine == nil)
    }

    /// A cut at a space or a line break splits no word, so nothing is left out.
    @Test func aCutBetweenWordsKeepsTheFirstWord() {
        #expect(tail("aaaa bbbb cccc", limit: 9).lastLine == "bbbb cccc")
        #expect(tail("aaaa\nbbbb cccc", limit: 9).lastLine == "bbbb cccc")
        // Only the split word goes, and a later line is whole.
        #expect(tail("aaaa bbbb\ncccc", limit: 12).lastLine == "cccc")
        #expect(tail("aaaa bbbb\ncccc\n", limit: 9).lastLine == "cccc")
    }

    @Test func manyAppendsKeepTheLimit() {
        var tail = ErrorTail(limit: 10)
        for index in 0..<100 { tail.append(Data("line \(index)\n".utf8)) }
        #expect(tail.bytes.count == 10)
        #expect(tail.lastLine == "line 99")
    }
}
