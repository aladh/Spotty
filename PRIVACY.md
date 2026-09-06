# Privacy

This notice describes Spotty's current source code. A third-party build can be modified, so review
the source and the distributor before running a binary you did not build yourself.

## Data Spotty accesses

After sign-in, Spotty requests broad Spotify desktop-client scopes and can access account identity,
library, playlists, playback state, devices, queue, listening history, and catalog metadata. It can
also send playback, queue, library, and playlist commands when the user invokes those features.
These scopes are broader than the current UI uses because the private desktop-client authorization
flow is designed for Spotify's own client, not for independently registered applications.

Spotty communicates directly with Spotify-owned account, client-token, catalog, metadata, and
playback services, plus artwork hosts returned by Spotify. It has no Spotty-operated backend.

## Local storage

- Spotify OAuth credentials are stored in macOS Keychain. Authenticated development launches
  use an Apple-issued signing identity with a stable Team ID so Keychain authorization survives
  rebuilds; see [signing setup](docs/development/signing.md). Self-signed packages are
  build-only and must not be used to sign in. Retired plaintext and Keychain credentials are
  deleted without being imported.
- Local preferences also retain a random installation/device identifier, UI preferences, shuffle
  history, and playback preferences.
- Artwork loads through SwiftUI `AsyncImage`. macOS frameworks manage any image and response
  caching; Spotty does not impose its own artwork cache limits or purge it on window close.
- Spotify/librespot session credentials may be cached under the app's local cache directory so the
  playback device can reconnect. Retired cache locations are deleted without being imported.
- Apple Unified Logging stores local operational events. The intended contract excludes tokens,
  OAuth redirects, raw API bodies, and raw user payloads; treat logs and diagnostic exports as
  potentially sensitive and review them before sharing.

Generated data remains on the Mac unless the user deliberately shares it. Spotty does not include
analytics, advertising, crash-reporting SDKs, or project-operated telemetry.

Repository fixtures are reduced, synthetic, and non-identifying; captured account payloads and
account-derived fixtures do not belong in the repository.

## Diagnostics

`Scripts/export-diagnostics.sh` exports a bounded slice of Spotty's Unified Logging into the ignored
`diagnostics/` directory. Review every report before sharing it. Do not attach credentials, account
exports, raw service responses, or unrelated system logs to an issue.

## Removing data

Use **Spotty → Sign Out** to clear the active Spotty grant, the local playback session, cached
streaming credentials, and Spotify authentication cookies from the shared `URLSession` cookie
store used by the token flow. Cookies for other domains are left in place. macOS application
preferences, caches, or diagnostic files may remain until removed through normal macOS file
management. Revoking the app's Spotify desktop access from the Spotify account is an additional way to
invalidate previously issued credentials.

## Service terms

Spotify processes data under its own privacy policy and terms. Spotty is unofficial, independent,
has no affiliation with Spotify AB, and uses private interfaces; see [README.md](README.md) before
signing in.
