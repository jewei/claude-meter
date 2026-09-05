---
name: Claude Meter — macOS Menu Bar Design System
medium: SwiftUI (MenuBarExtra .window). Source of truth: Claude Usage Popup.dc.html (Claude Design handoff).
fonts:
  display: Fredoka # headings, numbers, avatars, plan badges (rounded, chunky). SF Rounded fallback.
  body: Nunito # labels, captions, body. System fallback.
colors-light:
  # Shell & surfaces
  popover-bg: "#FBF9F2" # warm cream
  popover-border: "#EFE9DA"
  card-bg: "#FFFFFF"
  card-border: "#EFEAD9" # sides/top 2px; BOTTOM 4px → the 3D "chunky" look
  hero-bg: "#EAF8E0" # pale green (healthy state)
  hero-border: "#CFEEB8"
  track: "#ECE9DD" # ring/bar unfilled track
  # Text
  ink: "#3A382F" # primary warm near-black
  ink-muted: "#908C7E" # emails, reset times, "left"
  label: "#A8A496" # uppercase section labels
  # Severity / energy (green=plenty left, orange=getting low, red=almost dry)
  energy-full: "#4FC51C" # green
  energy-full-shadow: "#3DA013" # raised-button drop shadow
  energy-low: "#FF9D0A" # orange
  energy-empty: "#FF5A5A" # red
  # Hero text by state
  hero-ink: "#2E7D12"
  hero-subink: "#5B7A3E"
  # Plan badges
  plan-max-fg: "#A24DEB"
  plan-max-bg: "#F2E6FF"
  plan-pro-fg: "#2E9E0E"
  plan-pro-bg: "#E7F8DC"
  plan-free-fg: "#8A8676"
  plan-free-bg: "#EFECE0"
colors-dark: # faithful warm-dark counterpart (the design ships light only; these are ours)
  popover-bg: "#201E18"
  popover-border: "#3A372E"
  card-bg: "#2A2820"
  card-border: "#3D3A30" # bottom border darker (#15140F) for the 3D sit
  hero-bg: "#22311A"
  hero-border: "#3C5A2A"
  track: "#3A372E"
  ink: "#ECE8DC"
  ink-muted: "#9A9588"
  label: "#7C786C"
  energy-full: "#62D62C"
  energy-low: "#FFAE33"
  energy-empty: "#FF6B6B"
  hero-ink: "#8FE25A"
  hero-subink: "#A6C98A"
  plan-max-fg: "#D9B3FF"
  plan-max-bg: "#3A2A50"
  plan-pro-fg: "#7FD65A"
  plan-pro-bg: "#23381A"
  plan-free-fg: "#B8B3A2"
  plan-free-bg: "#33312A"
radius: { popover: 22, card: 18, badge-pill: 999, avatar: 11, header-icon: 9, button: 14 }
---

## Brand & Personality

Claude Meter is a **playful, high-energy, Duolingo-flavored** menu-bar app. The mental model is a
**fuel/energy gauge**: every limit is framed as **energy remaining**, not consumption. You're
"cruising" when tanks are full and nudged to "touch grass" when one runs dry. The tone is
encouraging and a little cheeky; never scolding.

Visual language: **warm cream surfaces, bright candy greens/oranges/reds, fat rounded type,
circular activity rings, and "chunky 3D" cards** (a thick bottom border + inset highlight that make
elements look pressable, like game buttons). It should feel like a friendly companion in the menu
bar, not a dashboard.

The app never appears in the Dock. Its footprint is the status-bar item and the popover.

---

## The Energy Model (most important concept)

**Display everything as "% left" (energy remaining), even though the data layer stores `percentUsed`.**

```
percentLeft = 100 − resolvedWindow.percentUsed     // clamp 0…100
```

- Rings and bars **deplete**: the arc/fill length == `percentLeft`. Full ring = lots of energy.
- The big number is `percentLeft` followed by a muted " left".
- A just-reset rolling window reads **100% left** (it refilled), via `LimitWindow.resolved(asOf:)`.

