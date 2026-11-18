# Build and verification

## Normal verification

Run from the repository root. The locked test suite exercises app interaction, account handling and playback in one Rust binary. Test fixtures use synthetic or loopback data.

```sh
./Scripts/check.sh
./Scripts/check-transport-traces.sh
```

The transport gate verifies all four named regressions are present and runs them in the default debug profile. Set `SPOTTY_BUILD_CONFIGURATION=release` when running `./Scripts/check.sh` to check the optimized profile. `./Scripts/check-clean.sh` verifies both profiles in a temporary target directory. CI runs Linux and Apple Silicon checks and packages the release configuration on macOS.

## Build and run

```sh
./script/build_and_run.sh --demo
```

On Apple Silicon macOS, `./Scripts/package-app.sh --release` writes a verified `Spotty.app` at the repository root. For an authorized live launch, `./script/build_and_run.sh` validates the Apple-issued signature and Team ID before replacing a running app. [Safe testing](../product/safe-testing.md) · [Development signing](signing.md)

Run `./Scripts/browse-synthetic.sh` to capture the reference scene in the isolated demo. [Source build and platform requirements](../../Rune/README.md)
