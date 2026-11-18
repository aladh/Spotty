# Packaging and releases

`./Scripts/package-app.sh --release` builds the Apple Silicon Rune app and validates its signature and bundle. `./Scripts/archive-app.sh` stages `dist/Spotty-Rune-<version>.zip`. The release version and build number live in [Rune/Info.plist](../../Rune/Info.plist). For an authorized distribution signing and notarization run, select a Developer ID Application identity and a `notarytool` keychain profile for `./Scripts/notarize-app.sh`. Notarization builds a private staging bundle and replaces the archive after stapling and validation succeed. [Signing guide](signing.md)

The release workflow requires a `rune-v<version>` tag on main, matching app version, `docs/releases/rune-v<version>.md` release notes, and successful CI for that revision. It retains the validated archive and its checksum as workflow artifacts for review. Published Swift releases keep their existing feed.

A Rune update release requires a dedicated HTTPS feed, Ed25519 key and increasing build number. `./Scripts/generate-update-feed.sh` stages `dist/rune-appcast.xml` from the exact configured archive. It uses the standalone Sparkle distribution's `bin` directory from `SPOTTY_SPARKLE_BIN` and the dedicated `SPOTTY_RUNE_SPARKLE_PRIVATE_KEY`. Signing and publication require separate release authorization. [Rune update configuration](../../Rune/README.md#updates)

## Verify a download

Download the archive and its corresponding `.sha256` file into the same directory. Run `shasum -a 256 -c <archive-name>.sha256`. Compare the version and filename with the release you intended to install.
