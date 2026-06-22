---
name: Claude Meter — macOS Menu Bar Design System
colors:
  # Dark glassmorphism base — matches macOS dark wallpapers
  surface-glass: "rgba(16, 19, 27, 0.72)" # popover background tint
  surface-dim: "#10131b"
  surface-container-low: "#181c23"
  surface-container: "#1c2028"
  surface-container-high: "#272a32"
  surface-container-highest: "#31353d"
  on-surface: "#e0e2ed"
  on-surface-variant: "#c1c6d7"
  on-surface-muted: "#8b90a0"
  outline: "#414755"
  outline-subtle: "rgba(255,255,255,0.08)" # glass edge stroke
  # Severity — mirrors macOS traffic lights for cognitive familiarity
  normal: "#4be257" # green — under warning
  warning: "#fdbb2c" # yellow — 80–94%
  critical: "#ff5f56" # red — ≥ 95%
  # Primary accent
  primary: "#adc6ff" # system blue proxy
  on-primary: "#002e69"
  # Semantic
  error: "#ff5f56"
  error-container: "#93000a"
  stale: "#8b90a0" # muted for stale/unknown state
---

## Brand & Style

Claude Meter lives in the macOS menu bar. Its UI is compact, glanceable, and unobtrusive. The personality is **utilitarian and calm by default, urgent only when limits are near**.

The visual language is **dark glassmorphism**: a semi-transparent, blurred backdrop that lets the user's wallpaper show through, making the widget feel like a native overlay rather than an opaque app. When severity rises, color intensity increases — a green progress glow becomes yellow, then red — providing urgency without alarm spam.

The app never appears in the Dock. Its entire visual footprint is the status bar label and the popover.

---

## SwiftUI Material Approach

Do not use CSS concepts. All materials map to SwiftUI equivalents:

| Design concept         | SwiftUI implementation                                                            |
| ---------------------- | --------------------------------------------------------------------------------- |
| Glass backdrop         | `.background(.ultraThinMaterial)`                                                 |
| Inner glow border      | `.overlay(RoundedRectangle(...).stroke(Color.white.opacity(0.10), lineWidth: 1))` |
| Lift shadow            | `.shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)`                     |
| Dim tint over material | `Color(hex: "10131b").opacity(0.45)` overlay                                      |
| Surface container      | `Color(hex: "1c2028")` or `.background(.thinMaterial)`                            |

The popover background is `ZStack` layered:

1. `.ultraThinMaterial` (provides the system blur).
2. A `Color(hex: "10131b").opacity(0.45)` rectangle overlay for additional darkening.
3. A 1px white/10% inner stroke via `.overlay`.

---

## Colors

### Palette in SwiftUI

```swift
extension Color {
    static let meterSurface       = Color(hex: "10131b")
    static let meterContainer     = Color(hex: "1c2028")
    static let meterContainerHigh = Color(hex: "272a32")
    static let meterOnSurface     = Color(hex: "e0e2ed")
    static let meterOnVariant     = Color(hex: "c1c6d7")
    static let meterMuted         = Color(hex: "8b90a0")
    static let meterOutline       = Color(hex: "414755")

    static let severityNormal   = Color(hex: "4be257")   // green
    static let severityWarning  = Color(hex: "fdbb2c")   // yellow
    static let severityCritical = Color(hex: "ff5f56")   // red
    static let severityStale    = Color(hex: "8b90a0")   // muted gray

    static let accentPrimary    = Color(hex: "adc6ff")   // soft blue
}
```

### Usage rules

- **Progress fill**: use severity color. Normal → green, warning → yellow, critical → red.
- **Progress track**: `Color.white.opacity(0.10)`.
- **Progress glow**: `.shadow(color: severityColor.opacity(0.5), radius: 4)` on the fill capsule.
- **Percentage text**: always `meterOnSurface` — never use color alone to convey severity.
- **Icon/badge tint**: match severity color (yellow or red overlay on the menu bar icon).
- **Stale state**: desaturate — use `meterMuted` for all text and progress.

---

## Typography

All SwiftUI font references. No web fonts needed — use SF Pro (system default) plus SF Mono for numbers.

| Role        | SwiftUI                                                   | Use                               |
| ----------- | --------------------------------------------------------- | --------------------------------- |
| Hero metric | `.system(size: 28, weight: .semibold, design: .rounded)`  | Large percentage in expanded view |
| Metric      | `.system(size: 20, weight: .semibold, design: .rounded)`  | Section percentages               |
| Label       | `.system(size: 13, weight: .semibold)`                    | Section headers (SESSION, WEEK)   |
| Body        | `.system(size: 13, weight: .regular)`                     | Reset time, model name            |
| Caption     | `.system(size: 11, weight: .regular)`                     | Footer: "Updated 14s ago"         |
| Mono number | `.system(size: 13, weight: .medium, design: .monospaced)` | Percentage, countdown             |

