#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Rune/Info.plist")"
archive_dir="$project_root/dist"
archive_path="$archive_dir/Spotty-Rune-$version.zip"

SPOTTY_APP_PATH="$project_root/Spotty.app" "$project_root/Scripts/package-app.sh" --release
mkdir -p "$archive_dir"

staging="$(mktemp -d "$archive_dir/.spotty-archive.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$project_root/Spotty.app" "$staging/Spotty.zip"
mv -f -- "$staging/Spotty.zip" "$archive_path"

print "Archived $archive_path"
