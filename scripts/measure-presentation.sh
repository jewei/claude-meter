#!/usr/bin/env bash
# Run synthetic presentation work in the test host. No provider I/O or live accounts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MEASUREMENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-meter-measure.XXXXXX")"
trap 'rm -rf "$MEASUREMENT_DIR"' EXIT

sw_vers
xcodebuild -version
swift --version
sysctl -n hw.model machdep.cpu.brand_string

xcodebuild -project "$PROJECT_DIR/ClaudeMeter.xcodeproj" -scheme ClaudeMeter \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$MEASUREMENT_DIR" CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES \
    -quiet build-for-testing

python3 - "$MEASUREMENT_DIR" <<'PY'
import pathlib
import plistlib
import sys

root = pathlib.Path(sys.argv[1])
runs = list((root / "Build/Products").glob("*.xctestrun"))
if len(runs) != 1:
    raise SystemExit(f"Expected one test run file; found {len(runs)}")
path = runs[0]
with path.open("rb") as stream:
    run = plistlib.load(stream)
for configuration in run["TestConfigurations"]:
    for target in configuration["TestTargets"]:
        target.setdefault("EnvironmentVariables", {})["CLAUDE_METER_MEASURE_PRESENTATION"] = "1"
        target["EnvironmentVariables"]["CLAUDE_METER_PRESENTATION_OUTPUT"] = str(root / "presentation.log")
with path.open("wb") as stream:
    plistlib.dump(run, stream)
PY

xcodebuild -xctestrun "$MEASUREMENT_DIR"/Build/Products/*.xctestrun \
    -destination 'platform=macOS' \
    '-only-testing:ClaudeMeterTests/AppLogicTests/presentationBenchmark()' \
    -resultBundlePath "$MEASUREMENT_DIR/measurement.xcresult" \
    -quiet test-without-building

python3 - "$MEASUREMENT_DIR/presentation.log" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
samples = re.findall(r"PRESENTATION accounts=(\d+) iterations=(\d+) median_us_per_batch=([\d.]+)", text)
if {count for count, _, _ in samples} != {"1", "5", "20"}:
    raise SystemExit("Presentation benchmark did not report all three fixture sizes")
for count, iterations, duration in samples:
    print(f"PRESENTATION accounts={count} iterations={iterations} median_us_per_batch={duration}")
PY
