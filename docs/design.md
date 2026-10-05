# Design system

How Claude Meter looks and moves, and where each part lives in `Sources/MeterUI`. Read this
before you change a view. Views render presentation models from `MeterApp/Presentation`;
they never decide data rules (see `AGENTS.md`).

## Tone

Quota shows as energy left. The style is playful: a warm cream background, bright green,
orange, and red, rounded type, rings, and "chunky" cards with a solid plate under them. The
app lives in the menu bar and has no Dock icon, except after Settings opens: it returns to
menu-bar-only when the last titled window (Settings or Sparkle's update window) closes
(`DockIconPolicy`).

## Color tokens

All tokens are in `Design/Palette.swift`. Each is an `NSColor` with a dynamic provider, so one
value serves SwiftUI, AppKit chrome, and the menu bar in both appearances.

### Surfaces and text

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `popover` | `#FBF9F2` | `#201E18` | Popover and Settings background, folder rows |
| `popoverBorder` | `#EFE9DA` | `#3A372E` | Popover border, Settings and Diagnostics rules |
| `card` | `#FFFFFF` | `#2A2820` | Cards |
| `cardBorder` | `#EFEAD9` | `#3D3A30` | Card border, dividers inside cards |
| `cardLip` | `#E4DDC9` | `#15140F` | The plate 3 pt below a card |
| `track` | `#ECE9DD` | `#3A372E` | Empty part of rings and bars, chips |
| `ink` | `#3A382F` | `#ECE8DC` | Primary text |
| `inkMuted` | `#6A665B` | `#ADA798` | Secondary text, section labels |

### Energy

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `energyFull` | `#4FC51C` | `#62D62C` | Green fills and dots |
| `energyLow` | `#FF9D0A` | `#FFAE33` | Orange fills and dots |
| `energyEmpty` | `#FF5A5A` | `#FF6B6B` | Red fills, dots, the "0" pill |
| `energyFullInk` | `#2E7D12` | `#8FE25A` | Green text; `accent` for focus, tint, selection |
| `energyLowInk` | `#965000` | `#FFC368` | Amber text: warnings, failed status lines |
| `energyEmptyInk` | `#B52C28` | `#FF9B96` | Red text: errors |
| `energyUnknown` | `inkMuted` at 45% | same | Dots of unknown values |
| `action` | `#287B12` | `#287B12` | Raised button fill |
| `actionShadow` | `#19550B` | `#19550B` | Raised button plate |
| `destructive` | `#B52C28` | `#B52C28` | Raised button that deletes something |
| `destructiveShadow` | `#7A1A17` | `#7A1A17` | Its plate |

Bright energy colors are for fills only. Small text uses the `…Ink` colors, which keep at
least 4.5:1 contrast on `card` and `popover`.

`Severity` maps to colors in `Design/SeverityColors.swift`: `normal` → full, `warning` →
low, `critical` and `exhausted` → empty, `unknown` → unknown. Header numbers on bar cards
stay `ink` while energy is full (`headlineInk`).

### Hero, plan badges, tiles

| Hero tone | Background | Border | Title | Subtitle |
| --- | --- | --- | --- | --- |
| full | `#EAF8E0` / `#22311A` | `#CFEEB8` / `#3C5A2A` | `#29700F` / `#8FE25A` | `#547236` / `#A6C98A` |
| low | `#FFF1DD` / `#332715` | `#FAD9A0` / `#5A4424` | `#965000` / `#FFC368` | `#846436` / `#D8B488` |
| empty | `#FFE4E1` / `#3A1F1E` | `#F6C0BC` / `#5E2F2D` | `#C0322E` / `#FF9B96` | `#8A4B47` / `#E0A8A4` |
| neutral | `card` | `cardBorder` | `ink` | `inkMuted` |

| Plan tier | Text | Background |
| --- | --- | --- |
| max | `#8133BC` / `#D9B3FF` | `#F2E6FF` / `#3A2A50` |
| pro | `#287B12` / `#7FD65A` | `#E7F8DC` / `#23381A` |
| free | `#6F6A5B` / `#B8B3A2` | `#EFECE0` / `#33312A` |

Values are light / dark. Settings row tiles and account avatars use fixed fills
(`Palette.Tile`, the same in both appearances) with white glyphs. Account avatars pick one of
eight tile colors from a djb2 hash of the account ID. The bolt tiles in the popover header
and on About use `energyFull`. The About bolt is a gradient from `aboutBoltTop` (`#FFE38A`)
to `Tile.orange`.

## Type

Fredoka (display) and Nunito (body) are bundled in `Resources/Fonts` and registered for the
process with `CTFontManagerRegisterFontURLs` on first use (`Design/MeterFont.swift`). A face
that is not available falls back to the system rounded font with the same weight. The menu
bar uses the system rounded font.

| Role | Face | Size | Use |
| --- | --- | --- | --- |
| Page title | Fredoka Bold | 26 | Settings page titles |
| Status title | Fredoka SemiBold | 20 | Welcome, Paused, errors |
| About title | Fredoka Bold | 28 | "Claude Meter" on About |
| Hero title, app name | Fredoka SemiBold | 18 | "You're cruising", "Claude Meter" |
| Hero subtitle | Nunito Bold | 12 | "Almost dry · Session resets in 30m" |
| Account name | Fredoka SemiBold | 15 ring / 14 bar | "Work" |
| Settings row title | Fredoka SemiBold | 16 | "Launch at login" |
| Big number | Fredoka Bold | 14 (12 in limit rows) | "78%" |
| Unknown number | Nunito Bold | one size smaller | "—" (Fredoka draws it like a minus) |
| Ring letter | Fredoka Bold | 19 | "W" |
| Plan badge | Fredoka Bold | 10 | "MAX 20X" |
| Primary button | Fredoka Bold | 14 | "Open Settings" |
| Metric label | Nunito Bold | 11 | "5-hr", "week" |
| Caption | Nunito SemiBold | 11 | "Resets in 3h 12m" |
| Section label | Nunito ExtraBold | 11, tracking 0.99, uppercase, `inkMuted` | "ACCOUNTS", Settings section headings |
| Note | Nunito SemiBold | 10 | "Token usage unavailable" |
| Pill | Nunito ExtraBold | 10 | "Menu bar" |

Every changing number uses `.monospacedDigit()`, also in text that can hold one: the hero
subtitle, notices, status lines and screens, the notes under tokens used and usage-limit
resets, and the last update check.

## Components (`Design/`)

| Component | Spec |
| --- | --- |
| `ChunkyCard` (`.chunkyCard()`) | Radius 18 continuous. Plate `cardLip` 3 pt below; fill; white wash 12% light / 6% dark from the top; 2 pt border; 1 pt inner top highlight. |
| `RaisedTile` | Rounded square with a brand fill, a 1 pt white top-light border, and a 3 pt `black 13%` band inside the bottom edge. Header 30/9, Settings 40/11, About 104/26. |
| `RaisedButtonStyle` | `action` fill, white Fredoka Bold 14, padding 20×12, radius 14, plate at y 4. Pressed: label down 2 pt, plate at y 2, spring 0.2/0.85. Hover: white 6%. Focus: 2 pt `accent` ring. Disabled: 45%. Reduce Motion: no movement, darker tint. |
| `QuietButtonStyle` | `ink` surface at 6% hover and 10% press (muted text keeps 4.5:1 on both), 2 pt focus border, 45% when disabled. Nothing moves. The style also draws the button's own fill (`Surface`: clear, chunky, or a flat fill) below the ink surface, so a label never hides the feedback; labels draw no opaque fill. `.buttonStyle(.chunky)` is the small chunky button for `ChunkyButtonLabel`. |
| `EnergyDot` | 9 pt rounded square, radius 3. |
| `EnergyBar` | Capsule on `track`. Fill width = share × width; the track's capsule clips the fill, so a tiny fill follows the rounded end. A white 45% highlight, `min(2, height / 4)` pt high, 2 pt below the top and 3 pt in from each end, runs along the top of the fill only when the fill is wider than 6 pt. |
| `ActivityRings` | 88 pt. Outer weekly ring radius 34, inner session ring radius 24, 8 pt strokes, round caps, start at the top, `track` behind, a white highlight along each arc that grows from clear at the start to 30% at the tip (angular gradient). Center disc 30 pt in `popover` with the letter. Hidden from accessibility. |
| `PlanBadgeView` | Capsule, padding 8×3, tier colors, one line. |
| `ChipView` | Neutral capsule for "same login", "paused", and "Not tracked"; a tooltip only when it has help text. |
| `ProviderMark` | Bundled logo as a 15 pt template image in `ink`; Grok uses the `atom` symbol. |
| `NoticeBanner` | Top-aligned 12 pt icon, wrapping Nunito SemiBold 11, padding 12×9, tint 8% fill, 16% 1 pt border, radius 12. Action: `key.slash.fill`, warning: `exclamationmark.triangle.fill` (both `energyLowInk`); info: `clock.fill` (`inkMuted`). |
| `SquareIconButton` | 28 pt target, glyph 12 bold, quiet style on a chunky surface. |
| `InlineConfirmation` (`Settings/Data`) | A question in the page in place of the control that asked: `energyEmptyInk` warning symbol, Fredoka SemiBold 15 title, Nunito SemiBold 12 message, Cancel (Escape, when it is the newest question: `CancelShortcuts`) and a raised `destructive` button; `popover` fill, 1.5 pt border in `energyEmptyInk` at 40%, radius 14. Never a blocking alert. |
| `MeterSwitch` | Native switch with the `action` tint in both appearances, so the white knob stays clear on it, and a spoken label. |
| `Spinner` | Native spinner; static while the popover is hidden. |

## Popover (`Popover/`)

`PopoverPanelController` shows `PopoverView` in a borderless, non-activating `PopoverPanel`.
The panel can become key without activating the app, so Escape works and the user's app keeps
its focus. Because the app stays inactive, the panel allows tooltips while the app is
inactive (`allowsToolTipsWhenApplicationIsInactive`).

- Width 360 pt. SwiftUI draws the chrome: `popover` fill, 2 pt `popoverBorder`, radius 22.
- Position (`PanelLayout`, pure): the top edge sits 4 pt below the menu bar (below the status
  button when the menu bar hides itself), centered under the button, at least 8 pt from the
  sides of the visible frame. The controller reads the button and the screen when the
  popover opens and keeps them while it is open, so a wider menu-bar label or a menu bar
  that hides itself does not move the panel. A screen change places it again.
- Height = header + body. Body = content height, at least 120 pt, at most
  `max(560, visibleFrame.height − 72)`, and never more than the room between the top edge
  and the bottom of the visible frame (short screens, a hidden menu bar). Content taller than
  the body scrolls, so every card can be reached. The panel never leaves the visible frame.
- When the content height changes, the frame animates 0.18 s ease-in-out with the top edge
  fixed. It changes at once under Reduce Motion, while hidden, and in the first 0.25 s after
  opening.
- It closes (`PopoverDismissal`, pure) on a click of the status button, Escape, Command-W, a
  click in another app or in a titled window of this app, another app activating, a Space
  change, Command-H, app deactivation, another window taking the keyboard (Spotlight),
  "Update available", and when Settings opens. One click changes the popover once: the mouse
  monitors ignore clicks on the status button (macOS 26 draws the menu bar in another
  process, so such a click can reach the global monitor), and a toggle within 0.35 s of an
  automatic close does nothing. Keys that nothing handles do not beep. Opening calls
  `popoverDidOpen()`, which refreshes due readings.
- While visible, `SecondClock` renders the content every whole second. While hidden the clock
  stops, spinners are static, and a store change renders for the current time.

```text
┌──────────────────────────────────────────────┐
│ [⚡] Claude Meter        2m ago      (⚙) (⏻) │  header: padding 15, top 14, bottom 12
│ ┌ update notice (when available) ──────────┐ │
│ ┌ notices ─────────────────────────────────┐ │  body: padding 15, top 2, bottom 16
│ ┌ hero ────────────────────────────────────┐ │  spacing 12
│  ACCOUNTS                     ◌ week ● 5-hr  │
│  Drag a Claude or Codex card to the top…     │
│  (▭ Menu bar)                                 │  pill above the main card
│ ┌ card ────────────────────────────────────┐ │  card list spacing 10
└──────────────────────────────────────────────┘
```

Header: a 30 pt bolt tile, "Claude Meter" (never wraps), the updated time (truncates first),
then Settings and Quit (28 pt; Quit shows on the welcome too). Settings, "Get started →"
(on the Data tab), and "Open Settings" open Settings, which ends the welcome.

Status screens (`StatusScreenView`): a 76 pt raised disc with the mascot (hidden from
accessibility), Fredoka SemiBold 20 title, wrapping Nunito SemiBold 12 message (inline code
in monospace), and a raised button. Loading: a spinner over a Nunito SemiBold 13 message.

Hero (`HeroView`): a 46 pt disc with the mascot, title and subtitle that wrap, tone colors,
padding 14×13. VoiceOver reads it as one element: "title. subtitle".

### Card list and reordering

`CardList` renders `AccountsModel.cards`. A local `DragGesture` (minimum 8 pt, named
coordinate space) tracks the pointer in `@GestureState`, so it resets on end and cancel.
`CardReorder.targetIndex` (pure) gives the card a new place only after the pointer crosses
a neighbor's midpoint; a pointer above or below the list counts as its first or last place.
During the drag the list shows a preview from view state only
(`AccountsModel.dragPreview`, `CardDragPreview`): it starts in the card's own place, it
skips places that the drop would refuse (Cursor, Grok, or extra usage first; the main card
off the top), and the pill moves to the card that the drop makes the main meter. So a first
card that is not the main card gets the pill when the drag starts, and a drop in place pins
it. The dragged card lifts (102%, a soft shadow; no scale under Reduce Motion). The drop
calls `AppModel.moveCard(_:to:visible:)` once, with the place that the preview shows; a
cancelled drag, or a refresh that changes the cards, puts them back. No pasteboard, no drops
from outside, and a hidden popover does not reorder. The release that ends a drag does not
toggle the bar card under the pointer, and the header does not show as pressed during the
drag.

Dragging is not the only way to choose the menu-bar meter: a Claude or Codex card that is
not the main card has "Use in Menu Bar" in its context menu and as a VoiceOver action
(`CardModel.canUseInMenuBar`); it moves the card to the top. VoiceOver also gets "Move up"
and "Move down", only where the move works (`AccountsModel.canMove`), and an announcement of
where the card went. Cards speak the provider once (`CardModel.spokenTitle`), and a bar
header's value is its headline and whether it is expanded.

## Cards (`Cards/`)

All cards: padding 14×13, `chunkyCard()`, full width.

- **Ring card** (`RingCardView`): the name (Fredoka SemiBold 15) with badges at the trailing
  edge, or below the name when they do not fit. Then rings and rows, 14 pt apart. Each row
  (`RingMetricRow`): dot, short title, value in severity ink, caption, and "Resets in …"
  below, indented 15 pt. Details and the status line follow; ring cards are always open.
- **Bar card** (`BarCardView`): a header button (provider mark, name, badges, headline
  value, chevron; 28 pt minimum height) that calls `toggleCard`. One 12 pt `BarRow` per
  window with "Session · 60% left" and the reset, unless `BarsModel.showsBarLabels` is false
  (Cursor and Grok: the caption states the spend and the reset; Grok's also names the
  window). Then the caption and status line.
  Expanded details reveal from the top with the card height; the card clips its content.
- **Extra usage** (`ExtraUsageCardView`): 💳, title, "paused" chip, and the amount spent of
  the limit (`$12.50 / $50.00`). The monthly limit is a budget, drawn as energy like every
  other limit (`ExtraUsageModel`): the 12 pt bar fills with the share of the limit left (the
  share spent in Usage mode), in the severity color of the share spent against the user's
  thresholds, with the share in words below (`75% left`). In Energy left mode the bar drains
  and turns orange, then red, as money is spent, and it is empty at the limit. In Usage mode
  it fills as money is spent, in the same colors, so it is green only while little is spent
  and red and full at the limit. Without a limit share there is no bar.
- **Details** (`DetailSectionsView`), each after a 1 pt `cardBorder` rule: limit rows
  (`LimitRow`), usage bars (`UsageBarRow`, 7 pt bars, the value with "left" or "used"), usage-limit resets
  (`ResetsSectionView`: count, rows with the exact date in a tooltip, note), and tokens used
  (`TokensSectionView`: source label with a scope tooltip, three rows with full counts in
  tooltips and accessibility values, note).
- **Status line**: Nunito SemiBold 11, `energyLowInk` for failures, `inkMuted` otherwise.

## Menu bar (`MenuBar/`)

`StatusItemController` owns an `NSStatusItem`. Its button hosts `MenuBarLabel` in a hosting
view that ignores clicks and stays out of the accessibility tree. The button's accessibility
label is `MenuBarModel.accessibilityLabel`. The label renders again on every change to what
the model reads (Observation, tracked in the render itself) and on a 30 s clock (5 s
tolerance, common run-loop modes, stopped while the display sleeps), so resets and staleness
show without a refresh. A render whose model and pulse equal the shown ones does not touch
the button. The label keeps flexible top and bottom margins, so it stays centered when the
menu bar changes height. Colors are real colors, not a template.

| `MenuBarModel.icon` | Drawing |
| --- | --- |
| `.bolt(.dot(severity))` | `bolt.fill` 13 bold, 6 pt dot at top trailing in the severity fill |
| `.bolt(.stale)` | dot in the system secondary color, no number |
| `.bolt(.exhausted)` | red capsule with "0" (7 pt heavy, white) |
| `.bolt(.none)` | no badge (before setup, paused, or no reading yet) |
| `.loading` | `arrow.clockwise` that turns once a second, redrawn at most 30 times a second |
| `.error` | `bolt.trianglebadge.exclamationmark.fill`, hierarchical |

The number is system rounded 12 bold with monospaced digits. `isDimmed` (before setup and
while paused) draws the item in the system secondary label color, with no further fade, so
it stays visible. A dot of unknown severity also uses the secondary color.

Critical pulse (`CriticalPulse`, pure): when the badge becomes critical, the dot scales to
135% and fades to 55% three times over 1.2 s each, redrawn at most 12 times a second. Then it
stays still. Loading, stale, and error periods do not restart it. Reduce Motion turns it off.

## Settings (`Settings/`)

`SettingsWindowController` owns a titled window, "Claude Meter Settings", 580 pt wide and
700 pt tall when the screen allows it. The height can change (at least 420 pt), and the
window never reaches past the visible frame (`SettingsWindowPlacement`, pure); pages scroll.
It remembers its place, its tab (`SettingsNavigation`), and a launch-at-login error
(`LaunchAtLoginState`); while it is closed its SwiftUI content is gone, so nothing renders. To open, the app switches to the regular activation
policy (Dock icon, menu bar, Command-Tab), activates, and then orders the window to the
front, asking once more on the next turn because activation is cooperative. It returns to
accessory when the last titled window closes, so Sparkle's window keeps the Dock icon
(`DockIconPolicy`, pure). Every
path into Settings (the popover, Command-comma, reopening the app, About) calls
`completeOnboarding()`. `MainMenu` (app, Edit, Window) is installed at launch and shows while
the app is regular; "About Claude Meter" opens the About tab.

- Tab bar (`SettingsTabBar`): Data, Appearance, Advanced, About; 112 pt targets; the selected
  tab has the hero-full fill and border and the selected trait; Command-1 to Command-4.
- Pages (`SettingsPage`): Fredoka Bold 26 title, Nunito SemiBold 13 subtitle, 24 pt insets,
  scrolling. Cards (`SettingsCard`) use padding 16 and radius 18. Rows (`SettingsRow`) have a
  40 pt tile, a Fredoka SemiBold 16 title, a Nunito SemiBold 12 subtitle, and a trailing
  control.
- **Data** (`Data/DataSettingsView`): one `DataSourceCard` per source with its switch.
  Controls for a source go in its card content, below a divider, while the source is on.
  - Claude: the connection (`ClaudeConnectionView`): both logins' states; Connect
    automatically (with a Keychain consent alert), Enter tokens manually or Update tokens,
    and Disconnect, as `DataSourceText.connectionButtons` says for the connection; and the
    last message, which shows a failure in `energyEmptyInk` with a warning symbol. Below a
    divider: the config dirs (`ClaudeAccountsList`) in automatic mode, or a "Plan" row with
    the manual login's badge or plan menu (`ClaudeSettingsModel.manualPlan`) in manual
    mode. While Claude is off these controls are hidden, so the Claude subtitle says when
    turning Claude off kept a Connect from being saved (`DataSourceText.claudeSubtitle`).
  - The token form (`ManualTokenForm`): a muted line that says that Claude Meter keeps the
    tokens in its own Keychain item; then, in `ink` with an amber warning symbol, that the
    tokens must come from a separate Claude login (`DataSourceText.manualTokensSource`);
    the access and refresh token fields; "Set an expiry" with a date picker; and Show
    tokens, Cancel, and Connect. Return in a token field connects; Connect is not the
    window's default button, so Return in a folder name never connects. Cancel discards the
    draft and abandons a running Connect, so nothing is saved after it; Escape cancels only
    while both token fields are empty. The draft rules (trimming, when Connect is enabled,
    Escape) are in `ManualTokenDraft`. Only the newest inline question or token form answers
    Escape (`CancelShortcuts`), so one key never cancels two things.
  - Disconnect asks first in the page (`InlineConfirmation`) when it would delete tokens
    that the user entered (`DataSourceText.disconnectConfirmation`).
  - Codex: the homes (`CodexHomesList`).
  - Rows (`FolderRow`) show an avatar, a display-name field, the row's details, and 28 pt
    controls. The name saves on Return, focus loss, leaving the page or the window, and
    Quit. While the field is empty it shows the default name in `inkMuted`; the system
    placeholder color is below 4.5:1, so the name and token fields draw their own
    (`fieldPlaceholder`). A Claude row (`ClaudeAccountRow`) adds a path chip with the full
    path in its tooltip, the plan (`PlanChoice`: the reported badge, or a menu), a "Not
    tracked" chip, and a tracking switch where the login can be turned off; a login that
    is not tracked dims only its avatar, so its text keeps full contrast. A Codex row
    (`CodexHomeRow`) adds a path chip and the sign-in state, and no plan. Remove asks in
    the row first (`InlineConfirmation`). Folders are added with the open panel as a sheet
    on Settings (hidden folders shown).
- **Appearance**: card style as two visual options with a checkmark; Energy left / Usage;
  menu bar 5h / 7d / Both; warning and critical sliders (`ThresholdSlider`: step 5, arrow
  keys, VoiceOver adjustable, focus border) written through `Thresholds`; "Use automatic
  order" when `CardOrderHint.canReset`.
- **Advanced**: Fetch usage, Launch at login (`LoginItem`, with approval and error text; the
  state is read again when the app or the window becomes active; an hourglass while waiting
  for approval, a warning symbol when macOS cannot start this copy; an error stays until
  macOS reports the state that the user chose, also after a tab change or a closed window,
  `LaunchAtLoginError`), automatic update checks
  with "Check for Updates…" and the last check (renders every minute; the status line's tone
  comes from `UpdateCheckText.statusLine`, so an unknown version is muted, not green),
  Diagnostics (a sheet with a Copy button; Escape closes it), and "Write a log file" with
  Show in Finder (selects the file, or opens the folder before the first line) and the log
  folder of this build.
- **About**: the bolt tile, name, version and build, the GitHub link, MIT license, font
  credits, and the disclaimer, on one card. The card is centered in the page and scrolls
  when the window is too short for it.

## Animation

| Trigger | Animation | Reduce Motion |
| --- | --- | --- |
| Ring arc, bar fill | ease-out 0.4 s | none |
| Hero tone | ease-in-out 0.3 s | none |
| Card expand and collapse, chevron, card reorder | ease-in-out 0.18 s | none |
| Panel height | ease-in-out 0.18 s, top edge fixed | at once |
| Button press | spring 0.2 / 0.85, down 2 pt | darker tint only |
| Loading arrow | one turn per second, ≤ 30 fps | still |
| Critical pulse | 3 × 1.2 s, ≤ 12 fps | none |

`Design/Motion.swift` holds every duration. A hidden popover runs no clock and no animation:
ring, bar, and hero animations are off while `popoverIsVisible` is false.

## Accessibility

- Rings and bars expose a label and a value: "Session", "78 percent left, full energy,
  resets in 3h". The band is in the words, not only the color.
- The hero is one element: "title. subtitle".
- The menu-bar button speaks the model's summary; the drawn label is hidden.
- Every icon button has a label and a tooltip, and a target of at least 28 pt.
- Tabs and options expose the selected trait. Sliders are adjustable.
- Decorative mascots and drawings are hidden.
- Text contrast is at least 4.5:1 in both appearances, also on tinted fills and on the hover
  and press surfaces of quiet buttons (`ContrastTests` checks every pair). A notice whose
  tint is too light for text ("Update available") keeps the tint for its icon and uses
  `ink` for the text. Rows that are off never fade their text.

## Visual checks

`Tests/MeterUITests` renders the popover states, the menu-bar states, and every Settings tab
with `ImageRenderer` in light and dark. Set `CLAUDE_METER_RENDER_DIR` to a folder to write
the PNGs; a normal `swift test` writes nothing. `rendersStatically` draws native switches and
spinners as shapes and lays out scroll views at full height, because `ImageRenderer` cannot
draw AppKit controls.
