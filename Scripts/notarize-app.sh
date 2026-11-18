#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Rune/Info.plist")"
archive_directory="$project_root/dist"
archive_path="$archive_directory/Spotty-Rune-$version.zip"
notary_profile="${SPOTTY_NOTARY_PROFILE:-}"

if [[ -z "${SPOTTY_SIGNING_IDENTITY:-}" ]]; then
    print -u2 "Set SPOTTY_SIGNING_IDENTITY to a Developer ID Application identity"
    exit 2
fi
if [[ -z "$notary_profile" ]]; then
    print -u2 "Set SPOTTY_NOTARY_PROFILE to a notarytool keychain profile"
    exit 2
fi

mkdir -p "$archive_directory"
staging="$(mktemp -d "$archive_directory/.spotty-notary.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
app="$staging/Spotty.app"
SPOTTY_APP_PATH="$app" "$project_root/Scripts/package-app.sh" --release
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/submission.zip"
xcrun notarytool submit "$staging/submission.zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
"$project_root/Scripts/validate-app.sh" --distribution "$app"

# Restapling changes the app bundle, so produce the final distributable archive afterward.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/Spotty.zip"
mv -f -- "$staging/Spotty.zip" "$archive_path"

print "Notarized and archived $archive_path"