**Severity stays driven by the existing, user-configurable `UsageThresholds` (percentUsed: warning
80, critical 95).** We do not invent new bands — keeping one source of truth means the menu-bar dot,
ring colors, hero state, and notifications always agree, and the user's threshold settings keep
working. Expressed as energy:

| Energy band | percentUsed      | percentLeft   | Color         | SF tone  |
| ----------- | ---------------- | ------------- | ------------- | -------- |
| Full        | `< warning` (80) | `> 20%`       | `energy-full` | green    |
| Low         | `80…<95`         | `5–20%`       | `energy-low`  | orange   |
| Empty       | `≥ 95`           | `≤ 5%`        | `energy-empty`| red      |
| Tapped out  | `≥ 100`          | `0%`          | `energy-empty`| red, "0" |
| Unknown     | nil              | —             | track gray    | —        |

The screenshot's sample colors imply orange earlier (~"half a tank"); that's illustrative sample
data. If the user wants a naggier gauge, they raise the orange band by lowering `warning` in
Settings — no code change.

### Energy phrases & mascot (Full Duolingo voice)

Per-window status line (left side, colored by band):

| Band       | 5-hour / weekly phrase examples                          |
| ---------- | -------------------------------------------------------- |
| Full       | "Tons of energy" · "Loads left" · "Full tank"            |
| Low        | "Half a tank" · "Getting low" · "Running on fumes soon"  |
| Empty      | "Almost dry — easy now" · "Tapped out"                    |

Hero state follows the selected main provider and account policy. An exact pin wins;
otherwise the nearest-limit account owns the hero, menu bar, widget, and quota alerts.
The subtitle may call out another low account from that provider:

| Overall | Emoji | Headline             | Subline pattern                                   | Hero colors |
| ------- | ----- | -------------------- | ------------------------------------------------- | ----------- |
| Full    | 🚀    | "You're cruising"    | Active account healthy; optionally flag a lower other account | green hero  |
| Low     | ⛽    | "Pace yourself"      | Active account is getting low and its refill phrase | orange hero |
| Empty   | 🪫    | "Almost tapped out"  | Active account is nearly dry and its refill phrase | red hero    |
| Tapped  | 🥵    | "Take a breather"    | Active account is out and its refill phrase | red hero    |

Single account collapses the subline to that account's own status ("Refills in 3h 12m").

### Pace reference

Pace is a neutral, display-only comparison between percent used and percent of the rolling
window elapsed. It never changes `EnergyBand`, severity, notifications, or threshold colors.

- Bar cards draw a 2pt `ink-muted` marker at the expected position. In usage mode that position
  is `percentTimeElapsed`; in energy-left mode it mirrors to `100 - percentTimeElapsed`.
- The bar status phrase becomes "On pace", "12% ahead of pace", or "12% behind pace" when the
  comparison is available.
- Ring cards keep their reset phrase and add the same neutral text below the primary 5-hour and
  weekly rows. Opus and dynamic scoped rows do not repeat it.
- When straight-line burn projects depletion before reset, `May run out in …` replaces pace copy.
  The expected-position marker remains neutral, and an early-window guard prevents bursty false alarms.
- Missing, expired, or implausible reset times produce no marker or pace text. Bar cards retain
  their existing energy phrase in that case.

---

## Typography

Two Google fonts, both rounded. Bundle the TTFs (OFL) under `ClaudeMeter/Fonts/` and register via
`ATSApplicationFontsPath`. **Until bundled, fall back to `.system(design: .rounded)` for Fredoka and
`.system(design: .default)` for Nunito** — a `Font` helper centralizes this so swapping in the real
faces is one edit.

| Role           | Spec (Fredoka)                         | Use                                        |
| -------------- | -------------------------------------- | ------------------------------------------ |
| Hero title     | Fredoka 600, 18                        | "You're cruising", "Claude Usage"          |
| Account name   | Fredoka 600, 15                        | "Work"                                     |
| Big number     | Fredoka 700–800, 14 (ring rows 11)     | "78%"                                      |
| Avatar letter  | Fredoka 700, 17 (ring center 19)       | "W"                                        |
| Plan badge     | Fredoka 700, 10–11                     | "MAX 20×"                                  |
| Add-account    | Fredoka 700, 14                        | primary button                            |

