import Foundation

/// Per-model token pricing used to estimate the dollar cost of local Claude Code
/// activity scanned from `~/.claude/projects`.
///
/// Prices are USD per **million tokens** and reflect Anthropic's published list
/// pricing. They are matched by model-family substring (`opus` / `haiku` / else
/// Sonnet) so new dated model ids (e.g. `claude-opus-4-8`) resolve without edits.
/// Estimates only — actual billing may differ (tiered cache, promos, plan caps).
public struct ModelPricing: Sendable {

    /// Rate card for one model family, USD per million tokens.
    public struct Rate: Sendable, Equatable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheWrite: Double

        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    private let opus: Rate
    private let sonnet: Rate
    private let haiku: Rate

    public init(opus: Rate, sonnet: Rate, haiku: Rate) {
        self.opus = opus
        self.sonnet = sonnet
        self.haiku = haiku
    }

    /// Current Anthropic list pricing (per MTok). Cache-write uses the 5-minute rate.
    public static let current = ModelPricing(
        opus: Rate(input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75),
        sonnet: Rate(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        haiku: Rate(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25)
    )

    /// Resolves the rate card for a model id by family substring.
    public func rate(forModel model: String) -> Rate {
        let lower = model.lowercased()
        if lower.contains("opus") { return opus }
        if lower.contains("haiku") { return haiku }
        return sonnet
    }

    /// Estimated USD cost for one model's token totals.
    public func cost(
        forModel model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> Double {
        let r = rate(forModel: model)
        let perToken = 1_000_000.0
        return Double(inputTokens) / perToken * r.input
            + Double(outputTokens) / perToken * r.output
            + Double(cacheReadTokens) / perToken * r.cacheRead
            + Double(cacheWriteTokens) / perToken * r.cacheWrite
    }
}
