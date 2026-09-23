#!/bin/bash
set -euo pipefail
trap 'echo "report-size.sh: failed at line $LINENO" >&2' ERR

# Reports release build size for measured resource comparisons (#37).
#
# Prints a Markdown table with the app binary size, the playback static archive size,
# per-segment totals for the binary, and the archive's exported symbol count.
# Appends the table to $GITHUB_STEP_SUMMARY when set, and always prints it to
# stdout. Also writes a machine-readable size-report.json under --out-dir.
#
# Usage:
#   Scripts/report-size.sh [--binary PATH] [--xcframework PATH] [--out-dir DIR]
#
# Defaults match Scripts/compile-release-spotty.sh's release layout:
#   --binary   SwiftPM's resolved release output (queried without rebuilding)
#   --xcframework  SwiftPM's resolved remote XCFramework path; use
#                  SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK for a source-built artifact
#   --out-dir  <repo>/.build (ignored by git)

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/Scripts/playback-xcframework.sh"

binary_path=""
xcframework_override=""
out_dir="$project_root/.build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)
            if [[ $# -lt 2 ]]; then
                echo "report-size.sh: --binary requires a path" >&2
                exit 1
            fi
            binary_path="$2"
            shift 2
            ;;
        --xcframework)
            if [[ $# -lt 2 ]]; then
                echo "report-size.sh: --xcframework requires a path" >&2
                exit 1
            fi
            xcframework_override="$2"
            shift 2
            ;;
        --archive)
            echo "report-size.sh: --archive is no longer accepted; pass the selected XCFramework with --xcframework" >&2
            exit 1
            ;;
        --out-dir)
            if [[ $# -lt 2 ]]; then
                echo "report-size.sh: --out-dir requires a path" >&2
                exit 1
            fi
            out_dir="$2"
            shift 2
            ;;
        *)
            echo "report-size.sh: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -n "$xcframework_override" ]]; then
    if [[ -n "${SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK:-}" ]]; then
        # An explicit local source artifact is intentionally outside the published package pin.
        # Keep the environment contract authoritative and reject a second, different path.
        local_override_path="$SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"
        case "$local_override_path" in
            /*) ;;
            *) local_override_path="$project_root/$local_override_path" ;;
        esac
        local_override_path="$(cd "$local_override_path" && pwd -P)"
        requested_override_path="$xcframework_override"
        case "$requested_override_path" in
            /*) ;;
            *) requested_override_path="$project_root/$requested_override_path" ;;
        esac
        requested_override_path="$(cd "$requested_override_path" && pwd -P)"
        if [[ "$local_override_path" != "$requested_override_path" ]]; then
            echo "report-size.sh: --xcframework conflicts with SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK" >&2
            exit 1
        fi
        selected_xcframework="$local_override_path"
    else
        # A path supplied by the release lane must be the path SwiftPM selected for the current
        # remote URL/checksum. This preserves the remote manifest validation below while still
        # allowing the size report to inspect the exact path used by compile-release-spotty.sh.
        resolved_remote_xcframework="$(spotty_playback_resolve_xcframework)"
        requested_override_path="$xcframework_override"
        case "$requested_override_path" in
            /*) ;;
            *) requested_override_path="$project_root/$requested_override_path" ;;
        esac
        requested_override_path="$(cd "$requested_override_path" && pwd -P)"
        if [[ "$resolved_remote_xcframework" != "$requested_override_path" ]]; then
            echo "report-size.sh: --xcframework must be SwiftPM's resolved remote artifact; set SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK for a source-built artifact" >&2
            exit 1
        fi
        selected_xcframework="$resolved_remote_xcframework"
    fi
else
    selected_xcframework="$(spotty_playback_resolve_xcframework)"
fi
spotty_playback_validate_xcframework "$selected_xcframework"
playback_slice="$(spotty_playback_slice_path "$selected_xcframework")"
archive_path="$(spotty_playback_archive_path "$playback_slice")"
archive_name="$(basename "$archive_path")"

if [[ -z "$binary_path" ]]; then
    # Match the compiler's selected build engine; searching old layouts can pick a stale binary.
    bin_path="$(swift build --disable-sandbox --package-path "$project_root" \
        --configuration release --product Spotty --show-bin-path)"
    binary_path="$bin_path/Spotty"
fi

if [[ ! -f "$binary_path" ]]; then
    echo "report-size.sh: binary not found at $binary_path" >&2
    exit 1
fi

if [[ ! -f "$archive_path" ]]; then
    echo "report-size.sh: playback archive not found at $archive_path" >&2
    exit 1
fi

mkdir -p "$out_dir"

# --- byte sizes -------------------------------------------------------------

binary_bytes="$(stat -f %z "$binary_path")"
archive_bytes="$(stat -f %z "$archive_path")"

to_mib() {
    LC_ALL=C awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / (1024 * 1024) }'
}

binary_mib="$(to_mib "$binary_bytes")"
archive_mib="$(to_mib "$archive_bytes")"

# --- optional: segment sizes via `size -m` ---------------------------------

text_bytes=""
data_bytes=""
linkedit_bytes=""
have_size_tool=1

if command -v size >/dev/null 2>&1; then
    size_output="$(size -m "$binary_path" 2>/dev/null || true)"
    text_bytes="$(awk -F'[ \t]+' '/Segment __TEXT:/ { print $3; exit }' <<<"$size_output")"
    data_bytes="$(awk -F'[ \t]+' '/Segment __DATA:/ { print $3; exit }' <<<"$size_output")"
    linkedit_bytes="$(awk -F'[ \t]+' '/Segment __LINKEDIT:/ { print $3; exit }' <<<"$size_output")"
    if [[ ! "$text_bytes" =~ ^[0-9]+$ || ! "$data_bytes" =~ ^[0-9]+$ || ! "$linkedit_bytes" =~ ^[0-9]+$ ]]; then
        have_size_tool=0
        text_bytes=""
        data_bytes=""
        linkedit_bytes=""
    fi
else
    have_size_tool=0
fi

# --- optional: exported symbol count via `nm -U` ----------------------------

symbol_count=""
have_nm_tool=1

if command -v nm >/dev/null 2>&1; then
    # Same form as Scripts/check.sh: Apple nm can exit non-zero on Rust objects, and
    # pipefail must not turn that into a script abort. -gU = global, defined only.
    # Count only symbol lines; nm also prints one "lib.a(member.o):" header per member.
    symbol_count="$( (nm -gU "$archive_path" 2>/dev/null || true) | grep -Ec '^[0-9a-f]+ [A-Za-z] ' || true)"
    if [[ -z "$symbol_count" || "$symbol_count" == "0" ]]; then
        have_nm_tool=0
    fi
else
    have_nm_tool=0
fi

# --- render Markdown ---------------------------------------------------------

render_table() {
    echo "| Metric | Value |"
    echo "| --- | ---: |"
    echo "| App binary | ${binary_bytes} bytes (${binary_mib} MiB) |"
    echo "| ${archive_name} | ${archive_bytes} bytes (${archive_mib} MiB) |"
    if [[ "$have_size_tool" -eq 1 ]]; then
        echo "| Binary __TEXT | ${text_bytes} bytes ($(to_mib "$text_bytes") MiB) |"
        echo "| Binary __DATA | ${data_bytes} bytes ($(to_mib "$data_bytes") MiB) |"
        echo "| Binary __LINKEDIT | ${linkedit_bytes} bytes ($(to_mib "$linkedit_bytes") MiB) |"
    else
        echo "| Binary segments | unavailable (\`size\` tool missing or unparseable) |"
    fi
    if [[ "$have_nm_tool" -eq 1 ]]; then
        echo "| Archive exported symbols | ${symbol_count} |"
    else
        echo "| Archive exported symbols | unavailable (\`nm\` missing or reported no symbols) |"
    fi
}

table_heading="## Release build size"
table_body="$(render_table)"

print_report() {
    echo "$table_heading"
    echo
    echo "$table_body"
}

print_report

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    print_report >>"$GITHUB_STEP_SUMMARY"
fi

# --- write machine-readable JSON --------------------------------------------

json_path="$out_dir/size-report.json"

python3 - "$json_path" "$binary_path" "$binary_bytes" "$binary_mib" \
    "$selected_xcframework" "$archive_path" "$archive_bytes" "$archive_mib" \
    "$have_size_tool" "$text_bytes" "$data_bytes" "$linkedit_bytes" \
    "$have_nm_tool" "$symbol_count" <<'PY'
import json
from pathlib import Path
import sys

(output, binary, binary_bytes, binary_mib, framework, archive, archive_bytes, archive_mib,
 segments_available, text, data, linkedit, symbols_available, symbols) = sys.argv[1:]

def optional_number(value):
    return int(value) if value else None

report = {
    "binary_path": binary,
    "binary_bytes": int(binary_bytes),
    "binary_mib": float(binary_mib),
    "xcframework_path": framework,
    "archive_path": archive,
    "archive_bytes": int(archive_bytes),
    "archive_mib": float(archive_mib),
    "binary_segments": {
        "available": segments_available == "1",
        "text_bytes": optional_number(text),
        "data_bytes": optional_number(data),
        "linkedit_bytes": optional_number(linkedit),
    },
    "archive_exported_symbols": {
        "available": symbols_available == "1",
        "count": optional_number(symbols),
    },
}
Path(output).write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
PY

echo "Wrote $json_path"
