"""Probe real macOS manifests and dependency resolution; stdout is the deployment target."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from verification_package import TEST_TARGETS, prepare


ROOT = Path(__file__).resolve().parents[1]


def swift(package: Path, graph: str, operation: str, **environment: str) -> subprocess.CompletedProcess:
    selected_environment = {**os.environ, **environment, "SPOTTY_PACKAGE_GRAPH": graph}
    override = selected_environment.get("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK")
    if override is not None:
        # Graph probes, like the user wrapper, keep relative artifact ownership at ROOT.
        selected_environment["SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"] = str(ROOT / override)
    return subprocess.run(
        ["swift", "package", "--disable-sandbox", "--package-path", str(package), operation],
        env=selected_environment,
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

    if "SpottyBrowsingHarness" in graph and reachable("SpottyBrowsingHarness") & {
        "SpottyTestSupport", "SpottyRuntimeTestSupport"
    }:
        raise ValueError("Runnable Demo acquired test-framework assertions")
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
        if reachable(product) & {support, "SpottyTestSupport", "SpottyHarnessSupport"}:
            raise ValueError(f"{product} acquired a test-support dependency")


def dependency_closure(targets: dict, selected: str) -> tuple[set[str], set[str]]:
    """Derive expectations from dump-package, never from a parallel dependency map."""
    local, external, pending = set(), set(), [selected]
    while pending:
        name = pending.pop()
        if name in local:
            continue
        if name not in targets:
            raise ValueError(f"Unknown local package dependency: {name}")
        local.add(name)
        for dependency in targets[name].get("dependencies", []):
            if "byName" in dependency or "target" in dependency:
                pending.append(dependency.get("byName", dependency.get("target"))[0])
            elif "product" in dependency:
                package = dependency["product"][1]
                if not package:
                    raise ValueError(f"Unbound external package dependency: {name}")
                external.add(package.lower())
            else:
                raise ValueError(f"Unknown package dependency shape in {name}")
    return local, external


def package_identity(dependency: dict) -> str:
    for kind in ("sourceControl", "fileSystem", "registry"):
        if kind in dependency:
            return dependency[kind][0]["identity"].lower()
    raise ValueError("Unknown external package declaration")


def verify_selection(full: dict, focused: dict, name: str, *, full_package: Path = ROOT,
                     focused_package: Path | None = None) -> None:
    targets = {target["name"]: target for target in full["targets"]}
    local, external = dependency_closure(targets, name)
    selected = {target["name"]: target for target in focused["targets"]}
    if selected.keys() != local or len(selected) != len(focused["targets"]):
        raise ValueError(f"{name} does not contain its exact local dependency closure")
    if {target["name"] for target in focused["targets"] if target["type"] == "test"} != {name}:
        raise ValueError(f"{name} must be the only focused test target")
    for target_name, declaration in selected.items():
        original = targets[target_name]
        if (declaration.get("type") == original.get("type") == "binary"
                and isinstance(declaration.get("path"), str) and isinstance(original.get("path"), str)
                and focused_package is not None):
            # A local binary's relative path belongs to its package, not to the source
            # checkout. Normalize only this path; every other declaration field stays exact.
            declaration = {**declaration, "path": str((focused_package / declaration["path"]).resolve())}
            original = {**original, "path": str((full_package / original["path"]).resolve())}
        if declaration != original:
            raise ValueError(f"{name} changed the shared declaration of {target_name}")
    dependencies = [dependency for dependency in full["dependencies"]
                    if package_identity(dependency) in external]
    if {package_identity(dependency) for dependency in dependencies} != external:
        raise ValueError(f"{name} has an unbound external dependency")
    if focused["dependencies"] != dependencies or focused.get("products"):
        raise ValueError(f"{name} acquired unexpected external dependencies or products")


def verify_full_manifest(full: dict) -> dict:
    """Validate the genuine shipping/test reference before comparing any focused cut."""
    targets = {target["name"]: target for target in full["targets"]}
    if len(targets) != len(full["targets"]):
        raise ValueError("Full verification contains duplicate target declarations")
    test_names = {*TEST_TARGETS, "SpottyBrowsingHarnessTests"}
    required = {"SpottyPlaybackCore": "binary", "SpottyEngineAdapter": "regular",
                "SpottySessionRuntime": "regular", "SpottyCore": "regular",
                "SpottyApp": "executable", "SpottyBrowsingHarness": "executable",
                "SpottyRuntimeTestSupport": "regular",
                **{name: "test" for name in test_names}}
    if not required.keys() <= targets.keys() or not full["dependencies"]:
        raise ValueError("Full verification lost an app, engine, browsing, or package dependency")
    if (any(targets[name].get("type") != kind for name, kind in required.items()) or
            {name for name, target in targets.items() if target.get("type") == "test"} != test_names):
        raise ValueError("Full verification changed the shipping or exact test target types")
    for name in targets:
        dependency_closure(targets, name)
    verify_test_support(targets)
    return targets


def verify() -> str:
    # Dumping the full graph preserves artifact validation without resolving dependencies.
    full = json.loads(succeeded(swift(ROOT, "full", "dump-package", SPOTTY_BUILD_BROWSING_HARNESS="1")))
    targets = verify_full_manifest(full)
    lockfile = ROOT / "Package.resolved"
    before = lockfile.read_bytes() if lockfile.exists() else None
    try:
        with tempfile.TemporaryDirectory(prefix="spotty-package-graphs-") as temporary:
            root = Path(temporary)
            for name in ("Package.swift", "Sources", "Tests"):
                (root / name).symlink_to(ROOT / name, target_is_directory=(ROOT / name).is_dir())
            # Give the temporary checkout its own lockfile too. Neither isolated root owns it.
            app_lock = before if before is not None else b'{"pins": [], "version": 3}\n'
            (root / "Package.resolved").write_bytes(app_lock)
            invalid = {"SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": str(root / "missing.xcframework"),
                       "SPOTTY_BUILD_BROWSING_HARNESS": "1"}
            for graph, names in (
                ("domain", {"SpottyDomain", "SpottyDomainTests"}),
                ("engine-free", {"SpottyDomain", "SpottyDomainTests", "SpottyRuntimeContracts",
                                 "SpottyDiagnostics", "SpottyGateway", "SpottyGatewayTests",
                                 "SpottyCatalogStorage", "SpottyCatalogStorageTests",
                                 "SpottyTestSupport", "SpottyTestSupportTests", "SpottyHarnessSupport"}),
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
                if (root / "Package.resolved").read_bytes() != app_lock:
                    raise ValueError(f"{graph} changed the app lockfile")
            for name in TEST_TARGETS:
                graph = f"test-target:{name}"
                package = prepare(root, graph)
                local, external = dependency_closure(targets, name)
                # Only binary-consuming cuts may evaluate the playback override. Dumping
                # those graphs needs no artifact download or external package resolution.
                environment = {"SPOTTY_BUILD_BROWSING_HARNESS": "1"}
                if "SpottyPlaybackCore" not in local:
                    environment.update(invalid)
                manifest = json.loads(succeeded(swift(package, graph, "dump-package", **environment)))
                verify_selection(full, manifest, name, focused_package=package)
                if not external and "SpottyPlaybackCore" not in local:
                    succeeded(swift(package, graph, "resolve", **invalid))
                if (root / "Package.resolved").read_bytes() != app_lock:
                    raise ValueError(f"{name} changed the app lockfile")
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
