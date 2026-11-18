# Synthetic acceptance

Run `./script/build_and_run.sh --demo` for interactive work with synthetic playback and catalog data. `./Scripts/smoke-synthetic-ui.sh` runs the integrated tests and renders the README scene. `./Scripts/browse-synthetic.sh` writes the screenshot and corresponding accessibility tree into a unique `.build/browsing-runs` directory. Pass Rune's `--script` and `--at` arguments for a recorded input sequence. [Rune build guide](../../Rune/README.md)

The synthetic suite exercises keyboard and mouse selection, search filters, queue ownership, album track expansion, and observed transport settlement. Capture the specific interaction or state being changed. Native device and account acceptance follows the [safe testing contract](../product/safe-testing.md).

`python3 Scripts/verify.py acceptance` runs each [named scenario](../../Rune/acceptance.json) and writes a revision-bound result, the test logs, screenshot and tree under `.build/rune-evidence`. The CI review artifact carries the same summary.