| Role           | Spec (Nunito)                          | Use                                        |
| -------------- | -------------------------------------- | ------------------------------------------ |
| Metric label   | Nunito 700, 13 (ring rows 11)          | "5-Hour Energy", "Weekly Fuel", "5-hr"     |
| Status phrase  | Nunito 700, 11                         | "Tons of energy" (colored)                 |
| Caption/meta   | Nunito 600, 11                         | "Refills in 3h 12m", "you@oneone.com"      |
| Section label  | Nunito 800, 11, tracking 0.09em, upper | "ACCOUNTS"                                 |

All changing numerics use `.monospacedDigit()`.

---

## The Chunky-3D Recipe

The signature look. Three reusable treatments:

1. **Chunky card** — `RoundedRectangle(cornerRadius: 18)` filled `card-bg`, stroked `card-border`
   2pt, plus a **4pt bottom edge**. SwiftUI has no per-side border, so layer a 2pt full stroke and
   add the thicker bottom via an overlay capsule/edge or a 2pt-offset shadow:
   `.shadow(color: cardBorder, radius: 0, y: 2)` reads as the bottom lip. Padding 13×14.
2. **Raised avatar / header icon** — rounded square (radius 11 / 9), solid brand fill, white glyph,
   inner bottom highlight `.overlay(alignment:.bottom){ Rectangle().fill(.black.opacity(0.13)).frame(height:3) }`
   clipped to the shape (the `inset 0 -3px` press effect).
