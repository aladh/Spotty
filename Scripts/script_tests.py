"""Discover and run every owned Python/Node script test in its CI lane."""

import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import importlib.util
import math
import os
from pathlib import Path, PurePosixPath
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
GROUPS = ("policy", "playback", "harness", "watchdog", "review")
REVIEW_ROOT = PurePosixPath("Scripts/agent-review-tests")
NODE_SUFFIXES = {".js", ".mjs", ".cjs"}
OUTPUT_LIMIT = 1024 * 1024  # Retain each stream's tail, including late assertion failures.


class _OutputTail:
    def __init__(self):
        self.chunks = deque()
        self.size = 0
        self.omitted = 0

    def append(self, chunk: bytes):
        self.chunks.append(chunk)
        self.size += len(chunk)
        while self.size > OUTPUT_LIMIT:
            first = self.chunks.popleft()
            excess = min(len(first), self.size - OUTPUT_LIMIT)
            self.size -= excess
            self.omitted += excess
            if excess < len(first):
                self.chunks.appendleft(first[excess:])

    def save(self, path: Path):
        with path.open("wb") as output:
            if self.omitted:
                output.write(f"[script tests: {self.omitted} earlier output bytes omitted]\n".encode())
            for chunk in self.chunks:
                output.write(chunk)


@dataclass(frozen=True)
class _CommandResult:
    status: int
    stdout: Path
    stderr: Path
    detail: str = ""


@dataclass
class _Cancellation:
    # Only the main thread writes these values. Signal handlers must not acquire a lock:
    # a second signal could interrupt Event.set() while its non-reentrant lock is held.
    interrupted: int = 0
    requested: bool = False

    def is_set(self):
        return self.requested or self.interrupted != 0


def _run_process(command, cwd, *, timeout_seconds, stop, report) -> _CommandResult:
    """Own one session, including pipe completion and bounded cleanup after its leader exits."""
    stdout, stderr = _OutputTail(), _OutputTail()
    selector = selectors.DefaultSelector()
    process = None
    started = time.monotonic()
    status, detail = 130, "cancelled before launch"

    def drain(timeout):
        if not selector.get_map():
            if process.poll() is not None:
                time.sleep(timeout)
            else:
                try:
                    process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    pass
            return
        for key, _ in selector.select(timeout):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if chunk:
                key.data.append(chunk)
            else:
                selector.unregister(key.fileobj)

    def signal_group(number):
        try:
            os.killpg(process.pid, number)
        except ProcessLookupError:
            pass

    def group_exists():
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False

    try:
        if not stop.is_set():
            process = subprocess.Popen(
                command, cwd=cwd, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
            selector.register(process.stdout, selectors.EVENT_READ, stdout)
            selector.register(process.stderr, selectors.EVENT_READ, stderr)
            deadline = started + timeout_seconds
            while process.poll() is None or selector.get_map():
                if stop.is_set():
                    status, detail = 130, "cancelled"
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    status, detail = 124, f"timed out after {timeout_seconds:g}s"
                    break
                drain(min(0.1, remaining))
            else:
                status, detail = process.returncode, ""
    except OSError as error:
        status, detail = 127, f"execution failed: {error}"
    finally:
        try:
            if process is not None:
                # Nested watchdogs receive TERM too. Let them finish their own bounded cleanup
                # before KILL; deliberately escaped sessions remain their owner's responsibility.
                try:
                    signal_group(signal.SIGTERM)
                    deadline = time.monotonic() + 4
                    while time.monotonic() < deadline and (
                        process.poll() is None or selector.get_map() or group_exists()
                    ):
                        drain(min(0.1, max(0, deadline - time.monotonic())))
                finally:
                    # A descendant may remain after the leader exits or closes both pipes.
                    signal_group(signal.SIGKILL)
                    process.wait(timeout=2)
        finally:
            selector.close()
            if process is not None:
                process.stdout.close()
                process.stderr.close()
    out_path, err_path = report.with_suffix(".stdout"), report.with_suffix(".stderr")
    stdout.save(out_path)
    stderr.save(err_path)
    return _CommandResult(status, out_path, err_path, detail)


def _print_output(result):
    # Completed futures retain paths, not every worker's output. Stream each diagnostic group
    # from its capped spool, replacing invalid bytes without losing the command's exit status.
    for path, destination in ((result.stdout, sys.stdout), (result.stderr, sys.stderr)):
        with path.open(encoding="utf-8", errors="replace") as source:
            while chunk := source.read(65536):
                destination.write(chunk)
        destination.flush()


def _discard_failed_output():
    # A buffered broken pipe must not replace an already recorded interrupt status with 120
    # during interpreter shutdown. Redirect only sinks that can no longer be flushed.
    with open(os.devnull, "wb") as sink:
        for destination in (sys.stdout, sys.stderr):
            try:
                destination.flush()
            except OSError:
                os.dup2(sink.fileno(), destination.fileno())


def is_test(path: PurePosixPath) -> bool:
    if path.suffix == ".py":
        return path.name == "test.py" or path.name.startswith("test_") or path.name.endswith("_test.py")
    if path.suffix in NODE_SUFFIXES | {".ts", ".mts", ".cts"}:
        return (".test." in path.name or ".spec." in path.name
                or path.name.startswith(("test.", "test_", "test-")))
    return False


def inventory(root: Path) -> dict[str, list[Path]]:
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root, timeout=30
    ).decode("utf-8", errors="surrogateescape").split("\0")
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
            elif path.name.startswith("test_harness_"):
                group = "harness"
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


