#!/bin/zsh
set -euo pipefail

backend_root="${0:A:h}"
project_root="${backend_root:h:h}"
source "$project_root/Scripts/ci-timings.sh"
trap 'spotty_ci_timings_finish "$?"' EXIT
if [[ -n "${SPOTTY_CI_TIMINGS_REPORT:-}" ]]; then
    trap 'spotty_ci_timings_finish "$?"' ZERR
fi
output_path=""
archive_path=""

usage() {
    print -u2 "usage: $0 [--output XCFRAMEWORK] [--archive ZIP]"
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || usage
            output_path="$2"
            shift 2
            ;;
        --archive)
            (( $# >= 2 )) || usage
            archive_path="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [[ "$(uname -m)" != "arm64" ]]; then
    print -u2 "SpottyPlaybackCore only supports Apple Silicon arm64 builds"
    exit 1
fi
minimum_macos="$(cat "$backend_root/macos-deployment-target")"
if [[ "${MACOSX_DEPLOYMENT_TARGET:-$minimum_macos}" != "$minimum_macos" ]]; then
    print -u2 "MACOSX_DEPLOYMENT_TARGET must be $minimum_macos for SpottyPlaybackCore"
    exit 1
fi
export MACOSX_DEPLOYMENT_TARGET="$minimum_macos"

if ! command -v xcodebuild >/dev/null 2>&1; then
    print -u2 "xcodebuild is required to package SpottyPlaybackCore"
    exit 1
fi

canonical_include="$project_root/Sources/SpottyPlaybackCore/include"
for header in spotty_playback.h spotty_playback_generated.h spotty_playback_annotations.h module.modulemap; do
    if [[ ! -f "$canonical_include/$header" ]]; then
        print -u2 "Canonical playback header is missing: $canonical_include/$header"
        exit 1
    fi
done

spotty_ci_timings_start candidate.input-identity
source_digest="$("$backend_root/source-input-digest.sh")"
spotty_ci_timings_finish 0
if [[ -z "$output_path" ]]; then
    output_path="$project_root/.build/playback-engine/$source_digest/SpottyPlaybackCore.xcframework"
else
    output_path="${output_path:A}"
fi
if [[ -z "$archive_path" ]]; then
    archive_path="$output_path.zip"
else
    archive_path="${archive_path:A}"
fi
if [[ "$output_path" != *.xcframework ]]; then
    print -u2 "XCFramework output must end in .xcframework: $output_path"
    exit 2
fi
if [[ "$archive_path" != *.zip ]]; then
    print -u2 "XCFramework archive output must end in .zip: $archive_path"
    exit 2
fi
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/spotty-playback-xcframework.XXXXXX")"
trap 'spotty_ci_timings_finish "$?"; rm -rf "$temporary_root"' EXIT
staged_headers="$temporary_root/Headers"
staged_rust_archive="$temporary_root/libspotty_playback.a"
staged_framework="$temporary_root/SpottyPlaybackCore.xcframework"
mkdir -p "$staged_headers"

for header in spotty_playback.h spotty_playback_generated.h spotty_playback_annotations.h module.modulemap; do
    cp "$canonical_include/$header" "$staged_headers/$header"
done

spotty_ci_timings_start candidate.rust.build
"$backend_root/build.sh" --output "$staged_rust_archive"
spotty_ci_timings_finish 0
spotty_ci_timings_start candidate.rust.archive-validation
if [[ "$(lipo -archs "$staged_rust_archive")" != "arm64" ]]; then
    print -u2 "Rust playback archive is not arm64-only"
    exit 1
fi
library_digest="$(shasum -a 256 "$staged_rust_archive" | awk '{print $1}')"
library_name="libSpottyPlaybackCore_${source_digest}_${library_digest}.a"
staged_archive="$temporary_root/$library_name"
mv "$staged_rust_archive" "$staged_archive"
spotty_ci_timings_finish 0

spotty_ci_timings_start candidate.xcframework.assembly
xcodebuild -create-xcframework \
    -library "$staged_archive" \
    -headers "$staged_headers" \
    -output "$staged_framework"

# xcodebuild records the platform and architecture in Info.plist. Keep the minimum OS and
# static/module identity beside that metadata so the validator can reject a misbuilt artifact.
plutil -insert MinimumOSVersion -string "$minimum_macos" "$staged_framework/Info.plist"
plutil -insert LibraryType -string static "$staged_framework/Info.plist"
plutil -insert ModuleName -string SpottyPlaybackCore "$staged_framework/Info.plist"

staged_library="$(find "$staged_framework" -type f -name "$library_name" -print -quit)"
if [[ -z "$staged_library" ]]; then
    print -u2 "xcodebuild did not produce $library_name in the XCFramework"
    exit 1
fi
spotty_ci_timings_finish 0

spotty_ci_timings_start candidate.provenance-inputs
source_revision="$(git -C "$project_root" rev-parse HEAD 2>/dev/null || print unknown)"
source_dirty=false
if [[ -n "$(git -C "$project_root" status --porcelain --untracked-files=all 2>/dev/null)" ]]; then
    source_dirty=true
fi
rust_toolchain="$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$project_root/rust-toolchain.toml" | head -1)"
librespot_revision="$(sed -nE 's/.*librespot-core.*rev[[:space:]]*=[[:space:]]*"([0-9a-f]{40})".*/\1/p' "$backend_root/Cargo.toml" | head -1)"
header_digest="$({
    for header in spotty_playback.h spotty_playback_generated.h spotty_playback_annotations.h module.modulemap; do
        print -r -- "$header $(shasum -a 256 "$canonical_include/$header" | awk '{print $1}')"
    done
} | shasum -a 256 | awk '{print $1}')"
cargo_lock_digest="$(shasum -a 256 "$backend_root/Cargo.lock" | awk '{print $1}')"
spotty_ci_timings_finish 0

