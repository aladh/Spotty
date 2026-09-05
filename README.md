<p align="center">
  <img src="Assets/SpottyIcon.png" width="112" height="112" alt="Spotty">
</p>

# Spotty

A native macOS music client for Spotify Premium, built for personal experimentation on Apple
Silicon Macs running macOS 15 or newer.

> [!CAUTION]
> **Experimental, unofficial software.** Spotty is an independent personal project built on
> unsupported, reverse-engineered Spotify interfaces. It is not affiliated with, endorsed by,
> sponsored by, or otherwise connected to Spotify AB. It may break without notice or lose
> functionality. Do not rely on it as your only Spotify client, and use it only with an account
> you control. Its use of private interfaces and Spotify's desktop-client authorization flow may
> violate Spotify's terms.

Spotty uses SwiftUI and AppKit for its interface, AVFoundation for audio output, and a pinned
Rust/librespot backend for Spotify sessions, Connect, and audio streaming and decoding. There is
no WebView or Chromium runtime.

The interface has a fixed dark appearance, a library sidebar, artwork-led media pages, dense
track tables, a queue rail, and a bottom player. Spotify's layout is a design reference, not an
indication of affiliation.

## Capabilities

- **Playback:** local 320 kbps audio, pause/resume, seeking, previous/next, gapless transitions,
  repeat, and persistent shuffle with fewer repeats.
- **Spotify Connect:** device discovery, remote playback mirroring, device transfer, and queue
  display. Add selected tracks to the queue in visible order. Remove upcoming queue entries when
  another device owns playback and permits edits; removals preserve duplicates and appear only
  after Spotify confirms them.
- **Browsing:** Home, Search, profile, Liked Songs, playlists, albums, and artists from the
  signed-in account.
- **Track details:** sortable metadata, including Date Added in playlists and Popularity, BPM,
  and Camelot Key in shared catalog tables where applicable.
- **Playlist editing:** add selected tracks to an owned library playlist or remove selected
  occurrences from an open owned playlist, with success and failure feedback.
- **macOS integration:** native navigation, tables, menus, inspector, keyboard commands, and
  accessibility. Selection and focus follow the system accent; playback actions use Spotty green.

## Getting started

You need a Spotify Premium account to use Spotty. Building from source is the intended way to run
it; follow the [development setup guide](docs/development-setup.md#fresh-clone) for build-machine
requirements, toolchains, and signing setup. Authenticated development launches require an
Apple Development signing identity with a stable Team ID. A free Xcode Personal Team is sufficient.

Once the prerequisites are installed, clone the repository and launch a development build:

```bash
git clone https://github.com/aladh/Spotty.git
cd Spotty
./script/build_and_run.sh
```

SwiftPM downloads the checksum-pinned playback XCFramework; ordinary app builds need no Rust tools.
The launch script replaces any running development copy. On first launch, choose **Connect** and
complete Spotify authorization in the browser. See [build modes](CONTRIBUTING.md#build-and-run).

Generated app bundles and engine archives stay out of Git. Version tags publish experimental
prereleases; until Developer ID and notarization credentials are configured, their hardened-runtime
ad-hoc signatures are not automatically trusted by macOS.

## Privacy and security

Spotty has no analytics, advertising, crash-reporting SDK, or Spotty-operated server. It requests
account data directly from Spotify and renders it locally. OAuth credentials are stored in macOS
Keychain. Artwork caching is bounded, and operational logs use Apple Unified Logging locally.

Read [PRIVACY.md](PRIVACY.md) before signing in. Report security issues through the private process
in [SECURITY.md](SECURITY.md), not a public issue.

## Development

- [Development setup](docs/development-setup.md): prerequisites, signing, generated local state,
  and recovery.
- [Agent operations](CONTRIBUTING.md): build modes, verification, packaging, and releases.
- [Product and acceptance contract](docs/product-and-acceptance-contract.md): UX behavior and safe
  live-account testing.
- [Architecture decisions](docs/architecture-decisions.md): choices, tradeoffs, and historical context.
- [Playback engine ownership](docs/playback-engine-ownership.md): current Swift/Rust responsibilities.

## License

Spotty is intended for personal, non-commercial experimentation. The MIT license covers this
repository's code; it does not grant rights to Spotify's service, content, trademarks, or private
interfaces. Review Spotify's [Developer Policy](https://developer.spotify.com/policy) before
considering distribution.

Portions of the playback bridge, authentication flow, renderer, and Connect command shapes are
adapted from MIT-licensed Spotifly. The Rust backend links a pinned librespot revision and the
locked crates in `Cargo.lock`. Attribution, revisions, and dependency notices are recorded in
[NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

See [LICENSE](LICENSE) for the full license.
