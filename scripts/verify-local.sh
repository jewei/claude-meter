#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "▶ Checking Swift formatting"
swift format lint --recursive --strict \
    "$PROJECT_DIR/ClaudeMeterCore" \
    "$PROJECT_DIR/ClaudeMeter" \
    "$PROJECT_DIR/ClaudeMeterWidget" \
    "$PROJECT_DIR/ClaudeMeterTests"

echo "▶ Running ClaudeMeterCore tests"
swift test --package-path "$PROJECT_DIR/ClaudeMeterCore"

echo "▶ Running ClaudeMeter app tests"
xcodebuild \
    -project "$PROJECT_DIR/ClaudeMeter.xcodeproj" \
    -scheme ClaudeMeter \
    -configuration Debug \
    -destination "platform=macOS" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO \
    test

for configuration in Debug Release; do
    echo "▶ Building ClaudeMeter ($configuration, unsigned)"
    xcodebuild \
        -project "$PROJECT_DIR/ClaudeMeter.xcodeproj" \
        -scheme ClaudeMeter \
        -configuration "$configuration" \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        build
done

echo "✓ Local verification passed"
