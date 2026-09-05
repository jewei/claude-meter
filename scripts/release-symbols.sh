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
    local executable bundle binary dwarf binary_uuids symbol_uuids
    for executable in ClaudeMeter ClaudeMeterWidgetExtension; do
        if [[ "$executable" == "ClaudeMeter" ]]; then
            bundle="$executable.app"
            binary="$app/Contents/MacOS/$executable"
        else
            bundle="$executable.appex"
            binary="$app/Contents/PlugIns/$executable.appex/Contents/MacOS/$executable"
        fi
        dwarf="$symbols/$bundle.dSYM/Contents/Resources/DWARF/$executable"
        if [[ ! -f "$binary" || ! -f "$dwarf" ]]; then
            echo "error: missing binary or dSYM for $executable" >&2
            return 1
        fi
        binary_uuids="$(release_symbol_uuids "$binary")" || return 1
        symbol_uuids="$(release_symbol_uuids "$dwarf")" || return 1
        if [[ "$binary_uuids" != "$symbol_uuids" ]]; then
            echo "error: dSYM UUIDs or architectures do not match $executable" >&2
            return 1
        fi
    done
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
            for bundle in ClaudeMeter.app ClaudeMeterWidgetExtension.appex; do
                /usr/bin/ditto "$source/$bundle.dSYM" "$temporary/dSYMs/$bundle.dSYM"
            done
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
