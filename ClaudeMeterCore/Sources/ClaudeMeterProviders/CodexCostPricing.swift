import Foundation

/// Public API price estimates, not ChatGPT subscription charges. Rates verified
/// on 2026-09-13 against developers.openai.com/api/docs/pricing and model pages.
public enum CodexCostPricing {
    public struct Estimate: Sendable, Equatable {
        public let costUsd: Double
        public let usesStandardTierAssumption: Bool
    }

    public static func normalizedModel(_ raw: String) -> String {
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if model.hasPrefix("openai/") { model.removeFirst("openai/".count) }
        if model == "gpt-5.6" { return "gpt-5.6-sol" }
        for base in ["gpt-6-astra", "gpt-5.6-sol"] {
            if model == base { return base }
            if model.hasPrefix(base + "-") {
                let suffix = String(model.dropFirst(base.count + 1))
                if suffix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                    return base
                }
            }
        }
        return model
    }

    /// Input includes cache reads and writes. Reasoning is already in output.
    /// Call once per exact request, before aggregation across days or models.
    public static func estimate(
        model: String, inputTokens: Int, cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0, outputTokens: Int,
        serviceTier: String? = nil
    ) -> Estimate? {
        guard inputTokens >= 0, outputTokens >= 0, cachedInputTokens >= 0,
            cacheWriteInputTokens >= 0, cachedInputTokens <= inputTokens,
            cacheWriteInputTokens <= inputTokens - cachedInputTokens
        else { return nil }
        let rates: (input: Double, read: Double, write: Double, output: Double)
        switch normalizedModel(model) {
        case "gpt-6-astra": rates = (10, 1, 12.5, 50)
        case "gpt-5.6-sol": rates = (4, 0.4, 5, 20)
        default: return nil
        }
        let tier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let multiplier: Double
        switch tier {
        case nil, "", "default", "standard": multiplier = 1
        case "priority", "fast": multiplier = 2
        default: return nil
        }
        let longInput = inputTokens > 272_000 ? 2.0 : 1.0
        let longOutput = inputTokens > 272_000 ? 1.5 : 1.0
        let uncached = inputTokens - cachedInputTokens - cacheWriteInputTokens
        let inputCost =
            Double(uncached) * rates.input
            + Double(cachedInputTokens) * rates.read
            + Double(cacheWriteInputTokens) * rates.write
        let cost =
            (inputCost * longInput + Double(outputTokens) * rates.output * longOutput)
            / 1_000_000 * multiplier
        guard cost.isFinite else { return nil }
        return Estimate(costUsd: cost, usesStandardTierAssumption: tier == nil || tier == "")
    }
}
