#!/bin/zsh
set -euo pipefail

backend_root="${0:A:h}"
project_root="${backend_root:h:h}"
published=false
xcframework_path=""
archive_path=""
for_publish=false

usage() {
    print -u2 "usage: $0 XCFRAMEWORK [--archive ZIP] [--published] [--for-publish]"
    exit 2
}

if (( $# == 0 )); then
    usage
fi
xcframework_path="$1"
shift
while (( $# > 0 )); do
    case "$1" in
        --archive)
            (( $# >= 2 )) || usage
            archive_path="$2"
            shift 2
            ;;
        --published)
            published=true
            shift
            ;;
        --for-publish)
            for_publish=true
            shift
            ;;
        *)
            usage
            ;;
    esac
done

xcframework_path="${xcframework_path:A}"
if [[ -n "$archive_path" ]]; then
    archive_path="${archive_path:A}"
fi

fail() {
    print -u2 "validate-xcframework.sh: $*"
    exit 1
}

[[ -d "$xcframework_path" && "$xcframework_path" == *.xcframework ]] || \
    fail "expected an XCFramework directory: $xcframework_path"
info_plist="$xcframework_path/Info.plist"
[[ -f "$info_plist" ]] || fail "XCFramework Info.plist is missing"
require_equal() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    [[ "$expected" == "$actual" ]] || fail "$label mismatch (expected $expected, found $actual)"
}

# Read the bounded metadata once instead of launching plutil for every field. This helper
# only validates metadata relationships and content hashes; lipo/otool still inspect the binary.
artifact_helper="$project_root/Scripts/playback_artifact.py"
artifact_metadata="$(python3 "$artifact_helper" metadata "$xcframework_path")" || exit 1
minimum_macos="$(cat "$backend_root/macos-deployment-target")"
artifact_minimum_macos="${artifact_metadata%%$'\n'*}"
library_relative_path="${artifact_metadata#*$'\n'}"
library_identifier=macos-arm64
headers_relative_path=Headers

library_path="$xcframework_path/$library_identifier/$library_relative_path"
headers_path="$xcframework_path/$library_identifier/$headers_relative_path"
[[ -f "$library_path" ]] || fail "static library is missing: $library_path"
[[ -d "$headers_path" ]] || fail "headers directory is missing: $headers_path"
[[ "$(lipo -archs "$library_path")" == arm64 ]] || fail "static library must contain only arm64"

canonical_include="$project_root/Sources/SpottyPlaybackCore/include"
# Consumer builds validate the released header/library pair against their pin. Source builds
# and publication additionally prove that pair was produced from the current engine checkout.
check_source=false
if [[ "$published" == false || "$for_publish" == true ]]; then
    check_source=true
fi
for header_name in spotty_playback.h spotty_playback_generated.h spotty_playback_annotations.h module.modulemap; do
    [[ -f "$headers_path/$header_name" ]] || fail "artifact header is missing: $header_name"
    if [[ "$check_source" == true ]]; then
        [[ -f "$canonical_include/$header_name" ]] || fail "canonical header is missing: $header_name"
        cmp -s "$canonical_include/$header_name" "$headers_path/$header_name" || \
            fail "artifact header differs from canonical $header_name"
    fi
done

# Validate the load-command minimum OS in the static archive. The XCFramework plist is metadata;
# this check proves the Rust objects were actually compiled for the requested deployment target.
if ! command -v otool >/dev/null 2>&1; then
    fail "otool is required to inspect the static archive"
fi
otool_dump="$(otool -l "$library_path")" || fail "could not inspect static archive load commands"
[[ "$otool_dump" == *"Load command"* ]] || fail "static archive contains no Mach-O object load commands"
python3 "$project_root/Scripts/playback_deployment.py" \
    --minimum "$minimum_macos" --declared "$artifact_minimum_macos" --check-source "$check_source" \
    <<< "$otool_dump" || fail "static archive deployment target is invalid"

provenance_arguments=()
if [[ "$check_source" == true ]]; then
    source_digest="$("$backend_root/source-input-digest.sh")"
    provenance_arguments+=(--source-digest "$source_digest")
fi
if [[ "$for_publish" == true ]]; then
    provenance_arguments+=(--for-publish)
fi
python3 "$artifact_helper" verify "$xcframework_path" \
    --expected-minimum "$artifact_minimum_macos" --expected-name "$library_relative_path" \
    "${provenance_arguments[@]}" || exit 1

for notice_path in \
    "$xcframework_path/Notices/ThirdPartyNotices.md" \
    "$xcframework_path/Notices/manifest.json" \
    "$xcframework_path/Notices/source/LICENSE" \
    "$xcframework_path/Notices/source/NOTICE" \
    "$xcframework_path/Notices/source/THIRD_PARTY_NOTICES.md"; do
    [[ -f "$notice_path" ]] || fail "artifact licensing file is missing: ${notice_path#$xcframework_path/}"
done
[[ -d "$xcframework_path/Notices/licenses" ]] || fail "artifact license directory is missing"

if [[ -n "$archive_path" ]]; then
    if ! archive_entries="$(unzip -Z1 "$archive_path" 2>/dev/null)"; then
        fail "could not list archive entries: $archive_path"
    fi
    [[ -n "$archive_entries" ]] || fail "archive is empty: $archive_path"
    duplicate_entries="$(printf '%s\n' "$archive_entries" | LC_ALL=C sort | uniq -d)"
    [[ -z "$duplicate_entries" ]] || fail "archive contains duplicate entries: $duplicate_entries"
    archive_root_entry=""
    while IFS= read -r archive_entry; do
        [[ -n "$archive_entry" ]] || continue
        case "$archive_entry" in
            /*) fail "archive contains an absolute path: $archive_entry" ;;
        esac
        case "/$archive_entry/" in
            */../*|*/./*) fail "archive contains an unsafe path: $archive_entry" ;;
        esac
        normalized_entry="${archive_entry%/}"
        if [[ "$normalized_entry" == *.xcframework ]]; then
            if [[ -n "$archive_root_entry" ]]; then
                fail "archive contains more than one XCFramework root"
            fi
            archive_root_entry="$normalized_entry"
        fi
    done <<< "$archive_entries"
    [[ -n "$archive_root_entry" ]] || fail "archive contains no XCFramework root"

    archive_extract_root="$(mktemp -d "${TMPDIR:-/tmp}/spotty-playback-archive.XXXXXX")"
    trap 'rm -rf "$archive_extract_root"' EXIT
    if ! unzip -q "$archive_path" -d "$archive_extract_root"; then
        fail "could not extract archive: $archive_path"
    fi
    archive_xcframework_candidates=("$archive_extract_root"/**/*.xcframework(N/))
    if (( ${#archive_xcframework_candidates[@]} != 1 )); then
        fail "archive must contain exactly one XCFramework directory"
    fi
    archive_xcframework_path="$archive_xcframework_candidates[1]"
    archive_relative_root="${archive_xcframework_path#$archive_extract_root/}"
    require_equal "archive XCFramework root" "$archive_root_entry" "$archive_relative_root"
    root_entry_found=false
    while IFS= read -r archive_entry; do
        [[ -n "$archive_entry" ]] || continue
        normalized_entry="${archive_entry%/}"
        if [[ "$normalized_entry" == "$archive_relative_root" ]]; then
            root_entry_found=true
        elif [[ "$normalized_entry" != "$archive_relative_root"/* ]]; then
            fail "archive contains content outside its XCFramework root: $archive_entry"
        fi
    done <<< "$archive_entries"
    [[ "$root_entry_found" == true ]] || fail "archive is missing its XCFramework root entry"
    [[ -z "$(find "$xcframework_path" -type l -print -quit)" ]] || \
        fail "selected XCFramework contains a symbolic link"
    [[ -z "$(find "$archive_xcframework_path" -type l -print -quit)" ]] || \
        fail "archive XCFramework contains a symbolic link"
    selected_files="$(cd "$xcframework_path" && find . -type f -print | LC_ALL=C sort)"
    archive_files="$(cd "$archive_xcframework_path" && find . -type f -print | LC_ALL=C sort)"
    require_equal "archive file list" "$selected_files" "$archive_files"
    while IFS= read -r relative_file; do
        [[ -n "$relative_file" ]] || continue
        cmp -s "$xcframework_path/$relative_file" "$archive_xcframework_path/$relative_file" || \
            fail "archive file differs from selected XCFramework: ${relative_file#./}"
    done <<< "$selected_files"
fi

if [[ "$for_publish" == true ]]; then
    [[ -n "$archive_path" ]] || fail "--for-publish requires --archive"
fi

print "Validated SpottyPlaybackCore XCFramework: $xcframework_path"
if [[ -n "$archive_path" ]]; then
    print "Validated archive: $archive_path"
fi
