# Spotty on Rune

Spotty uses the OpenCode team’s Rune framework for its desktop UI. The app builds from Rust
source. Its internal playback module compiles the retained librespot engine into the app. [Rune source](https://github.com/anomalyco/rune)

The reference scene reproduces the synthetic Moonlit Drive playlist from the README image.
It includes the same artwork, 1,000 tracks, date order, and paused Connect device. The product
documentation defines the interaction and layout references. [README screenshot](../Assets/PlaylistScreenshot.jpg) · [Product contracts](../docs/product/README.md)

## Build and run

On an Apple Silicon Mac with macOS 27 or later, install Xcode 27, select it with `xcode-select`,
and install Python 3.11 or newer and Rust with rustup. Run the packager from the repository root. It accepts
`SPOTTY_SIGNING_IDENTITY` for signing with a configured identity.

```sh
./Rune/package-macos.sh
open ".build/rune-app/Spotty.app"
```

Spotify Premium is required for playback. Spotty reads the existing session file format
when restoring an account. The first Rune run fetches fresh catalog data into its own cache.
Sign in through the browser when prompted.

## Playback architecture

The engine owns the Spotify session, Connect observation, decoder, and reconnect recovery.
It sends owned playback, connection, device, and queue observations and borrowed PCM slices
to Rune. Reconnect restores the interrupted context and track using the saved position and
playback modes. It uses the engine’s matching local and protocol evidence before confirming
the load. [Engine ownership](../docs/architecture/playback-engine-ownership.md#rune)

Rune owns the account and presentation state. One serial thread submits local engine work.
The app distinguishes a request accepted for dispatch from a matching playback or queue
observation. An in-flight mutation holds its permit until its writer settles.

## Updates

The packager enables Sparkle when both `SPOTTY_RUNE_UPDATE_FEED_URL` and
`SPOTTY_RUNE_UPDATE_PUBLIC_KEY` are provided. Set them to the dedicated HTTPS Rune appcast
and its base64 Ed25519 public key. Set `SPOTTY_RUNE_BUILD_NUMBER` to an increasing positive
integer for update releases. The configured bundle performs signed checks and lets the user
choose when to install an update. The current upstream release feed serves the Swift bundle.

## Synthetic demo and verification

Run from the `Rune` directory. On Linux, install the xkbcommon, ALSA, and OpenSSL development
packages, libseccomp, and a Vulkan driver. Mesa’s Vulkan software driver can render the headless checks.

```sh
cargo test --locked
../script/build_and_run.sh --demo
../Scripts/browse-synthetic.sh
```

The demo and headless scenes use synthetic catalog data and simulate playback and Connect
actions. They work without signing in. The same Cargo test invocation covers engine and application regressions. The repository script verifies four named transport traces.

```sh
../Scripts/check-transport-traces.sh
```

Verify the signed app bundle, VoiceOver, system sleep, AirPlay and output routing, Sparkle delivery,
and live Spotify Connect on Apple Silicon. Follow the live-account testing contract before
signing into a test account. [Safe testing](../docs/product/safe-testing.md)
