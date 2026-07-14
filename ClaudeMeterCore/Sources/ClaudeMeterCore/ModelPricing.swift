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
    public struct Rate: Sendable, Equatable, Codable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        /// 5-minute-TTL cache-write rate (1.25× input on Anthropic's list).
        public let cacheWrite: Double
        /// 1-hour-TTL cache-write rate. `nil` derives the list convention (2× input)
        /// — models.dev only publishes the 5m rate, so catalog entries stay `nil`.
        public let cacheWrite1h: Double?

        public init(
            input: Double, output: Double, cacheRead: Double, cacheWrite: Double,
            cacheWrite1h: Double? = nil
        ) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.cacheWrite1h = cacheWrite1h
        }

        /// The 1h cache-write rate, deriving 2× input when not explicitly set.
        public var resolvedCacheWrite1h: Double { cacheWrite1h ?? input * 2 }
    }

    private let opus: Rate
    private let sonnet: Rate
    private let haiku: Rate
    private let fable: Rate
    /// Optional per-exact-model-id rate catalog (normalized lowercased ids), e.g.
    /// fetched live from models.dev. Takes precedence over family matching; the
    /// family rates remain the offline fallback. See `ModelsDevPricing`.
    private let catalog: [String: Rate]?

    public init(
        opus: Rate, sonnet: Rate, haiku: Rate,
        fable: Rate = Rate(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        catalog: [String: Rate]? = nil
    ) {
        self.opus = opus
        self.sonnet = sonnet
        self.haiku = haiku
        self.fable = fable
        self.catalog = catalog
    }

    /// Returns a copy carrying a per-model-id catalog (keeping the family rates as
    /// the fallback). Used to layer live models.dev pricing onto `.current`.
    public func withCatalog(_ catalog: [String: Rate]?) -> ModelPricing {
        ModelPricing(opus: opus, sonnet: sonnet, haiku: haiku, fable: fable, catalog: catalog)
    }

    /// Current Anthropic list pricing (per MTok), used as the offline fallback when
    /// the live models.dev `catalog` is absent. `cacheWrite` is the 5-minute rate
    /// (1.25× input); the 1-hour tier (2× input) is derived via
    /// `Rate.resolvedCacheWrite1h` — Claude Code now writes 1h caches for top-level
    /// sessions, with the tier split carried in the transcript's `cache_creation`
    /// breakdown. The full 1M context window is billed at these flat rates: no
    /// current model carries a >200K long-context premium.
    public static let current = ModelPricing(
        // Opus 4.5–4.8 list pricing (the prior $15/$75 was Opus 4.1-era and
        // over-estimated current Opus usage ~3× whenever the catalog didn't load).
        opus: Rate(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25),
        sonnet: Rate(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        haiku: Rate(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25)
    )

    /// Resolves the rate card for a model id: an exact (or dated-prefix) catalog
    /// hit wins; otherwise fall back to family substring matching.
    public func rate(forModel model: String) -> Rate {
        let lower = model.lowercased()
        if let catalog, let hit = Self.catalogRate(for: lower, in: catalog) { return hit }
        if lower.contains("opus") { return opus }
        if lower.contains("haiku") { return haiku }
        if lower.contains("fable") { return fable }
        return sonnet
    }

    /// Looks up `id` in a per-model-id catalog. Tries an exact match first, then
    /// the longest catalog key that is a prefix of `id` — so a dated transcript id
    /// (`claude-opus-4-5-20251101`) still resolves to the base entry
    /// (`claude-opus-4-5`).
    static func catalogRate(for id: String, in catalog: [String: Rate]) -> Rate? {
        if let exact = catalog[id] { return exact }
        var best: (key: String, rate: Rate)?
        for (key, rate) in catalog where !key.isEmpty && id.hasPrefix(key) {
            // Only accept a prefix that ends on a hyphen boundary, so `claude-opus-4`
            // can't match `claude-opus-40`; Anthropic ids are hyphen-delimited.
            let after = id.index(id.startIndex, offsetBy: key.count)
            guard after == id.endIndex || id[after] == "-" else { continue }
            if best == nil || key.count > best!.key.count { best = (key, rate) }
        }
        return best?.rate
    }

    /// Estimated USD cost for one model's token totals. `cacheWriteTokens` is the
    /// 5-minute tier; `cacheWrite1hTokens` bills at the 1-hour rate (2× input).
    public func cost(
        forModel model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cacheWrite1hTokens: Int = 0
    ) -> Double {
        let r = rate(forModel: model)
        let perToken = 1_000_000.0
        return Double(inputTokens) / perToken * r.input
            + Double(outputTokens) / perToken * r.output
            + Double(cacheReadTokens) / perToken * r.cacheRead
            + Double(cacheWriteTokens) / perToken * r.cacheWrite
            + Double(cacheWrite1hTokens) / perToken * r.resolvedCacheWrite1h
    }
}
