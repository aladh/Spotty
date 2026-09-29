"""Isolate dependency-free verification graphs without copying their target definitions."""

import argparse
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def prepare(root: Path = ROOT, graph: str = "domain") -> Path:
    # A scratch path isolates products, but SwiftPM still owns Package.resolved beside the
    # manifest. Give the dependency-free graph its own package root so it cannot remove the
    # app lockfile or resolve its pins. Symlinks keep source paths live without copying code.
    if graph not in ("domain", "engine-free"):
        raise ValueError(f"Unknown isolated package graph: {graph}")
    inputs = ("Package.swift", "Sources/SpottyDomain", "Tests/SpottyDomainTests") if graph == "domain" else (
        "Package.swift", "Sources", "Tests",
    )
    package = root / ".build" / graph / "package"
    for relative in inputs:
        source = root / relative
        if not source.exists():
            raise ValueError(f"Missing {graph} package input: {source}")
        link = package / relative
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink():
            if link.resolve() != source.resolve():
                raise ValueError(f"Unexpected {graph} package link: {link}")
        elif link.exists():
            raise ValueError(f"Expected {graph} package symlink: {link}")
        else:
            link.symlink_to(os.path.relpath(source, link.parent), target_is_directory=source.is_dir())
    return package


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("graph", choices=("domain", "engine-free"))
    print(prepare(graph=parser.parse_args().graph))
