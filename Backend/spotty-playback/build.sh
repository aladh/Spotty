#!/bin/zsh
set -euo pipefail

backend_root="${0:A:h}"
output_root="${backend_root:h}/lib"
target="aarch64-apple-darwin"
output_path="$output_root/libspotty_playback.a"

if (( $# == 2 )) && [[ "$1" == "--output" ]]; then
    output_path="$2"
elif (( $# != 0 )); then
    print -u2 "usage: $0 [--output PATH]"
    exit 2
fi
output_path="${output_path:A}"

cargo_bin="${SPOTTY_CARGO:-$(command -v cargo || true)}"
workspace_cargo="/private/tmp/spotty-rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo"
if [[ -z "$cargo_bin" && -x "$workspace_cargo" ]]; then
    cargo_bin="$workspace_cargo"
    export CARGO_HOME="${CARGO_HOME:-/private/tmp/spotty-cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-/private/tmp/spotty-rustup}"
    export PATH="${cargo_bin:h}:$PATH"
fi
if [[ -z "$cargo_bin" || ! -x "$cargo_bin" ]]; then
    print -u2 "Rust cargo was not found. Install Rust or set SPOTTY_CARGO."
    exit 1
fi

if [[ -n "$(printenv RUSTFLAGS 2>/dev/null || true)" ||
      -n "$(printenv CARGO_ENCODED_RUSTFLAGS 2>/dev/null || true)" ]]; then
    print -u2 "RUSTFLAGS and CARGO_ENCODED_RUSTFLAGS must be unset for reproducible playback builds"
    exit 1
fi
if [[ -n "$(printenv RUSTC_WRAPPER 2>/dev/null || true)" ||
      -n "$(printenv RUSTC_WORKSPACE_WRAPPER 2>/dev/null || true)" ]]; then
    print -u2 "Rust compiler wrappers are not allowed for reproducible playback builds"
    exit 1
fi
minimum_macos="$(cat "$backend_root/macos-deployment-target")"
requested_deployment_target="$(printenv MACOSX_DEPLOYMENT_TARGET 2>/dev/null || true)"
if [[ -n "$requested_deployment_target" && "$requested_deployment_target" != "$minimum_macos" ]]; then
    print -u2 "MACOSX_DEPLOYMENT_TARGET must be $minimum_macos for SpottyPlaybackCore"
    exit 1
fi

mkdir -p "$output_root"
output_parent="${output_path:h}"
mkdir -p "$output_parent"
export MACOSX_DEPLOYMENT_TARGET="$minimum_macos"
export RUSTFLAGS="-C target-cpu=apple-m1 --cfg aes_armv8"

cd "$backend_root"
"$cargo_bin" build --release --locked --target "$target"
cp "target/$target/release/libspotty_playback.a" "$output_path"

echo "Built $output_path"
