# Print the validated ABI fixture's export names in sorted order. Keep the fixture grammar here so
# every caller rejects the same malformed, empty, and duplicate rows before consuming the names.
spotty_abi_fixture_symbols() {
    local fixture_path="${1:-}"
    local fixture_symbols
    local sorted_fixture_symbols
    local duplicate_fixture_symbols

    if [[ -z "$fixture_path" || ! -f "$fixture_path" ]]; then
        print -u2 "The C ABI signature fixture is missing: ${fixture_path:-<none>}"
        return 1
    fi
    if ! fixture_symbols="$(awk -F'|' '
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        NF != 2 ||
        $1 !~ /^spotty_playback_[a-z0-9_]+$/ ||
        $2 !~ /^[[:alnum:]_ *]+ \([[:alnum:]_ *,]*\)$/ {
            exit 1
        }
        { print $1 }
    ' "$fixture_path")"; then
        print -u2 "The C ABI signature fixture contains malformed rows: $fixture_path"
        return 1
    fi
    if [[ -z "$fixture_symbols" ]]; then
        print -u2 "The C ABI signature fixture contains no exported functions: $fixture_path"
        return 1
    fi
    if ! sorted_fixture_symbols="$(print -r -- "$fixture_symbols" | sort)"; then
        print -u2 "Could not sort C ABI signature fixture names: $fixture_path"
        return 1
    fi
    if ! duplicate_fixture_symbols="$(print -r -- "$sorted_fixture_symbols" | uniq -d)"; then
        print -u2 "Could not validate duplicate C ABI signature fixture names: $fixture_path"
        return 1
    fi
    if [[ -n "$duplicate_fixture_symbols" ]]; then
        print -u2 "The C ABI signature fixture contains duplicate export names:"
        print -u2 "$duplicate_fixture_symbols"
        return 1
    fi

    print -r -- "$sorted_fixture_symbols"
}

# The selected artifact can lag the producer during a staged API addition or retirement.
# Keep every call available in that artifact, and reject unused exports it shares with the
# producer. Producer-only additions need no consumer until the app adopts their artifact.
spotty_abi_check_consumption() {
    local selected_symbols_path="$1"
    local playback_core_path="$2"
    local fixture_path="$3"
    local producer_symbols consumed_symbols missing_exports unused_exports

    producer_symbols="$(spotty_abi_fixture_symbols "$fixture_path")" || return 1
    # PlaybackCore is the sole C importer. Drop line comments and strings so mentions are not calls.
    consumed_symbols="$(sed -e 's://.*::' -e 's/"[^"]*"//g' "$playback_core_path" \
        | grep -Eo 'spotty_playback_[a-z0-9_]+[[:space:]]*\(' \
        | sed -E 's/[[:space:]]*\($//' | sort -u)" || return 1
    missing_exports="$(comm -23 <(print -r -- "$consumed_symbols") "$selected_symbols_path")" || return 1
    if [[ -n "$missing_exports" ]]; then
        print -u2 "PlaybackCore.swift calls exports missing from the selected artifact:"
        print -u2 "$missing_exports"
        return 1
    fi
    unused_exports="$(comm -12 "$selected_symbols_path" <(print -r -- "$producer_symbols") \
        | comm -23 - <(print -r -- "$consumed_symbols"))" || return 1
    if [[ -n "$unused_exports" ]]; then
        print -u2 "Current producer exports in the selected artifact are not called from PlaybackCore.swift:"
        print -u2 "$unused_exports"
        return 1
    fi
}
