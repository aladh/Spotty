"""Exercise Rune acceptance evidence with synthetic script outputs."""

from pathlib import Path
import contextlib
import io
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify


class AcceptanceEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="spotty verify ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root = self.directory / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", self.root], check=True)
        self.scripts = self.root / "Scripts"
        self.scripts.mkdir()
        self.capture = self.directory / "rendered reference"
        self.capture.mkdir()
        self.output = self.directory / "evidence"
        self.output.mkdir()
        self.manifest = self.root / "acceptance.json"
        self.manifest.write_text(json.dumps({
            "schemaVersion": 1,
            "scenarios": [
                {"id": name, "version": 1, "corpus": "representative"}
                for name in verify.SCENARIOS
            ],
        }))
        self.script("rune.integrated", "print('integration passed')")
        self.script("playback.transport", "print('transport passed')")
        self.script("rune.reference", f"print({str(self.capture)!r})")
        self.commit()

    def commit(self):
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        subprocess.run(["git", "-c", "user.name=Spotty fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-qm", "Save fixture"], cwd=self.root, check=True)

    def script(self, key, python):
        script = self.scripts / verify.SCENARIOS[key]
        script.write_text("#!/usr/bin/env python3\n" + python + "\n")
        script.chmod(0o700)

    def acceptance(self):
        with patch.multiple(verify, ROOT=self.root, SCRIPTS=self.scripts, MANIFEST=self.manifest), \
                patch.object(verify, "source_identity", return_value={"revision": "fixture",
                                                                      "diffSHA256": "synthetic"}), \
                contextlib.redirect_stdout(io.StringIO()):
            return verify.acceptance(self.output)

    def test_success_records_the_reference_and_each_scenario(self):
        for name in verify.REFERENCE_FILES:
            (self.capture / name).write_bytes(name.encode())
        self.assertEqual(self.acceptance(), 0)
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(summary["outcome"], "passed")
        self.assertTrue(summary["sourceUnchanged"])
        self.assertFalse(summary["source"]["dirty"])
        self.assertEqual({row["id"] for row in summary["scenarios"]}, verify.SCENARIOS.keys())
        for name in verify.REFERENCE_FILES:
            self.assertEqual((self.output / name).read_bytes(), name.encode())

    def test_missing_reference_replaces_previous_evidence_with_failure(self):
        for name in ("summary.json", *verify.REFERENCE_FILES):
            (self.output / name).write_bytes(b"prior success")
        (self.capture / "reference.json").write_text("{}")
        self.assertEqual(self.acceptance(), 1)
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(summary["outcome"], "failed")
        self.assertEqual(summary["scenarios"][-1]["outcome"], "failed")
        self.assertIn("reference.png", (self.output / "rune.reference.log").read_text())
        self.assertTrue(all(not (self.output / name).exists() for name in verify.REFERENCE_FILES))

    def test_missing_executable_reports_failure_and_runs_other_scenarios(self):
        (self.scripts / verify.SCENARIOS["rune.integrated"]).unlink()
        self.commit()
        for name in verify.REFERENCE_FILES:
            (self.capture / name).write_text("synthetic")
        self.assertEqual(self.acceptance(), 1)
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual([row["outcome"] for row in summary["scenarios"]],
                         ["failed", "passed", "passed"])

    def test_malformed_manifest_reports_failure(self):
        self.manifest.write_text("not-json")
        self.commit()
        self.assertEqual(self.acceptance(), 1)
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(summary["outcome"], "failed")
        self.assertIn("Invalid acceptance manifest", summary["error"])

    def test_dirty_checkout_cannot_produce_passing_evidence(self):
        (self.root / "dirty").touch()
        for name in verify.REFERENCE_FILES:
            (self.capture / name).write_text("synthetic")
        self.assertEqual(self.acceptance(), 1)
        self.assertTrue(json.loads((self.output / "summary.json").read_text())["source"]["dirty"])

    def test_timed_out_scenario_records_failure(self):
        self.script("rune.integrated", "import time; time.sleep(60)")
        self.commit()
        with patch.dict(verify.SCENARIO_TIMEOUTS, {"rune.integrated": 0.2}):
            self.assertEqual(self.acceptance(), 1)
        self.assertIn("Scenario exceeded", (self.output / "rune.integrated.log").read_text())


if __name__ == "__main__":
    unittest.main()
