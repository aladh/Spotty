# Generated local state

[Development setup](setup.md) · Run commands from the repository root.

The following are ignored local outputs. Remove them only when cleanup is authorized; do not treat
signing material as disposable build output:

- `.build/` and `Backend/spotty-playback/target/` — Swift and Rust build products;
- `Backend/lib/*.a` — intermediate static archives for explicit engine builds;
- `Spotty.app/` and `dist/` — local packages and archives;
- `diagnostics/` — local reports; review them before sharing;
- `SpottyArtwork/`, `.DS_Store`, and `.swiftpm/` — artwork cache and local tooling metadata.

When changing the master app artwork in `Assets/SpottyIcon.png`, regenerate the legacy icon
representations with `./Scripts/generate-icon.sh`. Also replace the embedded image in
`Assets/Spotty.icon` using Icon Composer, then check its macOS previews and package the app to
compile the native catalog. Icon Composer embeds a copy; changing the master PNG does not update
that copy automatically. Commit the source PNG, generated `Assets/Spotty.icns`, and updated
`Assets/Spotty.icon` document together.

Prefer a fresh clone for uncertain local state; do not copy old build products or signing material.
SwiftPM resolves the pinned artifact, and Cargo resolves engine dependencies from `Cargo.lock`.
