"""Discover and run every owned Python/Node script test in its CI lane."""

import argparse
import importlib.util
from pathlib import Path, PurePosixPath
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
GROUPS = ("policy", "playback", "watchdog", "review")
REVIEW_ROOT = PurePosixPath("Scripts/agent-review-tests")
NODE_SUFFIXES = {".js", ".mjs", ".cjs"}


def is_test(path: PurePosixPath) -> bool:
    if path.suffix == ".py":
        return path.name.startswith("test") or path.name.endswith("_test.py")
    if path.suffix in NODE_SUFFIXES | {".ts", ".mts", ".cts"}:
        return (".test." in path.name or ".spec." in path.name
                or path.name.startswith(("test.", "test_", "test-")))
    return False


def inventory(root: Path) -> dict[str, list[Path]]:
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root
    ).decode().split("\0")
    groups = {name: [] for name in GROUPS}
    for name in sorted(set(names) - {""}):
        path = PurePosixPath(name)
        if name.startswith("Backend/spotty-playback/vendor/") or not is_test(path):
            continue
        if not (root / name).is_file():
            continue
        if path.parent == PurePosixPath("Scripts") and path.suffix == ".py":
            if path.name == "test_swift_test_watchdog.py":
                group = "watchdog"
            elif path.name.startswith("test_playback_"):
                group = "playback"
            else:
                group = "policy"
        elif path.parent == REVIEW_ROOT and path.suffix in NODE_SUFFIXES | {".py"}:
            group = "review"
        else:
            raise ValueError(f"No CI script-test owner for {name}; move it into an owned suite or extend the runner.")
        groups[group].append(root / name)
    for group, paths in groups.items():
        if not paths:
            raise ValueError(f"Script-test suite {group} is empty")
    for suffixes in ({".py"}, NODE_SUFFIXES):
        if not any(path.suffix in suffixes for path in groups["review"]):
            raise ValueError("Review tests must include both Python and Node suites")
    return groups


def run(group: str, root: Path = ROOT) -> int:
    paths = inventory(root)[group]
    for path in paths:
        print(f"{group}: {path.relative_to(root)}", flush=True)
    python_paths = [path for path in paths if path.suffix == ".py"]
    suite = unittest.TestSuite()
    for index, path in enumerate(python_paths):
        sys.path.insert(0, str(path.parent))
        spec = importlib.util.spec_from_file_location(f"script_test_{index}_{path.stem}", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        tests = unittest.defaultTestLoader.loadTestsFromModule(module)
        if tests.countTestCases() == 0:
            raise ValueError(f"No Python tests discovered in {path.relative_to(root)}")
        suite.addTests(tests)
    if python_paths and not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        return 1
    node_paths = [str(path) for path in paths if path.suffix in NODE_SUFFIXES]
    if node_paths:
        return subprocess.run(["node", "--test", *node_paths], cwd=root / REVIEW_ROOT).returncode
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=GROUPS)
    arguments = parser.parse_args()
    try:
        raise SystemExit(run(arguments.group))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Script tests: {error}\n")
