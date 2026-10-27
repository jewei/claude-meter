import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

/// How records carry cost through duplicates and the day tally.
@Suite struct HistoryCostTests {
    private func record(
        cost: String? = nil, unpriced: Int64 = 0, model: String? = nil
    ) -> TokenRecord {
        TokenRecord(
            date: .reference(), count: 100, cost: cost.flatMap { Decimal(string: $0) },
            unpricedTokens: unpriced, model: model)
    }

    /// On a full tie, pricing decides, so the kept record does not depend on read order.
    @Test(arguments: [
        ("priced wins", 0, 1), ("larger cost wins", 2, 3), ("fewer unpriced wins", 4, 5),
        ("no model first", 6, 7), ("smaller model wins", 8, 7),
    ])
    func tiesAreDecidedTheSameInBothOrders(name: String, winner: Int, loser: Int) {
        let records = [
            record(cost: "1"), record(), record(cost: "2"), record(cost: "1"),
            record(cost: "1", unpriced: 0), record(cost: "1", unpriced: 5),
            record(cost: "1", model: nil), record(cost: "1", model: "b"),
            record(cost: "1", model: "a"),
        ]
        for order in [[winner, loser], [loser, winner]] {
            var set = TokenRecordSet()
            for index in order { set.insert(records[index], key: "k") }
            #expect(set.records == [records[winner]], "\(name)")
        }
    }

    @Test func theTokenRuleStillComesFirst() {
        let bigger = TokenRecord(date: .reference(), count: 200)
        #expect(bigger.replaces(record(cost: "5")))
    }

    /// A record can have a priced part and an unpriced part; both add.
    @Test func theTallyAddsCostAndUnpricedTokensIndependently() throws {
        var tally = try TokenDayTally(now: .reference(), calendar: .fixed())
        tally.add(record(cost: "1.5", unpriced: 40, model: "m"))
        tally.add(record(cost: "0.5"))
        tally.add(record(unpriced: 100, model: "x"))
        // A zero-token record, such as Claude Code's `<synthetic>` lines, names no model.
        tally.add(
            TokenRecord(date: .reference(), count: 0, unpricedTokens: 0, model: "<synthetic>"))
        let history = tally.history
        let day = Calendar.fixed().startOfDay(for: .reference())
        #expect(history.dailyCost[day] == 2)
        #expect(history.dailyUnpricedTokens[day] == 140)
        #expect(history.unpricedModels == ["m", "x"])
    }
}
