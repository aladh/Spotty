# Packaging and releases

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

## Verify a download

Download the app archive and its `.sha256` file from the same GitHub release into one folder.
In Terminal, change to that folder and run the following, substituting the downloaded version:

```bash
shasum -a 256 -c Spotty-0.1.0.zip.sha256
```

Continue only if the result is `Spotty-0.1.0.zip: OK`. This checks download integrity; the checksum
is hosted with the archive and is not independent proof of publisher identity.

## Package, sign, and notarize

Local packages are development artifacts:

```bash
./Scripts/package-app.sh --debug
./Scripts/package-app.sh --release
./Scripts/validate-app.sh --local
```

A hardened-runtime Developer ID archive requires an explicitly supplied identity:

```bash
SPOTTY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./Scripts/archive-app.sh
```

The archive is written to ignored `dist/`. Notarization additionally requires an existing Apple
`notarytool` profile:

```bash
SPOTTY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SPOTTY_NOTARY_PROFILE="spotty-notary" \
  ./Scripts/notarize-app.sh
```

`validate-app.sh --distribution` requires a Developer ID signature, a valid notarization ticket, and
Gatekeeper acceptance. Signing proves artifact integrity; it does not make the private Spotify
integration supported or policy-compliant. Retain the selected engine's dependency notices; see
[playback artifacts](playback-artifacts.md) for engine publication.

## Tagged releases

An authorized `vX.Y.Z` tag must match `CFBundleShortVersionString` in `Packaging/Info.plist`. The
[release workflow](../../.github/workflows/release.yml) publishes an ARM64 app archive
and checksum after verification. Before tagging, write the release notes in
`docs/releases/vX.Y.Z.md`; the workflow publishes that file verbatim as a regular GitHub release.
Until Developer ID and notarization credentials are configured,
artifacts use hardened-runtime ad-hoc signing; release notes must state that macOS will not
automatically trust them. Renovate owns dependency updates.
