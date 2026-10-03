---
name: Claude Meter design system
medium: SwiftUI (MenuBarExtra .window). Tokens are implemented in ClaudeMeter/PlayfulTheme.swift.
fonts:
  display: Fredoka # headings, numbers, avatars, plan badges (rounded, chunky)
  body: Nunito # labels, captions, body
colors-light:
  # Popover and card backgrounds
  popover-bg: "#FBF9F2" # warm cream
  popover-border: "#EFE9DA"
  card-bg: "#FFFFFF"
  card-border: "#EFEAD9" # Sides and top 2px, bottom 4px for depth
  hero-bg: "#EAF8E0" # pale green (healthy state)
  hero-border: "#CFEEB8"
  track: "#ECE9DD" # Unfilled ring and bar track
  # Text
  ink: "#3A382F" # primary warm near-black
  ink-muted: "#6A665B" # emails, reset times, "left"
  label: "#6A665B" # uppercase section labels
  # Energy severity: green is full, orange is low, red is empty
  energy-full: "#4FC51C" # green
  action: "#287B12" # raised-button fill, both modes
  action-shadow: "#19550B" # raised-button drop shadow, both modes
  energy-low: "#FF9D0A" # orange
  energy-empty: "#FF5A5A" # red
  # Hero text by state
  hero-ink: "#2E7D12"
  hero-subink: "#547236"
  # Plan badges
  plan-max-fg: "#8133BC"
  plan-max-bg: "#F2E6FF"
  plan-pro-fg: "#287B12"
  plan-pro-bg: "#E7F8DC"
  plan-free-fg: "#6F6A5B"
  plan-free-bg: "#EFECE0"
colors-dark: # Dark palette. The original design uses light colors only.
  popover-bg: "#201E18"
  popover-border: "#3A372E"
  card-bg: "#2A2820"
  card-border: "#3D3A30" # Darker bottom border (#15140F) for depth
  hero-bg: "#22311A"
  hero-border: "#3C5A2A"
  track: "#3A372E"
  ink: "#ECE8DC"
  ink-muted: "#ADA798"
  label: "#ADA798"
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

# Claude Meter design system

This reference defines the UI colors, typography, components, and states. [The
specification](SPECS.md) defines behavior and settings.

## Brand and tone

Claude Meter uses a playful style with encouraging text. Quota appears as energy left.
Cream backgrounds, bright green, orange, and red, rounded type, and circular rings
define its appearance. Cards have thick bottom borders and inset highlights for depth.
The app appears in the menu bar and popover. It has no Dock icon.

## Energy model

The default display shows energy left. The data layer stores `percentUsed`:

```text
percentLeft = 100 − resolvedWindow.percentUsed     // clamp 0…100
```

Numbers, rings, and bars use these rules:

- Ring arc length and bar fill length equal `percentLeft`. A full ring means full
  energy.
- The big number is `percentLeft` followed by a muted " left".
- A just-reset current rolling window reads 100% left. A stale expired window is
  unknown. Headers, bars, rings, and spoken values share the same resolved observation.
- **Progression mode** in **Appearance** can switch every number and fill to percent
  used.

Severity uses `UsageThresholds` on percent used, with defaults of 80 for warning and 95
for critical. The menu-bar dot, ring colors, and hero state use the same thresholds.
Individual windows can have different bands. The dot considers all binding windows. A
lower warning threshold in **Settings** shows orange earlier.

| Energy band | percentUsed      | percentLeft   | Color         |
| ----------- | ---------------- | ------------- | ------------- |
| Full        | `< warning` (80) | `> 20%`       | `energy-full` |
| Low         | `80…<95`         | `5–20%`       | `energy-low`  |
| Empty       | `≥ 95`           | `≤ 5%`        | `energy-empty`|
| Tapped out  | `≥ 100`          | `0%`          | `energy-empty`, "0" |
| Unknown     | nil              | —             | `track` gray  |

### Hero

The selected main provider and its account policy drive the hero. An exact pin wins.
Otherwise, the account nearest its limit owns the hero and menu bar.

