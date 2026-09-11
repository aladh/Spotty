# Development setup

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

Ordinary app builds download the pinned playback binary; engine development uses the included Rust
source.

## Fresh clone

Development requires:

- An Apple Silicon Mac running macOS 26.2 or newer; the app's runtime target is macOS 15+.
- Xcode 26.6 with Swift 6.3.3.
- [ripgrep](https://github.com/BurntSushi/ripgrep) for repository verification.
- Ruby and pinned cbindgen for the verification gate, which `package-app.sh` also runs.
  Bare `swift build` and `compile-release-spotty.sh` do not need these tools.
- Python 3, used by `check.sh`, `check-source-policy.sh`, `package-app.sh`, and
  `browse-synthetic.sh`.
- Spotify Premium only for live integration testing authorized under the
  [product contract](../product/safe-testing.md#safe-acceptance-testing).

Then clone the public repository:

```bash
git clone https://github.com/aladh/Spotty.git
cd Spotty
```

Confirm the local toolchains before a long first build:

```bash
xcode-select -p
swift --version
rg --version
```

Build directly with SwiftPM, or run the Swift verification scope:

```bash
swift build --product Spotty
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
```

Run [source policies](verification.md#normal-verification) separately for the complete app/source
verification coverage; that portable check requires the pinned ast-grep CLI.

App builds and Swift tests need the Apple SDK and Clang but no Rust tools.
The Swift verification gate additionally uses cbindgen as a source parser, without Cargo or rustc.
Install the pinned parser as described below before running the gate or `package-app.sh`.
Verification does not sign in or start playback.

For authenticated launches, follow [development signing](signing.md), including identity selection
and credential recovery. See [generated local state](local-state.md) for build outputs and artwork
regeneration.

## Engine development

Install [Rustup](https://rustup.rs/) when changing the Rust engine or running its tests.
`rust-toolchain.toml` pins the components and ARM64 macOS target.
<!-- Renovate's cbindgen custom manager (renovate.json) matches the version in the next line. -->
Install cbindgen 0.29.4 for header
regeneration: `cargo install cbindgen --locked --version 0.29.4`.

Producing an engine artifact also requires Python 3.11 or newer for dependency-notice generation.

See [build and verification](verification.md#normal-verification) for Rust checks and
[playback binary artifacts](playback-artifacts.md#playback-binary-artifacts) for source builds, the local
override, publication, and pin updates.
