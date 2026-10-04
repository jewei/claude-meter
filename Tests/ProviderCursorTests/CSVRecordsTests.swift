import Foundation
import Testing

@testable import ProviderCursor

/// The CSV reader under the usage export: RFC 4180 quoting with bounds on every row.
@Suite struct CSVRecordsTests {
    private func rows(_ text: String) throws -> [[String]] {
        try rows(Data(text.utf8))
    }

    private func rows(_ data: Data) throws -> [[String]] {
        var rows: [[String]] = []
        try CSVRecords.read(data) { row in
            rows.append(row)
            return true
        }
        return rows
    }

    @Test func everyKindOfLineBreakEndsARow() throws {
        #expect(
            try rows("a,b\rc,d\r\ne,f\ng,h") == [
                ["a", "b"], ["c", "d"], ["e", "f"], ["g", "h"],
            ])
    }

    @Test func aLeadingByteOrderMarkIsSkipped() throws {
        #expect(try rows(Data([0xEF, 0xBB, 0xBF]) + Data("a,b".utf8)) == [["a", "b"]])
    }

    @Test func quotedFieldsHoldCommasLineBreaksAndQuotes() throws {
        let text = "\"a,\r\nb\",\"say \"\"hi\"\"\",\"\"\nx,y"
        #expect(try rows(text) == [["a,\r\nb", "say \"hi\"", ""], ["x", "y"]])
    }

    @Test func blankLinesAreSkipped() throws {
        #expect(try rows("\n\na\r\n\r\n") == [["a"]])
    }

    @Test func fieldsAndRowsAtTheirLimitsAreAccepted() throws {
        let field = String(repeating: "x", count: CSVRecords.maxFieldBytes)
        #expect(try rows(field) == [[field]])
        let row = Array(repeating: "x", count: CSVRecords.maxFields)
        #expect(try rows(row.joined(separator: ",")) == [row])
    }

    @Test(arguments: [
        Data("\"a\"b".utf8), Data("a\"b".utf8), Data("\"unterminated".utf8),
        Data([0x61, 0xFF, 0x2C, 0x62]),
        Data(String(repeating: "x", count: CSVRecords.maxFieldBytes + 1).utf8),
        Data(Array(repeating: "x", count: CSVRecords.maxFields + 1).joined(separator: ",").utf8),
    ])
    func malformedInputThrows(data: Data) {
        #expect(throws: CSVRecords.MalformedError.self) { try rows(data) }
    }

    @Test func theConsumerCanStopTheRead() throws {
        var seen: [[String]] = []
        try CSVRecords.read(Data("a\nb\n\"broken".utf8)) { row in
            seen.append(row)
            return false
        }
        #expect(seen == [["a"]])
    }

    /// A `""` pair at bytes 65535 and 65536 steps over the first multiple of the cancellation
    /// interval. The check must still run in that block, not wait for the next multiple.
    @Test func cancellationIsCheckedWhenAQuotePairStepsOverTheInterval() async throws {
        let interval = CSVRecords.cancellationInterval
        var text = "a\n"
        let line = String(repeating: "x", count: 1_000) + "\n"
        while text.utf8.count + line.utf8.count <= interval - 6 { text += line }
        text += String(repeating: "x", count: interval - 6 - text.utf8.count - 1) + "\n"
        // The open quote is at 65530, and the pair at 65535 and 65536.
        text += "\"yyyy\"\"z\"\n"
        #expect(text.utf8.count < 2 * interval)
        let data = Data(text.utf8)
        let task = Task {
            try CSVRecords.read(data) { row in
                if row == ["a"] { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
