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

Builds configured for updates use Sparkle to contact their configured feed and download hosts.
Automatic checks run on startup and periodically while Spotty is open. Update requests expose
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
- A random installation/device identifier is stored in `Session/device` and in macOS preferences.
  The inspector and its selected panel are kept in memory.
- The app stores bounded JSON snapshots under `~/Library/Application Support/Spotty/RuneCatalog/`.
  They include the library tree, Home, Liked Songs, playlist and album details, recently played
  track metadata, and the last remote device ID. Partition names are derived from the account
  identifier. Private directory and file permissions limit access to the macOS user. Other
  processes running as that user can read the unencrypted snapshots. The app verifies the current
  profile before reading a partition. Saved data cannot authorize sign-in or playlist edits.
- Completed playlist, album, and artist pages also have bounded in-memory snapshots. Window-local
  search, selection, sort, and scroll state remain in memory and clear when the account changes;
  navigation is not restored across launches.
- Artwork downloads use HTTPS with Spotify artwork hosts. Spotty keeps bounded decoded thumbnails
  and header tints in memory. Account retirement cancels image work and clears those images.
- Spotify/librespot session credentials may be cached in
  `~/Library/Application Support/Spotty/credentials` so the playback device can reconnect. Retired
  cache locations are deleted without being imported.
- Rust playback diagnostics go to standard error. Treat diagnostic output as sensitive and review
  it before sharing.

Generated data remains on the Mac unless the user deliberately shares it. Spotty does not include
analytics, advertising, crash-reporting SDKs, or project-operated telemetry.

Repository fixtures are reduced, synthetic, and non-identifying; captured account payloads and
account-derived fixtures do not belong in the repository.

## Diagnostics

Keep diagnostic captures local. Share reviewed excerpts that exclude credentials, account exports,
raw service responses, and unrelated system logs.

## Removing data

Use **Spotty → Sign Out** to clear the active grant, local playback session, cached streaming
credentials, account snapshots, and Spotify cookies in the app's macOS cookie store. The browser
used for sign-in manages its own cookies. Sign-out also removes the owned SQLite files from earlier
Swift installations. Spotty reports cleanup errors. Empty directories and lock files can remain.
An interrupted sign-out resumes cleanup before Spotty can restore an account.
Ordinary app termination retains the catalog for a later verified session. To invalidate
previously issued credentials, revoke Spotify desktop access from your Spotify account.

## Service terms

Spotify processes data under its own privacy policy and terms. Spotty is unofficial, independent,
has no affiliation with Spotify AB, and uses private interfaces; see [README.md](README.md) before
signing in.
