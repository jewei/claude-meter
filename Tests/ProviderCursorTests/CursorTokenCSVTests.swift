import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

/// The usage export parser, without credentials or requests.
@Suite struct CursorTokenCSVTests {
    private static let header = CursorFixture.csvHeader

    private let calendar = Calendar.fixed("UTC")

    private func range() throws -> DateInterval {
        try #require(TokenPeriod.lastSevenDays.interval(at: .reference(), calendar: calendar))
    }

    private func parse(_ csv: String, maxRecords: Int = CursorTokenCSV.maxRecords) throws
        -> TokenHistory
    {
        try CursorTokenCSV.history(
            Data(csv.utf8), range: try range(), now: .reference(), calendar: calendar,
            maxRecords: maxRecords)
    }

    private func tokens(_ history: TokenHistory, _ period: TokenPeriod) -> Int64? {
        history.tokens(in: period, now: .reference(), calendar: calendar)
    }

    @Test func countsTheDisjointTokenColumnsWithoutPrices() throws {
        let history = try parse(
            """
            \(Self.header)
            2026-10-01T12:00:00.000Z,"unknown, model",2,10,"1,000",3,-
            """)
        #expect(tokens(history, .lastSevenDays) == 1015)
        #expect(history.hasRecords)
        #expect(!history.isPartial)
    }

    @Test func aHeaderOnlyExportIsZeroButAMalformedExportFails() throws {
        let empty = try parse(Self.header + "\r\n")
        #expect(tokens(empty, .lastSevenDays) == 0)
        for csv in ["", "Date,Cost\n2026-10-01,1", "\(Self.header)\n\"unterminated,1,2,3,4,5,6"] {
            #expect(throws: CursorFailure.unexpectedResponse) { try parse(csv) }
        }
    }

    @Test func badRowsMakeTheHistoryPartialAndTheEighthDayIsOutside() throws {
        let history = try parse(
            """
            \(Self.header)
            2026-10-04T10:00:00Z,m,1,1,1,2,0.1
            2026-10-03 08:00:00,m,8,,,,-
            2026-09-27T12:00:00Z,m,100,0,0,0,-
            2026-10-02T12:00:00Z,m,"1,00",0,0,0,-
            2026-10-02T12:00:00Z,m,1
            2026-10-04T13:00:00Z,m,7,0,0,0,-
            """)
        #expect(tokens(history, .today) == 5)
        #expect(tokens(history, .yesterday) == 8)
        #expect(tokens(history, .lastSevenDays) == 13)
        #expect(history.isPartial)
    }

    @Test func moreRowsThanTheCapMakeTheHistoryPartialInsteadOfFailing() throws {
        let rows = Array(repeating: "2026-10-04T10:00:00Z,m,1,0,0,0,-", count: 3)
        let history = try parse(([Self.header] + rows).joined(separator: "\n"), maxRecords: 2)
        #expect(tokens(history, .today) == 2)
        #expect(history.isPartial)
    }

    @Test func integersAcceptOnlyStrictThousandsGroups() {
        #expect(CursorTokenCSV.integer("1,000") == 1000)
        #expect(CursorTokenCSV.integer(" 12 ") == 12)
        #expect(CursorTokenCSV.integer("") == 0)
        for text in ["1,00", "1000,000", "-1", "1.5", "x", "99999999999999999999"] {
            #expect(CursorTokenCSV.integer(text) == nil)
        }
    }
}
