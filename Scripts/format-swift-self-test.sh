#!/bin/zsh
set -euo pipefail

# Wrapper-contract checks for Scripts/format-swift.sh. Uses a temp Git repo and a
# fake toolchain so the real working tree is not mutated. Invoked from check.sh.

project_root="${0:A:h:h}"
wrapper="$project_root/Scripts/format-swift.sh"
config_path="$project_root/.swift-format"

if [[ ! -x "$wrapper" || ! -f "$config_path" ]]; then
    print -u2 "format-swift self-test requires Scripts/format-swift.sh and .swift-format"
    exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/spotty-format-swift.XXXXXX")"
{
    fake_bin="$tmp/fake-bin"
    mkdir -p "$tmp/Scripts" "$tmp/Sources" "$fake_bin"
    script="$tmp/Scripts/format-swift.sh"
    config="$tmp/.swift-format"
    cp "$wrapper" "$script"
    chmod +x "$script"
    cp "$config_path" "$config"
    log="$tmp/formatter.log"
    : > "$log"

    write_xcrun() {
        local find_swift="$1"
        local find_format="$2"
        cat > "$fake_bin/xcrun" <<EOF
#!/bin/zsh
set -euo pipefail
if [[ "\${1:-}" == --find && "\${2:-}" == swift ]]; then
    if [[ "$find_swift" == 1 ]]; then
        print -r -- "$fake_bin/swift"
        exit 0
    fi
    exit 1
fi
if [[ "\${1:-}" == --find && "\${2:-}" == swift-format ]]; then
    if [[ "$find_format" == 1 ]]; then
        print -r -- "$fake_bin/swift-format"
        exit 0
    fi
    exit 1
fi
exit 1
EOF
        chmod +x "$fake_bin/xcrun"
    }

    cat > "$fake_bin/swift" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
    print "Apple Swift version 6.1.2 (self-test)"
    exit 0
fi
exit 1
EOF
    chmod +x "$fake_bin/swift"

    cat > "$fake_bin/swift-format" <<'EOF'
#!/bin/zsh
set -euo pipefail
log="${SPOTTY_FAKE_FORMAT_LOG:?}"
print -r -- "$*" >> "$log"
if [[ "${1:-}" == --version ]]; then
    print "0.0.0-self-test"
    exit 0
fi

files=()
subcommand=""
in_place=0
while (( $# > 0 )); do
    case "$1" in
        --)
            shift
            files+=("$@")
            break
            ;;
        lint|format)
            subcommand="$1"
            shift
            ;;
        --in-place|-i)
            in_place=1
            shift
            ;;
        --strict|-s|--parallel|-p)
            shift
            ;;
        --configuration)
            shift 2
            ;;
        *)
            if [[ "$1" == -* ]]; then
                shift
            else
                files+=("$1")
                shift
            fi
            ;;
    esac
done

