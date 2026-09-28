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
