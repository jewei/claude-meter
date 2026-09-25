---
name: Claude Meter — macOS Menu Bar Design System
medium: SwiftUI (MenuBarExtra .window). Tokens are implemented in ClaudeMeter/PlayfulTheme.swift.
fonts:
  display: Fredoka # headings, numbers, avatars, plan badges (rounded, chunky)
  body: Nunito # labels, captions, body
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
colors-dark: # warm-dark counterpart; the original design is light only
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

## Brand and personality

Claude Meter is a **playful, high-energy, Duolingo-flavored** menu-bar app. The mental
model is a **fuel gauge**: every limit is **energy remaining**, not consumption. The tone
is encouraging and a little cheeky, never scolding.

Visual language: **warm cream surfaces, bright candy greens/oranges/reds, fat rounded
type, circular activity rings, and chunky 3D cards** (a thick bottom border and inset
highlight make elements look pressable, like game buttons). It is a friendly companion
in the menu bar, not a dashboard. The app has no Dock icon; its footprint is the
status-bar item and the popover.

---

## The energy model

**Display energy left, even though the data layer stores `percentUsed`.**

```
percentLeft = 100 − resolvedWindow.percentUsed     // clamp 0…100
```

- Rings and bars **deplete**: arc or fill length is `percentLeft`. A full ring is lots of energy.
- The big number is `percentLeft` followed by a muted " left".
- A just-reset rolling window reads **100% left**, through `resolved(asOf:)`.
- Appearance → progression mode can switch every number and fill to percent used.

**Severity comes from the user's `UsageThresholds` on percent used (warning 80, critical
95).** The menu-bar dot, ring colors, and hero state share this one source, so they always
agree. To show orange earlier, lower the warning threshold in Settings.

| Energy band | percentUsed      | percentLeft   | Color         |
| ----------- | ---------------- | ------------- | ------------- |
| Full        | `< warning` (80) | `> 20%`       | `energy-full` |
| Low         | `80…<95`         | `5–20%`       | `energy-low`  |
| Empty       | `≥ 95`           | `≤ 5%`        | `energy-empty`|
| Tapped out  | `≥ 100`          | `0%`          | `energy-empty`, "0" |
| Unknown     | nil              | —             | `track` gray  |

### Hero

The selected main provider and its account policy drive the hero. An exact pin wins;
otherwise the nearest-limit account owns the hero and menu bar.

| Band       | Emoji | Headline            | Hero colors |
| ---------- | ----- | ------------------- | ----------- |
| Full       | 🚀    | "You're cruising"   | green       |
| Low        | ⛽️    | "Pace yourself"     | orange      |
| Empty      | 🪫    | "Almost tapped out" | red         |
| Tapped out | 🥵    | "Take a breather"   | red         |
| Unknown    | 🛰️    | "Warming up"        | neutral     |

One account: the subline speaks to its most constrained window, such as "Plenty in the
tank · refills 3h 12m" or "Getting low · refills 1h 8m". Several accounts: the subline
counts fresh accounts and flags the lowest other one, such as "2 fresh · buildbot low
(1h 8m)", or reads "All 3 accounts fresh 🎉".

---

## Typography

Fredoka and Nunito, both rounded, are bundled OFL TTFs in `ClaudeMeter/Fonts/`. `PFont`
maps roles and weights to their faces. The menu bar uses system fonts.

| Role           | Spec (Fredoka)                         | Use                                        |
| -------------- | -------------------------------------- | ------------------------------------------ |
| Hero title     | Fredoka 600, 18                        | "You're cruising", "Claude Meter"          |
| Account name   | Fredoka 600, 15                        | "Work"                                     |
| Big number     | Fredoka 700–800, 14 (ring rows 11)     | "78%"                                      |
| Avatar letter  | Fredoka 700, 17 (ring center 19)       | "W"                                        |
| Plan badge     | Fredoka 700, 10–11                     | "MAX 20×"                                  |
| Primary button | Fredoka 700, 14                        | "Open Settings"                            |

| Role           | Spec (Nunito)                          | Use                                        |
| -------------- | -------------------------------------- | ------------------------------------------ |
| Metric label   | Nunito 700, 13 (ring rows 11)          | "5-Hour Energy", "Weekly Fuel", "5-hr"     |
| Caption/meta   | Nunito 600, 11                         | "Refills in 3h 12m", "you@oneone.com"      |
| Section label  | Nunito 800, 11, tracking 0.09em, upper | "ACCOUNTS"                                 |

All changing numbers use `.monospacedDigit()`.

---

## The chunky 3D recipe

The signature look has three reusable treatments:

1. **Chunky card**: `RoundedRectangle(cornerRadius: 18)` filled `card-bg`, a 2pt
   `card-border` stroke, and a **4pt bottom lip**. SwiftUI has no per-side border, so a
   `.shadow(color: cardBorder, radius: 0, y: 2)` makes the lip. Padding 13×14.
2. **Raised avatar or header icon**: rounded square (radius 11 or 9), solid brand fill,
   white glyph, and a 3pt `black.opacity(0.13)` inner bottom highlight clipped to the shape.
