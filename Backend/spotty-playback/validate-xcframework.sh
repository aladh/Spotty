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
plutil -lint "$info_plist" >/dev/null || fail "XCFramework Info.plist is invalid"

plist_value() {
    local key="$1"
    local plist="$2"
    plutil -extract "$key" raw -o - "$plist" 2>/dev/null
}
require_equal() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    [[ "$expected" == "$actual" ]] || fail "$label mismatch (expected $expected, found $actual)"
}

require_equal "package type" XFWK "$(plist_value CFBundlePackageType "$info_plist")"
require_equal "minimum OS version" 15.0 "$(plist_value MinimumOSVersion "$info_plist")"
require_equal "library type" static "$(plist_value LibraryType "$info_plist")"
require_equal "module name" SpottyPlaybackCore "$(plist_value ModuleName "$info_plist")"

library_count="$(plist_value AvailableLibraries "$info_plist")"
require_equal "available library count" 1 "$library_count"
library_identifier="$(plist_value AvailableLibraries.0.LibraryIdentifier "$info_plist")"
require_equal "library identifier" macos-arm64 "$library_identifier"
platform="$(plist_value AvailableLibraries.0.SupportedPlatform "$info_plist")"
require_equal "supported platform" macos "$platform"
architecture_count="$(plist_value AvailableLibraries.0.SupportedArchitectures "$info_plist")"
require_equal "architecture count" 1 "$architecture_count"
architecture="$(plist_value AvailableLibraries.0.SupportedArchitectures.0 "$info_plist")"
require_equal "architecture" arm64 "$architecture"
library_relative_path="$(plist_value AvailableLibraries.0.LibraryPath "$info_plist")"
headers_relative_path="$(plist_value AvailableLibraries.0.HeadersPath "$info_plist")"
require_equal "binary path" "$library_relative_path" "$(plist_value AvailableLibraries.0.BinaryPath "$info_plist")"
[[ "$library_relative_path" == libSpottyPlaybackCore_*.a ]] || \
    fail "static library name must carry the engine input digest"
[[ "$library_relative_path" != */* && "$library_relative_path" != *..* ]] || \
    fail "static library path must be a safe file name"
library_stem="${library_relative_path%.a}"
library_identity="${library_stem#libSpottyPlaybackCore_}"
library_engine_digest="${library_identity%%_*}"
library_name_digest="${library_identity#*_}"
[[ "$library_engine_digest" =~ ^[0-9a-fA-F]{64}$ ]] || \
    fail "static library name has no valid engine input digest"
[[ "$library_name_digest" =~ ^[0-9a-fA-F]{64}$ && "$library_identity" == "$library_engine_digest"\_* ]] || \
    fail "static library name has no valid library digest"
require_equal "headers path" Headers "$headers_relative_path"

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
versions="$(awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { mode = "build"; next }
    $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { mode = "legacy"; next }
    $1 == "cmd" && $2 ~ /^LC_/ { mode = "" }
    mode == "build" && $1 == "minos" { print $2; mode = "" }
    mode == "legacy" && $1 == "version" { print $2; mode = "" }
' <<< "$otool_dump")"
[[ -n "$versions" ]] || fail "static archive has no macOS deployment load command"
while IFS= read -r minimum_version; do
    if ! awk -v version="$minimum_version" '
        BEGIN {
            if (version !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) exit 1
            split(version, parts, ".")
            if (parts[1] > 15 || (parts[1] == 15 && parts[2] > 0)) exit 1
        }
    ' </dev/null; then
        fail "static archive requires macOS newer than 15.0: $minimum_version"
    fi
done <<< "$versions"

provenance_path="$xcframework_path/spotty_playback_provenance.json"
[[ -f "$provenance_path" ]] || fail "embedded playback provenance is missing"
plutil -convert xml1 -o /dev/null "$provenance_path" >/dev/null 2>&1 || fail "embedded playback provenance is invalid"
provenance_value() {
    local key="$1"
    plutil -extract "$key" raw -o - "$provenance_path" 2>/dev/null || \
        fail "embedded provenance is missing $key"
}

if [[ "$check_source" == true ]]; then
    source_digest="$("$backend_root/source-input-digest.sh")"
else
    source_digest="$(provenance_value source.engineInputDigest)"
fi
require_equal "provenance source input digest" "$source_digest" "$(provenance_value source.engineInputDigest)"
require_equal "provenance target" aarch64-apple-darwin "$(provenance_value target)"
require_equal "library filename input digest" "$source_digest" "$library_engine_digest"
require_equal "provenance module" SpottyPlaybackCore "$(provenance_value module)"
require_equal "provenance library name" "$library_relative_path" "$(provenance_value libraryName)"
require_equal "provenance platform" macOS "$(provenance_value platform)"
require_equal "provenance minimum OS version" 15.0 "$(provenance_value minimumOSVersion)"
require_equal "provenance library type" static "$(provenance_value libraryType)"

header_digest="$({
    for header_name in spotty_playback.h spotty_playback_generated.h spotty_playback_annotations.h module.modulemap; do
        print -r -- "$header_name $(shasum -a 256 "$headers_path/$header_name" | awk '{print $1}')"
    done
} | shasum -a 256 | awk '{print $1}')"
require_equal "provenance canonical header digest" "$header_digest" "$(provenance_value source.canonicalHeadersSHA256)"

library_digest="$(shasum -a 256 "$library_path" | awk '{print $1}')"
require_equal "provenance library digest" "$library_digest" "$(provenance_value librarySHA256)"
require_equal "library filename digest" "$library_digest" "$library_name_digest"

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
    require_equal "provenance source dirty flag" false "$(provenance_value source.sourceDirty)"
    require_equal "provenance source input digest" "$source_digest" "$(provenance_value source.engineInputDigest)"
fi

print "Validated SpottyPlaybackCore XCFramework: $xcframework_path"
if [[ -n "$archive_path" ]]; then
    print "Validated archive: $archive_path"
fi
