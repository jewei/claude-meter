# Presentation benchmark baseline

This measurement records the presentation benchmark after the fixes on 2026-09-28. The
test host used the following configuration:

| Component | Value |
| --- | --- |
| Hardware | Apple M2, Mac14,2 |
| macOS | 27.0, build 26A428 |
| Xcode | 27.0, build 27A266a |
| Swift | Apple Swift 6.4 |
| Build | Release, native architecture, testability enabled |
| Samples | One warm-up, then five batches of 500 iterations |

The script reports the median time per complete model batch:

| Accounts | Median time |
| --- | --- |
| 1 | 10.376 microseconds |
| 5 | 42.833 microseconds |
| 20 | 170.848 microseconds |

These values have no comparison with an earlier build and no numerical pass threshold.
They measure display-model work, without SwiftUI layout, drawing, animation, native
accessibility, or whole-app energy use.

The measurement command is:

```bash
./scripts/measure-presentation.sh > /tmp/claude-meter-presentation.log 2>&1
```

[Measure performance](performance.md) defines the procedure and comparison limits.
