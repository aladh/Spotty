# Historical Swift playback artifact

The earlier Swift app consumes the immutable XCFramework pinned by [Package.swift](../../Package.swift). To reproduce a historical Swift release, use its source tag and the build and publication scripts in that revision.

The current app builds its internal playback module and the pinned librespot graph with Cargo. [Build and verification](verification.md) · [Playback ownership](../architecture/playback-engine-ownership.md)