| Band       | Emoji | Headline            | Hero colors |
| ---------- | ----- | ------------------- | ----------- |
| Full       | 🚀    | "You're cruising"   | green       |
| Low        | ⛽️    | "Pace yourself"     | orange      |
| Empty      | 🪫    | "Almost tapped out" | red         |
| Tapped out | 🥵    | "Take a breather"   | red         |
| Unknown    | 🛰️    | "Warming up"        | neutral     |

For one account, the subline names its most constrained window. Examples are "Plenty in
the tank · Session resets in 3h 12m" or "Getting low · Weekly resets in 1h 8m". Equal
usage selects the later reset. No reset time is shown if that window has none. An
earlier reset of another window must not imply that the limiting quota returns. For
several accounts, the subline counts fresh accounts and names the lowest other account.
Examples are "2 fresh · buildbot low · Weekly resets in 1h 8m", or "All 3 accounts fresh
🎉".

## Typography

Fredoka and Nunito, both rounded, are bundled OFL TTFs in `ClaudeMeter/Fonts/`. `PFont`
maps roles and weights to their faces. The menu bar uses system fonts.

| Role           | Spec (Fredoka)                         | Use                                        |
| -------------- | -------------------------------------- | ------------------------------------------ |
| Hero title     | Fredoka 600, 18                        | "You're cruising", "Claude Meter"          |
| Account name   | Fredoka 600, 15                        | "Work"                                     |
| Big number     | Fredoka 700–800, 14     | "78%"                                      |
| Avatar letter  | Fredoka 700, 17 (ring center 19)       | "W"                                        |
| Plan badge     | Fredoka 700, 10–11                     | "MAX 20×"                                  |
| Primary button | Fredoka 700, 14                        | "Open Settings"                            |

| Role           | Spec (Nunito)                          | Use                                        |
| -------------- | -------------------------------------- | ------------------------------------------ |
| Metric label   | Nunito 700, 13 (ring rows 11)          | "5-Hour Energy", "Weekly Fuel", "5-hr"     |
| Caption and metadata   | Nunito 600, 11                         | "Refills in 3h 12m", "you@oneone.com"      |
| Section label  | Nunito 800, 11, tracking 0.09em, upper | "ACCOUNTS"                                 |

All changing numbers use `.monospacedDigit()`.

## Card, avatar, and button depth

Cards, avatars, and buttons use these treatments:

- Cards use `RoundedRectangle(cornerRadius: 18)` with a `card-bg` fill and a 2pt
  `card-border` stroke. A 4pt bottom border adds depth through `.shadow(color:
  cardBorder, radius: 0, y: 2)`. Padding is 13×14pt.
- Avatars and header icons use rounded squares with radii of 11pt and 9pt. They have a
  solid brand fill and a white glyph. A 3pt `black.opacity(0.13)` inner bottom highlight
  is clipped to the shape.
- Primary buttons use a dark green `#287B12` fill, white Fredoka text, and a 14pt radius.
  This replaces the bright energy fill so the label has sufficient contrast. The shadow
  uses `action-shadow` at `y: 4`. On press, the button moves down 2pt and the shadow
  moves to `y: 2`. Disabled buttons use 45% opacity.
- Compact controls use `QuietButtonStyle`: a subtle ink surface on hover and press,
  a 2pt focus border, and 45% opacity when disabled. Feedback changes without motion.
- Bright energy colors belong to rings, dots, and bars. Small status text and values
  use darker energy ink in light mode: green `#2E7D12`, amber `#965000`, and red `#B52C28`.
  Dark mode uses `#8FE25A`, `#FFC368`, and `#FF9B96`.

Progress bars and rings have a 2pt white capsule overlay at the top of the fill. The
overlay uses 45% opacity.

## Popover layout

The popover is 360pt wide with a `popover-bg` background, a 22pt radius, and a 2pt
`popover-border` border. Internal padding is 15pt. The body has a screen-derived height
cap and scrolls when accounts or providers overflow.

