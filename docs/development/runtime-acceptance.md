# Runtime architecture acceptance

[Verification](verification.md) · [Architecture decisions](../architecture/adrs/README.md)

Apply the [product contracts](../product/README.md) and [PR acceptance criteria](../../CONTRIBUTING.md#pr-acceptance). Exercise account and playback generation changes, cancellation during I/O, retirement, late publications, and corrupt retained data. A stored identity cannot authorize a fresh mutation. Catalog changes also need route restoration, write invalidation, and account-scoped metadata and artwork checks.

Exercise changed controls in the isolated Rune demo and record the relevant screenshots, accessibility tree, or test assertions. The reference capture checks the README scene and exposes renderer warnings. Dedicated tests cover individual interactions. Live account, audio, and native macOS behavior have separate proof requirements. [Synthetic acceptance](synthetic-acceptance.md) · [Safe testing](../product/safe-testing.md)

## Quit and playback position

With playback-test permission, record the paused position, the destination's prior open state, and fresh Connect observations after quit. An open Spotify client can observe the position before disconnection. Closed Spotify clients may restore their own cached sessions. Quit stops the Spotty runtime. Closing the window leaves it running. [Playback measurements](playback-measurements.md)

## Offline lifecycle measurements

```sh
measurement_dir=$(mktemp -d)
SPOTTY_LIFECYCLE_REPORT="$measurement_dir/lifecycle.json" cargo test --locked \
  --manifest-path Rune/Cargo.toml named_lifecycle_fault_measurements -- --ignored
SPOTTY_STALLED_SHUTDOWN_REPORT="$measurement_dir/stalled-shutdown.json" cargo test --locked \
  --manifest-path Rune/Cargo.toml measure_stalled_spirc_task_deadline -- --ignored
SPOTTY_AUDIO_CACHE_REPORT="$measurement_dir/cache.json" \
  SPOTTY_AUDIO_CACHE_SOURCE_REVISION="$(git rev-parse HEAD)" cargo test --locked \
  --manifest-path Rune/Cargo.toml record_synthetic_cold_and_warm_cache_io -- --ignored
```

These probes measure injected lifecycle faults, a stalled shutdown task, and synthetic cache I/O. Real Spotify readiness, audible output, and renderer timings need their own measurements. Record the source and executable, hardware and OS, output route, window state, workload, and sample conditions. Review machine-bearing profiler output locally. [Historical Swift profiling and fixture commands](https://github.com/aladh/Spotty/blob/9b5d72b686ac094148b395006918cc1215cbb8e3/docs/development/runtime-acceptance.md)
