# C ABI surface agent guidance

This directory holds the canonical headers for the Rust ABI, consumed by the app as a prebuilt
artifact under [ADR 006](../../docs/architecture/adrs/ADR-006-prebuilt-playback-engine.md). Follow the
[engine contract](../../docs/architecture/engine-contract.md) and
[ownership boundary](../../docs/architecture/playback-engine-ownership.md).

- `include/spotty_playback.h` wraps cbindgen-generated declarations. Change the Rust declaration
  and regenerate per [verification](../../docs/development/verification.md#normal-verification);
  never hand-edit the generated header or add, remove, rename, or reinterpret a declaration as a
  header-only change. The headers must match the exported `spotty-playback` symbol set exactly.
- Make ownership explicit for every pointer, buffer, callback, and returned allocation. Pair every
  Rust allocation with the documented release path; do not assume the panic barrier validates
  foreign pointers or extends callback lifetimes.
- Keep Swift nullable-pointer and open-enum annotations in `spotty_playback_annotations.h`.
  Do not enable cbindgen's global nullable-pointer annotation: required callbacks would become nullable.
- Review ABI changes for threading, reentrancy, nullability, sentinel errors, and pointer lifetime.
