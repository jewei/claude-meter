import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

/// Cost estimates of Codex records (`docs/token-history.md`, "Cost estimate"). The rollout
/// helpers give every usage object cached input of half its input. Amounts are worked out by
/// hand from ``CodexPrices``: GPT-6 Astra is $10 input, $1 cached input, and $50 output per
/// million tokens.
@Suite struct CodexCostTests: CodexRolloutTesting {
    let calendar = Calendar.fixed("UTC")

    private func turn(_ id: String, model: String?) -> [String: Any] {
        var payload: [String: Any] = ["turn_id": id]
        payload["model"] = model
        return [
            "type": "turn_context", "timestamp": Date.reference(-1).ISO8601Format(),
            "payload": payload,
        ]
    }

    private func dollars(_ text: String) -> Decimal { Decimal(string: text) ?? -1 }

    private func read(_ lines: [[String: Any]], copies: [String] = ["sessions/a.jsonl"])
        async throws -> TokenHistory
    {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let log = try lines.map { try json($0) }.joined()
        for path in copies { try home.write(log, to: path) }
        return try await history(["home": home]).history(for: "home")
    }

    private func cost(_ history: TokenHistory) -> CostEstimate? {
        history.cost(in: .today, now: .reference(), calendar: calendar)
    }

    private func unpriced(_ history: TokenHistory) -> Int64? {
        history.unpricedTokens(in: .today, now: .reference(), calendar: calendar)
    }