def run_python(path: Path, root: Path, result_file: Path | None = None) -> int:
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(f"script_test_{path.stem}", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    if suite.countTestCases() == 0:
        raise ValueError(f"No Python tests discovered in {path.relative_to(root)}")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result_file is not None:
        result_file.write_text(str(result.testsRun))
    return 0 if result.wasSuccessful() else 1


def run(group: str, root: Path = ROOT, jobs: int = 4, timeout_seconds: float = 120) -> int:
    started = time.monotonic()
    paths = inventory(root)[group]
    for path in paths:
        print(f"{group}: {path.relative_to(root)}", flush=True)
    python_paths = [path for path in paths if path.suffix == ".py"]
    # Each file owns its imports, environment patches and module globals. Bound subprocesses
    # rather than running unittest cases concurrently inside a shared interpreter. Keep each
    # file's output together and report every worker failure before leaving the lane.
    failed = False
    tests_run = 0
    stop = _Cancellation()

    def request_stop(number, _frame):
        stop.interrupted = stop.interrupted or 128 + number

    handlers = {number: signal.signal(number, request_stop) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        with tempfile.TemporaryDirectory(prefix="spotty-script-tests-") as temporary:
            reports = [Path(temporary) / str(index) for index in range(len(python_paths))]
            with ThreadPoolExecutor(max_workers=jobs) as workers:
                try:
                    results = {workers.submit(
                        _run_process,
                        [sys.executable, "-B", str(root / "Scripts/script_tests.py"), group,
                         "--test-file", str(path), "--result-file", str(report)],
                        root, timeout_seconds=timeout_seconds, stop=stop, report=report,
                    ): (path, report) for path, report in zip(python_paths, reports)}
                    for result in as_completed(results):
                        path, report = results.pop(result)
                        completed = result.result()
                        _print_output(completed)
                        try:
                            count = int(report.read_text())
                        except (OSError, ValueError):
                            count = 0
                        tests_run += max(0, count)
                        if completed.status:
                            failed = True
                            reason = completed.detail or f"exited {completed.status}"
                            print(f"Script tests: {path.relative_to(root)} {reason}", file=sys.stderr)
                        elif count <= 0:
                            # Process success alone cannot turn an early exit into a passing lane.
                            failed = True
                            print(f"Script tests: {path.relative_to(root)} did not complete its tests", file=sys.stderr)
                except BaseException:
                    # Cancel active and queued work before executor shutdown joins worker threads.
                    stop.requested = True
                    raise
            print(f"{group}: {tests_run} Python tests in {time.monotonic() - started:.2f}s ({jobs} workers)", flush=True)
            if stop.interrupted:
                return stop.interrupted
            if failed:
                return 1
            node_paths = [str(path) for path in paths if path.suffix in NODE_SUFFIXES]
            if node_paths:
                result = _run_process(
                    ["node", "--test", *node_paths], root / REVIEW_ROOT,
                    timeout_seconds=timeout_seconds, stop=stop, report=Path(temporary) / "node",
                )
                _print_output(result)
                if result.detail:
                    print(f"Script tests: {group} Node invocation {result.detail}", file=sys.stderr)
                return stop.interrupted or result.status
            return 0
    except OSError:
        if stop.interrupted:
            _discard_failed_output()
            return stop.interrupted
        raise
    finally:
        stop.requested = True
        for number, handler in handlers.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=GROUPS)
    parser.add_argument("--jobs", type=int, choices=range(1, 17), default=min(4, os.cpu_count() or 1),
                        metavar="1..16", help="Maximum concurrent Python test files; use 1 for serial diagnosis")
    parser.add_argument("--timeout-seconds", type=float, default=120,
                        help="Deadline for each Python file or the Node invocation (default: 120)")
    parser.add_argument("--test-file", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--result-file", type=Path, help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if not math.isfinite(arguments.timeout_seconds) or arguments.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be finite and positive")
    try:
        if arguments.test_file is not None:
            path = arguments.test_file.resolve()
            if path.suffix != ".py" or path not in inventory(ROOT)[arguments.group]:
                raise ValueError("Python worker file must belong to its selected script-test lane")
            raise SystemExit(run_python(path, ROOT, arguments.result_file))
        raise SystemExit(run(arguments.group, jobs=arguments.jobs, timeout_seconds=arguments.timeout_seconds))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Script tests: {error}\n")