```text
┌──────────────────────────────────────────────┐
│ [⚡] Claude Meter       2m ago       (⚙) (⏻) │  Header
│ ┌──────────────────────────────────────────┐ │
│ │ (🚀)  You're cruising                      │ │  Hero
│ │       2 fresh · buildbot low (1h 8m)       │ │
│ └──────────────────────────────────────────┘ │
│  ACCOUNTS                    ◌ weekly ● 5-hour │  Section label + ring legend
│ ┌──────────────────────────────────────────┐ │
│ │ ((W))  Work                     [MAX 20×]  │ │  Ring card (selected)
│ │        ▪ 5-hr 78% · 3h 12m                 │ │
│ │        ▪ week 64% · 6d 7h                  │ │
│ └──────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────┐ │  Ring card (other account)
│ │ ((A))  Personal …                          │ │
│ └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

### Header

The header has these elements:

- A 30×30pt icon on the left, with a 9pt radius, `energy-full` fill, and white
  `bolt.fill`. "Claude Meter" uses Fredoka 600 at 18pt in `ink`.
- A compact relative update time on the right, then 28×28pt **Settings** and **Quit**
  buttons. The time truncates first, so all controls stay visible.

Opening the popover checks reading freshness and refreshes when necessary. There is no
refresh button. **Settings** contains pause and resume controls.

### Hero

A 46×46 white circle (border `hero-border`) holds the mascot emoji, then the headline
(Fredoka 600/18 `hero-ink`) and subline (Nunito 700/12 `hero-subink`). Background and
border change from green to orange to red as severity increases, with `.easeInOut(0.3)`.
Unknown, unavailable, and stale summaries use neutral card surfaces and ink. The headline
and subline wrap when necessary; recovery text is not cut to a fixed number of lines.

### Accounts section

The account list has a label row and account cards:

- The label row shows "ACCOUNTS" on the left. The ring legend is on the right: `◌
  weekly` (2.5pt ring outline dot) and `● 5-hour` (filled dot), Nunito 700/10
  `ink-muted`.
- Every provider has one card per account in one list. The first card is always the
  main-meter account, the one the menu bar shows. The user can drag cards to a new
  position. The list reorders with `.easeInOut(0.18)` and saves the order. A Claude or
  Codex card dragged to the top becomes the main meter. Cursor, Grok, and extra usage
  cannot go to the top. Cards read normalized `ProviderAccountSnapshot` values from
  UsageStore.
- A small **Menu bar** label identifies the selected card. When several Claude or Codex
  accounts are present, a visible instruction explains that dragging one to the top
  selects it for the menu bar. The label does not imply that the reading is fresh.

### Ring card (default)

The ring card keeps the name above its quota display:

- The full-width header shows the account name (Fredoka 600/15 `ink`) and known plan.
  If the name and badges do not fit on one line, the badges move below the name. The
  name can use two lines; a tooltip exposes the full name. Plan text truncates only
  when necessary and has a full-plan tooltip.
- Below the header, `ActivityRings` occupies 88×88pt with a 14pt gap before the metrics.
  The weekly ring has a 34pt radius; the 5-hour ring has a 24pt radius. Both use 8pt
  strokes, round caps, and `track` backgrounds. Arcs start at the top. The center
  letter uses Fredoka 700/19.
- Each metric has a band dot, a Nunito 700/11 label, and a right-aligned Fredoka 700/14
  value with an explicit **left** or **used** caption. Unknown values show only `—`.
  A separate Nunito 600/11 line says **Resets in …**, using `ResetPhrase`.
- An unavailable or stale account keeps its label and shows its sanitized error below
  the quota and token rows. Error text uses energy ink rather than a bright fill color.
  A secondary-provider card also shows **Refresh failed · showing last known data**
  or **Data may be stale**, with the same rules as bar cards.
- Codex cards, and Claude cards with a reset allowance, add a full-width "Usage limit
  resets" section below the rings or bars, with the available count. Each returned reset
  shows its title and time to expiry, sorted by expiry. A tooltip shows the exact local
  date and time. Missing or partial expiry details are stated below the count. The total
  can exceed the number of rows.

Label, 5-hour and weekly values, and reset times exist for every account. Plan badge,
weekly Opus, and scoped windows come only from the account's OAuth response. Without
them, the card shows name, rings, and two rows. No card shows the account email.

### Bar card

With **Energy bars** selected in **Appearance**, under **Account cards**, every Claude
and Codex account card uses this layout. Each card is collapsible. The provider logo
names the provider, with no section label. The card has these elements:

- Header: provider mark, account name (Fredoka 600/14), plan badge when known, "same
  login" chip when needed, disclosure chevron, and the headline percentage (Fredoka
  700/14): Claude session, Codex primary window kind. When several binding windows have
  the same kind, the header, bar, ring, and menu bar show the highest usage for that
  kind.
- One 12pt `EnergyBar` per reported window: session, then weekly. Below each bar, Nunito
  600/11 `ink-muted`: "Session · 60% left" on the left and "Resets in 2h 53m" on the
  right. With no reported value, one "Session · —" bar remains.
- Caption: credits (Codex), then "1 usage reset available" when the account has a reset
  allowance.
- The account's own error in `energy-low`. A card of the provider that is not selected
  also shows a failed provider refresh, or "Data may be stale" in `ink-muted`. For the
  selected provider, these are notices above the hero.
- Expanded Claude cards show Opus and scoped dot rows after a divider. The **Usage limit
  resets** section follows with a divider, "Usage limit resets … 1 available", and rows
  for each reset and its time to expiry. With no reset data from the provider, the
  section reads "Usage limit resets … Not reported". Every bar card has the chevron.

The only difference between providers is the number of bars: Codex Pro reports only a
weekly window. With no Claude account rows, a notice states the refresh failure. No
provider has a summary card.

### Tokens used

Each provider account card contains a **Tokens used** section after its **Usage limit
resets** section, or after its other quota details for Cursor and Grok. The token section
appears only when the card is expanded. It shares the card's saved disclosure state and
resize animation. Ring cards remain always expanded. There is no separate token card.

A divider separates token usage from the details above it. The **Tokens used** heading
uses Nunito 700/11 in `ink`. The source label uses Nunito 600/10 in `ink-muted`:
**Account usage** for Cursor and **This Mac** for Claude Code, Codex, and Grok Build.
Each account card for the same local provider shows the same total. The source tooltip
explains this because local records do not prove historical account ownership.

Each section has **Today**, **Yesterday**, and **Last 7 Days** rows. Labels align left
and token counts align right, in Nunito 600/11 with monospaced digits. Counts use compact
notation, such as `35.8M tokens`. A tooltip and accessibility value give the full count.
Unknown values use `—`. There are no prices or currency symbols. Last 7 Days includes
today and the previous six local calendar dates.

Below the rows, Nunito 600/10 in `ink-muted` states missing records, a sanitized error,
partial history, or stale data when applicable. A source tooltip explains that local
history can include earlier logins and excludes other devices. Opening and closing the
card follows Reduce Motion. A history update does not change quota colors or freshness.

## Menu bar icon

The icon shows the selected main provider's pinned account or the account nearest its
limit. It never falls back to another provider.

| State      | Glyph                                   | Badge and text                                   |
| ---------- | --------------------------------------- | ------------------------------------------------ |
| Full       | `bolt.fill`                             | green `energy-full` dot                          |
| Low        | `bolt.fill`                             | orange `energy-low` dot                          |
| Critical   | `bolt.fill`                             | red `energy-empty` dot, pulses 3 times on entry  |
| Tapped out | `bolt.fill`                             | red pill badge with "0"                          |
| Stale      | `bolt.fill`                             | Gray dot with no percentage                          |
| Loading    | spinning `arrow.clockwise`              | —                                                |
| Error      | `bolt.trianglebadge.exclamationmark.fill` | shown when there is no reading and an error    |
| Paused     | Whole item at 55% opacity in the secondary color | no dot, no percentage                         |

The critical pulse scales from 1 to 1.35 and fades to 55% opacity over 1.2 s, capped at
12 fps. It runs three times when the main meter becomes critical, then the dot stays
static. A persistent critical state causes no further redraws from the pulse. Loading
and stale periods do not start a new pulse.

A compact percentage follows the glyph. The **Menu bar shows** setting picks `5h`
(default), `7d`, or both (`99% 5h · 73% 7d`). The first card picks the account. `5h`
shows the weekly value with a `7d` suffix when the account has no 5-hour window, such as
Codex Pro. The dot tracks severity across all windows, so a single-window number can
differ from the dot. Colors render in the menu bar because the SwiftUI `MenuBarExtra`
label is not forced to a template.

## Settings

The Settings window uses a cream `popover-bg` background, cards with thick bottom
borders for each section and data source, raised primary buttons, Fredoka headings,
Nunito body, and adaptive dark mode. The tabs are **Data**, **Appearance**,
**Advanced**, and **About**. Appearance holds the warning and critical sliders that set
menu-bar and card colors. Codex Data settings show enablement, sign-in status, homes,
and display names.

Claude config dirs and Codex homes use one folder per account. Both lists use the same
components:

- An account row with an avatar, a bordered display-name field, folder path chip, and
  trailing controls. The field is labeled **Display name** for accessibility. The full
  config dir is available in the path tooltip and accessibility value.
- An **Add …** button with `folder.badge.plus` and a thick bottom border.
- Error text in red Nunito 700 at 11pt.
- A note in a `popover-bg` box.

New folder lists use the same components.

Tabs and Appearance options expose their selected state. Command-1 through Command-4
open the four Settings tabs. Threshold sliders support arrow keys and show a focus
border. Manual OAuth fields have explicit labels and 28pt Show/Hide token controls.
**Cancel** is available during both initial entry and reauthentication; it discards the
form draft and returns to the previous screen without changing stored credentials.

## Non-data states

These states use the same popover background, a centered mascot, and one line of text:

| State      | Emoji and title                | Message and action                                            |
| ---------- | ------------------------------ | ------------------------------------------------------------- |
| Onboarding | 🚀 "Welcome to Claude Meter"   | "Connect a data source to start your engines." → "Get started →" |
| Paused     | 😴 "Paused"                    | "Hit play below to refuel the gauge."                         |
| No sources | 🔌 "No data methods on"        | "Turn on at least one method in Settings → Data." → "Open Settings" |
| No usage   | 🪫 "No usage yet"              | Setup guidance for the enabled sources                        |
| Loading    | spinner                        | "Checking your tanks…", or "Checking Codex…" for one source   |

Stale data shows "Data may be stale". A failed refresh shows "Refresh failed · showing
last known data" or "Refresh failed · no usage data".

## Animation

| Trigger            | Animation                                                         |
| ------------------ | ----------------------------------------------------------------- |
| Ring or bar value     | `.easeOut(0.5)` on arc length or fill width                       |
| Severity color     | `.easeInOut(0.3)` on color                                        |
| Critical dot pulse | three 1.2 s scale and opacity cycles in a `TimelineView`, ≤ 12 fps |
| Button press       | Move down 2pt, shadow `y` from 4 to 2, `.spring(response: 0.2)`           |
| Loading spin       | linear 1 s rotation, repeated                                     |
| Hero state change  | `.easeInOut(0.3)`                                                 |
| Card expansion or collapse | Card bounds, neighboring rows, detail clipping, and popover height use `.easeInOut(0.18)` |

Card details stay visible during collapse. The scroll viewport keeps its larger height
until the window finishes shrinking, so lower cards do not disappear early. The header
and window top edge stay fixed. Card contents stay clipped to the moving card bounds,
including when the popover is at its screen height cap. Rapid clicks continue from the
current visible size.

One frame driver updates the native window and the SwiftUI fitting height together.
The menu bar host must not restore the old height during expansion or collapse.

**Reduce Motion** removes the pulse, spin, value, and disclosure animations. Colors,
values, and card sizes change at once.

## Accessibility

The UI follows these accessibility rules:

- Rings and bars expose a label that names the account or window, and a value such as
  "78 percent".
- Bars and rings state the band in their accessibility value, not by color alone.
- The hero reads as one element: "headline. subline".
- Every button has an `.accessibilityLabel` for its action. The minimum target is
  28×28pt.
- Contrast is at least 4.5:1 in light and dark mode, including `ink` and `ink-muted` on
  `card-bg`.
- The menu-bar summary rules are in [ClaudeMeter/AGENTS.md](ClaudeMeter/AGENTS.md).
