# Packaging and releases

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

## Verify a download

Download the app archive and its `.sha256` file from the same GitHub release into one folder.
In Terminal, change to that folder and run the following, substituting the downloaded version:

```bash
shasum -a 256 -c Spotty-X.Y.Z.zip.sha256
```

Continue only if the result is `Spotty-X.Y.Z.zip: OK`. This checks download integrity; the checksum
is hosted with the archive and is not independent proof of publisher identity.

## Package, sign, and notarize

Local packages are development artifacts:

```bash
./Scripts/package-app.sh --debug
./Scripts/package-app.sh --release
./Scripts/validate-app.sh --local
```

`archive-app.sh` delegates building and signing to `package-app.sh --release`, then archives the
resulting app as `dist/Spotty-<version>.zip` with `ditto`. `SPOTTY_SIGNING_IDENTITY` selects the
signing identity. Unset, packaging falls back to the checkout-local self-signed identity.
`SPOTTY_SIGNING_IDENTITY="-"` is an ad-hoc signature, used by
[release.yml](../../.github/workflows/release.yml). For a hardened-runtime Developer ID archive,
supply a Developer ID identity explicitly:

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

The production session runtime runs inside the app executable. Spotty does not package a custom
session XPC helper; the XPC services embedded by Sparkle belong only to the updater.

## Tagged releases

An authorized `vX.Y.Z` tag must match `CFBundleShortVersionString` in `Packaging/Info.plist`. The
[release workflow](../../.github/workflows/release.yml) runs `archive-app.sh`, which packages and
signs after the Swift-scope `check.sh` run inside `package-app.sh` verifies the build; the workflow
itself then computes the `.sha256` checksum and generates a signed Sparkle appcast. Before tagging,
write the release notes in `docs/releases/vX.Y.Z.md`; the workflow publishes that file verbatim as a
regular GitHub release. Until Developer ID and notarization credentials are configured,
artifacts use hardened-runtime ad-hoc signing with the library-validation exception in
[AdHoc.entitlements](../../Packaging/AdHoc.entitlements). Hosts without an Apple Team ID cannot
otherwise load Sparkle. Apple-team development and Developer ID packages retain library validation.
Release notes must state that macOS will not automatically trust these unnotarized downloads.
Renovate owns dependency updates.

## Built-in updates

**Spotty → Check for Updates…** checks the latest regular GitHub release. Automatic checks are off
by default and can be enabled in the same menu. Downloads and installation require user action;
Sparkle's automatic-install option is disabled. Installation uses the normal application termination
path, which shuts down playback before exit. Restart does not initiate playback.

Sparkle is pinned by SwiftPM and embedded with its helpers by
[embed-sparkle.sh](../../Scripts/embed-sparkle.sh). The release lane generates the appcast from the
final archive and embeds the canonical release notes with
[generate-update-feed.sh](../../Scripts/generate-update-feed.sh). GitHub's latest-release asset URL
serves the feed; only regular app releases should become latest. Version and build number must both
increase for a release (not enforced by CI: `release.yml` only checks that the tag equals
`Info.plist`, and `generate-update-feed.sh` only checks the feed against the built version).
v0.2.0 is the first updater-enabled version and must be installed manually.

Both the feed and archives require Ed25519 authentication using the public key in
[Info.plist](../../Packaging/Info.plist). The corresponding private seed is stored in the GitHub
Actions secret `SPARKLE_PRIVATE_KEY`; keep a private backup outside version control. Configure the secret
and store the backup before creating the release tag: tag pushes start feed generation, which fails without the secret.
Never rotate it
by simply replacing the public key: existing installations trust the old key. Follow
[Sparkle's key rotation procedure](https://sparkle-project.org/documentation/) when needed.
The key authenticates Spotty updates independently of Apple signing or notarization.

## Release-note format

Start each `docs/releases/vX.Y.Z.md` with one sentence summarizing the release. Follow with
`## Fixes`, `## Improvements`, or `## What’s new` and concise user-facing bullets. An optional
`## Known limitations` section and a behavior/migration-change section (for example v0.2.4's
`## Session storage change`) may follow. Describe observable changes and relevant limits, avoiding
internal implementation details.

End with `## Install`: list macOS, hardware, and account requirements; explain built-in updates
when supported; name the versioned archive and checksum and give its verification command.
Include the current signing/notarization status and the macOS first-launch instructions, with a
link to the README at that release's tag; the "will not automatically trust" sentence applies from
v0.2.1 onward. Use [v0.2.5](../releases/v0.2.5.md) as the template and update every version
reference for the new release.
