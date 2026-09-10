# Synthetic cost scan measurements

Measured on 2026-09-08 with Apple M2, macOS 15.7.9, and Apple Swift 6.2.4.
The test uses Release optimization, generated JSONL files, an in-memory file cache,
and built-in pricing. It reads no user transcripts and makes no network requests.
This run includes the device/inode cache-key fix and its shared stat-based metadata reader.
The two sizes run sequentially. Each size has one cold scan and seven unchanged warm scans.

| Files | Requests | Cold scan | Warm median | Warm maximum | Accounted cache bytes |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 50 | 5,000 | 366.1 ms | 3.00 ms | 3.87 ms | 1,493,890 |
| 500 | 50,000 | 3,564.5 ms | 39.16 ms | 39.97 ms | 15,037,390 |

Run the opt-in measurement with:

```bash
CLAUDE_METER_PROFILE_COST_SCAN=1 swift test -c release \
  --package-path ClaudeMeterCore --filter CostScanProfileTests
```

The timing table above is a baseline, not a gate. CI cannot enforce a wall-clock
threshold reliably on a shared machine. `warmScanPerformsNoRepeatParsing` therefore counts
the work instead: it asserts that a second scan of an unchanged corpus performs zero full
parses, and that one changed transcript re-parses only itself. That test runs in the normal
suite and fails if the per-file cache stops being consulted.

Keep the existing per-file cache. These warm results do not justify an aggregate cache
with another set of root, inventory, date-window, pricing, and time-zone invalidation rules.
Cost scans now run independently of quota publication, so a slow scan cannot hold a ready
quota observation. The app tests hold the scanner open and verify that quota publication
completes before the scanner is released.

This is a synthetic baseline, not a measurement of all user libraries. It includes warm
file discovery, metadata reads, request reconciliation, and pricing, but does not separate
their individual time. It excludes pricing-catalog network access, persisted-cache loading,
large tail reads, memory pressure, and slow filesystems. The retained-byte count is the
cache's accounting limit, not process resident memory. Measure a slow real workload before
adding aggregate reuse.
