# Generated local state

[Development setup](setup.md) · Run commands from the repository root.

The following are ignored local outputs. Remove them only when cleanup is authorized; do not treat
signing material as disposable build output:

- `.build/` and `Backend/spotty-playback/target/` — Swift and Rust build products;
- `Backend/lib/*.a` — intermediate static archives for explicit engine builds;
- `Spotty.app/` and `dist/` — local packages and archives;
- `diagnostics/` — local reports; review them before sharing;
- `SpottyArtwork/`, `.DS_Store`, and `.swiftpm/` — artwork cache and local tooling metadata.

For artwork changes, follow the [icon regeneration procedure](../../Assets/README.md). The native
icon embeds a copy of the master image, so regenerating only the legacy icon is insufficient.

Prefer a fresh clone for uncertain local state; do not copy old build products or signing material.
SwiftPM resolves the pinned artifact, and Cargo resolves engine dependencies from `Cargo.lock`.