3. **Raised primary button**: `energy-full` fill, white Fredoka, radius 14, and a **solid
   colored drop shadow** `.shadow(color: energy-full-shadow, radius: 0, y: 4)`. On press,
   it moves down 2pt and the shadow shrinks to y: 2.

Progress bars and rings get an inner top gloss: a 2pt white capsule overlay at 45%
opacity on top of the fill.

---

## Popover anatomy

Width **360pt**. Background `popover-bg`, radius 22, border `popover-border` 2pt, internal
padding 15pt. The body has a screen-derived height cap and scrolls when accounts or
providers overflow.

```
┌──────────────────────────────────────────────┐
│ [⚡] Claude Meter       2m ago       (⚙) (⏻) │  Header
│ ┌──────────────────────────────────────────┐ │
│ │ (🚀)  You're cruising                      │ │  Hero
│ │       2 fresh · buildbot low (1h 8m)       │ │
│ └──────────────────────────────────────────┘ │
│  ACCOUNTS                    ◌ weekly ● 5-hour │  Section label + ring legend
│ ┌──────────────────────────────────────────┐ │
│ │ ((W))  Work                     [MAX 20×]  │ │  Ring card (selected)
│ │        you@oneone.com                      │ │
│ │        ▪ 5-hr 78% · 3h 12m                 │ │
│ │        ▪ week 64% · 6d 7h                  │ │
│ └──────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────┐ │  Ring card (other account)
│ │ ((A))  Personal …                          │ │
│ └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

### Header

- Left: 30×30 raised header icon (radius 9, `energy-full` fill, white `bolt.fill`) and
  "Claude Meter" in Fredoka 600/18 `ink`.
- Right: the compact relative update time, then 28×28 Settings and Quit buttons. The time
  truncates first, so all controls stay visible. Opening the popover starts an
  interactive refresh, so there is no refresh button. Pause/resume is in Settings.

### Hero

A 46×46 white circle (border `hero-border`) holds the mascot emoji, then the headline
(Fredoka 600/18 `hero-ink`) and subline (Nunito 700/12 `hero-subink`). Background and
border change green → orange → red with severity, animated with `.easeInOut(0.3)`.

### Accounts section

- Label row: "ACCOUNTS" (section label) on the left. The **ring legend** is on the right:
  `◌ weekly` (2.5pt ring outline dot) and `● 5-hour` (filled dot), Nunito 700/10 `ink-muted`.
- **One card per account** for every provider, in one list. The first card is always the
  main-meter account, the one the menu bar shows. The user can drag cards to a new
  position; the list reorders live with `.easeInOut(0.18)`, and the order is saved. A
  Claude or Codex card dragged to the top becomes the main meter; Cursor, Grok, and extra
  usage cannot go to the top. Cards read normalized
  `ProviderAccountSnapshot` values from UsageStore.

### Ring card (default)

Chunky card, flex row, gap 14.

- **ActivityRings** 88×88: outer ring (weekly) radius 34, inner ring (5-hour) radius 24,
  stroke 8pt, round caps. Track `track`; the value arc takes that window's band color;
  **arc length is percentLeft**; it starts at the top. Center: avatar letter, Fredoka
  700/19 `ink`.
- Right column:
  - Name (Fredoka 600/15 `ink`) and a plan badge pill on the right, **only when the plan
    is known**.
  - 5-hr row: 9×9 rounded dot (band color) · "5-hr" (Nunito 700/11 `ink`) · "78%" (Fredoka
    800/11, band color) · "· 3h 12m" (Nunito 600/11 `ink-muted`).
  - Week row: the same, with a `ResetPhrase` duration such as "· 6d 7h".
  - An unavailable or stale account keeps its label and shows its sanitized error in small
    text below its quota rows. Unknown values stay unknown.
- Codex cards, and Claude cards with a reset allowance, add a full-width "Usage limit
  resets" section below the rings or bars, with the
  available count. Each returned reset shows its title and time to expiry, sorted by
  expiry; hovering shows the exact local date and time. Missing or partial expiry details
  are stated below the count. The total can exceed the number of rows.

Label, 5-hour and weekly values, and reset times exist for every account. Plan badge,
weekly Opus, and scoped windows come only from the account's OAuth response; never
fabricate them. Without them, the card shows name, rings, and two rows. No card shows the
account email.

### Bar card (Appearance → Account cards → Energy bars)

Every Claude and Codex account card uses this one layout, whatever its position or
provider. It is collapsible and has no section label; the provider logo names the provider:

- Header: provider mark, account name (Fredoka 600/14), plan badge when known, "same
  login" chip when needed, disclosure chevron, and the headline
  percentage (Fredoka 700/14): Claude session, Codex primary window.
- One 12pt `EnergyBar` per reported window: session, then weekly. Below each bar, Nunito
  600/11 `ink-muted`: "Session · 60% left" on the left and "Resets in 2h 53m" on the
  right. With no reported value, one "Session · —" bar remains.
- Caption: credits (Codex), then "1 usage reset available" when the account has a reset
  allowance.
- The account's own error in `energy-low`. A card of the provider that is not selected also
  shows a failed provider refresh, or "Data may be stale" in `ink-muted`; for the selected
  provider these are notices above the hero.
- Expanded: Opus and scoped dot rows after a divider (Claude), then the "Usage limit
  resets" section: a divider, "Usage limit resets … 1 available", and one row per reset
  with its time to expiry. With no reset data from the provider, the section reads
  "Usage limit resets … Not reported". Every bar card has the chevron.

The only difference between providers is the number of bars: Codex Pro reports only a
weekly window. With no Claude account rows, a notice states the refresh failure. No
provider has a summary card.

---

## Menu bar icon

**The icon mirrors the selected main provider's pinned or nearest-limit account**, so a
glance says whether a big prompt is safe. It never falls back to another provider.

| State      | Glyph                                   | Badge and text                                   |
| ---------- | --------------------------------------- | ------------------------------------------------ |
| Full       | `bolt.fill`                             | green `energy-full` dot                          |
| Low        | `bolt.fill`                             | orange `energy-low` dot                          |
| Critical   | `bolt.fill`                             | red `energy-empty` dot, pulses 3 times on entry  |
| Tapped out | `bolt.fill`                             | red pill badge with "0"                          |
| Stale      | `bolt.fill`                             | gray dot; no percentage                          |
| Loading    | spinning `arrow.clockwise`              | —                                                |
| Error      | `bolt.trianglebadge.exclamationmark.fill` | shown when there is no reading and an error    |
| Paused     | whole item at 55% opacity, secondary color | no dot, no percentage                         |

The critical pulse scales 1 → 1.35 and fades to 55% opacity over 1.2 s, capped at 12 fps.
It runs three times when the main meter becomes critical, then the dot stays static. A
state that can last days must not keep the status item redrawing. Loading and stale
periods do not start a new pulse.

A compact percentage follows the glyph. The **Menu bar shows** setting picks `5h`
(default), `7d`, or both (`99% 5h · 73% 7d`). The first card picks the account. `5h` shows the
weekly value with a `7d` suffix when the account has no 5-hour window, such as Codex Pro. The dot tracks
severity across all windows, so a single-window number can differ from the dot. Colors
render in the menu bar because the SwiftUI `MenuBarExtra` label is not forced to a template.

---

## Settings

The Settings window uses a cream `popover-bg` background, chunky cards per section and
data source, raised primary buttons, Fredoka headings, Nunito body, and adaptive dark
mode. The tabs are Data, Appearance, Advanced, and About. Appearance holds the warning and
critical sliders that set menu-bar and card colors. Codex Data settings show enablement,
sign-in status, homes, and display names.

Claude config directories and Codex homes are both "one folder, one account" lists, and
they share one set of parts: an account row (avatar tile, editable display name, folder
path chip, trailing controls), a chunky "Add …" button with `folder.badge.plus`, red
Nunito 700/11 error text, and a note in a `popover-bg` box. A new folder list uses the
same parts.

---

## Non-data states

These states reuse the playful shell with a centered mascot and one line:

| State      | Emoji and title                | Message and action                                            |
| ---------- | ------------------------------ | ------------------------------------------------------------- |
| Onboarding | 🚀 "Welcome to Claude Meter"   | "Connect a data source to start your engines." → "Get started →" |
| Paused     | 😴 "Paused"                    | "Hit play below to refuel the gauge."                         |
| No sources | 🔌 "No data methods on"        | "Turn on at least one method in Settings → Data." → "Open Settings" |
| No usage   | 🪫 "No usage yet"              | Setup guidance for the enabled sources                        |
| Loading    | spinner                        | "Checking your tanks…", or "Checking Codex…" for one source   |

Stale data shows "Data may be stale". A failed refresh shows "Refresh failed · showing
last known data" or "Refresh failed · no usage data".

---

## Animation

| Trigger            | Animation                                                         |
| ------------------ | ----------------------------------------------------------------- |
| Ring/bar value     | `.easeOut(0.5)` on arc length or fill width                       |
| Severity color     | `.easeInOut(0.3)` on color                                        |
| Critical dot pulse | three 1.2 s scale and opacity cycles in a `TimelineView`, ≤ 12 fps |
| Button press       | move down 2pt, shadow y 4 → 2, `.spring(response: 0.2)`           |
| Loading spin       | linear 1 s rotation, repeated                                     |
| Hero state change  | `.easeInOut(0.3)`                                                 |

Reduce Motion removes the pulse, spin, and value animations; colors and values change at once.

---

## Accessibility

1. Rings and bars expose a label that names the account or window, and a value such as
   "78 percent".
2. Bars and rings state the band in their accessibility value, not by color alone.
3. The hero reads as one element: "headline. subline".
4. Every game button has an `.accessibilityLabel` for its action; the minimum target is 28×28.
5. Contrast is at least 4.5:1 in light and dark mode. Check `ink` and `ink-muted` on `card-bg`.
6. The menu-bar summary rules are in [ClaudeMeter/AGENTS.md](ClaudeMeter/AGENTS.md).
