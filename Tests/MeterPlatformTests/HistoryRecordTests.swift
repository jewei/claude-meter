import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

/// Records, days, and lenient JSON fields.
@Suite struct HistoryRecordTests {
    @Test func theLargerCountThenTheEarlierDateWins() {
        let early = TokenRecord(date: .reference(), count: 10)
        let late = TokenRecord(date: .reference(60), count: 10)
        let larger = TokenRecord(date: .reference(-60), count: 11)
        #expect(early.replaces(late))
        #expect(!late.replaces(early))
        #expect(larger.replaces(early))
        #expect(!early.replaces(larger))
        #expect(!early.replaces(early))
    }

    @Test func aRecordSetDoesNotDependOnInsertionOrder() {
        let records = [
            TokenRecord(date: .reference(), count: 10), TokenRecord(date: .reference(5), count: 30),
            TokenRecord(date: .reference(-5), count: 30),
            TokenRecord(date: .reference(), count: 20),
        ]
        var forward = TokenRecordSet()
        var backward = TokenRecordSet()
        for record in records { forward.insert(record, key: "response") }
        for record in records.reversed() { backward.insert(record, key: "response") }
        #expect(forward == backward)
        #expect(forward.records == [TokenRecord(date: .reference(-5), count: 30)])

        var withoutKeys = TokenRecordSet()
        withoutKeys.insert(records[0], key: nil)
        withoutKeys.insert(records[0], key: nil)
        #expect(withoutKeys.count == 2)
        var union = forward
        union.formUnion(withoutKeys)
        #expect(union.count == 3)
    }

    @Test func sumsRejectMissingNegativeAndOverflowingCounts() {
        #expect(TokenRecord.sum([1, 2, 3]) == 6)
        #expect(TokenRecord.sum([1, nil]) == nil)
        #expect(TokenRecord.sum([-1]) == nil)
        #expect(TokenRecord.sum([Int64.max, 1]) == nil)
    }

    @Test func recordsGoToTheLocalDayOfTheCalendar() throws {
        // 02:00 UTC is the evening before in Los Angeles and the same morning in Tokyo.
        let record = TokenRecord(date: .reference(-.hours(10)), count: 5)
        for (zone, period) in [
            ("America/Los_Angeles", TokenPeriod.yesterday), ("Asia/Tokyo", .today),
        ] {
            let calendar = Calendar.fixed(zone)
            var tally = try TokenDayTally(now: .reference(), calendar: calendar)
            tally.hasRecords = true
            tally.add(record)
            let history = tally.history
            #expect(history.timeZoneID == zone)
            #expect(history.tokens(in: period, now: .reference(), calendar: calendar) == 5)
            #expect(history.tokens(in: .lastSevenDays, now: .reference(), calendar: calendar) == 5)
        }
    }

    @Test func theTallyCoversTodayAndSixDaysBefore() throws {
        let calendar = Calendar.fixed("UTC")
        var tally = try TokenDayTally(now: .reference(), calendar: calendar)
        #expect(tally.start == calendar.startOfDay(for: .reference(-.days(6))))
        tally.add(TokenRecord(date: tally.start.addingTimeInterval(-1), count: 1_000))
        tally.add(TokenRecord(date: tally.start, count: 1))
        #expect(!tally.isPartial)
        tally.add(TokenRecord(date: .reference(TokenDayTally.writeTolerance + 1), count: 50))
        #expect(tally.isPartial)
        #expect(tally.dailyTokens == [tally.start: 1])
    }

