#!/bin/zsh
set -euo pipefail

backend_root="${0:A:h}"
project_root="${backend_root:h:h}"
archive_path=""
artifact_version=""
artifact_url=""

usage() {
    print -u2 "usage: $0 --archive ZIP --version MAJOR.MINOR.PATCH"
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --archive)
            (( $# >= 2 )) || usage
            archive_path="$2"
            shift 2
            ;;
        --version)
            (( $# >= 2 )) || usage
            artifact_version="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$archive_path" && -n "$artifact_version" ]] || usage
archive_path="${archive_path:A}"
[[ -f "$archive_path" ]] || { print -u2 "Archive is missing: $archive_path"; exit 1; }

fail() {
    print -u2 "update-artifact-pin.sh: $*"
    exit 1
}
version_pattern='^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$'
[[ "$artifact_version" =~ "$version_pattern" ]] || fail "version must be MAJOR.MINOR.PATCH without a prefix or leading zeroes"
artifact_url="https://github.com/aladh/Spotty/releases/download/playback-v$artifact_version/SpottyPlaybackCore.xcframework.zip"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/spotty-playback-pin.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
python3 - "$archive_path" "$temporary_root" <<'PYTHON'
import stat
import sys
import zipfile
from pathlib import PurePosixPath

with zipfile.ZipFile(sys.argv[1]) as archive:
    entries = archive.infolist()
    names = [entry.filename for entry in entries]
    if len(names) != len(set(names)):
        raise SystemExit("Archive contains duplicate entries")
    for entry in entries:
        path = PurePosixPath(entry.filename)
        mode = stat.S_IFMT(entry.external_attr >> 16)
        if path.is_absolute() or ".." in path.parts or mode not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise SystemExit(f"Unsafe archive entry: {entry.filename}")
    archive.extractall(sys.argv[2])
PYTHON
xcframework_candidates=("$temporary_root"/**/*.xcframework(N/))
if (( ${#xcframework_candidates[@]} != 1 )); then
    fail "archive must contain exactly one XCFramework"
fi
xcframework_path="$xcframework_candidates[1]"
archive_digest="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
"$backend_root/validate-xcframework.sh" "$xcframework_path" \
    --archive "$archive_path" --published >/dev/null

package_path="$project_root/Package.swift"
temporary_package="$temporary_root/Package.swift"
cp "$package_path" "$temporary_package"
PIN_URL="$artifact_url" PIN_CHECKSUM="$archive_digest" \
    perl -0pi -e '
        my $url_count = s{(private\s+let\s+generatedPlaybackArtifactURL\s*=\s*)("[^"]*")}{$1 . q{"} . $ENV{PIN_URL} . q{"}}eg;
        my $checksum_count = s{(private\s+let\s+generatedPlaybackArtifactChecksum\s*=\s*)("[^"]*")}{$1 . q{"} . $ENV{PIN_CHECKSUM} . q{"}}eg;
        die "generated playback URL declaration count is $url_count\n" unless $url_count == 1;
        die "generated playback checksum declaration count is $checksum_count\n" unless $checksum_count == 1;
    ' \
    "$temporary_package"
mv "$temporary_package" "$package_path"

print "Pinned SpottyPlaybackCore v$artifact_version in $package_path"
print "Archive checksum: $archive_digest"
