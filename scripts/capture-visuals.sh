#!/usr/bin/env bash
# Capture native SwiftUI surfaces with synthetic readings and a separate user home.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPTURE_DIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/claude-meter-visual.XXXXXX")}"
BUILD_DIR="${CLAUDE_METER_VISUAL_BUILD:-/tmp/claude-meter-visual-build}"
mkdir -p "$CAPTURE_DIR" "$CAPTURE_DIR/home"
CAPTURE_DIR="$(cd "$CAPTURE_DIR" && pwd)"
xcodebuild -project "$PROJECT_DIR/ClaudeMeter.xcodeproj" -scheme ClaudeMeter \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
    'PRODUCT_BUNDLE_IDENTIFIER=com.jewei.ClaudeMeter.VisualCapture.$(PRODUCT_NAME:rfc1034identifier)' \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES -quiet build-for-testing
python3 - "$BUILD_DIR" "$CAPTURE_DIR" <<'PY'
import pathlib, plistlib, sys
root, output = map(pathlib.Path, sys.argv[1:])
paths = list((root / "Build/Products").glob("*.xctestrun"))
assert len(paths) == 1
path = paths[0]
run = plistlib.loads(path.read_bytes())
for config in run["TestConfigurations"]:
    for target in config["TestTargets"]:
        env = target.setdefault("EnvironmentVariables", {})
        env["CLAUDE_METER_VISUAL_OUTPUT"] = str(output)
        env["CFFIXED_USER_HOME"] = str(output / "home")
        env["CLAUDE_METER_MEASURE_PRESENTATION"] = "1"
path.write_bytes(plistlib.dumps(run))
PY
xcodebuild -xctestrun "$BUILD_DIR"/Build/Products/*.xctestrun \
    -destination 'platform=macOS' '-only-testing:ClaudeMeterTests/VisualCaptureTests/capture()' \
    -quiet test-without-building
printf 'Visual captures: %s\n' "$CAPTURE_DIR"