    /// 500 uncached × $10 + 500 cached × $1 + 100 output × $50, per million tokens.
    @Test func oneResponseIsPricedAtItsTurnsModel() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: "gpt-6-astra"),
            event(total: (1_000, 100), last: (1_000, 100), id: "one"),
        ])
        #expect(cost(history) == CostEstimate(amount: dollars("0.0105"), isComplete: true))
    }

    /// GPT-6 Sol for the second turn: 500 × $2 + 500 × $0.20 + 100 × $10.
    @Test func eachTurnUsesItsOwnModel() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: "gpt-6-astra"),
            event(total: (1_000, 100), last: (1_000, 100), id: "one"),
            turn("t2", model: "gpt-6-sol"),
            event(total: (2_000, 200), last: (1_000, 100), id: "two"),
        ])
        #expect(cost(history)?.amount == dollars("0.0126"))
    }

    /// Growth seen only in cumulative counters can span turns of two models, so it counts
    /// without a price. The model has a price, so the note does not name it.
    @Test func cumulativeOnlyGrowthHasNoPrice() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: "gpt-6-astra"),
            event(total: (1_000, 100), last: nil, id: "one"),
        ])
        #expect(history.tokens(in: .today, now: .reference(), calendar: calendar) == 1_100)
        #expect(cost(history) == nil)
        #expect(unpriced(history) == 1_100)
        #expect(history.unpricedModels.isEmpty)
    }

    /// A session resumed in the same file restarts its counters; each response is priced
    /// once. 500 × $10 + 500 × $1 + 100 × $50, then 250 × $10 + 250 × $1 + 50 × $50.
    @Test func aResumeInTheSameFilePricesEachResponseOnce() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: "gpt-6-astra"),
            event(total: (1_000, 100), last: (1_000, 100), ordinal: 1, id: "one"),
            turn("t2", model: "gpt-6-astra"),
            event(total: (500, 50), last: (500, 50), ordinal: 2, id: "two"),
        ])
        #expect(history.tokens(in: .today, now: .reference(), calendar: calendar) == 1_650)
        #expect(cost(history)?.amount == dollars("0.01575"))
    }

    @Test func everyTableEntryHasPositiveRates() {
        for (model, price) in CodexPrices.table {
            for rates in [price.rates] + [price.longContext].compactMap({ $0 }) {
                #expect(rates.input > 0 && rates.cachedInput > 0 && rates.output > 0, "\(model)")
            }
        }
    }

    @Test func aTurnWithoutAModelHasNoPrice() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: nil),
            event(total: (1_000, 100), last: (1_000, 100), id: "one"),
        ])
        #expect(cost(history) == nil)
        #expect(unpriced(history) == 1_100)
        #expect(history.unpricedModels.isEmpty)
    }

    @Test func anUnknownModelIsNamed() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: "gpt-9"),
            event(total: (1_000, 100), last: (1_000, 100), id: "one"),
        ])
        #expect(history.unpricedModels == ["gpt-9"])
    }

    /// Cache writes have no price: the log does not say how long they last. 400 uncached ×
    /// $10 + 500 cached × $1 + 100 × $50, and 100 tokens without a price.
    @Test func cacheWritesAreUnpriced() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: "gpt-6-astra"),
            event(
                total: (1_000, 100), last: (1_000, 100), id: "one",
                extra: ["cache_write_input_tokens": 100]),
        ])
        #expect(cost(history) == CostEstimate(amount: dollars("0.0095"), isComplete: false))
        #expect(unpriced(history) == 100)
        #expect(history.unpricedModels.isEmpty)
    }

    /// A breakdown above the input leaves the input without a price; the output keeps its.
    @Test func cacheAboveInputLeavesTheInputUnpriced() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: "gpt-6-astra"),
            event(
                total: (1_000, 100), last: (1_000, 100), id: "one",
                extra: ["cached_input_tokens": 1_200]),
        ])
        #expect(cost(history) == CostEstimate(amount: dollars("0.005"), isComplete: false))
        #expect(unpriced(history) == 1_000)
        #expect(history.tokens(in: .today, now: .reference(), calendar: calendar) == 1_100)
    }

    /// More than 272,000 input tokens: $20 input, $2 cached, $75 output.
    @Test func longRequestsUseTheLongContextRate() async throws {
        let history = try await read([
            metadata("s"), turn("t1", model: "gpt-6-astra"),
            event(total: (300_000, 100), last: (300_000, 100), id: "one"),
        ])
        #expect(cost(history)?.amount == dollars("3.3075"))
    }

    /// The archived copy of a session counts, and is priced, once.
    @Test func anArchivedCopyIsPricedOnce() async throws {
        let history = try await read(
            [
                metadata("s"), turn("t1", model: "gpt-6-astra"),
                event(total: (1_000, 100), last: (1_000, 100), id: "one"),
            ], copies: ["sessions/a.jsonl", "archived_sessions/a.jsonl"])
        #expect(cost(history)?.amount == dollars("0.0105"))
    }

    /// Copies match on token identity: two copies whose events differ only in the model of
    /// their turn still match, and the tokens count once, as before pricing.
    @Test func copiesWithAndWithoutModelLinesMatch() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let events = [
            event(total: (1_000, 100), last: (1_000, 100), id: "one"),
            event(total: (1_500, 150), last: (500, 50), id: "two"),
        ]
        let withModel = try ([metadata("s"), turn("t1", model: "gpt-6-astra")] + events)
            .map { try json($0) }.joined()
        let withoutModel = try ([metadata("s"), turn("t1", model: nil)] + events)
            .map { try json($0) }.joined()
        try home.write(withModel, to: "sessions/a.jsonl")
        try home.write(withoutModel, to: "archived_sessions/a.jsonl")
        let history = try await history(["home": home]).history(for: "home")
        #expect(history.tokens(in: .today, now: .reference(), calendar: calendar) == 1_650)
        #expect(!history.isPartial)
    }

    /// A fork counts, and prices, only its own events after the parent's history.
    @Test func aForkIsPricedOnce() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let parent = try json(
            metadata("parent"), turn("t1", model: "gpt-6-astra"),
            event(total: (1_000, 100), last: (1_000, 100), at: .reference(-30), id: "one"))
        let child = try json(
            metadata("child", parent: "parent"), turn("t1", model: "gpt-6-astra"),
            event(total: (1_000, 100), last: (1_000, 100), at: .reference(-30), id: "one"),
            turn("t2", model: "gpt-6-astra"),
            event(total: (2_000, 200), last: (1_000, 100), id: "two"))
        try home.write(parent, to: "sessions/parent.jsonl")
        try home.write(child, to: "sessions/child.jsonl")
        let history = try await history(["home": home]).history(for: "home")
        #expect(history.tokens(in: .today, now: .reference(), calendar: calendar) == 2_200)
        #expect(cost(history)?.amount == dollars("0.021"))
    }
}
