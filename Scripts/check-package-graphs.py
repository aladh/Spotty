"""Probe real macOS manifests and dependency resolution; stdout is the deployment target."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from verification_package import prepare


ROOT = Path(__file__).resolve().parents[1]


def swift(package: Path, graph: str, operation: str, **environment: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["swift", "package", "--disable-sandbox", "--package-path", str(package), operation],
        env={**os.environ, "SPOTTY_PACKAGE_GRAPH": graph, **environment},
        text=True, capture_output=True, timeout=60,
    )


def succeeded(result: subprocess.CompletedProcess) -> str:
    if result.returncode:
        raise ValueError(f"Package graph probe failed: {result.args}\n{result.stderr}")
    return result.stdout


def verify_test_support(targets: dict) -> None:
    """Keep shared fakes independent of runtime/desktop owners and shipping products."""
    graph = {}
    for name, target in targets.items():
        edges = set()
        for dependency in target.get("dependencies", []):
            if "byName" in dependency or "target" in dependency:
                edges.add(dependency.get("byName", dependency.get("target"))[0])
            elif "product" not in dependency:
                raise ValueError(f"Unknown package dependency shape in {name}")
        graph[name] = edges

    def reachable(name):
        found, pending = set(), [name]
        while pending:
            current = pending.pop()
            if current not in found:
                found.add(current)
                pending.extend(graph.get(current, ()))
        return found

    support = "SpottyRuntimeTestSupport"
    for owner in (support, "SpottySessionRuntimeTests"):
        if "SpottyCore" in reachable(owner):
            raise ValueError(f"{owner} acquired a desktop dependency")
    if "SpottySessionRuntime" in reachable(support):
        raise ValueError(f"{support} acquired a runtime implementation dependency")
    for consumer in ("SpottyBoundaryTests", "SpottySessionRuntimeTests"):
        if support not in graph.get(consumer, ()):
            raise ValueError(f"{consumer} lost its shared runtime fixtures")
    for product in ("SpottyApp", "SpottyCore", "SpottyDomain"):
        if reachable(product) & {support, "SpottyTestSupport"}:
            raise ValueError(f"{product} acquired a test-support dependency")


def verify() -> str:
    # Dumping the full graph preserves artifact validation without resolving dependencies.
    full = json.loads(succeeded(swift(ROOT, "full", "dump-package", SPOTTY_BUILD_BROWSING_HARNESS="1")))
    targets = {target["name"]: target for target in full["targets"]}
    required = {"SpottyPlaybackCore", "SpottyEngineAdapter", "SpottySessionRuntime", "SpottyCore",
                "SpottyApp", "SpottyBoundaryTests", "SpottyBrowsingHarnessTests", "SpottyRuntimeTestSupport"}
    if not required <= targets.keys() or not full["dependencies"]:
        raise ValueError("Full verification lost an app, engine, browsing, or package dependency")
    verify_test_support(targets)
    lockfile = ROOT / "Package.resolved"
    before = lockfile.read_bytes() if lockfile.exists() else None
    try:
        with tempfile.TemporaryDirectory(prefix="spotty-package-graphs-") as temporary:
            root = Path(temporary)
            for name in ("Package.swift", "Sources", "Tests"):
                (root / name).symlink_to(ROOT / name, target_is_directory=(ROOT / name).is_dir())
            # Give the temporary checkout its own lockfile too. Neither isolated root owns it.
            (root / "Package.resolved").write_bytes(b"synthetic app lockfile\n")
            invalid = {"SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": str(root / "missing.xcframework"),
                       "SPOTTY_BUILD_BROWSING_HARNESS": "1"}
            for graph, names in (
                ("domain", {"SpottyDomain", "SpottyDomainTests"}),
                ("engine-free", {"SpottyDomain", "SpottyDomainTests", "SpottyRuntimeContracts",
                                 "SpottyDiagnostics", "SpottyGateway", "SpottyGatewayTests",
                                 "SpottyCatalogStorage", "SpottyCatalogStorageTests",
                                 "SpottyTestSupport", "SpottyTestSupportTests"}),
            ):
                package = prepare(root, graph)
                manifest = json.loads(succeeded(swift(package, graph, "dump-package", **invalid)))
                selected = {target["name"]: target for target in manifest["targets"]}
                if manifest["dependencies"] or selected.keys() != names:
                    raise ValueError(f"{graph} acquired an unexpected dependency or lost a target")
                for name, target in selected.items():
                    if target != targets[name]:
                        raise ValueError(f"{graph} changed the shared declaration of {name}")
                succeeded(swift(package, graph, "resolve", **invalid))
                if (root / "Package.resolved").read_bytes() != b"synthetic app lockfile\n":
                    raise ValueError(f"{graph} changed the app lockfile")
            rejected = swift(ROOT, "full", "dump-package", **invalid)
            if rejected.returncode == 0 or "must point to an existing XCFramework directory" not in rejected.stderr:
                raise ValueError("The full graph stopped validating its playback override")
    finally:
        after = lockfile.read_bytes() if lockfile.exists() else None
        if after != before:
            raise ValueError("Package graph probes changed the repository lockfile")
    print("Package graphs: shared declarations, dependency isolation, artifact validation, and lockfiles passed",
          file=sys.stderr)
    return next(platform["version"] for platform in full["platforms"] if platform["platformName"] == "macos")


if __name__ == "__main__":
    try:
        print(verify())
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"Package graph checks: {error}") from error