**Rule:** All numeric values that change over time (percentages, countdowns) must use `.monospacedDigit()` or `design: .monospaced` to prevent layout jitter.

---

## Popover Layout

### Dimensions

| Property      | Value                            |
| ------------- | -------------------------------- |
| Width         | 320 pt (fixed)                   |
| Height        | Dynamic, min 220 pt, max ~480 pt |
| Corner radius | 16 pt (squircle-adjacent)        |
| Padding       | 16 pt on all sides               |

### Anatomy

```
┌────────────────────────────────────┐
│ [◉] Claude Meter     [⚙]  [↻]      │  ← Header (H: 44pt)
│                                    │
│  SESSION                           │  ← Section label (uppercase, caption)
│  ████████████░░░░░░░░  25%         │  ← Progress bar (H: 4pt) + mono pct
│  Resets 2:50 PM                    │  ← Reset time (body)
│                                    │
│  WEEK (ALL MODELS)                 │
│  ███████████████░░░░░  30%         │
│  Resets Jun 27, 3:00 PM            │
│                                    │
│ ┌──────────────────────────────┐   │  ← Detail card (surface-container)
│ │ Model    claude-opus-4-8     │   │
│ │ Session  Implement fraud…    │   │  ← hidden in minimal/anon modes
│ │ MCP      8 connected         │   │
│ └──────────────────────────────┘   │
│                                    │
│  Updated 14s ago       [Refresh]   │  ← Footer
└────────────────────────────────────┘
```

### Spacing

| Gap                          | Size  |
| ---------------------------- | ----- |
| Header ↔ first section       | 12 pt |
| Section label ↔ progress bar | 6 pt  |
| Progress bar ↔ reset time    | 4 pt  |
| Section ↔ next section       | 16 pt |
| Last section ↔ detail card   | 12 pt |
| Detail card ↔ footer         | 12 pt |

### Header

- Left: colored status dot (`Circle`, 8 pt diameter) + "Claude Meter" in `.headline`.
- Right: gear icon (settings) + refresh icon, both `Image(systemName:)`, 20 pt tap targets.
- No separator line — use spacing.

### Progress bar

```swift
// Track
Capsule()
    .fill(Color.white.opacity(0.10))
    .frame(height: 4)

// Fill overlay
Capsule()
    .fill(severityColor)
    .frame(width: trackWidth * clampedFraction, height: 4)
    .shadow(color: severityColor.opacity(0.6), radius: 4, x: 0, y: 0)
```

Percentage label: right-aligned, `.monospacedDigit()`, same row as section label.

### Detail card

`RoundedRectangle(cornerRadius: 10)` filled with `meterContainerHigh`.
Rows: left label (`meterMuted`, caption weight) + right value (`meterOnSurface`, body).
1 pt separator `meterOutline` between rows, except last.

### Footer

Two-column layout:

- Left: "Updated Xs ago" — caption, `meterMuted`, auto-refreshes every second.
- Right: "Refresh" button — `.buttonStyle(.borderless)`, `accentPrimary` color.

---

## Menu Bar Icon

### States

| State    | Label example | Tint              |
| -------- | ------------- | ----------------- |
| Normal   | `25%/30%`     | Default (no tint) |
| Warning  | `84%/30%`     | Yellow dot prefix |
| Critical | `96%/30%`     | Red dot prefix    |
| Stale    | `~25%`        | Muted gray        |
| Loading  | Spinner       | —                 |
| Error    | `!`           | Red               |

Use `NSStatusItem.button.image` with a template image for dark/light mode auto-adaptation.
For the text label variant, use `NSStatusItem.button.title` with an `NSAttributedString` for color.

Prefer the text label over an icon-only approach since the primary info (percentage) is self-contained.

### Label format

- Normal: `25% / 30%` (session / week).
- High severity, close reset: `92% · 18m` (dominant percent + countdown).
- Max chars target: ≤ 12 characters to avoid crowding other status bar items.

---

## Severity States — Full Visual Reference

### Normal (< 80%)

- Status dot: `severityNormal` (green).
- Progress fills: green with green glow.
- All text: standard `meterOnSurface`.
- Footer: normal opacity.

### Warning (80–94%)

- Status dot: `severityWarning` (yellow).
- Affected progress fill: yellow with yellow glow.
- Percent label: bold yellow.
- Section label: unchanged.
- No red used.

