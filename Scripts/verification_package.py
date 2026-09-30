"""Own isolated verification package roots without copying target declarations."""

import argparse
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_TARGETS = (
    "SpottyDomainTests", "SpottyTestSupportTests", "SpottyCatalogStorageTests",
    "SpottyGatewayTests", "SpottyEngineAdapterTests", "SpottySessionRuntimeTests",
    "SpottyBoundaryTests",
)


def workspace(root: Path, graph: str) -> Path:
    if graph.startswith("test-target:"):
        target = graph.removeprefix("test-target:")
        if target not in TEST_TARGETS:
            raise ValueError(f"Unknown isolated test target: {target}")
        return root / ".build" / "test-targets" / target
    if graph not in ("domain", "engine-free"):
        raise ValueError(f"Unknown isolated package graph: {graph}")
    return root / ".build" / graph


def owned_directory(root: Path, directory: Path) -> None:
    # Never follow an unexpected generated-root symlink into somebody else's package.
    current = root
    for component in directory.relative_to(root).parts:
        current = current / component
        if current.is_symlink() or (current.exists() and not current.is_dir()):
            raise ValueError(f"Expected owned package directory: {current}")
        current.mkdir(exist_ok=True)


def prepare(root: Path = ROOT, graph: str = "domain") -> Path:
    # A scratch path isolates products, but SwiftPM still owns Package.resolved beside the
    # manifest. Give the dependency-free graph its own package root so it cannot remove the
    # app lockfile or resolve its pins. Symlinks keep source paths live without copying code.
    package = workspace(root, graph) / "package"
    owned_directory(root, package)
    inputs = ("Package.swift", "Sources/SpottyDomain", "Tests/SpottyDomainTests") if graph == "domain" else (
        "Package.swift", "Sources", "Tests",
    )
    for relative in inputs:
        source = root / relative
        if not source.exists():
            raise ValueError(f"Missing {graph} package input: {source}")
        link = package / relative
        owned_directory(root, link.parent)
        if link.is_symlink():
            if link.resolve() != source.resolve():
                raise ValueError(f"Unexpected {graph} package link: {link}")
        elif link.exists():
            raise ValueError(f"Expected {graph} package symlink: {link}")
        else:
            link.symlink_to(os.path.relpath(source, link.parent), target_is_directory=source.is_dir())
    if graph.startswith("test-target:"):
        # SwiftPM may rewrite/remove its own resolution file, but can never touch the
        # app's. Seed current pins for external-product cuts without a second graph map.
        lockfile = package / "Package.resolved"
        if lockfile.is_symlink() or (lockfile.exists() and (
                not lockfile.is_file() or lockfile.stat().st_nlink != 1)):
            raise ValueError(f"Expected owned package lockfile: {lockfile}")
        app_lockfile = root / "Package.resolved"
        if app_lockfile.exists():
            lockfile.write_bytes(app_lockfile.read_bytes())
    return package


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("graph", choices=("domain", "engine-free", *(f"test-target:{name}" for name in TEST_TARGETS)))
    print(prepare(graph=parser.parse_args().graph))
