# Spotty Rune port evidence

These captures support [PR #627](https://github.com/aladh/Spotty/pull/627). The original README screenshot comes from [base commit 9b5d72b](https://github.com/aladh/Spotty/tree/9b5d72b686ac094148b395006918cc1215cbb8e3). Rune interaction captures and supplemental test logs come from [clean source commit b07f63e](https://github.com/aladh/Spotty/tree/b07f63e439ff2450babb0620f0ea0e0b8c7b4420).

The [regular acceptance suite](acceptance/summary.json) passed on clean PR head [3c7a19f](https://github.com/aladh/Spotty/tree/3c7a19f6ac9009e556eae81af74fdefc6bb2fff9) after review fixes. Its reference PNG and accessibility tree match the original Rune captures byte for byte.

## Visual captures

| Surface | Evidence |
| --- | --- |
| README playlist comparison | [main README image](screenshots/main-readme-reference.jpg) · [Rune reference](screenshots/reference.png) · [Rune accessibility tree](trees/reference.json) |
| Playlist interactions | [MP4](replays/playlist-and-connect.mp4) · [animated preview](replays/playlist-and-connect.gif) · [input script](replays/playlist-and-connect.json) |
| Playlist checkpoints | [filtered](screenshots/filtered.png) · [queue](screenshots/queue.png) · [history](screenshots/history.png) · [Connect](screenshots/connect.png) |
| Search and navigation | [MP4](replays/search-and-navigation.mp4) · [input script](replays/search-and-navigation.json) |
| Two-query history, captured at 3dfd957 | [Back and Forward MP4](replays/search-history-round-trip.mp4) · [Input script](replays/search-history-round-trip.json) · [First query restored](screenshots/restored-first-query.png) · [Second query restored](screenshots/restored-second-query.png) |
| Search checkpoints | [results](screenshots/results.png) · [opened playlist](screenshots/playlist.png) · [restored query](screenshots/restored.png) |

The reference uses Rune’s 1720×1078 point scene at scale 2. Interaction captures use 1280×800 points at scale 1. The recordings replay real app input over synthetic data. They contain no audio. The [trees](trees/) cover all ten Rune still captures and each has zero layout warnings. Device names and playback states in the capture come from the demo.

## Tests

- All three acceptance scenarios passed from a clean tree. [Summary](acceptance/summary.json)
- 200 regular Rust tests and all four separately named transport traces passed. [Integrated log](acceptance/rune.integrated.log) · [Trace log](acceptance/playback.transport.log)
- All three opt-in synthetic probes passed. The values describe injected fixtures. [Probe log](probes/tests.log) · [Probe receipts](probes/)
- Review automation passed 32 Python and 13 Node tests. The current source policy run passed nine AST rule groups and 16 routing tests. Eight acceptance collector tests passed. [Tooling logs](tooling/) · [Pagination and approval recheck regressions](tooling/review-pagination.log) · [37 historical workflow fixture tests](tooling/historical-workflow-fixtures.log)
- The Linux binary has no exported Spotty playback C symbols. [Binary check](tooling/binary.log)

- The Apple-target dependency notice audit accounted for 352 of 393 dependencies. It records 41 entries that need pinned license files or fork provenance. [Audit data](tooling/notice-audit.json)

## Reproduce

From the product checkout, with the dependencies in its build guide installed, run the acceptance suite and pass the replay JSON files to the demo wrapper.

```sh
python3 Scripts/verify.py acceptance
./Scripts/browse-synthetic.sh --interactive --size 1280x800 --scale 1 \
  --scene reference --script /path/to/playlist-and-connect.json \
  --pointer --keys --fps 18 --duration auto --video /tmp/playlist-and-connect.mp4
./Scripts/browse-synthetic.sh --interactive --size 1280x800 --scale 1 \
  --script /path/to/search-and-navigation.json \
  --pointer --keys --fps 18 --duration auto --video /tmp/search-and-navigation.mp4
```

These Linux captures cover the synthetic UI and test fixtures. macOS signing, native accessibility, physical audio output, Sparkle updates, and live Spotify require separate evidence. [Checksums](SHA256SUMS)
