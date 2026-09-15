# Documentation

[Spotty overview](../README.md) · [Repository rules](../AGENTS.md) ·
[PR workflow and acceptance](../CONTRIBUTING.md)

Start with [why Spotty exists](product/scope.md#why-spotty), then choose the owner of your question.
Product contracts define behavior, ADRs record decisions, and development guides explain procedures.

## Development

- [Setup](development/setup.md): prerequisites and app/engine toolchains.
- [Development signing](development/signing.md): signing identities and credential recovery.
- [Generated local state](development/local-state.md): build outputs and artwork regeneration.
- [Build and verification](development/verification.md): launch, formatting, tests, and diagnostics.
- [Runtime acceptance and measurements](development/runtime-acceptance.md): evidence requirements, synthetic workloads, and profiling.
- [Playback binary artifacts](development/playback-artifacts.md): local candidates, publication, and app pins.
- [Packaging and releases](development/releases.md): packaging, signing, notarization, and app releases.
- [Agent reviews](development/agent-reviews.md): shared review pipeline, approval, thread handling, and trust.
- [Thermos review](development/thermos-review.md): correctness and quality review of every ready PR.
- [Documentation review](development/docs-review.md): documentation accuracy, missing updates, and product-specification guard for every eligible PR.

## Product

- [Product contracts](product/README.md): scope, navigation, playback, queue, and playlists.
- [Safe testing](product/safe-testing.md): live-account authorization and bounded playback tests.

## Architecture

- [Architecture decisions](architecture/adrs/README.md): current and superseded ADRs.
- [Playback engine ownership](architecture/playback-engine-ownership.md): Swift/Rust responsibilities.
- [Engine contracts](architecture/engine-contract.md): lifecycle guarantees, FFI, and boundary constraints.
- [Performance baseline](architecture/performance-baseline.md): historical measurements and size reporting.
- [Enforcement inventory](architecture/enforcement.md): rule owners and verification coverage.
