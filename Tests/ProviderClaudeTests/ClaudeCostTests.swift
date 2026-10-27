import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

/// Cost estimates of Claude Code records at API list prices (`docs/token-history.md`, "Cost
/// estimate"). Amounts are worked out by hand from the rates in ``ClaudePrices``.
@Suite struct ClaudeCostTests {
    private func line(
        id: String = "m", model: String? = "claude-opus-5-5", input: Int = 1_000,
        output: Int = 500, read: Int = 2_000, write: Int? = 400, split: (Int, Int)? = nil,
        speed: String? = nil
    ) throws -> Data {
        var usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read,
        ]
        usage["cache_creation_input_tokens"] = write
        if let split {
            usage["cache_creation"] = [
                "ephemeral_5m_input_tokens": split.0, "ephemeral_1h_input_tokens": split.1,
            ]
        }
        usage["speed"] = speed
        var message: [String: Any] = ["id": id, "usage": usage]
        message["model"] = model
        let object: [String: Any] = [
            "type": "assistant", "timestamp": Date.reference().ISO8601Format(), "requestId": "r",
            "message": message,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func records(_ lines: [Data]) -> [TokenRecord] {
        var parser = ClaudeHistoryParser()
        for (index, line) in lines.enumerated() {
            parser.append(line, offset: Int64(index), decoder: JSONDecoder())
        }
        return parser.records.records
    }

    private func record(_ line: Data) throws -> TokenRecord {
        try #require(records([line]).first)
    }

    private func dollars(_ text: String) -> Decimal { Decimal(string: text) ?? -1 }

    /// Opus 5.5: 1000 × $4 + 500 × $20 + 2000 × $0.20 + 400 × $5 (5-minute writes), per
    /// million tokens.
    @Test func everyPartHasItsRate() throws {
        let record = try record(try line())
        #expect(record.cost == dollars("0.0164"))
        #expect(record.unpricedTokens == 0)
        #expect(record.count == 3_900)
    }

    /// The split prices 1-hour writes at 2× input: 100 × $5 + 300 × $8.
    @Test func cacheWritesSplitByLifetime() throws {
        let record = try record(try line(write: 400, split: (100, 300)))
        #expect(record.cost == dollars("0.0173"))
    }

    @Test func fastModeDoublesTheOpusPrice() throws {
        #expect(try record(try line(speed: "fast")).cost == dollars("0.0328"))
        #expect(try record(try line(speed: "standard")).cost == dollars("0.0164"))
    }

    /// Sonnet 5.5 has no fast mode, so a fast record has no price. The model itself has a
    /// price, so the note does not name it.
    @Test func fastModeWithoutAMultiplierHasNoPrice() throws {
        let record = try record(try line(model: "claude-sonnet-5-5", speed: "fast"))
        #expect(record.cost == nil)
        #expect(record.unpricedTokens == 3_900)
        #expect(record.unpricedModel == nil)
    }

    /// Only a model that is not in the table is named in the price note.
    @Test func anUnknownModelIsNamed() throws {
        let record = try record(try line(model: "claude-opus-9"))
        #expect(record.cost == nil)
        #expect(record.unpricedModel == "claude-opus-9")
        #expect(try self.record(try line()).unpricedModel == nil)
    }

    /// Haiku 5.5 pays higher rates when the prompt (input plus cache) is over 100,000 tokens.
    @Test func haikuLongPromptsPayMore() throws {
        let border = try record(
            try line(
                model: "claude-haiku-5-5", input: 60_000, output: 1_000, read: 40_000, write: 0))
        #expect(border.cost == dollars("0.0069"))
        let over = try record(
            try line(
                model: "claude-haiku-5-5", input: 60_001, output: 1_000, read: 40_000, write: 0))
        #expect(over.cost == dollars("0.0345005"))
    }

    @Test(arguments: [
        ("claude-opus-5-5", true), ("Claude-Opus-5-5-20261001", true),
        ("anthropic/claude-opus-5-5", true), ("claude-opus-9", false), ("opus", false),
    ])
    func modelNamesMatchExactlyAfterNormalizing(model: String, isPriced: Bool) {
        #expect((ClaudePrices.price(for: model) != nil) == isPriced)
    }

    @Test func everyTableEntryHasPositiveRates() {
        for (model, price) in ClaudePrices.table {
            for rates in [price.rates] + [price.longContext].compactMap({ $0 }) {
                #expect(rates.input > 0 && rates.read > 0 && rates.output > 0, "\(model)")
                #expect(rates.fiveMinuteWrite == rates.input * 5 / 4, "\(model)")
                #expect(rates.oneHourWrite == rates.input * 2, "\(model)")
            }
        }
    }

    @Test func aRecordWithoutAModelHasNoPrice() throws {
        let record = try record(try line(model: nil))
        #expect(record.cost == nil)
        #expect(record.unpricedTokens == record.count)
        #expect(record.unpricedModel == nil)
    }

    /// Claude Code writes `<synthetic>` lines with zero usage. They add nothing unpriced.
    @Test func aSyntheticZeroLineAddsNoUnpricedTokens() throws {
        let record = try record(
            try line(model: "<synthetic>", input: 0, output: 0, read: 0, write: 0))
        #expect(record.count == 0)
        #expect(record.unpricedTokens == 0)
    }

    /// The streamed lines of one response keep one record, priced from the winning line.
    @Test func aStreamedResponseIsPricedOnce() throws {
        let kept = records([try line(input: 500), try line(input: 1_000)])
        #expect(kept.count == 1)
        #expect(kept.first?.cost == dollars("0.0164"))
    }
}