    @Test func aLineWrittenDuringTheReadWaitsForTheNextRead() throws {
        let calendar = Calendar.fixed("UTC")
        let written = TokenRecord(date: .reference(TokenDayTally.writeTolerance), count: 7)
        var tally = try TokenDayTally(now: .reference(), calendar: calendar)
        tally.add(TokenRecord(date: .reference(1), count: 3))
        tally.add(written)
        #expect(!tally.isPartial)
        #expect(tally.dailyTokens.isEmpty)

        // The next read starts after the lines were written, so it counts them.
        var next = try TokenDayTally(
            now: .reference(TokenDayTally.writeTolerance), calendar: calendar)
        next.add(TokenRecord(date: .reference(1), count: 3))
        next.add(written)
        #expect(!next.isPartial)
        #expect(next.dailyTokens.values.reduce(0, +) == 10)
    }

    @Test func anOverflowingDayMakesTheTallyPartial() throws {
        var tally = try TokenDayTally(now: .reference(), calendar: .fixed())
        tally.add(TokenRecord(date: .reference(), count: .max))
        tally.add(TokenRecord(date: .reference(), count: 1))
        #expect(tally.isPartial)
        #expect(tally.dailyTokens.values.first == .max)
    }

    @Test func anInvalidDateCannotStartATally() {
        #expect(throws: HistoryError.invalidDate) {
            try TokenDayTally(now: Date(timeIntervalSince1970: -1), calendar: .fixed())
        }
    }
}

@Suite struct HistoryJSONTests {
    private struct Fields: Decodable {
        let count: HistoryJSON.Count?
        let text: HistoryJSON.Text?
        let date: HistoryJSON.Timestamp?
        let number: HistoryJSON.Number?
    }

    private func decode(_ json: String) throws -> Fields {
        try JSONDecoder().decode(Fields.self, from: Data(json.utf8))
    }

    @Test(arguments: [
        (#"12"#, Int64?.some(12)), (#""12""#, 12), (#"0"#, 0), (#"1.0"#, 1), (#"1.5"#, nil),
        (#"-1"#, nil), (#"true"#, nil), (#""1e3""#, nil), (#""+5""#, nil), (#""""#, nil),
        (#"9223372036854775808"#, nil), (#"{}"#, nil),
    ])
    func counts(json: String, expected: Int64?) throws {
        let fields = try decode(#"{"count":\#(json)}"#)
        #expect(fields.count?.value == expected)
    }

    @Test func missingAndNullFieldsAreAbsent() throws {
        let fields = try decode(#"{"count":null}"#)
        #expect(fields.count == nil)
        #expect(fields.text == nil)
    }

    @Test func textMustBeANonEmptyShortString() throws {
        #expect(try decode(#"{"text":"id"}"#).text?.value == "id")
        #expect(try decode(#"{"text":""}"#).text?.value == nil)
        #expect(try decode(#"{"text":7}"#).text?.value == nil)
        let long = String(repeating: "x", count: HistoryJSON.Text.maxBytes + 1)
        #expect(try decode(#"{"text":"\#(long)"}"#).text?.value == nil)
    }

    @Test func timestampsAcceptISOSecondsAndMilliseconds() throws {
        let seconds = referenceDate.timeIntervalSince1970
        #expect(try decode(#"{"date":"2026-10-04T12:00:00Z"}"#).date?.date == referenceDate)
        #expect(try decode(#"{"date":"2026-10-04T12:00:00.123456Z"}"#).date?.date != nil)
        #expect(try decode(#"{"date":\#(Int(seconds))}"#).date?.date == referenceDate)
        #expect(try decode(#"{"date":\#(Int(seconds * 1000))}"#).date?.date == referenceDate)
        #expect(try decode(#"{"date":"\#(Int(seconds * 1000))"}"#).date?.date == referenceDate)
        #expect(try decode(#"{"date":true}"#).date?.date == nil)
        #expect(try decode(#"{"date":-1}"#).date?.date == nil)
    }

    @Test func numbersAcceptNumbersAndDecimalText() throws {
        #expect(try decode(#"{"number":1.5}"#).number?.value == 1.5)
        #expect(try decode(#"{"number":"2.5"}"#).number?.value == 2.5)
        #expect(try decode(#"{"number":false}"#).number?.value == nil)
    }
}
