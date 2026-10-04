# Claude Meter

A macOS 14+ menu-bar app that shows coding quota for Claude, Codex, Cursor, and Grok as
energy left. Swift 6, SwiftUI hosted in AppKit, Sparkle updates. No Dock icon.

Read this file before you change anything. It is short on purpose: every rule here is one
that a change has broken before.

## Commands

| Command | What it does |
| --- | --- |
| `make check` | The gate. Format lint, all tests with warnings as errors, unsigned Debug and Release app builds. CI runs exactly this. |
| `make test` | Build with warnings as errors, then run every test. Prints only failures, with file and line. Fast; no Xcode project involved. |
| `make test VERBOSE=1` | The same, and lists every test. Use it to find the test that crashed. |
| `make format` | Format every Swift file with `swift format` and `.swift-format`. |
| `make app` / `make run` | Build the unsigned Debug app / build and launch it. |
| `make release VERSION=… BUILD=…` | Signed, notarized release. Maintainer only; agents never run it. See `docs/releasing.md`. |

A change is done when `make check` passes and the docs that describe the behavior are
updated in the same commit.

## Map

All code is one Swift package (`Package.swift`). A module imports only modules above it.

| Module | Owns | Never |
| --- | --- | --- |
| `MeterDomain` | Value types and pure rules: `ProviderUsage`, `AccountUsage`, `QuotaWindow`, `Reading`, `Severity`, `AccountSelection`, `Countdown`, `TokenHistory`, `Redactor`, provider protocols | I/O of any kind |
| `MeterPlatform` | OS adapters: `HTTPClient`, `Keychain`, `LocalFile`, `BlockingIO`, `SQLiteReader`, `LineProcess`, `Log`, `KeyValueStore`, `JWTClaims`, `DateParsing`, history scanning | Provider knowledge |
| `ProviderClaude`, `ProviderCodex`, `ProviderCursor`, `ProviderGrok` | One provider each: credentials, wire formats, mapping to the domain model | Another provider, `MeterApp`, UI |
| `MeterApp` | `Settings`, `UsageStore` (the only owner of readings), `RefreshScheduler`, the reading archive, presentation models | SwiftUI views, wire formats |
| `MeterUI` | SwiftUI views, design tokens, status item, popover panel, Settings window | Business rules (put them in `MeterApp` with a test) |
| `App/` | Xcode app target: entry point, Sparkle, Info.plist, icon | Logic of any kind |

Tests mirror the modules in `Tests/`. Shared fakes (`FakeHTTPClient`, `FakeKeychain`,
`TemporaryDirectory`, `JWTFixture`, `.reference()` dates) are in `Tests/MeterTestSupport`.

Docs, each the single source for its topic:

| Doc | Topic |
| --- | --- |
| `docs/architecture.md` | Layers, data flow, provider contract, refresh lifecycle, retention, storage, time limits |
| `docs/product.md` | Every user-visible rule and the code that owns it |
| `docs/design.md` | Visual tokens, type, components, layout, animation, accessibility |
| `docs/providers/*.md` | Each provider's external contracts and rules (Claude: `claude-oauth.md`) |
| `docs/token-history.md` | Local token history: files, counting rules, limits |
| `docs/development.md` | Requirements, commands, the Xcode project, where things live |
| `docs/releasing.md` | Signing, notarization, the update feed, recovery |

## Rules

### Architecture

1. **One model.** Providers map their wire formats to `ProviderUsage` inside their module.
   Wire types never leave it.
2. **One owner of readings.** `UsageStore` holds every `Reading`. Providers hold no usage
   cache; each refresh hands them the `previous` value.
3. **One retention rule.** A failed account keeps its last observation, marked stale, only
   while `AccountUsage.belongs(to:)` says its owner is still signed in.
4. **One settings value.** All preferences live in `Settings` (one Codable struct). Add a
   property with a default; decoding fills missing keys from defaults.
5. **Views render, models decide.** Anything with an `if` about data (ordering, copy,
   severity, staleness) is a pure function in `MeterApp/Presentation` with a test.
6. **Only Claude and Codex can own the menu bar** (`ProviderID.canOwnMenuBar`). A missing
   selection shows as unavailable: it never falls back to another account, and a provider
   in use never yields to the other provider (`docs/product.md` §2).

### Concurrency

- Swift 6 language mode with complete checking. No `@unchecked Sendable` without a comment
  that names the lock or queue.
- UI state is `@MainActor`. Providers are actors or immutable `Sendable` types.
- Every wait on the outside world has a deadline: `withDeadline` for async work,
  `BlockingIO.run(timeout:)` for blocking calls (files, SQLite, Keychain).
- Never `Data(contentsOf:)` for a file that another app owns. Use `LocalFile.read`.

### Security and privacy

- The app never writes, refreshes, or deletes another app's credentials. The only
  credential it owns is the manual Claude OAuth item.
- Text that reaches the UI, a log, or the disk goes through `Redactor`. `UsageIssue`,
  `DiagnosticFact`, and `Log` do it for you; do not bypass them.
- Log only through `Log`. Log faults and state changes, not routine success.
- Only `AccountOwner.identity` owners may be written to disk.
- Tests never touch the network, the real Keychain, the real home directory, or
  `UserDefaults.standard`. Inject fakes.

### Release invariants

Every installed copy depends on these. Never change them without the maintainer:

- `appcast.xml` is the live update feed. Only `scripts/release.sh` edits it, and it keeps
  every item. The one exception is the maintainer's bad-release procedure
  (`docs/releasing.md`, "Recovery").
- The bundle identifier, team, `SUFeedURL`, `SUPublicEDKey`, `ClaudeMeterUpdateRequirement`,
  and the Sparkle version pin.
- `CURRENT_PROJECT_VERSION` only grows, and is never lower than the newest build in
  `appcast.xml`. The release commit sets it (`docs/releasing.md`, "The build number").

### Style

`make check` enforces formatting and warnings. Reviews enforce the rest:

- Name things for what they are. No `Manager`, `Helper`, `Utils`, or abbreviations.
- Prefer one main type per file, named after it, and files under ~300 lines.
- Comments explain why, not what. Give API that other modules call a doc comment.
- No force unwrap or `try!` in `Sources/` unless the value is a compile-time literal.
- Errors that users see are short sentences that say what to do.
- `swift format` owns formatting. Do not fight it.

## Recipes

**Add a setting.** Add a property with a default to the right group in
`Sources/MeterApp/Settings/Settings.swift`. Bind it in the Settings view. Add a test if it
changes a decision.

**Change what a card shows.** Change the model builder in `Sources/MeterApp/Presentation`,
add a test, then render the new field in `Sources/MeterUI`.

**Change a provider request.** Update the provider module, its tests with a recorded
fixture, and its doc in `docs/providers/` in the same commit. (Claude's is
`claude-oauth.md`: a file named `claude.md` would load as a `CLAUDE.md` memory file.)

**Add a provider.** Add a `ProviderID` case, a `Provider<Name>` module that implements
`UsageProvider` (and `TokenHistoryProvider` if it has history), register it in
`MeterApp/Composition`, add a doc in `docs/providers/`, and give it a card builder.
