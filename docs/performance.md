# Measure performance

Run `swift test --package-path ClaudeMeterCore` for the fast package check. Run
`./scripts/verify-local.sh` for formatting, package and app tests, and unsigned Debug
and Release builds. Record the Xcode, Swift, and macOS versions that CI prints with each
measurement. The runner image can change.

## Run the synthetic presentation benchmark

Run the benchmark from the repository root:

```bash
./scripts/measure-presentation.sh > /tmp/claude-meter-presentation.log 2>&1
```

The script builds a native-architecture Release test host with testability enabled in a
temporary directory and removes it on exit. It prints hardware and toolchain details,
then runs only `presentationBenchmark` with synthetic accounts. It uses no provider I/O,
credentials, account files, or app monitors.

The benchmark measures account resolution, selection, card and menu-bar conversion, and
hero text for 1, 5, and 20 accounts. It warms up once, then reports the median of five
batches of 500 iterations. Each iteration uses the same fixed observation time. Search
the output for `PRESENTATION`. Compare the same machine, toolchain, build settings, and
fixture before setting a numerical regression threshold.

This measures display-model work. It does not measure SwiftUI layout, drawing,
animation, native accessibility, or whole-app energy use. Do not report a UI speed or
energy improvement from this result alone.

Use the [presentation benchmark baseline](performance-baseline.md) as the recorded
measurement. It has no numerical pass threshold or comparison with an earlier build.

## Sample native runtime activity

Use a separate test account with synthetic provider data for app-level checks. Build the
existing sampler and supply the exact test process ID:

```bash
clang -O2 scripts/measure-runtime.c -o /tmp/claude-meter-runtime
/tmp/claude-meter-runtime PID 300 > /tmp/claude-meter-runtime.csv
```

The sampler records 60 seconds at five samples per second. CPU time, wakeups, and disk
I/O are cumulative. Compare the change in each value. Record hardware, macOS, Xcode,
build configuration, fixture size, process ID, and sampling duration with each result.

Check each of these scenarios separately:

- The popover is closed.
- The popover is open with 1, 5, and 20 accounts.
- The critical pulse has ended.
- The popover opens and closes repeatedly.
- The display sleeps and wakes repeatedly.
- A provider fails.
- A preflight check blocks.

Check for increasing memory use, worker activity, or child processes. Use an isolated
desktop with synthetic data for these native checks. The automated benchmark needs no
desktop and does not cover these scenarios.
