# Shared catalog interaction

[Product contracts](README.md) · [Playback ownership](playback.md) · [Safe testing](safe-testing.md)

This contract owns behavior shared by catalog surfaces. Surface contracts retain their layout,
dimensions, ordering, and deliberate exceptions.

## Loading and retained content

- Distinguish an unknown result from a successful empty result. Missing response lists, rejected
  unions, mismatched collections, incomplete paged reads, and contradictory collection counts are
  failures, never empty success. Preserve ordered duplicate occurrences; only complete accepted
  results may replace saved collections.
- After verifying the current account, show complete saved playlists/albums and the saved library,
  including empty results, while refreshing. Label saved content potentially outdated during refresh
  and offline, timeout, or throttled failure. No offline sign-in or downloaded music.
- Refreshing keeps useful content and interaction visible. Transient failure retains that content
  with an in-place retry and stale/error notice; a successful live refresh removes the notice.
  Without useful rows, retain the surface's full error/retry presentation. Retry is unavailable while
  refreshing or disconnected. Successful empty results clear the corresponding content.
- Cancellation is not a displayed error and cannot restore current authority to the preceding
  content. Reconnect requires fresh proof before historical ownership or occurrence IDs can enable
  editing. Metadata enrichment updates labels without changing collection freshness or authority.
- Credential refusal clears the affected detail and its retained routes. Within Search it clears
  every category; within Home/library it clears every section and its metadata. Fence sibling and
  suspended responses so they cannot restore rejected content. Credential/account failures cannot
  become cached success. New profile proof is required before further cached reads.
- Account replacement clears retention and interaction. Superseded route, query, account, and
  session responses cannot publish into their replacements. A retained control cannot act for a
  replacement account.

[Search](search.md) owns category-level partial failure and debounce; the
[sidebar](library-sidebar.md#empty-and-failed-loads) owns saved-empty wording. Navigation owns
[bounded route retention](navigation.md#navigation-and-retained-content).

## Playback intent

The control's glyph, label, tooltip, availability, and dispatch must describe one action. Current
selection activation pauses observed playback or resumes its retained position; a different
selection starts playback. Track controls match the track URI; collections match context, never
membership. Revalidate the target and account against current runtime authority when activated.
Controls target the current owner without implicitly transferring playback.

| Surface/action | Meaning |
| --- | --- |
| Home/shelf/grid Play, sidebar artwork, expanded/compact detail Play, discography release Play | Activate the selected track or collection |
| Numbered playlist/album/artist/Search row button; Search preview artwork | Activate the selected track |
| Track-row Return, double-click, or context-menu Play | Start the selected track from the beginning |
| Current Queue row artwork, Return, or double-click | Pause/resume the current track |
| Upcoming Queue activation | Start that occurrence's track from the beginning, even if its URI matches the current track |
| Recently played activation | Start that entry's track from the beginning, even if its URI matches the current track |

Disconnected playback and pending commands disable activation. An unavailable track cannot start
or resume, but the playing current track remains pausable. Numbered rows announce unavailable
status alongside the ordinal. Browsing selection alone never starts playback.

## Focus and accessibility

Keep navigation and playback as separate native actions, without nested buttons. Hover or
keyboard/accessibility focus reveals artwork playback controls; assistive technology can discover
them at rest. Hidden controls do not intercept pointer navigation. Disabled visible controls are
dimmed while navigation remains usable. Tab reaches each available action; Space activates once
per press, including repeat and key-up phases.

In the sidebar, Search preview, Queue, and Recently played native lists, Tab enters the available
artwork or folder-disclosure control of one selected, loaded row. Shift-Tab returns to native row
selection; Tab from the control continues through the window's focus order. Multiple selection and
rows without a loaded control follow normal window order. Moving focus does not activate a row.
Retained controls must remain attached to the current row and window; removal or reuse retires
their focus ownership. Preserve selection, focus, and scroll through metadata/refresh updates
unless their occurrence is removed or filtered out.
