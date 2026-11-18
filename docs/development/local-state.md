# Generated local state

Cargo writes compiled app and test targets under `Rune/target` or `CARGO_TARGET_DIR`. Packaging uses `.build/rune-app`. The root packaging wrapper installs `Spotty.app` in the repository root. Synthetic UI artifacts are under `.build/browsing-runs`. `./Scripts/check-clean.sh` creates and removes its own temporary target directory.

macOS stores the app’s private session and account state in its application support directory. Sign out through the app for account retirement. Preserve credentials and user state during build troubleshooting. [Account storage contract](../architecture/adrs/ADR-007-session-persistence.md) · [Safe testing](../product/safe-testing.md)

The icon sources are under [Assets](../../Assets). The macOS packager compiles `Spotty.icon` with Xcode’s asset compiler and includes the fallback icon file.

Release archives and appcasts land in `dist/`. Earlier Swift diagnostics exports use `diagnostics/`. Review logs before sharing them. [Privacy](../../PRIVACY.md#diagnostics)
