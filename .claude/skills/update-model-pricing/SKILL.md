---
name: update-model-pricing
description: Update Claude Meter's per-model token pricing (ModelPricing.current) used to estimate local Claude Code cost. Use when the user wants to refresh Anthropic model prices, fix a wrong rate, or says "update model pricing".
---

# Update model pricing

Claude Meter estimates the dollar cost of local Claude Code usage from a hardcoded
rate card. This skill updates that rate card.

## The single source of truth

File: `ClaudeMeterCore/Sources/ClaudeMeterCore/ModelPricing.swift`
Static: `ModelPricing.current`

It holds three family `Rate`s, each in **USD per million tokens (MTok)** with four
fields: `input`, `output`, `cacheRead`, `cacheWrite` (cacheWrite = the 5-minute
cache-creation rate). Families are matched by substring: `opus`, `haiku`, else
`sonnet` (the default for any unrecognized id).

```swift
public static let current = ModelPricing(
    opus:   Rate(input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75),
    sonnet: Rate(input: 3,  output: 15, cacheRead: 0.30, cacheWrite: 3.75),
    haiku:  Rate(input: 1,  output: 5,  cacheRead: 0.10, cacheWrite: 1.25)
)
```

## Steps

1. **Get the prices.** If the user supplied them, use those. Otherwise look up
   Anthropic's current published pricing (e.g. https://www.anthropic.com/pricing or
   the docs pricing page) for Opus, Sonnet, and Haiku — input, output, prompt-cache
   **read**, and prompt-cache **write (5-minute)**, all per MTok. Confirm the numbers
   with the user before editing if you had to look them up.
2. **Edit `ModelPricing.current`** in the file above. Only change the numbers; keep
   the structure, comments, and the substring-matching logic intact.
3. **Update the tests if a changed number is asserted.** `ClaudeMeterCoreTests/CostUsageScannerTests.swift`
   (suite `ModelPricing`) asserts `haiku.input` and that an unknown model uses Sonnet
   `input`, and `computesCostPerMillionTokens` asserts the Sonnet `input` rate. Adjust
   those expectations to match new values.
4. **Verify:** `swift test --package-path ClaudeMeterCore` (all green) and
   `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
5. **Record it:** add a one-line entry under `## [Unreleased]` → `### Changed` in
   `CHANGELOG.md`, e.g. "Updated model pricing to Anthropic's <month/year> rates."

## Notes

- These are **list-price estimates**; batch/tiered discounts and promos aren't
  modeled. Don't over-engineer — a single rate per family is intentional.
- If a brand-new family appears (not opus/sonnet/haiku) and needs distinct pricing,
  that's a code change beyond this skill: add a `Rate` + a substring branch in
  `rate(forModel:)`. Flag it rather than forcing it into an existing family.