if (( ${#files} == 0 )); then
    print -u2 "fake swift-format received no files"
    exit 1
fi

if [[ "$subcommand" == lint ]]; then
    for file in "${files[@]}"; do
        if grep -q UNFORMATTED -- "$file"; then
            print -u2 "$file: unformatted"
            exit 1
        fi
    done
    exit 0
fi

if [[ "$subcommand" == format && "$in_place" == 1 ]]; then
    for file in "${files[@]}"; do
        perl -pi -e 's/UNFORMATTED/FORMATTED/g' "$file"
    done
    exit 0
fi

print -u2 "fake swift-format unsupported invocation"
exit 1
EOF
    chmod +x "$fake_bin/swift-format"

    git -C "$tmp" init -q
    git -C "$tmp" config user.email "format-swift-self-test@spotty.invalid"
    git -C "$tmp" config user.name "Spotty format-swift self-test"

    print 'let value = UNFORMATTED' > "$tmp/Package.swift"
    print 'let source = UNFORMATTED' > "$tmp/Sources/App.swift"
    print 'let script = UNFORMATTED' > "$tmp/Scripts/tool.swift"
    print 'let spaced = UNFORMATTED' > "$tmp/file with spaces.swift"
    print 'fn unused() {}' > "$tmp/ignored.rs"
    print '{"k":1}' > "$tmp/ignored.json"
    print '# ignored' > "$tmp/ignored.md"
    print 'echo ignored' > "$tmp/ignored.sh"
    print 'int ignored;' > "$tmp/ignored.h"
    print 'let newSource = UNFORMATTED' > "$tmp/untracked.swift"
    print 'let deleted = UNFORMATTED' > "$tmp/deleted.swift"
    print 'let skipped = UNFORMATTED' > "$tmp/scratch.ignored.swift"
    print '.build/\n*.ignored.swift' > "$tmp/.gitignore"
    mkdir -p "$tmp/.build/generated"
    print 'let generated = UNFORMATTED' > "$tmp/.build/generated/Generated.swift"

    git -C "$tmp" add \
        Package.swift \
        Sources/App.swift \
        Scripts/tool.swift \
        "file with spaces.swift" \
        deleted.swift .gitignore \
        ignored.rs ignored.json ignored.md ignored.sh ignored.h \
        .swift-format \
        Scripts/format-swift.sh
    rm "$tmp/deleted.swift"

    export SPOTTY_FAKE_FORMAT_LOG="$log"
    export PATH="$fake_bin:$PATH"

    write_xcrun 1 0
    if "$script" --check >/dev/null 2> "$tmp/missing-format.err"; then
        print -u2 "expected --check to fail when swift-format is missing"
        exit 1
    fi
    if ! grep -q 'swift-format was not found' "$tmp/missing-format.err"; then
        print -u2 "missing formatter did not fail clearly:"
        cat "$tmp/missing-format.err" >&2
        exit 1
    fi

    write_xcrun 1 1
    if "$script" --check >/dev/null 2> "$tmp/unformatted.err"; then
        print -u2 "expected --check to fail on an unformatted tracked Swift file"
        exit 1
    fi

    "$script" --write >/dev/null
    if grep -q UNFORMATTED "$tmp/Package.swift" "$tmp/Sources/App.swift" "$tmp/Scripts/tool.swift" "$tmp/file with spaces.swift" "$tmp/untracked.swift"; then
        print -u2 "write mode did not format repository Swift sources"
        exit 1
    fi
    for protected in "$tmp/scratch.ignored.swift" "$tmp/.build/generated/Generated.swift"; do
        if ! grep -q UNFORMATTED "$protected"; then
            print -u2 "write mode mutated an ignored Swift file: $protected"
            exit 1
        fi
    done
    "$script" --check >/dev/null
    print 'let newSource = UNFORMATTED' > "$tmp/untracked.swift"
    if "$script" --check >/dev/null 2> "$tmp/untracked.err"; then
        print -u2 "expected --check to reject formatting drift in a new file before staging"
        exit 1
    fi

    if ! grep -F -q 'Package.swift' "$log"; then
        print -u2 "tracked Package.swift was not passed to the formatter"
        exit 1
    fi
    if ! grep -F -q 'Sources/App.swift' "$log"; then
        print -u2 "tracked Sources/*.swift was not passed to the formatter"
        exit 1
    fi
    if ! grep -F -q 'Scripts/tool.swift' "$log"; then
        print -u2 "tracked Scripts/*.swift was not passed to the formatter"
        exit 1
    fi
    if ! grep -F -q 'file with spaces.swift' "$log"; then
        print -u2 "tracked Swift path with spaces was not passed to the formatter"
        exit 1
    fi
    if grep -E -q 'deleted\.swift|scratch\.ignored\.swift|\.build/|ignored\.(rs|json|md|sh|h)' "$log"; then
        print -u2 "formatter received an excluded path:"
        cat "$log" >&2
        exit 1
    fi

    empty="$tmp/empty"
    mkdir -p "$empty/Scripts"
    cp "$script" "$empty/Scripts/format-swift.sh"
    cp "$config" "$empty/.swift-format"
    git -C "$empty" init -q
    git -C "$empty" add .swift-format Scripts/format-swift.sh
    if PATH="$fake_bin:$PATH" SPOTTY_FAKE_FORMAT_LOG="$log" "$empty/Scripts/format-swift.sh" --check \
        >/dev/null 2> "$tmp/empty.err"; then
        print -u2 "expected --check to fail when no repository Swift files exist"
        exit 1
    fi
    if ! grep -q 'No repository Swift sources were found' "$tmp/empty.err"; then
        print -u2 "empty source set did not fail clearly:"
        cat "$tmp/empty.err" >&2
        exit 1
    fi

    print "format-swift.sh self-test passed"
} always {
    rm -rf "$tmp"
}
