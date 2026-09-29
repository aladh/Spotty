# Development setup

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

App builds and packaging use Xcode's SDK and Clang with the pinned playback binary; they need no
Rust tools or cbindgen. Engine development uses the included Rust source.

## Fresh clone

Development requires:

- An Apple Silicon Mac running macOS 26.2 or newer; the app's runtime target is macOS 26+.
- Xcode 26.6 with Swift 6.3.3.
- [ripgrep](https://github.com/BurntSushi/ripgrep) for repository verification.
- Python 3.10 or newer for verification and helper scripts; engine artifact production needs
  Python 3.11 or newer as described below.
- Ruby for Swift/full verification. [Gate prerequisites](verification.md#normal-verification)
  cover the additional source-policy and engine tools.
- Spotify Premium only for live integration testing authorized under the
  [product contract](../product/safe-testing.md#safe-acceptance-testing).

Clone the repository and discover the tools:

```bash
git clone https://github.com/aladh/Spotty.git
cd Spotty
python3 Scripts/verify.py preflight
xcode-select -p
swift --version
```

Preflight inventories every gate's tools; missing Rust tools do not block app-only work.
Run `python3 Scripts/verify.py swift` to build and check the app, then `python3 Scripts/verify.py source`
for source policies. [Verification](verification.md#normal-verification) owns prerequisites and focused commands.

Follow [development signing](signing.md) for authenticated launches and credential recovery, and
[local state](local-state.md) for build outputs and artwork regeneration.

## Engine development

Install [Rustup](https://rustup.rs/) when changing the Rust engine or running its tests.
`rust-toolchain.toml` pins the components and ARM64 macOS target.
<!-- Renovate's cbindgen custom manager (renovate.json) matches the version in the next line. -->
Install cbindgen 0.29.4 for header
regeneration: `cargo install cbindgen --locked --version 0.29.4`.

Producing an engine artifact also requires Python 3.11 or newer for dependency-notice generation.

Use [verification](verification.md#normal-verification) for Rust checks and
[playback artifacts](playback-artifacts.md) for source builds, overrides, publication, and pin updates.
