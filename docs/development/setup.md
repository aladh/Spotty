# Development setup

Install rustup, Python 3 and the platform requirements in the [Rune build guide](../../Rune/README.md). macOS packaging requires Xcode 27 with the Apple Silicon SDK, Icon Composer compiler and signing tools. On Linux, install the ALSA, xkbcommon and OpenSSL development packages, libseccomp and a Vulkan driver. From the repository root, run [the app and playback checks](verification.md). Rustup selects the compiler from the repository's [toolchain file](../../rust-toolchain.toml).

The pinned librespot graph includes local patches under `Backend/spotty-playback/vendor`. Cargo builds those sources with Spotty. The earlier Swift client remains available for historical comparison through `Package.swift` and its published playback artifact.
