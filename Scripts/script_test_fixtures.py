"""Disposable runner repositories and fallback ownership for synthetic process tests."""

import contextlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
PASSING_PYTHON = "import unittest\nclass Example(unittest.TestCase):\n    def test_example(self):\n        self.assertTrue(True)\n"
PASSING_NODE = "const {test} = require('node:test'); test('example', () => {});\n"


def process_has_stopped(pid):
    """Read-only observation; a disappearing /proc entry defers to the next kill(0) probe."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    # Linux may retain a killed orphan as a zombie until init reaps it. On other
    # hosts /proc is absent; that alone never proves a still-addressable PID stopped.
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (FileNotFoundError, ProcessLookupError):
        return False
    return state == "Z"


@contextlib.contextmanager
def repository():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        for name in ("Scripts/test_existing_policy.py", "Scripts/test_playback_existing.py",
                     "Scripts/test_harness_existing.py",
                     "Scripts/test_swift_test_watchdog.py", "Scripts/agent-review-tests/publication_test.py"):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(PASSING_PYTHON)
        (root / "Scripts/agent-review-tests/review.test.cjs").write_text(PASSING_NODE)
        shutil.copy(ROOT / "Scripts/script_tests.py", root / "Scripts/script_tests.py")
        yield root


def execute(root, group, *arguments):
    return subprocess.run([sys.executable, "-B", str(root / "Scripts/script_tests.py"), group, *arguments],
                          cwd=root, capture_output=True, text=True, timeout=30)


class LifetimeFixtureMixin:
    """Register fallback cleanup; leave behavioral cleanup assertions to each test."""

    @contextlib.contextmanager
    def fixture(self):
        with repository() as root, contextlib.ExitStack() as cleanup:
            self.cleanup = cleanup
            yield root

    def start(self, root, *arguments):
        process = subprocess.Popen(
            [sys.executable, "-B", str(root / "Scripts/script_tests.py"), "policy", *arguments],
            cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
        )

        def close():
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

        self.cleanup.callback(close)
        return process

    def wait_for_file(self, path, process):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.is_file() and (path.suffix != ".pid" or path.read_text().isdigit()):
                return
            if process.poll() is not None:
                break
            time.sleep(0.01)
        self.fail(f"fixture did not create {path.name}")

    def own_pid(self, path):
        def close():
            if path.is_file():
                try:
                    os.kill(int(path.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.cleanup.callback(close)

    def assert_stopped(self, path):
        self.assertTrue(path.is_file(), "fixture never started")
        pid = int(path.read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if process_has_stopped(pid):
                return
            time.sleep(0.01)
        self.fail(f"owned test process {pid} survived cleanup")
