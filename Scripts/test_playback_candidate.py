"""Exercise CI's change detector against real Git history without building an engine."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class CandidateSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spotty-candidate-policy-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        inputs = subprocess.check_output(
            [str(ROOT / "Scripts/playback-candidate-needed.sh"), "--print-paths"], text=True,
        ).splitlines()
        for name in inputs:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if (ROOT / name).is_dir():
                shutil.copytree(ROOT / name, target, dirs_exist_ok=True)
            else:
                shutil.copy2(ROOT / name, target)
        workflow = self.root / ".github/workflows/ci.yml"
        workflow.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / ".github/workflows/ci.yml", workflow)
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

    def select(self, base=None, unset_base=False):
        output = self.root / "job-output"
        output.unlink(missing_ok=True)
        (self.root / "job-env").unlink(missing_ok=True)
        env = {**os.environ, "INPUT_BASE_SHA": self.base if base is None else base,
               "GITHUB_ENV": str(self.root / "job-env"), "GITHUB_OUTPUT": str(output)}
        if unset_base:
            env.pop("INPUT_BASE_SHA")
        result = subprocess.run(
            [str(self.root / "Scripts/playback-candidate-needed.sh")], cwd=self.root, text=True, capture_output=True,
            env=env,
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
        self.assertEqual(output, "candidate_needed=false\n")

    def test_engine_addition_deletion_and_infrastructure_trigger_candidate(self):
        for path, delete in (("Backend/spotty-playback/src/extra.rs", False),
                             ("Backend/spotty-playback/src/tests.rs", True),
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
                self.assertEqual(output, "candidate_needed=true\n")
                self.base = self.git("rev-parse", "HEAD")

    def test_unrelated_workflow_change_does_not_build_candidate(self):
        workflow = self.root / ".github/workflows/ci.yml"
        workflow.write_text(workflow.read_text().replace("ubuntu-latest", "ubuntu-24.04")
                            .replace("id: debug", "id: debug # consumer change"))
        self.commit()
        result, output = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "candidate_needed=false\n")

    def test_producer_workflow_change_or_unknown_layout_builds_candidate(self):
        workflow = self.root / ".github/workflows/ci.yml"
        original = workflow.read_text()
        for changed in (original.replace("--for-publish", "--for-publish --changed"),
                        original.replace("contents: read", "contents: write"), "jobs: {}\n"):
            with self.subTest(workflow=changed[:60]):
                workflow.write_text(changed)
                self.commit()
                result, output = self.select()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, "candidate_needed=true\n")

    def test_initial_push_builds_conservatively(self):
        for base in ("", "0" * 40):
            with self.subTest(base=base):
                result, output = self.select(base)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, "candidate_needed=true\n")

    def test_unset_base_builds_conservatively(self):
        result, output = self.select(unset_base=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "candidate_needed=true\n")

    def test_invalid_or_unavailable_base_fails_closed(self):
        for base in ("invalid", "f" * 40):
            with self.subTest(base=base):
                result, output = self.select(base)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("candidate_needed=false", output)
                self.assertIn("base", result.stderr)


if __name__ == "__main__":
    unittest.main()
