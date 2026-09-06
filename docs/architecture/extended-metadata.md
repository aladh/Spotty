# Private extended-metadata protocol

Spotty uses Spotify's unsupported extended-metadata service for Popularity, BPM, and Key in shared
catalog tables. It may change without notice, and its use may violate Spotify's Terms of Use.

## Discovery notes

To re-derive the protocol, unzip `Spotify.app/Contents/Resources/Apps/xpui.spa` and search its
JavaScript for `BPM`, `camelotKey`, and `AUDIO_ATTRIBUTES_V2`. Executable strings identify
`spotify.playlistmixing.extensions.audio_attributes.v2.AudioAttributes` and
`com.spotify.extendedmetadata.*`. Desktop playlist requests ask for `AUDIO_ATTRIBUTES_V2`.

## Wire shape

[TrackAttributes.swift](../../Sources/Spotty/Spotify/TrackAttributes.swift) owns the endpoint,
request/response encoding, and display conversion. Consult that codec rather than maintaining a
second schema here. The maintenance-sensitive protocol facts are:

- The protobuf response carries separate entity/extension pairs inside `Any` payloads. Merge partial
  attributes by entity; do not assume one complete response per track.
- `TRACK_V4` popularity is zigzag-encoded `sint32`, not an unsigned integer.
- `AUDIO_ATTRIBUTES_V2` is newer than the pinned librespot schema, so the codec deliberately uses
  its raw extension value. BPM uses a protobuf double; reject non-finite values before integer
  conversion. Prefer Spotify's Camelot label over deriving one from musical key and mode.
- This POST is a metadata read, so it may use replay-safe credential/retry handling. That does not
  make arbitrary POST mutations replay-safe.

## Client behavior

Enrichment is best-effort: lists render before it finishes. Cache by track identity within the
account and deduplicate metadata requests for repeated tracks while preserving every playlist and
queue occurrence. Keep work bounded. Missing attributes and failures
are not durable negative results; a later load may retry them.

[CatalogMetadataRepository](../../Sources/Spotty/Spotify/CatalogMetadataRepository.swift) owns
batching and caching; [SpotifyCredentials](../../Sources/Spotty/Spotify/SpotifyCredentials.swift)
owns signing and retry policy.
