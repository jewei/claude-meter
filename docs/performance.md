# Performance checks

Run `swift test --package-path ClaudeMeterCore` for the fast package check. Run
`./scripts/verify-local.sh` for formatting, package and app tests, and unsigned Debug
and Release builds. CI prints its Xcode, Swift, and macOS versions; record those versions
with a measurement instead of assuming that the runner image stays unchanged.

## Synthetic presentation benchmark

Run `./scripts/measure-presentation.sh > /tmp/claude-meter-presentation.log 2>&1`.
The script builds a native-architecture Release test host with testability enabled in
a temporary directory and removes it on exit.
It prints hardware and toolchain details, then runs only `presentationBenchmark` with
synthetic accounts. It uses no provider I/O, credentials, account files, or app monitors.

The benchmark measures account resolution, selection, card and menu-bar conversion,
and hero text for 1, 5, and 20 accounts. It warms up once, then reports the median of
five batches of 500 iterations. Each iteration uses the same fixed observation time.
Search the output for `PRESENTATION`. Compare the same machine, toolchain, build settings,
and fixture before setting a numerical regression threshold.

This measures display-model work. It does not measure SwiftUI layout, drawing,
animation, native accessibility, or whole-app energy use. Do not report a UI speed or
energy improvement from this result alone.

Baseline after the presentation fixes, 2026-09-28: Apple M2 (Mac14,2), macOS 27.0
(26A428), Xcode 27.0 (27A266a), Apple Swift 6.4. Release, native architecture,
testability enabled; one warm-up and five measured batches of 500 iterations.

| Accounts | Median time per complete model batch |
| --- | --- |
| 1 | 10.376 microseconds |
| 5 | 42.833 microseconds |
| 20 | 170.848 microseconds |

These values establish a baseline. There is no before/after speed comparison and no
numerical pass threshold.

## Native runtime sampling

Use a separate test account with synthetic provider data for app-level checks. Build
the existing sampler and supply the exact test process ID:

```bash
clang -O2 scripts/measure-runtime.c -o /tmp/claude-meter-runtime
/tmp/claude-meter-runtime PID 300 > /tmp/claude-meter-runtime.csv
```

This records 60 seconds at five samples per second. CPU time, wakeups, and disk I/O are
cumulative; compare their deltas. Record hardware, macOS, Xcode, build configuration,
fixture size, process ID, and sampling duration with each result.

Check these scenarios separately: popover closed; popover open with 1, 5, and 20 accounts;
critical pulse after it ends; repeated open/close and display sleep/wake; failed provider;
and blocked preflight. Watch for increasing memory, worker activity, or child processes.
The source-level benchmark is repeatable without a desktop. These native checks still
require an isolated desktop fixture and are not part of the automated performance result.
