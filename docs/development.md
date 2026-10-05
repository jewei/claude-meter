# Development

How to build, run, and test Claude Meter, and how the Xcode project is set up.

## Requirements

- A Mac with macOS 14 or later.
- Xcode 27.0 or later (Swift 6.4). `Package.swift` uses Swift tools version 6.4, so an
  older Xcode cannot build the package. CI pins Xcode 27.0 on GitHub's `xcode-27` image, a
  public preview (`.github/workflows/ci.yml`). Change the CI version, the tools version,
  and this line together.
- Nothing else. `swift format` and `make` come with Xcode.

## First build

```bash
git clone https://github.com/jewei/claude-meter.git
cd claude-meter
make check
```

`make check` lints the format, runs all tests, and builds the unsigned Debug app and the
unsigned universal Release app. The first run downloads Sparkle into `build/SourcePackages`.
CI runs the same command. A change is done when `make check` passes (see `AGENTS.md`).

To build and open the app:

```bash
make run
```

> **Note:** The development build uses the bundle identifier `com.jewei.claudemeter.debug`.
> Its settings, saved readings (`Application Support/ClaudeMeter Debug`), log file, and
> manual Claude Keychain item are separate from an installed Claude Meter (`AppIdentity`).
> It reads the same provider credentials, because Claude Code, Codex, Cursor, and Grok own
> them. `make run` quits only the development build of this checkout.

To work in Xcode, open `ClaudeMeter.xcodeproj` and run the `ClaudeMeter` scheme. Xcode
signs Debug builds with the Apple Development certificate of team 4L4SS26L9J. If you are
not on that team, use `make app` and `make run`. They build without a signature.

## Commands

| Command | What it does |
| --- | --- |
| `make help` | List the commands. This is what `make` with no target does. |
| `make check` | The gate: format lint, all tests, unsigned Debug and universal Release apps. |
| `make test` | Build with warnings as errors, then run every test. It prints a short summary for each test product, and each failure with its file and line. It does not use the Xcode project. |
| `make test VERBOSE=1` | The same, and it lists every test. A crash names no test in the quiet output; this shows which test ran last. |
| `make format` | Format all Swift files in place with `.swift-format`. |
| `make lint` | Fail on a format difference. |
| `make app` | Build the unsigned Debug app into `build/DerivedData`. |
| `make run` | Build the Debug app and open it. |
| `make release-build` | Build the unsigned universal Release app. |
| `make release-candidate VERSION=… BUILD=…` | Build and validate a signed candidate. It uploads to Apple notarization, but publishes nothing. Maintainer only. |
| `make clean` | Remove `.build` and `build`. |
| `make release VERSION=… BUILD=…` | Publish a signed release. Maintainer only. See [releasing.md](releasing.md). |

## How the Xcode project works

All code is in the Swift package (`Package.swift`, `Sources/`, `Tests/`). The Xcode project
is a thin shell around it. It has one target, `ClaudeMeter`, a macOS app.

- **Synchronized folders.** `App/Sources` and `App/Resources` are synchronized folder
  groups. Xcode adds every file in these folders to the target. To add, move, or delete a
  file, change the folder. The project file does not change.
- **Build settings in xcconfig files.** The project file sets no build settings. The target
  uses `Config/Debug.xcconfig` and `Config/Release.xcconfig`. Both include
  `Config/Base.xcconfig`, which includes `Config/Version.xcconfig`. Change settings in these
  files, not in the Xcode build settings editor. If Xcode writes a setting into
  `project.pbxproj`, move it to an xcconfig file.
- **Files outside the synchronized folders.** `App/Info.plist` and
  `App/ClaudeMeter.entitlements` are referenced from the build settings. They are not in
  `App/Resources`, because Xcode must not copy them into the app as resources.
- **Packages.** The project has a local package reference to the repository root. The app
  links the `MeterUI` product, which brings in every module that it needs. Sparkle is
  pinned to exactly 2.9.3. The pin is in
  `ClaudeMeter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  The make targets and the release script pass `-onlyUsePackageVersionsFromResolvedFile`,
  so a build never changes the pin.
- **No test target.** All tests are package tests. Run them with `make test`. To run them in
  Xcode, open `Package.swift` instead of the project.
- **Release signing.** Debug signs automatically with Apple Development. Release signs with
  Developer ID and the hardened runtime, and keeps dSYMs. To build Release without the
  certificate, pass `CODE_SIGNING_ALLOWED=NO`.
- **Updates.** Debug builds and builds without the release signature use
  `DisabledUpdater`. Only a Release build signed with the Developer ID of team 4L4SS26L9J
  uses Sparkle (`App/Sources/ReleaseSignature.swift`). A development build never replaces
  itself with a download.

Maintainer only. The Sparkle version pin is a release invariant (`AGENTS.md`), so only the
maintainer changes it. To update Sparkle, change the exact version in Xcode (project,
Package Dependencies). Then commit `project.pbxproj` and `Package.resolved` together. The
maintainer then runs `make release-candidate` to make sure that `sign_update` still works.

## Where things live

| Path | Contents |
| --- | --- |
| `Package.swift` | The package: all modules and test targets. |
| `Sources/<Module>/` | Module code. See `AGENTS.md` for what each module owns. |
| `Tests/<Module>Tests/` | Tests for each module. Shared fakes are in `Tests/MeterTestSupport/`. |
| `App/Sources/` | The app entry point (`main.swift`), `SparkleUpdater`, and `ReleaseSignature`. |
| `App/Resources/` | The asset catalog with the app icon. |
| `App/Info.plist` | Bundle keys, `LSUIElement`, and the Sparkle feed URL and public key. |
| `App/ClaudeMeter.entitlements` | Entitlements. The app is not sandboxed. |
| `Config/` | Build settings and the version (`Version.xcconfig`). |
| `ClaudeMeter.xcodeproj/` | The project, the shared scheme, and the package pins. |
| `scripts/` | The release script and its export options and CHANGELOG-to-HTML filter. |
| `.github/workflows/ci.yml` | CI. It runs `make check`. |
| `appcast.xml` | The live Sparkle feed. Only the release script changes it, except the maintainer's bad-release procedure. |
| `docs/` | One document per topic. The doc table in `AGENTS.md` lists them. |

## Build output

All output is in folders that Git ignores. `make clean` removes them.

| Folder | Made by |
| --- | --- |
| `.build/` | `swift test` and `swift build`. |
| `build/DerivedData/` | `make app`. The Debug app is in `Build/Products/Debug/ClaudeMeter.app`. |
| `build/SourcePackages/` | Package resolution. It holds Sparkle and its `sign_update` tool. |
| `build/release/` | `scripts/release.sh`: the archive, the DMG, the dSYMs, and the candidate feed. |
