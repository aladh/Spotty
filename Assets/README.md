# App icon

[SpottyIcon.png](SpottyIcon.png) is the Codex-generated square source artwork for the native macOS
app icon: five connected mint-to-lime audio spots form a compact waveform on a charcoal tile. The
mark is distinct from Spotify's three-line logo and contains no Spotify artwork. Preserve its
transparent outer padding and readability at 16 px; do not imitate Spotify's logo.

`Spotty.icon` is the Icon Composer document used for the native icon catalog. It embeds the original
artwork at its native size on the 1024-point canvas, so its transparent padding falls outside the
system mask. Extra glass, translucency, and group shadows are disabled to preserve the artwork.
Edit this document in Icon Composer and verify its macOS previews when changing the native icon.

The generated `Spotty.icns` retains the legacy icon representations. After changing the source PNG,
follow the [icon regeneration procedure](../docs/development-setup.md#generated-local-state).
