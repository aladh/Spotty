# Queue behavior

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Queue

Playback is the ordering authority. Catalog and Web metadata may enrich labels but must not
replace newer Connect order, including when a refresh began before the first Connect observation
or later failed. Resolve fallback labels progressively without changing occurrence identity.

Upcoming rows support native selection. Delete/Backspace and **Remove from Queue** remove selected
occurrences, never every matching track URI. Ambiguous identities fail closed. Now-playing and
Recently played rows are not removable queue entries. A row click selects; Return or double-click
is a deliberate playback action.

Removal requires complete, current, unrestricted Connect authority for the same account, engine,
owner, and selection. Preserve all protocol metadata when replacing the queue, and never change
presentation to imply success before confirmation. Provisional, stale, restricted, local-owner,
or rejected requests retain the visible queue. Refuse another removal while one is in flight:
cancelling local work cannot undo a service-accepted write. Cancelled or stale-lifetime completions
must not publish feedback into the current account.

Local-owner removal is unavailable because the retained engine has no public selected-occurrence
removal command. Future support must stay within that engine boundary. Add to Queue supports local
and remote owners and preserves visible selection order; sequential adds are non-atomic and report
full, partial, or zero completion.

See [transient feedback](navigation.md#transient-mutation-feedback),
[queue authority](../../Sources/Spotty/Spotify/QueueService.swift), and
[mutation policy](../../Sources/SpottyDomain/QueueMutation.swift) for the behavior's owners.
