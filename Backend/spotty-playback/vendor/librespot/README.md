# Retained librespot patches

Only `core` and `playback` are retained from upstream revision
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
- Standalone crate manifests expand workspace metadata and pin sibling dependencies to the
  same upstream revision. The redundant tokio dev-dependency is omitted (its macros feature
  already comes from librespot-core's own tokio features), allowing Cargo to run retained-crate
  tests without a second workspace. `playback/Cargo.toml` expands the inherited
  `redundant_closure_for_method_calls` Clippy warning.
- `playback/src/spotty_player_tests.rs` supplies the synthetic current/preload/refusal/unencrypted
  decode regression cases, included by the player module as `spotty_key_refusal_tests` only under
  `cfg(test)`.

Do not import unrelated fork changes. Review the upstream diff when updating the pin and remove
patches when equivalent upstream behavior is available. The engine source digest includes these
files, and normal Rust verification runs the `spotty_` regression tests in both retained crates.

`playback/tests/fixtures/silence.flac` is a synthetic 50 ms, 44.1 kHz stereo silence
fixture generated with `ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.05 -c:a flac`.
Tests decode it in memory; they do not open an audio output device.

`UPSTREAM` records the retained revision and commit date. The core build script uses these rather
than discovering Spotty's enclosing Git repository; the notice generator validates the revision
against the engine's Cargo pin and attaches it to each retained package and license record.
