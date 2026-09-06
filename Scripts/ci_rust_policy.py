"""Select compiler verification from trusted PR paths; main always verifies both toolchains."""

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
}


DOCUMENTATION_FILES = {"README.md", "AGENTS.md", "CONTRIBUTING.md", "PRIVACY.md", "SECURITY.md"}
DOCUMENTATION_SUFFIXES = {".md", ".png", ".jpg", ".jpeg", ".svg", ".gif", ".webp"}


def documentation_path(path):
    return (Path(path).name == "AGENTS.md" or path in DOCUMENTATION_FILES
            or (path.startswith("docs/") and Path(path).suffix in DOCUMENTATION_SUFFIXES))


def verification_needed(event, base, repository):
    if event != "pull_request":
        return {"rust_needed": True, "macos_needed": True}
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
    paths = [path for path in result.decode("utf-8", errors="surrogateescape").split("\0") if path]
    return {
        "rust_needed": any(not documentation_path(path) and path not in APP_ONLY_FILES
                           and not path.startswith(APP_ONLY_DIRECTORIES) for path in paths),
        "macos_needed": any(not documentation_path(path) for path in paths),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="")
    args = parser.parse_args()
    for name, needed in verification_needed(args.event, args.base, Path.cwd()).items():
        print(f"{name}={str(needed).lower()}")


if __name__ == "__main__":
    main()
