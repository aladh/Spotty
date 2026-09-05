# ADR 006: Consume a prebuilt playback engine through SwiftPM

Status: accepted on 2026-09-04.

## Context

The previous static archive lived outside SwiftPM's dependency graph, leaving callers responsible
for freshness, relinking, and Rust tooling even during app-only work.

## Decision

Distribute the existing engine as a macOS ARM64 static XCFramework through a SwiftPM binary target.
Release engine versions as `playback-vMAJOR.MINOR.PATCH`, separately from the app's `vMAJOR.MINOR.PATCH`
tags in the same repository. Pin the versioned immutable HTTPS archive by SHA-256 and package the
library with its matching generated C
headers, module map, provenance, and dependency notices. Keep the Swift adapter in source.

Ordinary app compilation and packaging do not invoke Rust tools or silently fall back to a source
build. Engine development uses an explicit local artifact override. Versioned release URLs select the
binary directly; this does not use SwiftPM Git-package semantic-version resolution. Rust source and its locked
dependency graph remain in the repository; generated binaries stay out of Git.

Two measured SwiftPM behaviors shape the pin: literal URL/checksum declarations make changes visible
to manifest caching, and content-addressed library filenames force relinking when the binary changes.
Replacing an archive under the same name was insufficient in the tested toolchain.

## Alternatives and tradeoffs

Source-only integration simplifies distribution but requires Rust tooling for Swift work. Committing
engine binaries grows Git history without remote artifact resolution. A binary target retains the
C ABI; keeping the Swift adapter in source avoids compiled Swift-module compatibility requirements.

Artifact availability, checksums, provenance, and license material become part of the build contract.
App validation compares the selected artifact with the app's pin, not the evolving Rust source or
producer headers. Source-built candidates and publication still validate against current engine
inputs. Adopting an engine change in the app requires a validated artifact and explicit pin update;
Rust debugging still needs the source toolchain. Apple SDK and signing requirements are unchanged.

CI verifies source-built candidates before publication and published artifacts before merge, with
Rust blocked in app lanes. See [agent operations](../CONTRIBUTING.md#playback-binary-artifacts) for
commands and the [enforcement inventory](architecture-enforcement.md) for coverage.
[ADR 005](ADR-005-retain-librespot.md) still owns engine choice and runtime ownership.
