#!/usr/bin/env python3
"""Warn when an intentionally independent app pin lags the engine sources."""
import json
from pathlib import Path
import subprocess
import sys


def freshness_warning(pinned: str, current: str) -> str | None:
    if pinned == current:
        return None
    return ("Pinned playback engine inputs differ from current source inputs "
            f"(pinned {pinned}, source {current}). Publish and adopt an engine release "
            "when these source changes should ship.")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    provenance = json.loads((Path(sys.argv[1]) / 'spotty_playback_provenance.json').read_text())
    pinned = provenance['source']['engineInputDigest']
    current = subprocess.check_output(
        [str(root / 'Backend/spotty-playback/source-input-digest.sh')], text=True).strip()
    warning = freshness_warning(pinned, current)
    if warning:
        print(f'::warning title=Playback pin freshness::{warning}')
    else:
        print('Pinned playback engine matches current source inputs')


if __name__ == '__main__':
    main()
