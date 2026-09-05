#!/bin/zsh
set -euo pipefail

# Prints the SHA-256 identity of every input that can change the playback XCFramework. The
# app package pin is intentionally excluded so adopting a release cannot change engine identity.
backend_root="${0:A:h}"
project_root="${backend_root:h:h}"

if (( $# > 1 )); then
    print -u2 "usage: $0 [--print-inputs]"
    exit 2
fi

input_paths=(
    "$project_root/rust-toolchain.toml"
    "$backend_root/Cargo.toml"
    "$backend_root/Cargo.lock"
    "$backend_root/cbindgen.toml"
    "$backend_root/abi-signatures.txt"
    "$backend_root/build.sh"
    "$backend_root/build-xcframework.sh"
    "$backend_root/source-input-digest.sh"
    "$project_root/Scripts/generate-c-header.sh"
    "$project_root/Scripts/generate-playback-notices.py"
    "$project_root/Scripts/playback-license-overrides.json"
    "$project_root/Scripts/playback-notices-preamble.md"
    "$project_root/Sources/SpottyPlaybackCore/include/module.modulemap"
    "$project_root/Sources/SpottyPlaybackCore/include/spotty_playback.h"
    "$project_root/Sources/SpottyPlaybackCore/include/spotty_playback_annotations.h"
    "$project_root/Sources/SpottyPlaybackCore/include/spotty_playback_generated.h"
    "$project_root/LICENSE"
    "$project_root/NOTICE"
    "$project_root/THIRD_PARTY_NOTICES.md"
)

source_paths=("${(@f)$(find "$backend_root/src" -type f -name '*.rs' -print | LC_ALL=C sort)}")
input_paths+=("${source_paths[@]}")
notice_license_paths=("${(@f)$(find "$project_root/Scripts/playback-license-overrides" -type f -print | LC_ALL=C sort)}")
input_paths+=("${notice_license_paths[@]}")

for input_path in "${input_paths[@]}"; do
    if [[ ! -f "$input_path" ]]; then
        print -u2 "Playback artifact input is missing: ${input_path#$project_root/}"
        exit 1
    fi
done

if (( $# == 1 )); then
    if [[ "$1" != "--print-inputs" ]]; then
        print -u2 "usage: $0 [--print-inputs]"
        exit 2
    fi
    for input_path in "${input_paths[@]}"; do
        print -r -- "${input_path#$project_root/}"
    done
    exit 0
fi

if ! command -v shasum >/dev/null 2>&1; then
    print -u2 "shasum is required to identify playback artifact inputs"
    exit 1
fi

export LC_ALL=C
{
    for input_path in "${input_paths[@]}"; do
        relative_path="${input_path#$project_root/}"
        file_hash="$(shasum -a 256 "$input_path" | awk '{print $1}')"
        print -r -- "$relative_path $file_hash"
    done
} | shasum -a 256 | awk '{print $1}'
