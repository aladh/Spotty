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
