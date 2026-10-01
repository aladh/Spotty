"""Exercise the UI smoke wrapper's single attempt and retained timeout evidence."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


class UISmokeWrapperChecks(unittest.TestCase):
    def invoke(self, root, result):
        wrapper = Path(__file__).with_name("smoke-synthetic-ui.sh").read_text()
        program = wrapper.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        with patch.object(sys, "argv", ["wrapper", "/synthetic/driver", str(root)]):
            with patch.object(subprocess, "run", side_effect=result) as run:
                with self.assertRaises(SystemExit) as finished, redirect_stdout(io.StringIO()):
                    exec(compile(program, "smoke-synthetic-ui.sh:python", "exec"), {"__name__": "__main__"})
        return finished.exception.code, run

    def test_completed_driver_is_invoked_once(self):
        for code in (0, 1):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result, run = self.invoke(root, lambda *args, **kwargs: subprocess.CompletedProcess(args[0], code))
                self.assertEqual(result, code)
                run.assert_called_once_with(["/synthetic/driver", str(root.resolve())], timeout=135)

    def test_prior_evidence_rejects_another_attempt_without_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "ui-smoke.json"
            original = b'{"passed": false, "checkpoints": ["home.ready"]}\n'
            evidence.write_bytes(original)
            code, run = self.invoke(root, AssertionError("a second attempt must not launch"))
            self.assertIsInstance(code, str)
            run.assert_not_called()
            self.assertEqual(evidence.read_bytes(), original)

    def test_timeout_retains_completed_checkpoints_and_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def timeout(*args, **kwargs):
                (root / "ui-smoke.json").write_text(json.dumps({
                    "passed": False, "category": "running", "runID": "owned-run", "pid": 42,
                    "checkpoints": ["home.content-ready", "search.all-results"],
                    "baseline": {"commandCount": 0, "mutationAttempts": 0},
                    "observed": {"commandCount": 0, "mutationAttempts": 0},
                }))
                raise subprocess.TimeoutExpired(args[0], kwargs["timeout"])

            code, run = self.invoke(root, timeout)
            self.assertEqual(code, 1)
            run.assert_called_once()
            evidence = json.loads((root / "ui-smoke.json").read_text())
            self.assertFalse(evidence["passed"])
            self.assertEqual(evidence["category"], "timeout")
            self.assertEqual(evidence["runID"], "owned-run")
            self.assertEqual(evidence["checkpoints"], ["home.content-ready", "search.all-results"])
            self.assertEqual(evidence["observed"], evidence["baseline"])

    def test_timeout_preserves_malformed_partial_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = b'{"passed":false,"checkpoints":['

            def timeout(*args, **kwargs):
                (root / "ui-smoke.json").write_bytes(original)
                raise subprocess.TimeoutExpired(args[0], kwargs["timeout"])

            code, run = self.invoke(root, timeout)
            self.assertEqual(code, 1)
            run.assert_called_once()
            self.assertEqual((root / "ui-smoke.partial.json").read_bytes(), original)
            self.assertFalse(json.loads((root / "ui-smoke.json").read_text())["passed"])


if __name__ == "__main__":
    unittest.main()
