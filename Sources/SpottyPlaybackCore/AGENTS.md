# C ABI surface agent guidance

This directory describes the Rust ABI. Follow the
[engine contract](../../docs/architecture/engine-contract.md) and
[ownership boundary](../../docs/architecture/playback-engine-ownership.md).

- `include/spotty_playback.h` must match the exported `spotty-playback` symbol set and signatures exactly.
  Never add, remove, rename, or reinterpret a declaration as a header-only change.
- Make ownership explicit for every pointer, buffer, callback, and returned allocation. Pair every
  Rust allocation with the documented release path; do not assume the panic barrier validates
  foreign pointers or extends callback lifetimes.
- Keep Swift nullable-pointer and open-enum annotations in `spotty_playback_annotations.h`.
  Do not enable cbindgen's global nullable-pointer annotation: required callbacks would become nullable.
- Review ABI changes for threading, reentrancy, nullability, sentinel errors, and pointer lifetime.
