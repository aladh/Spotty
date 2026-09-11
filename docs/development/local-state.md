# Generated local state

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

The following are ignored local outputs. Remove them only when cleanup is authorized; do not treat
signing material as disposable build output:

- `.spotty-connect-device-id` — nonsecret Debug Connect identity, stable per checkout; preserve it
  across rebuilds and build-directory resets. Packaging preserves an existing legacy
  `.build/connect-device-id` when first moving to this location. Debug bundles embed this value and do not use the installed app’s identity.
  Release builds persist a separate nonsecret `connectInstallationID` in standard preferences;
  logout retains it. Unbundled Debug tools/tests use an ephemeral identity.
- `.build/` and `Backend/spotty-playback/target/` — Swift and Rust build products;
- `Backend/lib/*.a` — produced only by running `Backend/spotty-playback/build.sh` directly without
  `--output`; the XCFramework build always passes `--output` and stages elsewhere;
- `Spotty.app/` and `dist/` — local packages and archives;
- `diagnostics/` — local reports; review them before sharing;
- `.DS_Store` and `.swiftpm/` — local tooling metadata.

For artwork changes, follow the [icon regeneration procedure](../../Assets/README.md). The native
icon embeds a copy of the master image, so regenerating only the legacy icon is insufficient.

Prefer a fresh clone for uncertain local state; do not copy old build products or signing material.
SwiftPM resolves the pinned artifact, and Cargo resolves engine dependencies from `Cargo.lock`.
