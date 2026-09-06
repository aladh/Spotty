"""Skip PR Rust verification only when every changed path belongs to the app or docs."""

import argparse
from pathlib import Path
import re
import subprocess


APP_ONLY_DIRECTORIES = (
    "Sources/Spotty/", "Sources/SpottyApp/", "Sources/SpottyDomain/",
    "Tests/SpottyBoundaryTests/", "Tests/SpottyDomainTests/",
    "Assets/", "Packaging/", "docs/",
)
APP_ONLY_FILES = {
    "Package.swift", "Package.resolved", ".swift-format",
    "README.md", "AGENTS.md", "CONTRIBUTING.md", "PRIVACY.md", "SECURITY.md",
}


def rust_needed(event, base, repository):
    if event != "pull_request":
        return True
    if not re.fullmatch(r"[0-9a-f]{40}", base) or base == "0" * 40:
        raise ValueError("PR Rust selection requires a valid base SHA")
    subprocess.run(
        ["git", "fetch", "--quiet", "--no-tags", "--depth=1", "origin", base], cwd=repository, check=True,
        stdout=subprocess.DEVNULL,
    )
    # A move out of engine scope must retain its deleted source path. NUL framing also handles
    # whitespace/newlines in filenames without accidentally classifying part of a name as app-only.
    result = subprocess.check_output(
        ["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--"], cwd=repository,
    )
    paths = result.decode("utf-8", errors="surrogateescape").split("\0")
    return any(path and path not in APP_ONLY_FILES and not path.startswith(APP_ONLY_DIRECTORIES)
               for path in paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="")
    args = parser.parse_args()
    needed = rust_needed(args.event, args.base, Path.cwd())
    print(f"rust_needed={str(needed).lower()}")


if __name__ == "__main__":
    main()