if [[ ! -f "$project_root/Scripts/generate-playback-notices.py" ]]; then
    print -u2 "Playback notice generator is missing: Scripts/generate-playback-notices.py"
    exit 1
fi
notices_root="$temporary_root/generated-notices"
spotty_ci_timings_start candidate.notices
python3 "$project_root/Scripts/generate-playback-notices.py" \
    --target aarch64-apple-darwin \
    --output "$notices_root"
if [[ ! -f "$notices_root/ThirdPartyNotices.md" || ! -f "$notices_root/manifest.json" ]]; then
    print -u2 "Playback notice generator did not produce its required manifest and notice"
    exit 1
fi
mkdir -p "$staged_framework/Notices/source"
cp -R "$notices_root/." "$staged_framework/Notices/"
for license_file in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
    cp "$project_root/$license_file" "$staged_framework/Notices/source/$license_file"
done
spotty_ci_timings_finish 0

spotty_ci_timings_start candidate.provenance-and-install
provenance_path="$staged_framework/spotty_playback_provenance.json"
{
    print '{'
    print '  "schemaVersion": 1,'
    print '  "module": "SpottyPlaybackCore",'
    print '  "target": "aarch64-apple-darwin",'
    print '  "platform": "macOS",'
    print "  \"minimumOSVersion\": \"$minimum_macos\","
    print '  "libraryType": "static",'
    print "  \"libraryName\": \"$library_name\","
    print "  \"librarySHA256\": \"$library_digest\","
    print '  "source": {'
    print "    \"engineInputDigest\": \"$source_digest\","
    print "    \"sourceRevision\": \"$source_revision\","
    print "    \"sourceDirty\": $source_dirty,"
    print "    \"rustToolchain\": \"$rust_toolchain\","
    print "    \"librespotRevision\": \"$librespot_revision\","
    print "    \"cargoLockSHA256\": \"$cargo_lock_digest\","
    print "    \"canonicalHeadersSHA256\": \"$header_digest\""
    print '  },'
    print '  "licensing": {'
    print '    "sourceLicense": "MIT",'
    print '    "sourceLicenseFiles": ["Notices/source/LICENSE", "Notices/source/NOTICE", "Notices/source/THIRD_PARTY_NOTICES.md"],'
    print '    "archiveNoticePath": "Notices/ThirdPartyNotices.md",'
    print '    "archiveLicenseDirectory": "Notices/licenses",'
    print '    "archiveManifest": "Notices/manifest.json"'
    print '  }'
    print '}'
} > "$provenance_path"

if [[ -e "$output_path" ]]; then
    /bin/rm -rf -- "$output_path"
fi
mkdir -p "${output_path:h}"
mv "$staged_framework" "$output_path"
spotty_ci_timings_finish 0

spotty_ci_timings_start candidate.compression
if [[ -e "$archive_path" ]]; then
    /bin/rm -f -- "$archive_path"
fi
mkdir -p "${archive_path:h}"

# Normalize timestamps and omit Finder metadata so a repeated build from identical inputs has a
# stable archive checksum suitable for the package pin.
find "$output_path" -exec touch -t 200001010000 {} +
(
    cd "${output_path:h}"
    zip -X -q -r "$archive_path" "${output_path:t}"
)
spotty_ci_timings_finish 0

spotty_ci_timings_start candidate.archive-checksum
archive_digest="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
spotty_ci_timings_finish 0
print "Built $output_path"
print "Archived $archive_path"
print "SHA-256: $archive_digest"
