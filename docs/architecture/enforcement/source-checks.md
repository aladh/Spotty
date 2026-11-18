# Source and topology enforcement

The Rune app uses Cargo for compilation, rustfmt for formatting and behavioral regression tests for playback, account and interface contracts. The integrated checks and independent transport trace gate run through [the verification entry point](../../development/verification.md). The CI aggregate and release checks are documented in [build and CI enforcement](build-and-abi.md).

The repository retains Swift-era source-policy rules and fixtures with the earlier Swift code. To reproduce those policy and workflow checks, use the scripts and source at the same historical revision. The [historical source-policy guide](https://github.com/aladh/Spotty/blob/9b5d72b686ac094148b395006918cc1215cbb8e3/docs/architecture/enforcement/source-checks.md) includes the matching rules, fixtures and workflow checker.
