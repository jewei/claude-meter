import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("ModelPricing catalog matching")
struct ModelPricingCatalogTests {
    // A deliberately distinct sentinel (not the real Opus rate) so a catalog hit is
    // distinguishable from the static family fallback (which is also Opus $5).
    private let opusCatalog = ModelPricing.Rate(input: 7, output: 25, cacheRead: 0.5, cacheWrite: 6.25)

    @Test("Exact and dated-prefix ids hit the catalog; others fall back to family") func matching() {
        let catalog = ["claude-opus-4-5": opusCatalog]
        let pricing = ModelPricing.current.withCatalog(catalog)

        // Exact id → catalog rate (the sentinel 7, not the static family fallback 5).
        #expect(pricing.rate(forModel: "claude-opus-4-5").input == 7)
        // Dated transcript id → longest-prefix catalog hit.
        #expect(pricing.rate(forModel: "claude-opus-4-5-20251101").input == 7)
        // Unknown opus id with no catalog entry → static family fallback (Opus $5).
        #expect(pricing.rate(forModel: "claude-opus-3").input == 5)
        // Sonnet (not in catalog) → family fallback.
        #expect(pricing.rate(forModel: "claude-sonnet-4-5").input == 3)
    }

    @Test("Prefix must end on a hyphen boundary") func prefixBoundary() {
        let r = ModelPricing.Rate(input: 9, output: 9, cacheRead: 0, cacheWrite: 0)
        let pricing = ModelPricing.current.withCatalog(["claude-opus-4": r])
        // Boundary hit (next char is '-') → catalog rate.
        #expect(pricing.rate(forModel: "claude-opus-4-5").input == 9)
        // No boundary ("...-40") → must NOT match; falls back to opus family ($5).
        #expect(pricing.rate(forModel: "claude-opus-40").input == 5)
    }

    @Test("Longest matching prefix wins") func longestPrefix() {
        let four = ModelPricing.Rate(input: 9, output: 9, cacheRead: 0, cacheWrite: 0)
        let fourFive = ModelPricing.Rate(input: 5, output: 5, cacheRead: 0, cacheWrite: 0)
        let pricing = ModelPricing.current.withCatalog([
            "claude-opus-4": four, "claude-opus-4-5": fourFive,
        ])
        #expect(pricing.rate(forModel: "claude-opus-4-5-20251101").input == 5)
    }
}

@Suite("ModelsDevPricing parsing")
struct ModelsDevPricingTests {
    private let payload = """
        {
          "openai": {"models": {"gpt-x": {"cost": {"input": 1, "output": 2}}}},
          "anthropic": {"models": {
            "claude-opus-4-5": {"cost": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25}},
            "claude-sonnet-4-5": {"cost": {"input": 3, "output": 15, "cache_read": 0.3, "cache_write": 3.75}},
            "claude-haiku-4-5": {"cost": {"input": 1, "output": 5}},
            "claude-3-5-haiku": {"cost": {"input": 0.8, "output": 4}},
            "claude-3-opus": {"cost": {"input": 15, "output": 75}},
            "free-model": {"cost": {"input": 0, "output": 0}}
          }}
        }
        """

    @Test("Parses anthropic costs, drops zero-priced, requires opus+sonnet") func parse() throws {
        let data = try #require(payload.data(using: .utf8))
        let catalog = try #require(ModelsDevPricing.parseCatalog(from: data))
        #expect(catalog["claude-opus-4-5"]?.input == 5)
        #expect(catalog["claude-opus-4-5"]?.cacheWrite == 6.25)
        // cache fields default to 0 when absent.
        #expect(catalog["claude-haiku-4-5"]?.cacheRead == 0)
        // Zero-priced entries are dropped.
        #expect(catalog["free-model"] == nil)
    }

    @Test("Implausible payloads are rejected") func plausibility() throws {
        // Missing the anthropic provider entirely.
        let noAnthropic = try #require(#"{"openai":{"models":{}}}"#.data(using: .utf8))
        #expect(ModelsDevPricing.parseCatalog(from: noAnthropic) == nil)
        // Too few / no sonnet.
        #expect(!ModelsDevPricing.isPlausible(["claude-opus-4-5": .init(
            input: 5, output: 25, cacheRead: 0, cacheWrite: 0)]))
    }

    @Test("Merge keeps vanished ids, prefers fresh prices") func merge() {
        let old = ["a": ModelPricing.Rate(input: 1, output: 1, cacheRead: 0, cacheWrite: 0),
                   "gone": ModelPricing.Rate(input: 9, output: 9, cacheRead: 0, cacheWrite: 0)]
        let new = ["a": ModelPricing.Rate(input: 2, output: 2, cacheRead: 0, cacheWrite: 0)]
        let merged = ModelsDevPricing.merge(new: new, old: old)
        #expect(merged["a"]?.input == 2)
        #expect(merged["gone"]?.input == 9)
    }
}
