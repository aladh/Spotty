"""Bound living documentation; semantic review still owns usefulness and duplication."""

from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
GUIDE_WORD_LIMIT = 1000
README_WORD_LIMIT = 500
AGENT_WORD_LIMIT = 400


def word_limit(name: str) -> int | None:
    path = PurePosixPath(name)
    if name.startswith("Backend/spotty-playback/vendor/") or path.suffix != ".md":
        return None
    if path.name == "AGENTS.md":
        return AGENT_WORD_LIMIT
    if name == "README.md":
        return README_WORD_LIMIT
    if path.name == "README.md":
        return GUIDE_WORD_LIMIT
    if len(path.parts) == 1:
        return None if name == "THIRD_PARTY_NOTICES.md" else GUIDE_WORD_LIMIT
    if path.parts[0] != "docs":
        return None
    # Records and generated legal notices are not living how-to guides.
    if name == "docs/architecture/performance-baseline.md":
        return None
    if re.fullmatch(r"docs/releases/v\d+\.\d+\.\d+\.md", name):
        return None
    if re.fullmatch(r"docs/architecture/adrs/ADR-\d+-.+\.md", name):
        return None
    return GUIDE_WORD_LIMIT


def violations(root: Path, names: list[str]) -> list[str]:
    failures = []
    for name in sorted(set(names)):
        limit = word_limit(name)
        path = root / name
        if limit is None or not path.is_file():
            continue
        # Count the entire Markdown source, including code, tables, and comments.
        words = len(path.read_text(encoding="utf-8").split())
        if words > limit:
            failures.append(f"{name}: {words} words exceeds the {limit}-word limit")
    return failures


def check(root: Path) -> int:
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root,
    ).decode("utf-8").split("\0")
    failures = violations(root, [name for name in names if name])
    if failures:
        print("\n".join(failures), file=sys.stderr)
        print(
            "Keep one canonical owner; remove repetition before adding or splitting pages. "
            "Preserve requirements. See docs/AGENTS.md. Limit changes are policy changes.",
            file=sys.stderr,
        )
        return 1
    print("Documentation size limits passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(check(ROOT))
