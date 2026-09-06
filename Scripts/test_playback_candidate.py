"""Exercise CI's change detector against real Git history without building an engine."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent


class CandidateSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spotty-candidate-policy-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Identify playback inputs\n", 1)[1]
        self.script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        inputs = subprocess.check_output(
            [str(ROOT / "Backend/spotty-playback/source-input-digest.sh"), "--print-inputs"], text=True,
        ).splitlines()
        for name in [*inputs, ".github/workflows/ci.yml", "Backend/spotty-playback/validate-xcframework.sh"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        # The digest enumerates this directory even when it has no extra licenses.
        (self.root / "Scripts/playback-license-overrides").mkdir(exist_ok=True)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("remote", "add", "origin", str(self.root))
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")
        return self.git("rev-parse", "HEAD")

    def select(self, base=None):
        output = self.root / "job-output"
        result = subprocess.run(
            ["bash", "-c", self.script], cwd=self.root, text=True, capture_output=True,
            env={**os.environ, "INPUT_BASE_SHA": self.base if base is None else base,
                 "GITHUB_ENV": str(self.root / "job-env"), "GITHUB_OUTPUT": str(output)},
        )
        return result, output.read_text() if output.exists() else ""

    def test_app_change_ignores_unpublished_engine_history(self):
        # This engine commit is already in the PR base; no published tag is needed.
        engine = self.root / "Backend/spotty-playback/src/lib.rs"
        engine.write_text(engine.read_text() + "\n// earlier unpublished engine change\n")
        self.base = self.commit()
        (self.root / "Package.swift").write_text("// app pin update\n")
        self.commit()
        result, output = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("candidate_needed=false", output)

    def test_engine_addition_deletion_and_infrastructure_trigger_candidate(self):
        for path, delete in (("Backend/spotty-playback/src/extra.rs", False),
                             ("Backend/spotty-playback/src/tests.rs", True),
                             (".github/workflows/ci.yml", False),
                             ("Backend/spotty-playback/validate-xcframework.sh", False)):
            with self.subTest(path=path):
                target = self.root / path
                if delete:
                    target.unlink()
                else:
                    target.write_text("// changed input\n")
                self.commit()
                result, output = self.select()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("candidate_needed=true", output)
                self.base = self.git("rev-parse", "HEAD")

    def test_initial_push_builds_conservatively(self):
        for base in ("", "0" * 40):
            with self.subTest(base=base):
                result, output = self.select(base)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("candidate_needed=true", output)

    def test_invalid_or_unavailable_base_fails_closed(self):
        for base in ("invalid", "f" * 40):
            with self.subTest(base=base):
                result, output = self.select(base)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("candidate_needed=false", output)


if __name__ == "__main__":
    unittest.main()
