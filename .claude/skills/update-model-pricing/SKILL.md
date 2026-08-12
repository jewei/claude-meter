---
name: update-model-pricing
description: Update Claude Meter's live models.dev catalog mapping or offline Anthropic family price fallbacks. Use when model token prices, cache tiers, family matching, or local cost estimates need correction.
---

# Update model pricing

Maintain accurate local Claude Code cost estimates without turning a catalog refresh
into a wire-format or billing-policy rewrite.

## Sources of truth

- `ClaudeMeterCore/Sources/ClaudeMeterProviders/ModelsDevPricing.swift` fetches and
  caches the live `models.dev` Anthropic catalog.
- `ClaudeMeterCore/Sources/ClaudeMeterProviders/ModelPricing.swift` defines offline
  family fallbacks and exact-model catalog precedence.
- `ClaudeMeterCore/Tests/ClaudeMeterProvidersTests/CostUsageScannerTests.swift` and
  `ModelsDevPricingTests.swift` cover price selection and cost calculation.

Rates are USD per million tokens. `Rate.cacheWrite` is the five-minute cache-write
rate. `resolvedCacheWrite1h` uses an explicit one-hour rate when supplied, otherwise
derives the one-hour rate as 2× input. Cache reads and 5-minute/1-hour writes remain
separate token fields; never merge the tiers.

## Workflow

1. Inspect current provider documentation and `models.dev/api.json`. Prefer current
   primary-source Anthropic pricing when correcting fallback rates.
2. Determine whether the change belongs in catalog decoding, exact-model data, family
   fallback (`opus`, `sonnet`, `haiku`, `fable`), or substring matching. Keep catalog
   entries ahead of family matching and Sonnet as the unknown-model fallback.
3. Edit the smallest relevant provider file. Preserve list-price semantics; do not add
   batch, promotional, or account-specific discounts without a product requirement.
4. Add or update fixtures for every changed rate, model family, or cache tier. Assert
   both rate selection and a representative calculated total.
5. Add a concise `CHANGELOG.md` entry under Unreleased when behavior or estimates change.
6. Run `./scripts/verify-local.sh`.

If a new provider payload cannot express a required price tier, report that schema gap
explicitly instead of silently folding it into another tier.