3. **Raised primary button** — `energy-full` fill, white Fredoka, radius 14, with a **solid colored
   drop shadow** `.shadow(color: energy-full-shadow, radius: 0, y: 4)` (Duolingo's signature button).
   On press, translate down 2pt and shrink the shadow to y:2.

Progress bars/rings get an inner top gloss: `inset 0 2px 0 rgba(255,255,255,.45)` → a 2pt white
capsule overlay at the top of the fill.

---

## Popover Anatomy

Width **360pt**. Background `popover-bg`, radius 22, border `popover-border` 2pt.
Internal padding is 15pt. The body uses a screen-derived height cap and scrolls
when accounts/providers overflow.

```
┌──────────────────────────────────────────────┐
│ [⚡] Claude Meter       2m ago       (⚙) (⏻) │  Header
│ ┌──────────────────────────────────────────┐ │
│ │ (🚀)  You're cruising                      │ │  Hero (combined health)
│ │       2 accounts fresh · buildbot low (1h) │ │
│ └──────────────────────────────────────────┘ │
│  ACCOUNTS                    ◌ weekly ● 5-hour │  Section label + ring legend
│ ┌──────────────────────────────────────────┐ │
│ │ ((W))  Work                     [MAX 20×]  │ │  Ring card (active)
│ │        you@oneone.com                      │ │
│ │        ▪ 5-hr 78% · 3h 12m                 │ │
│ │        ▪ week 64% · 29 Jun                 │ │
│ └──────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────┐ │  Ring card (other account)
│ │ ((A))  Personal …                          │ │
│ └──────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────┐ │  Cost card (tap → heatmap)
│ │ 💸 Last 7 days              $75.68      ›  │ │
│ └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

### Header
- Left: 30×30 raised header icon (radius 9, `energy-full` fill, white ⚡/bolt.fill) + "Claude Usage"
  Fredoka 600/18 `ink`.
- Right: compact relative update time plus 28×28 Settings and Quit buttons. Opening
  the popover already triggers an interactive refresh, so no redundant refresh
  control is shown. Pause/resume lives in Settings.

### Hero
The selected Claude or Codex meter drives the hero. State follows the table above. Layout: 46×46 white circle (border = hero-border) holding the
mascot emoji, then headline (Fredoka 600/18 `hero-ink`) + subline (Nunito 700/12 `hero-subink`).
Hero bg/border swap green→orange→red with severity. Animate color with `.easeInOut(0.3)`.

### Accounts section
- Label row: "ACCOUNTS" (label style) left; **ring legend** right — `◌ weekly` (2.5pt ring outline
  dot) + `● 5-hour` (filled dot), Nunito 700/10 `ink-muted`. (Bars variant shows "N connected".)
- **One ring card per account**, selected nearest/pinned account first. Build a unified `[AccountUsage]`: use
  `snapshot.accounts` when present, else synthesize a single element from the top-level snapshot.

### Ring card (primary — Frame B)
Chunky card, flex row, gap 14.
- **ActivityRings** 88×88: outer ring (weekly) radius 34, inner ring (5-hour) radius 24, stroke 8pt
  round-cap; track `track`; value arc colored by that window's band; **arc length = percentLeft**;
  start at top (rotate −90). Center: avatar letter, Fredoka 700/19 `ink`.
- Right column:
  - Name (Fredoka 600/15 `ink`) + plan badge pill (right). **Plan badge only when known** (active
    OAuth account); omit otherwise.
  - Subtitle (Nunito 700/11 `ink-muted`): email when known, else nothing (or the config-dir key).
  - 5-hr row: 9×9 rounded dot (band color) · "5-hr" (Nunito 700/11 `ink`) · "78%" (Fredoka 800/11
    band color) · "· 3h 12m" (Nunito 600/11 `ink-muted`).
  - week row: same, followed by a shared `ResetPhrase` duration such as "· in 6d 7h".
  - Codex cards add a full-width section below the rings for "Usage limit resets" and the
    available count. Each returned reset shows its title and time to expiry, sorted by expiry.
    Hovering a row shows the exact local expiry date and time. Missing or partial expiry
    details are stated below the count. The section uses the card's existing fonts and colors.

**Per-account data reality:** label, 5-hr %, week %, reset/refill exist for every account. Email,
plan badge, and weekly-Opus are OAuth-only → present only on the active account. Never fabricate
them; the card degrades gracefully (name + rings + two rows). When Claude is the secondary
provider, keep one compact summary card: show the nearest-limit account's known plan in its header,
then expand in place for per-account session/week/Opus/scoped rows and known identity metadata.

### Energy-bar card (alt — Frame A, keep available)
Same card; replaces rings with two stacked rows, each: icon (⚡/📅) + label + "78% left", a 14pt
depleting capsule bar (band color, inner top gloss), and a phrase/reset row. Document but ship rings
as the default. Appearance → Account cards switches between rings and bars.

### Cost card → activity heatmap
The "Last 7 days" cost card is **tappable** (chevron affordance): it flips the popover body to a
GitHub-style **activity punchcard** — 7 rows (Mon–Sun) × 24 columns (hour of day), each cell a
rounded square shaded in 5 `energy-full` intensity levels by message volume relative to the busiest
hour (empty = `track`). Weekday labels at left, a 6-hour axis below, and a "Less → More" legend. A
**Back** button returns to the main view. Data is scanned on demand from local transcripts (last 30
days, local time); shows "Scanning…" / "No activity" placeholders.

---

## Menu Bar Icon (Frame C)

**The icon mirrors the selected main provider's nearest-limit account** so a glance says whether
it's safe to fire a big prompt. It never falls back to another provider. Bolt glyph + a colored
status dot (top-right), severity from the same engine as the rings:

| State       | Glyph         | Dot                          |
| ----------- | ------------- | ---------------------------- |
| All good    | bolt          | green `energy-full`          |
| Low         | bolt          | orange `energy-low`          |
| Critical    | bolt          | red `energy-empty`, **pulsing** (scale 1→1.4, opacity 1→.5, 1.2s) |
| Tapped out  | bolt, 55% op  | red pill badge with "0"      |
| Stale       | bolt          | gray dot                     |
| Loading     | spinning ⟳    | —                            |
| Error       | bolt.trianglebadge.exclamationmark | —       |

Retain a compact "{percentLeft}% left" text after the glyph for glanceability (design omits it; it's
trivial to hide via a setting). The **"Menu bar shows"** setting picks nearest limit (default, unsuffixed), `5h`, `7d`,
`both` (`99% 5h · 73% 7d`), or `forecast` (`20% · out 38m`). Forecast uses the nearest binding
window and falls back to its percentage when projection is unavailable. The dot color always tracks
severity across all windows, so a single-window number can differ from the dot.
Pause = dimmed glyph, no dot/number. Reduce Motion disables the pulse. Colors render in the menu bar
(SwiftUI MenuBarExtra label is not force-templated).

---

## Notifications (Frame C voice)

macOS can't style the toast (system chrome + app icon only), so "implementing Frame C" = **copy**.
Keep the existing dedup + threshold logic; only titles/bodies change. Title always "Claude Usage".
Frame `%` as **% left**. Examples:

Quota notification policy follows the selected main meter. Claude attention-hook notifications
remain Claude-specific.

- **Low (warning):** "Heads up — {account} is at {left}%. Refills in {refill}. Maybe touch grass? 🌱"
- **Empty (critical):** "{account} is almost dry ({left}%). {refill} to refuel. Easy now. 🫠"
- **Tapped out:** "{account} is tapped out. Back in {refill}. Go stretch. 🧘"
- **Recovered/refueled:** "You're refueled! {account} is back to 100%. Go get 'em. 🎉"

Weekly scope swaps "Refills" → "Resets {day}". No sound (unchanged).

---

## Settings & Widget

No design spec ships for these — translate the language faithfully:
- **Settings:** cream `popover-bg` window, chunky cards per section/data-source, raised primary
  buttons, Fredoka headings / Nunito body, adaptive dark. Keep the existing tab structure & controls.
- **Widget (sandboxed):** the depleting-ring look for the selected Claude or Codex account;
  medium/large show provider/account identity and optional Opus detail. Duplicate the ring component
  + token hexes into the widget target (design tokens are intentionally not shared across targets —
  see `Color(widgetHex:)`). Open only `SnapshotStore.appGroup()` and load through Core's
  provider/account/revision-validating `MainMeterPublication`; degrade to a neutral "no data" ring.

---

## Non-data States

Reuse the playful shell; center a mascot + line:
- **Onboarding:** 🚀 "Welcome!" + "Connect a source to start your engines." → Open Settings.
- **Paused:** 😴 "Paused" + "Flip the switch to refuel the gauge."
- **No sources:** 🔌 "No data methods on" + Open Settings.
- **Loading:** spinner + "Checking your tanks…".
- **Error / stale:** ⚠️ friendly line + recovery button; stale desaturates rings + shows "Data may be
  stale".

---

## Animation

| Trigger              | Animation                                                     |
| -------------------- | ------------------------------------------------------------ |
| Ring/bar value       | `.easeOut(0.5)` on arc length / fill width                   |
| Severity color       | `.easeInOut(0.3)` on color                                   |
| Critical dot pulse   | `.easeInOut(1.2).repeatForever` scale+opacity (TimelineView) |
| Button press         | translate y +2, shadow y 4→2, `.spring(response:0.2)`        |
| Refresh spin         | continuous rotation via `TimelineView(.animation)`           |
| Hero state change    | `.easeInOut(0.3)`                                            |

Reduce Motion: drop the pulse and continuous spins; keep instant color/value swaps.

---

## Accessibility

1. Rings/bars: `.accessibilityValue("78 percent left")` + `.accessibilityLabel("Work, 5-hour energy")`.
2. Convey band in text, not color alone: VO reads "Work, 5-hour, 78 percent left, plenty".
3. Combined hero announced: "You're cruising. 2 accounts fresh, buildbot low, refills in 1 hour 8 minutes".
4. All game buttons have `.accessibilityLabel` describing the action; min target 28×28.
5. Contrast ≥ 4.5:1 in both light and dark — verify `ink`/`ink-muted` on `card-bg`.
6. Respect Reduce Motion (pulse/spin) and Increase Contrast (thicken borders).
