# ADR 007: File-backed session persistence

Status: accepted.

## Context

Spotty distributes ad-hoc-signed releases. The Keychain-backed OAuth grant can be saved during
browser authorization but denied to subsequent app processes, forcing authorization on each launch.
Session restoration must not depend on a stable Apple signing identity. The product owner accepts
filesystem protection in place of Keychain's per-app access controls.

## Decision

Store the complete OAuth grant in a private Application Support directory through
[KeymasterFileStore](../../../Sources/Spotty/Spotify/KeymasterFileStore.swift). The directory uses
0700 permissions and the file uses 0600. Bound reads, reject symlinks and nonregular files, and
publish replacements atomically, syncing the file and containing directory. A directory lock
serializes store operations across processes, and a fixed staging file is reclaimed after a crash. Keep the existing serialized persistence worker, rotation ordering,
reauthentication marker, and account-lifetime checks. Missing, denied, and corrupt sessions remain
distinct outcomes.

Do not read, migrate, or modify old Keychain entries. Upgrading requires one browser authorization;
subsequent launches restore the file. Sign Out removes the active file. Existing historical entries
are inert and can be removed separately by their owner. Retired plaintext preferences are still
removed without being imported.

## Tradeoffs and verification

The file is not encrypted and can be read by other processes running as the same macOS user.
The [privacy contract](../../../PRIVACY.md#local-storage) makes that limitation explicit. This changes
OAuth storage only; streaming credentials retain their existing engine-owned cache lifecycle.

[Boundary checks](../../../Tests/SpottyBoundaryTests/KeymasterFileStoreChecks.swift) exercise fresh
session restoration, durable replacement, logout, permissions, and invalid-file handling without
real credentials. Operational diagnostics remain in system-managed Unified Logging; no app-owned
log file is introduced.
