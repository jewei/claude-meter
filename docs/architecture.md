# Architecture

Claude Meter uses three layers. Dependencies point inward; the widget never
links provider code.

```text
ClaudeMeter app ──────> ClaudeMeterProviders ──────> ClaudeMeterCore
       │                                                  ↑
       └──────────────────────────────────────────────────┘
ClaudeMeterWidget ────────────────────────────────────────┘
```

## Modules

- `ClaudeMeterCore` owns normalized usage models, snapshot storage, display and
  notification policy, history, and the `ClaudeMeterPipeline` protocol. It has
  no AppKit, SwiftUI, Security, subprocess, or network boundary.
- `ClaudeMeterProviders` owns external I/O: Claude statusline and OAuth,
  Keychain access, provider HTTP, local transcript scanning, and the Codex,
  Cursor, and Grok adapters. It depends only on `ClaudeMeterCore`.
- `ClaudeMeter` owns `AppState`, polling orchestration, macOS lifecycle services,
  settings, notifications, and SwiftUI views. Feature views are split by screen;
  the settings shell only selects feature tabs.
- `ClaudeMeterWidget` reads `SnapshotStore.appGroup()` and depends only on Core.

## Polling flow

1. `AppState` captures one immutable `PollConfiguration` for the cycle.
2. Enabled providers fetch independently. A provider failure does not cancel its
   siblings or affect Claude-only menu bar, widget, and notification behavior.
3. The pipeline generation is checked before results reach published state, so
   an old cycle cannot overwrite a rebuilt pipeline.
4. Optional providers publish one `ReadingState`: current, stale with the last
   good value, or failed. This keeps value, timestamp, and error coherent.
5. Claude snapshots are enriched with local cost data and optional OAuth account
   data, persisted, then passed to history, notifications, and the widget.

## Source layout

```text
ClaudeMeter/                         app orchestration and feature views
ClaudeMeterWidget/                   widget-only UI
ClaudeMeterCore/Sources/
  ClaudeMeterCore/                   pure models, policy, and persistence
  ClaudeMeterProviders/              external provider boundaries
ClaudeMeterCore/Tests/
  ClaudeMeterCoreTests/              pure behavior tests
  ClaudeMeterProvidersTests/         provider and integration-boundary tests
```

The Xcode project remains hand-maintained. SwiftPM is the authoritative module
graph and provides the fast cross-module compile and test path.
