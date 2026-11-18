# Development signing

For an authorized live run, set `SPOTTY_DEVELOPMENT_SIGNING_IDENTITY` to an Apple Development identity or `SPOTTY_SIGNING_IDENTITY` to a distribution identity. With one Apple Development identity in the keychain, the launch script selects it automatically. With multiple identities, choose one explicitly.

`./script/build_and_run.sh` builds and validates the staged app, its Team ID and Apple's trust anchor before replacing a running process. Use `./Scripts/package-app.sh --release` for a compile-and-sign check, or `./script/build_and_run.sh --demo` for synthetic interaction. Packages without a configured identity use an ad-hoc signature. [Safe testing](../product/safe-testing.md) · [Updates and packaging](releases.md)

Spotty restores the grant at `~/Library/Application Support/Spotty/Session/session.json`. Upgrading from a Keychain-backed version requires one browser authorization. Spotty leaves retired Keychain grants untouched. [Local storage](../../PRIVACY.md#local-storage)
