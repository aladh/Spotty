# Packaging and releases

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

## Verify a download

Download the archive and `.sha256` file from the same GitHub release into one folder. In that
folder, substitute the downloaded version and run:

```bash
shasum -a 256 -c Spotty-X.Y.Z.zip.sha256
```

Continue only on `Spotty-X.Y.Z.zip: OK`. This verifies download integrity, not independent
publisher identity: the checksum is hosted alongside the archive.

## Package, sign, and notarize

Local packages are development artifacts:

```bash
./Scripts/package-app.sh --debug
./Scripts/package-app.sh --release
./Scripts/validate-app.sh --local
```

`archive-app.sh` compiles and packages with `package-app.sh --release`, then uses `ditto` to write
ignored `dist/Spotty-<version>.zip`. PR/main CI owns test acceptance; archiving does not rerun tests.
`SPOTTY_SIGNING_IDENTITY` selects the identity. Unset, it uses the checkout-local self-signed
identity; `-` means ad-hoc signing. For a hardened-runtime Developer ID archive:

```bash
SPOTTY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./Scripts/archive-app.sh
```

Notarization additionally needs an existing Apple `notarytool` profile:

```bash
SPOTTY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SPOTTY_NOTARY_PROFILE="spotty-notary" \
  ./Scripts/notarize-app.sh
```

`validate-app.sh --distribution` requires Developer ID signing, a valid notarization ticket, and
Gatekeeper acceptance. Signing does not make the private Spotify integration supported or
policy-compliant. Retain the engine's dependency notices; see [engine publication](playback-artifacts.md).
The session runtime is in-process; embedded XPC services belong only to Sparkle, not a session helper.

## Tagged releases

Before creating an authorized `vX.Y.Z` tag:

1. Increase **both** version and build number in [Info.plist](../../Packaging/Info.plist).
   The tag must match `CFBundleShortVersionString`. CI checks that match, not monotonic increases.
2. Commit `docs/releases/vX.Y.Z.md` using the [format below](#release-note-format).
3. Merge to `main` and require the tag commit's latest main CI run to succeed.
4. Configure `SPARKLE_PRIVATE_KEY` and back it up privately before tagging; feed generation fails
   without it. Preserve the existing key when one is configured.

The [release workflow](../../.github/workflows/release.yml) checks main ancestry and CI, archives
that accepted commit without repeating tests, computes its checksum, generates the signed appcast,
and publishes the committed notes verbatim as a regular GitHub release. Only regular app releases
should become latest. Renovate owns dependency updates.

Until Developer ID/notarization credentials are configured, releases use hardened-runtime ad-hoc
signing with [library validation disabled](../../Packaging/AdHoc.entitlements): hosts without an
Apple Team ID otherwise cannot load Sparkle. Apple-team development and Developer ID packages
retain validation. Notes must say macOS will not automatically trust these unnotarized downloads.

## Built-in updates

Spotty checks the latest regular GitHub release in the background on startup and periodically while
running. **Spotty → Check for Updates…** checks immediately. Download and installation require user action; automatic
installation is disabled. Installation follows normal termination, draining playback; restart does
not start playback. v0.2.0 was the first updater-enabled version and requires manual installation.

SwiftPM pins Sparkle; [embed-sparkle.sh](../../Scripts/embed-sparkle.sh) embeds its helpers.
[generate-update-feed.sh](../../Scripts/generate-update-feed.sh) builds the feed from the final
archive and canonical notes and checks it against the built version. GitHub's latest-release asset
URL serves the feed.

Both archives and feeds require Ed25519 authentication with the public key in Info.plist. The
private seed lives in the `SPARKLE_PRIVATE_KEY` Actions secret, with a backup outside version
control. This authentication is independent of Apple signing/notarization. Never replace the
public key alone: installed apps trust the old key. Follow
[Sparkle's key rotation procedure](https://sparkle-project.org/documentation/) when needed.

## Release-note format

Write for a listener, answering **what will I notice?**:

- Start with one sentence summarizing the release, followed by `## Fixes`, `## Improvements`, or
  `## What’s new` and concise user-facing bullets. Name the recognizable screen, control, action,
  or problem and when the change matters.
- Add `## Known limitations` or a behavior/migration section when needed.
- Omit changes without observable effects: refactors, dependencies, tests, architecture, and
  release machinery. Include technical detail only to help the listener act, assess privacy or
  security consequences, or understand a limitation.
- Before approval, read the notes without their PRs. A nontechnical listener should understand
  the benefit. Explain or remove terms such as *invalidation*, *runtime*, and *session ownership*;
  translating engineering work into user outcomes is part of writing the notes.

End with `## Install`: macOS, hardware, and account requirements; built-in updates when supported;
versioned archive/checksum names and verification command; signing/notarization status; and
first-launch instructions linking to the README at that tag. The “will not automatically trust”
warning applies from v0.2.1 onward. Use [v0.2.3](../releases/v0.2.3.md) for structure, update every
version reference, and apply the audience test independently of older wording.
