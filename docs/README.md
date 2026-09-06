# Documentation

[Spotty overview](../README.md) · [Repository rules](../AGENTS.md) ·
[PR workflow and acceptance](../CONTRIBUTING.md)

Choose the guide for the task; the product, ADR, and enforcement indexes lead to their focused
contracts and records.

## Development

- [Setup](development/setup.md): prerequisites and app/engine toolchains.
- [Development signing](development/signing.md): signing identities and credential recovery.
- [Generated local state](development/local-state.md): build outputs and artwork regeneration.
- [Build and verification](development/verification.md): launch, formatting, tests, and diagnostics.
- [Playback binary artifacts](development/playback-artifacts.md): local candidates, publication, and app pins.
- [Packaging and releases](development/releases.md): packaging, signing, notarization, and app releases.
- [Thermos review](development/thermos-review.md): advisory PR review operation and limits.

## Product

- [Product contracts](product/README.md): scope, navigation, playback, queue, and playlists.
- [Safe testing](product/safe-testing.md): live-account authorization and bounded playback tests.

## Architecture

- [Architecture decisions](architecture/adrs/README.md): current and superseded ADRs.
- [Playback engine ownership](architecture/playback-engine-ownership.md): Swift/Rust responsibilities.
- [Engine contracts](architecture/engine-contract.md): lifecycle guarantees, FFI, and boundary constraints.
- [Performance baseline](architecture/performance-baseline.md): historical measurements and size reporting.
- [Enforcement inventory](architecture/enforcement.md): rule owners and verification coverage.
- [Extended metadata](architecture/extended-metadata.md): private protocol reference.
