# Build and verification

## Normal verification

Run from the repository root. The locked test suite exercises app interaction, account handling and playback in one Rust binary. Test fixtures use synthetic or loopback data.

```sh
./Scripts/check.sh
./Scripts/check-transport-traces.sh
```

The transport gate verifies all four named regressions are present before running them. Set `SPOTTY_BUILD_CONFIGURATION=release` for the optimized profile. `./Scripts/check-clean.sh` verifies both profiles in a temporary target directory. CI runs Linux and Apple Silicon checks and packages the release configuration on macOS.

## Build and run

```sh
./script/build_and_run.sh --demo
./Scripts/package-app.sh --release
```

The first command starts synthetic Spotty. The second writes a verified `Spotty.app` at the repository root. For an authorized live launch, `./script/build_and_run.sh` validates the Apple-issued signature and Team ID before replacing a running app. [Safe testing](../product/safe-testing.md) · [Development signing](signing.md)

Run `./Scripts/browse-synthetic.sh` to capture the reference scene in the isolated demo. [Source build and platform requirements](../../Rune/README.md)
