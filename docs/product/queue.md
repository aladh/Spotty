# Queue behavior

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Queue

- A queue refresh started before the first Connect snapshot must preserve and hydrate the newer
  Connect ordering when it arrives, including when the Web request fails. Metadata hydration cannot
  replace that ordering with its captured startup fallback.
- Playback is the queue's ordering authority. Catalog and Web API metadata may enrich names but
  cannot reorder it; resolvable entries progressively replace fallback `Unknown` labels.
- Upcoming queue rows use a native selectable list. Delete/Backspace and **Remove from Queue**
  remove only selected *upcoming* occurrences by queue identity (Connect occurrence uid when
  present), never by track URI. Duplicate URIs or duplicate UIDs that cannot be proven fail
  closed. The now-playing row and Recently played tab are not removable queue entries. Play from the queue
  remains a deliberate primary action (Return/double-click), not a single-click.
- Queue replacement calls Spotify Connect `set_queue` with remaining protocol `next_tracks`, current
  `prev_tracks`, and the exact incoming ProvidedTrack metadata map (`metadata`, `uid`, `provider`,
  and every other snapshot player.proto field). Never synthesize `is_queued` or alter presentation
  state to imply success. Sequential Add to Queue is non-atomic and reports full, zero, or partial
  completion.
  Removal requires a complete Connect mutation snapshot, matching account/engine epoch and owner,
  and no `disallow_set_queue` or `disallow_removing_from_next_tracks` reason. Partial, provisional,
  web-API-only, restricted, joining, local-owner, stale-selection, and rejected requests retain the
  visible queue and report through `TransientFeedbackPresenter`. While authoritative replacement is
  in flight, silently refuse another removal: cancelling the local task cannot undo an accepted
  `set_queue`. Cancelled or account-epoch-invalidated in-flight removals also retain the queue
  without transient feedback.
- Local-owner removal is disabled: librespot `Spirc` at the pinned revision exposes append and
  clear operations, but not selected-occurrence removal, and inbound `SetQueue` is not a public
  local command. Any future support must remain within
  the retained engine boundary and pass focused checks. Add to Queue remains available for local
  and remote owners, including multiple selected tracks in visible order.
