# Build and CI enforcement

The Cargo graph builds the Rune app and its internal playback module in one binary. The four transport trace names are independently checked before execution. [Verification commands](../../development/verification.md) · [Playback ownership](../playback-engine-ownership.md)

## CI and release workflow

CI verifies the locked Rust graph on Linux and Apple Silicon. Linux runs the integrated checks, checks each transport trace and records the reference UI scene. The Apple job builds, tests, signs and validates the release app bundle. The required `macOS checks` job requires both lanes to succeed. [CI](../../../.github/workflows/ci.yml) · [Synthetic evidence](../../development/synthetic-acceptance.md)

Rune archive staging requires a matching tag, app version, release notes and successful CI for the source revision. [Release workflow](../../../.github/workflows/release.yml) · [Release procedure](../../development/releases.md)

## Historical Swift checks

The earlier C header generator, ABI fixtures, XCFramework candidate classification and Swift workflow-policy checker applied to the Swift release source. Their original documented commands and tools are available together in the [historical build and ABI guide](https://github.com/aladh/Spotty/blob/9b5d72b686ac094148b395006918cc1215cbb8e3/docs/architecture/enforcement/build-and-abi.md).
