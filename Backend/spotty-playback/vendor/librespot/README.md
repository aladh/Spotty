# Retained librespot patches

Only `core`, `playback`, and `connect` are retained from upstream revision
`939dc5ee9d833e1980f9495241219d9d4868a061` (MIT; see LICENSE). Cargo patches these
crates throughout the pinned dependency graph. Other librespot crates remain Git dependencies.

Changes from that source:

- AP connection timeout includes socket/proxy setup and handshake. Local stalled sockets
  exercise both phases and retry resource release in `spotty_deadline_tests`.
- The per-load decoder failure classification retains an explicit `AudioKeyError::AesKey`
  refusal. An unencrypted file may still decode. Timeouts remain ordinary failures.
- Only the current load emits `AudioKeyRefused`, then stops the player and sink using its
  existing stop path. Spirc consumes `Stopped` without marking a track unavailable or advancing
  the queue. Refused preloads are discarded without marking the upcoming occurrence unavailable.
- Self-transfer HTTP completion is polled alongside Dealer intake, so the Connect task can
  acknowledge its own inbound transfer before the HTTP request expires. An observed transfer
  validates the paused track/context/position, retains the protocol's occurrence order and modes,
  and signals readiness only after context restoration finishes. Failed setup cannot signal
  readiness or consume the pending transfer; an abandoned receipt cannot claim a later inbound
  transfer. Replacement loads and disconnects cancel its receipt. Resolving a changed playlist
  establishes later queue refill without replacing the transferred current track or queue.
- Own-device cluster echoes do not schedule another state publication. The upstream refresh for
  other devices remains; the echo regression prevents a notify loop from starving restoration
  and exhausting Spotify's request limit. Transferred duration remains available while loading.
- Disconnect advances the position timestamp without adding paused time to played time, preserving
  the paused position for another client. The transfer/advancement regression checks this handoff.
- Periodic position events expose their request ID through the same accessor as transport events,
  so late samples cannot replace a newer load's resume position.
- Spirc ignores paused/playing load events that contradict a newer transport command, so a delayed
  paused event cannot strand resumed audio behind paused Connect state, or undo a newer pause.
- Explicit ordered loads can retain shuffle/repeat options without shuffling the supplied order
  again. Spotty captures these options before activation can publish empty-player defaults.
- `connect/src/spotty_spirc_tests.rs` exercises the command handler, restoration receipt, and
  cancellation without a network connection or audio. `spotty_transfer_tests.rs` follows paused
  hydration through context resolution and natural queue advancement, then decodes the serialized
  Connect state another client consumes, including duplicate occurrences and playback modes.
- Standalone crate manifests expand workspace metadata and pin sibling dependencies to the
  same upstream revision. The redundant tokio dev-dependency is omitted (its macros feature
  already comes from librespot-core's own tokio features), allowing Cargo to run retained-crate
  tests without a second workspace. `playback/Cargo.toml` and `connect/Cargo.toml` expand the inherited
  `redundant_closure_for_method_calls` Clippy warning.
- `playback/src/spotty_player_tests.rs` supplies the synthetic current/preload/refusal/unencrypted
  decode regression cases, included by the player module as `spotty_key_refusal_tests` only under
  `cfg(test)`.

Do not import unrelated fork changes. Review the upstream diff when updating the pin and remove
patches when equivalent upstream behavior is available. The engine source digest includes these
files, and normal Rust verification runs the `spotty_` regression tests in all three retained crates.

`playback/tests/fixtures/silence.flac` is a synthetic 50 ms, 44.1 kHz stereo silence
fixture generated with `ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.05 -c:a flac`.
Tests decode it in memory; they do not open an audio output device.

`UPSTREAM` records the retained revision and commit date. The core build script uses these rather
than discovering Spotty's enclosing Git repository; the notice generator validates the revision
against the engine's Cargo pin and attaches it to each retained package and license record.
