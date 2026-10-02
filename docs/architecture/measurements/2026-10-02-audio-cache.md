# Audio cache evaluation (2026-10-02)

Issue #12 evaluates the retained librespot audio cache, separately from persisted streaming
credentials and catalog/artwork retention. Production continues to construct
`Cache::new(Some(credentials_directory), None, None, None)`: persistent audio is disabled.
This evaluation makes no app/engine pin change and ships no cache implementation.

The trial invokes the actual retained `Cache` with a private disposable audio path and a fixed
size limit. Six cache-layer checks use synthetic bytes in unique mode0700 directories. No Session,
credentials, encrypted Spotify data, key request, decoder, network or playback is constructed.
The delayed writer is a raw cloned Cache experiment, not an engine shutdown reproduction.

Observed prerequisites:

| Scenario | Result |
| --- | --- |
| Disabled versus completed candidate repeat reads | Disabled has no audio path/file and cannot save; candidate retains and reuses65,536 synthetic bytes |
| Completed size bound and restart | Two16-byte saves under24-byte quota retain16; restart with8-byte limit prunes; oversized completed save can succeed after evicting itself |
| Interrupted copy |16-byte prefix remains readable/unaccounted after copy failure with8-byte quota; explicit removal works and restart later prunes it |
| Retired partition and delayed clone | After owned account-A partition deletion, delayed Cache clone recreates16 bytes; separate account-B partition is unchanged |
| Failed removal | Replacing a cached file with an owned nonempty directory makes eviction fail after accounting is popped; a later save leaves16 bytes under8-byte quota |
| Restart directory symlink | Startup scanning follows an owned link outside the trial partition and quota pruning deletes its owned target marker |

No-go for enabling the unmodified cache. The candidate demonstrates repeated byte reuse, but
fixed bounds and account cleanup cannot rely on raw Cache alone. Shipping would require owned
retirement fencing/draining, failure-atomic writes/accounting, no-follow partition confinement,
and explicit cleanup-failure policy in the Rust leaf under ADR005. That is additional lifecycle
complexity without an established live benefit; this batch keeps audio caching disabled.

The opt-in report performs three disabled memory-source reads versus one candidate save followed
by two file reads across five fresh partitions. Input counts are observed fixture bytes, not
network download measurements. Record exact source/engine identities and build configuration
with the report. OS page cache may be warm; descriptive file IO timing cannot establish repeat-play,
startup or output latency. A live comparison was not attempted because the safety prerequisites
failed and this task does not authorize playback. Decoder corruption/key-refresh/sign-out flow
and actual playback benefit remain unverified; cache-layer deletion/restart/clone tests do not
stand in for them.

Reproduce the six prerequisites with the pinned repository Rust toolchain:

```bash
cargo test --locked --manifest-path Backend/spotty-playback/Cargo.toml \
  --lib audio_cache_evaluation
```

The [sanitized receipt](2026-10-02-audio-cache.json) records clean source `e2bb40f`,
engine input identity, toolchain, optimized test executable, five IO waves and validation.
Cold-save median was0.2025ms (0.1656–0.4000); warm-read median0.03215ms (0.0277–0.0525).
Those descriptive measurements establish file reuse, not a playback improvement. The complete
Rust gate passed reproducible headers, format, warning-clean clippy,173 bridge checks and17
retained-librespot checks; three explicit probes remained ignored in the normal suite.

To collect a fresh optimized IO receipt, use a clean checkout and a new absolute path:

```bash
SPOTTY_AUDIO_CACHE_REPORT=/tmp/audio-cache-new.json \
SPOTTY_AUDIO_CACHE_SOURCE_REVISION=$(git rev-parse HEAD) \
  cargo test --release --locked --manifest-path Backend/spotty-playback/Cargo.toml \
  --lib record_synthetic_cold_and_warm_cache_io -- --ignored
```

The direct Rust test host is not a signed app/engine artifact. It uses Cargo's default deployment
minimum11.0 on macOS27; the shipping app and engine retain minimum27.
