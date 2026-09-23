#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-symbols.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/Claude Meter.app"
SYMBOLS="$TEST_DIR/build/dSYMs"
ZIP="$TEST_DIR/retained-release.dSYMs.zip"
MAIN_DWARF="$SYMBOLS/ClaudeMeter.app.dSYM/Contents/Resources/DWARF/ClaudeMeter"
mkdir -p "$APP/Contents/MacOS" "$(dirname "$MAIN_DWARF")"

# These fixtures are synthetic dwarfdump output, not executable files.
cat > "$MAIN_DWARF" <<'UUIDS'
UUID: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA (arm64)
UUID: BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB (x86_64)
UUIDS
cp "$MAIN_DWARF" "$APP/Contents/MacOS/ClaudeMeter"
dwarfdump() {
    [[ "$1" == "--uuid" ]] || return 2
    cat "$2"
}
expect_rejected() {
    if verify_release_symbols "$APP" "$SYMBOLS" 2> "$TEST_DIR/error"; then
        echo "error: invalid release symbols were accepted" >&2
        exit 1
    fi
}

verify_release_symbols "$APP" "$SYMBOLS"
release_symbols_main package "$APP" "$SYMBOLS" "$ZIP"
release_symbols_main verify "$APP" "$ZIP"

printf '%s\n' 'UUID: EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE (arm64)' > "$MAIN_DWARF"
expect_rejected
cp "$APP/Contents/MacOS/ClaudeMeter" "$MAIN_DWARF"
head -n 1 "$MAIN_DWARF" > "$TEST_DIR/one-arch"
cp "$TEST_DIR/one-arch" "$MAIN_DWARF"
expect_rejected
: > "$MAIN_DWARF"
expect_rejected
rm "$MAIN_DWARF"
expect_rejected

# A retained release copy must survive removal of the next build's work directory.
rm -rf "$TEST_DIR/build"
release_symbols_main verify "$APP" "$ZIP"
echo "✓ Release-symbol tests passed"