### Critical (≥ 95%)

- Status dot: `severityCritical` (red), pulsing (`.easeInOut` opacity animation, 0.8–1.0, 1.5s repeat).
- Affected progress fill: red with red glow.
- Percent label: bold red.
- "Limit nearly reached" auxiliary text below reset time in caption.

### Stale (> 3 min since last poll)

- Status dot: `severityStale` (gray).
- Progress bars: 30% opacity.
- All text: `meterMuted`.
- Footer: prominently shows "Updated Xm ago".
- No severity glow.

### Error

- Status dot: red `!` symbol (SF Symbol `exclamationmark.circle.fill`).
- Body replaced with error description + recovery action button.
- No progress bars shown.

### Loading (initial)

- Status dot: animated `.progressViewStyle(.circular)` (size `.small`).
- Body: "Checking Claude…" in `meterMuted`.

---

## Shapes

| Element                 | Corner radius                          |
| ----------------------- | -------------------------------------- |
| Popover window          | 16 pt (matches `MenuBarExtra` default) |
| Detail card             | 10 pt                                  |
| Progress bar track/fill | capsule (full radius)                  |
| Buttons                 | 8 pt                                   |
| Status dot              | circle                                 |
| Notification badges     | circle                                 |

---

## Icons

Use SF Symbols exclusively (no custom assets needed for MVP):

| Meaning      | SF Symbol                       |
| ------------ | ------------------------------- |
| Settings     | `gearshape`                     |
| Refresh      | `arrow.clockwise`               |
| Warning      | `exclamationmark.triangle.fill` |
| Error        | `exclamationmark.circle.fill`   |
| OK / healthy | `checkmark.circle.fill`         |
| Model / AI   | `cpu` or `sparkles`             |
| Session      | `clock`                         |
| Week         | `calendar`                      |
| Stale        | `clock.badge.xmark`             |
| MCP          | `plug`                          |

All icons rendered as `.imageScale(.small)` inside the popover to maintain density.

---

## Animation

| Trigger                | Animation                                                          |
| ---------------------- | ------------------------------------------------------------------ |
| Progress value changes | `.animation(.easeOut(duration: 0.4), value: percent)` on bar width |
| Severity color changes | `.animation(.easeInOut(duration: 0.3), value: severity)`           |
| Critical pulse         | Repeating `.easeInOut(duration: 1.5)` opacity 0.8 → 1.0            |
| Popover appear         | Default `MenuBarExtra` transition (no custom needed)               |
| "Updated Xs ago"       | `withAnimation(.none)` — suppress jitter on counter tick           |

Keep animation subtle. The popover should feel snappy, not flashy.

---

## Settings Panel

Standard macOS `.settingsStyle(.pane)` or a custom sheet.
Sections styled as grouped `List` with `listStyle(.insetGrouped)`.
Use `LabeledContent` for each setting row.
Destructive actions (reset history, clear cache) use red tint and confirmation dialog.

---

## Onboarding

First-run sheet shown before any polling occurs:

1. Title: "Welcome to Claude Meter".
2. Single field: "Claude CLI path" (pre-filled with auto-detected path).
3. "Locate…" button opens file picker (`NSOpenPanel`).
4. "Test CLI" button runs a quick check and shows version or error inline.
5. "Get Started" button dismisses and starts polling.

No multi-step wizard for MVP. Keep it to one screen.

---

## Diagnostics View

Sheet or popover-within-popover (use a secondary `NavigationStack` or sheet from the gear button).

Layout:

- Monospaced text view for raw/sanitized output.
- Key-value rows for metadata (CLI path, last poll time, parser version).
- Two buttons at bottom: "Copy Diagnostics" and "Reveal Raw Output" (gated confirmation).

Background: `meterContainerHigh` for differentiation from main popover.

---

## Accessibility

1. Every `ProgressView` / custom bar: `.accessibilityValue("25 percent")` + `.accessibilityLabel("Session usage")`.
2. Combined VoiceOver announcement: `"Session usage 25 percent, resets at 2:50 PM. Weekly usage 30 percent, resets June 27 at 3 PM."`.
3. Severity state conveyed in `.accessibilityLabel` (not color only): `"Warning: session usage 84 percent"`.
4. All buttons have `.accessibilityLabel` with action description.
5. Minimum tap target: 28 × 28 pt for all interactive elements.
6. Support `.prefersDarkColorScheme` (popover is always dark; ensure text contrast ≥ 4.5:1).
7. Reduce motion: skip glow animation and pulse when `AccessibilityReduceMotion` is enabled.
