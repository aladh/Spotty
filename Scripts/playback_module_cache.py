"""Invalidate only stale Xcode playback modules after an engine artifact is validated."""

import argparse
from pathlib import Path
import sys


HEADERS = (
    "spotty_playback.h", "spotty_playback_generated.h", "spotty_playback_annotations.h", "module.modulemap",
)


def local_directory(build_root: Path, relative: str) -> Path | None:
    """Do not follow build-directory symlinks into another cache."""
    path = build_root
    if path.is_symlink():
        return None
    for component in Path(relative).parts:
        path /= component
        if path.is_symlink():
            return None
    return path if path.is_dir() else None


def invalidate_stale_modules(build_root: Path, headers: Path, configuration: str) -> int:
    selected = {name: (headers / name).read_bytes() for name in HEADERS}
    # Xcode stages binary-target headers at a stable path even when the selected archive's
    # content-addressed name changes. Compare bytes: artifact timestamps are normalized.
    staged = local_directory(build_root, f"out/Products/{configuration.capitalize()}/include")
    if staged is None or any(
        (staged / name).is_symlink() or not (staged / name).is_file() for name in HEADERS
    ):
        return 0
    if all((staged / name).read_bytes() == content for name, content in selected.items()):
        return 0

    cache = local_directory(build_root, "out/Intermediates.noindex/SwiftExplicitPrecompiledModules")
    if cache is None:
        return 0
    removed = 0
    for module in cache.glob("SpottyPlaybackCore-*.pcm"):
        if module.is_file() and not module.is_symlink():
            module.unlink()
            removed += 1
    return removed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_root", type=Path)
    parser.add_argument("headers", type=Path)
    parser.add_argument("--configuration", required=True, choices=("debug", "release"))
    arguments = parser.parse_args()
    try:
        removed = invalidate_stale_modules(arguments.build_root, arguments.headers, arguments.configuration)
    except OSError as error:
        parser.exit(1, f"Playback module cache: {error}\n")
    if removed:
        print(f"Removed {removed} stale SpottyPlaybackCore compiled modules", file=sys.stderr)
