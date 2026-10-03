# Build and test Claude Meter

From the repository root, run the full local check:

```bash
./scripts/verify-local.sh
```

The script checks release helpers and Swift formatting. It runs package tests, hosted
app tests, and unsigned Debug and Release builds. Success ends with `Local verification
passed`.

To run only the package tests, use this command:

```bash
swift test --package-path ClaudeMeterCore
```

To build only the unsigned Debug app, use this command:

```bash
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Before you change code, read the [development rules](../AGENTS.md). Use [Measure
performance](performance.md) for performance checks and [Prepare and publish a signed
release](releases.md) for releases.

## Folder structure

| Path | Contents |
| --- | --- |
| `ClaudeMeter/Application/` | App entry point, state, settings storage, updates, and refresh scheduling |
| `ClaudeMeter/Design/` | Design tokens, theme, and shared UI components |
| `ClaudeMeter/MenuBar/` | Menu-bar label, popover, transitions, and token rows |
| `ClaudeMeter/Settings/` | Settings views, OAuth connection UI, and diagnostics |
| `ClaudeMeter/Assets.xcassets/`, `ClaudeMeter/Fonts/` | App images and bundled fonts with their licenses |
| `ClaudeMeterCore/Sources/ClaudeMeterCore/` | Normalized models, storage, and policy |
| `ClaudeMeterCore/Sources/ClaudeMeterProviders/` | `Claude`, `Codex`, `Cursor`, and `Grok` folders, plus `Shared` helpers and `Migration` cleanup |
| `ClaudeMeterCore/Tests/` | Separate Core and provider test targets |
| `ClaudeMeterTests/` | Hosted app tests and visual capture tests |
| `docs/`, `docs/images/` | Guides and README screenshots |
| `scripts/` | Verification, release, and measurement tools |

The Xcode project builds the macOS app with Sparkle and bundled resources. Its groups
match the app source folders. Keep the file references and build phases in sync when
you move app files.

The root `Package.swift` supports Swift package builds and editor tooling for the app
sources. This build excludes app resources and uses the existing updater stub. Use
Xcode to build the complete app. `ClaudeMeterCore/Package.swift` defines the Core and
provider libraries and their tests.

Keep `.swift-format` at the repository root. `verify-local.sh` and CI use its format
rules, including four-space indentation. Without this file, the formatter defaults
to two spaces.

Build output belongs in ignored folders. The verification script uses
`build/verify-local/`; Swift Package Manager uses `.build/` in each package. Keep
release archives and debug symbols until the release retention rules allow removal.
