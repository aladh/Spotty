# Build and verification scripts

Run the [Rune checks](../docs/development/verification.md) for changes to the app or its internal playback engine. Preserve transport trace coverage, signed bundle validation and live testing authorization. Use a temporary Cargo target directory for clean builds. The Swift source and its historical release inputs are retained for reference.

Use `Scripts/check-source-policy.sh` for the current local and CI source checks. SwiftPM focused-selection evidence belongs to its [historical checkout](https://github.com/aladh/Spotty/tree/9b5d72b686ac094148b395006918cc1215cbb8e3). The current `verify.py` runs the Rune check, clean-build, trace, and acceptance gates.
