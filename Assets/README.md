# App icon

[SpottyIcon.png](SpottyIcon.png) is the generated master artwork. Preserve transparent outer padding
and readability at small sizes. The mark is independent of Spotify's logo and contains no Spotify
artwork; do not imitate that logo.

After changing the source PNG:

1. Run `./Scripts/generate-icon.sh` from the repository root to regenerate `Assets/Spotty.icns`.
2. Replace the embedded image in `Spotty.icon` with Icon Composer and check its macOS previews.
   The document embeds a copy, so updating the PNG alone does not update the native icon.
3. Package the app to compile and inspect the catalog. Commit the PNG, ICNS, and Icon Composer
   document together.

The [packager](../Scripts/package-app.sh) owns catalog compilation and bundle selection. Keep the
native document's padding and effects deliberate so system masking preserves the artwork.
