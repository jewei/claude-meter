#!/usr/bin/env bash

set -euo pipefail

release_symbol_uuids() {
    local output
    output="$(dwarfdump --uuid "$1")" || return 1
    local uuids
    uuids="$(awk '$1 == "UUID:" { print $2, $3 }' <<< "$output" | LC_ALL=C sort -u)"
    if [[ -z "$uuids" ]]; then
        echo "error: no debug UUIDs in $1" >&2
        return 1
    fi
    printf '%s\n' "$uuids"
}

verify_release_symbols() {
    local app="$1" symbols="$2"
    local binary="$app/Contents/MacOS/ClaudeMeter"
    local dwarf="$symbols/ClaudeMeter.app.dSYM/Contents/Resources/DWARF/ClaudeMeter"
    local binary_uuids symbol_uuids
    if [[ ! -f "$binary" || ! -f "$dwarf" ]]; then
        echo "error: missing binary or dSYM for ClaudeMeter" >&2
        return 1
    fi
    binary_uuids="$(release_symbol_uuids "$binary")" || return 1
    symbol_uuids="$(release_symbol_uuids "$dwarf")" || return 1
    if [[ "$binary_uuids" != "$symbol_uuids" ]]; then
        echo "error: dSYM UUIDs or architectures do not match ClaudeMeter" >&2
        return 1
    fi
}

release_symbols_main() (
    if [[ $# -lt 3 ]]; then
        echo "usage: $0 package <app> <archive-dSYMs> <zip> | verify <app> <zip>" >&2
        exit 2
    fi
    local action="$1" app="$2" source="$3"
    local temporary
    temporary="$(mktemp -d)"
    trap 'rm -rf "$temporary"' EXIT
    case "$action" in
        package)
            [[ $# -eq 4 ]] || exit 2
            verify_release_symbols "$app" "$source"
            mkdir "$temporary/dSYMs"
            # Include only symbols for our shipped executables, from this archive.
            /usr/bin/ditto "$source/ClaudeMeter.app.dSYM" "$temporary/dSYMs/ClaudeMeter.app.dSYM"
            /usr/bin/ditto --norsrc -c -k --keepParent "$temporary/dSYMs" "$4"
            ;;
        verify)
            [[ $# -eq 3 ]] || exit 2
            /usr/bin/ditto -x -k "$source" "$temporary"
            verify_release_symbols "$app" "$temporary/dSYMs"
            ;;
        *) exit 2 ;;
    esac
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    release_symbols_main "$@"
fi
