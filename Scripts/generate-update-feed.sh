#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Packaging/Info.plist")"
archive_directory="${1:-$project_root/dist}"
archive="$archive_directory/Spotty-$version.zip"
notes="$project_root/docs/releases/v$version.md"
sparkle_tools="$project_root/.build/artifacts/sparkle/Sparkle/bin"
: "${SPARKLE_PRIVATE_KEY:?Set the release Ed25519 key through the CI secret}"
[[ -s "$archive" && -s "$notes" ]] || { print -u2 "Missing archive or release notes"; exit 1; }

# A fresh staging directory prevents stale archives or deltas entering a release feed.
feed_directory="$(mktemp -d "${TMPDIR:-/tmp}/spotty-appcast.XXXXXXXX")"
trap 'rm -rf "$feed_directory"' EXIT
cp "$archive" "$feed_directory/"
cp "$notes" "$feed_directory/Spotty-$version.md"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_tools/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/aladh/Spotty/releases/download/v$version/" \
    --embed-release-notes \
    --link "https://github.com/aladh/Spotty/releases/tag/v$version" \
    "$feed_directory"
# Sparkle compares the archive's SUPublicEDKey to the derived signing key and omits
# the archive signature on mismatch. Fail even if generate_appcast itself exits successfully.
python3 - "$feed_directory/appcast.xml" "$archive" "$project_root/Packaging/Info.plist" <<'PYTHON'
import base64
import pathlib
import plistlib
import sys

def require(condition, message):
    if not condition:
        raise SystemExit(message)

import xml.etree.ElementTree as ET

feed, archive, plist = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads(plist.read_bytes())
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(feed).findall("./channel/item")
require(len(items) == 1, "Feed must contain exactly this release")
item = items[0]
enclosure = item.find("enclosure")
require(enclosure is not None, "Missing release enclosure")
require(item.findtext(namespace + "version") == info["CFBundleVersion"], "Incorrect build")
require(item.findtext(namespace + "shortVersionString") == info["CFBundleShortVersionString"], "Incorrect version")
require(len(base64.b64decode(enclosure.attrib.get(namespace + "edSignature", ""), validate=True)) == 64, "Missing archive signature: check that the signing key matches the app public key")
require(int(enclosure.attrib["length"]) == archive.stat().st_size, "Incorrect archive length")
expected = f'https://github.com/aladh/Spotty/releases/download/v{info["CFBundleShortVersionString"]}/{archive.name}'
require(enclosure.attrib["url"] == expected, "Incorrect archive URL")
PYTHON
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_tools/sign_update" --ed-key-file - --verify "$feed_directory/appcast.xml"
cp "$feed_directory/appcast.xml" "$archive_directory/appcast.xml"
