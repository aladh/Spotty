#!/bin/zsh
set -euo pipefail

# Repository Swift formatting using swift-format from the selected Xcode/Swift toolchain.
# Modes: --check (lint --strict) and --write (format --in-place).

project_root="${0:A:h:h}"
config_path="$project_root/.swift-format"

usage() {
    print -u2 "Usage: Scripts/format-swift.sh --check|--write"
    exit 2
}

collect_swift_sources() {
    swift_files=()
    while IFS= read -r -d '' file; do
        # New files need verification before staging; deleted and ignored outputs do not.
        [[ -f "$project_root/$file" ]] && swift_files+=("$file")
    done < <(git -C "$project_root" ls-files -z --cached --others --exclude-standard -- '*.swift')
    swift_files=("${(@u)swift_files}")
    if (( ${#swift_files} == 0 )); then
        print -u2 "No repository Swift sources were found."
        exit 1
    fi
}

resolve_formatter() {
    if ! command -v xcrun >/dev/null 2>&1; then
        print -u2 "xcrun was not found. Select the Swift 6.4 Xcode toolchain so bundled swift-format is available."
        exit 1
    fi

    swift_path="$(xcrun --find swift 2>/dev/null || true)"
    formatter_path="$(xcrun --find swift-format 2>/dev/null || true)"
    if [[ -z "$formatter_path" || ! -x "$formatter_path" ]]; then
        print -u2 "swift-format was not found in the selected Swift/Xcode toolchain."
        print -u2 "Use the same selected toolchain as Swift builds; do not install a second formatter."
        exit 1
    fi
    if [[ -z "$swift_path" || ! -x "$swift_path" ]]; then
        print -u2 "swift was not found in the selected toolchain."
        exit 1
    fi
    if [[ "${swift_path:h}" != "${formatter_path:h}" ]]; then
        print -u2 "swift-format is not from the same selected toolchain as swift:"
        print -u2 "swift: $swift_path"
        print -u2 "swift-format: $formatter_path"
        exit 1
    fi

    print "Swift: $("$swift_path" --version | head -n 1)"
    print "swift-format: $("$formatter_path" --version)"
    print "swift-format path: $formatter_path"
}

run_formatter() {
    local mode="$1"
    if [[ ! -f "$config_path" ]]; then
        print -u2 "Missing Swift format configuration: $config_path"
        exit 1
    fi
    case "$mode" in
        check)
            (cd "$project_root" && "$formatter_path" lint --strict --parallel --configuration "$config_path" -- "${swift_files[@]}")
            ;;
        write)
            (cd "$project_root" && "$formatter_path" format --in-place --parallel --configuration "$config_path" -- "${swift_files[@]}")
            ;;
        *)
            usage
            ;;
    esac
}

typeset -a swift_files
formatter_path=""
swift_path=""

if [[ $# -ne 1 ]]; then
    usage
fi

case "$1" in
    --check|--write)
        ;;
    *)
        usage
        ;;
esac

if ! git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print -u2 "Swift formatting requires a Git checkout to exclude ignored outputs."
    exit 1
fi

resolve_formatter
collect_swift_sources

if [[ "$1" == --check ]]; then
    run_formatter check
else
    run_formatter write
fi
