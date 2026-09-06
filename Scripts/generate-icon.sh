#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_icon="${1:-$project_root/Assets/SpottyIcon.png}"
output_icon="${2:-$project_root/Assets/Spotty.icns}"
temporary_root="${TMPDIR%/}"
working_dir="$(mktemp -d "$temporary_root/spotty-icon.XXXXXX")"
iconset_dir="$working_dir/Spotty.iconset"
module_cache="$working_dir/module-cache"
mkdir "$iconset_dir"
mkdir "$module_cache"

cleanup() {
    if [[ -d "$working_dir" && "$working_dir" == "$temporary_root"/spotty-icon.* ]]; then
        find "$working_dir" -depth -delete
    fi
}
trap cleanup EXIT

if [[ ! -f "$source_icon" ]]; then
    print -u2 "Missing source artwork: $source_icon"
    exit 1
fi

width="$(sips -g pixelWidth "$source_icon" | awk '/pixelWidth:/ { print $2 }')"
height="$(sips -g pixelHeight "$source_icon" | awk '/pixelHeight:/ { print $2 }')"
if [[ -z "$width" || "$width" != "$height" || "$width" -lt 1024 ]]; then
    print -u2 "Source artwork must be square and at least 1024 pixels"
    exit 1
fi

representations=(
    "16 icon_16x16.png"
    "32 icon_16x16@2x.png"
    "32 icon_32x32.png"
    "64 icon_32x32@2x.png"
    "128 icon_128x128.png"
    "256 icon_128x128@2x.png"
    "256 icon_256x256.png"
    "512 icon_256x256@2x.png"
    "512 icon_512x512.png"
    "1024 icon_512x512@2x.png"
)

for representation in "${representations[@]}"; do
    pixels="${representation%% *}"
    filename="${representation#* }"
    sips --resampleHeightWidth "$pixels" "$pixels" \
        "$source_icon" \
        --out "$iconset_dir/$filename" >/dev/null
done

SWIFT_MODULECACHE_PATH="$module_cache" \
CLANG_MODULE_CACHE_PATH="$module_cache" \
    xcrun swift "$project_root/Scripts/assemble-icns.swift" "$iconset_dir" "$output_icon"

verification_dir="$working_dir/Verification.iconset"
iconutil --convert iconset "$output_icon" --output "$verification_dir"
SWIFT_MODULECACHE_PATH="$module_cache" \
CLANG_MODULE_CACHE_PATH="$module_cache" \
    xcrun swift "$project_root/Scripts/verify-icon.swift" "$iconset_dir" "$verification_dir"

print "Generated $output_icon from $source_icon"
