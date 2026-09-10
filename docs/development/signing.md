# Development signing and credential recovery

[Development setup](setup.md) · [Packaging and releases](releases.md)

Follow [repository authorization rules](../../AGENTS.md#development) and run commands
from the repository root.

For an authenticated launch, sign in to Xcode with an Apple Account and create an Apple Development
certificate under its free Personal Team; paid membership is unnecessary for local personal use. If
Xcode does not offer that control, create a disposable macOS App project, select the Personal Team
under **Signing & Capabilities**, and let Xcode manage signing once.

`build_and_run.sh` selects the only available Apple Development identity. When several are available,
choose one with its exact name from `security find-identity -p codesigning -v`:

```bash
export SPOTTY_DEVELOPMENT_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)'
```

Then build, package, sign, and launch the development app. This replaces a running development copy,
so use it only for an authorized launch or interactive acceptance:

```bash
./script/build_and_run.sh
```

`build_and_run.sh` requires an Apple-issued development identity with a stable Team ID and never
falls back to self-signing. Session persistence is independent of code signing; see
[local storage](../../PRIVACY.md#local-storage).

`Scripts/package-app.sh` can create a build-only self-signed bundle with an isolated identity and
keychain under `.build/spotty-signing/`. It is local-only, unsuitable for distribution or sign-in.
`build_and_run.sh` fails before terminating or launching Spotty when no Apple-issued Team identity
is available. Never install the generated identity in the login keychain or commit it.

Packaging needs full Xcode selected through `xcode-select` or `DEVELOPER_DIR` to compile the
native icon. See [icon maintenance](../../Assets/README.md) when changing artwork.

Sandboxed development tools may need permission for the packaging or launch script to invoke
`security` and `codesign`. Apple Development signing can require private-key access once. That build-time access is separate
from Spotty’s runtime session storage.

## Session restoration

See [local storage](../../PRIVACY.md#local-storage) for the file-backed OAuth grant, the
Keychain-to-file migration, and Sign Out. Do not delete session files as routine troubleshooting;
read failures remain distinct from missing sessions.

Before exercising a live account, follow the [safe testing contract](../product/safe-testing.md).
