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

## Application updates

Checking for updates contacts GitHub and its download hosts through Sparkle. Automatic checks
are off by default and can be enabled or disabled in the Spotty menu. Update requests expose
ordinary connection information such as the IP address and app version; they do not include Spotify
credentials or listening data. System-profile reporting and automatic installation are disabled.
Updates require the user to choose installation.

## Local storage

- Spotify OAuth credentials are stored in
  `~/Library/Application Support/Spotty/Session/session.json`, with owner-only file permissions
  (0600) inside a private directory (0700). Writes atomically replace the complete grant. The file
  is not encrypted; other processes running as the same macOS user can read it. Do not share or
  commit this directory. Existing Keychain grants are no longer read, imported, or modified;
  upgrading from Keychain storage requires one browser authorization. Retired plaintext preferences
  are removed without importing their grant.
- Local preferences (`UserDefaults`) also retain a random installation/device identifier and
  playback preferences, including shuffle history. The playback inspector's open/closed state and
  selected panel instead use SwiftUI `@SceneStorage`, not `UserDefaults`.
- Previously fetched playlist and album browsing metadata is retained in an account-partitioned
  SQLite catalog under `~/Library/Application Support/Spotty/Catalog/`. Partition names are
  derived from the account identifier; hashing a directory name does not anonymize its contents.
  Private directory and file permissions limit access to the macOS user, but the catalog is not
  encrypted and other processes running as that user can read it. The cache has explicit entity,
  collection, record, and database-size bounds. It stores typed track/item labels, artwork URLs,
  ordered browsing occurrences, collection metadata, and freshness—not OAuth grants, raw service
  responses, artwork bytes, or audio. A current live profile must verify the account before that
  process reads its partition; a saved partition cannot authorize sign-in or playlist edits.
- Completed playlist, album, and artist pages also have bounded in-memory snapshots. Window-local
  search, selection, sort, and scroll state remain in memory and clear when the account changes;
  navigation is not restored across launches.
- Artwork uses a shared account-scoped in-memory pipeline. Source image bytes, size-limited
  thumbnails, decoded pixels, and header tint reuse bounded memory; Spotty does not keep an artwork
  disk cache. Network image loads use an ephemeral HTTPS session without shared cookies,
  credentials, or response caching. Account retirement cancels image work and clears retained
  bytes; late results from that lifetime cannot populate the replacement account's cache.
- Spotify/librespot session credentials may be cached in
  `~/Library/Application Support/Spotty/credentials` so the playback device can reconnect. Retired
  cache locations are deleted without being imported.
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
store used by the token flow. It also fences catalog access and removes retained account catalog
content and SQLite sidecars. If catalog removal fails, that content remains inaccessible to the
runtime and the failure is reported; filesystem cleanup may still be needed. Empty ownership-lock
files and directories can remain. This is logical deletion, not guaranteed forensic erasure.
Cookies for other domains are left in place. Ordinary app termination retains the catalog for a
later verified session. macOS application preferences, framework caches from older builds, or
diagnostic files may remain until removed through normal macOS file management. Revoking the app's Spotify desktop access from the Spotify account is an additional way to
invalidate previously issued credentials.

## Service terms

Spotify processes data under its own privacy policy and terms. Spotty is unofficial, independent,
has no affiliation with Spotify AB, and uses private interfaces; see [README.md](README.md) before
signing in.
