# Queue behavior

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Queue

- In Queue and Recently played, Tab enters the available artwork control of one selected, loaded row.
  Shift-Tab returns to native row selection; Tab from the control continues through the window's focus order.
  Multiple selection and rows without a loaded control follow the normal window focus order.
- A queue refresh started before the first Connect snapshot must preserve and hydrate the newer
  Connect ordering when it arrives, including when the Web request fails. Metadata hydration cannot
  replace that ordering with its captured startup fallback.
- Playback is the queue's ordering authority. Catalog and Web API metadata may enrich names but
  cannot reorder it; resolvable entries progressively replace fallback `Unknown` labels.
- Current and upcoming queue rows use a native selectable list. Selection alone never plays;
  Return/double-click on the current row pauses
  or resumes at the retained position; on one upcoming row it starts that track. Multiple selected
  rows do not activate playback. Delete/Backspace and **Remove from Queue**
  remove only selected *upcoming* occurrences by queue identity (Connect occurrence uid when
  present), never by track URI. Duplicate URIs or duplicate UIDs that cannot be proven fail
  closed. The now-playing row and Recently played tab are not removable queue entries; a selection
  mixing current and upcoming rows cannot remove either.
- Selection follows a valid Connect occurrence UID through reorder and metadata enrichment and
  survives closing/reopening the inspector. Removed occurrences are pruned even while it is closed;
  account replacement clears selection. Position-based fallback rows cannot promise continuity
  when no stable occurrence identity is available.
- Recently played uses single native selection. Clicking a row or moving with arrows never plays;
  Return/double-click starts the selected track from
  the beginning, including the current track. Playback controls disable when unavailable.
  History selection follows the track through metadata updates/reordering and inspector reopening;
  removed entries and account changes clear it. History never offers queue removal.
- History records observed changes to a playing track and transitions into playing, including an
  externally resumed current track, for local and remote Connect playback after the first playback snapshot.
  The first snapshot, recovery replays, paused observations, and
  rejected/stale events do not create entries. Known Play/Resume targets enter history only after
  observed confirmation. Timing and metadata updates do not rewrite the played time; account
  replacement clears session history. The accessibility value announces the recorded date and time,
  remaining truthful while idle without periodic row updates.
- Authoritative ordering and cached labels appear immediately. Missing metadata arrives in batches
  no more often than every 50 ms; one stalled lookup must not hold completed labels until the whole
  queue finishes. Shared refresh work survives panel cancellation when it can still serve a matching
  caller, while account replacement cancels unpublished batches.
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

See [transient mutation feedback](navigation.md#transient-mutation-feedback) for shared banner behavior.
[QueueService](../../Sources/SpottySessionRuntime/QueueService.swift) owns queue authority;
[QueueMutation](../../Sources/SpottyDomain/QueueMutation.swift) owns mutation policy.
