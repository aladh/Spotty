"""Exercise Rust PR selection and the aggregate gate without any compiler toolchain."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch

from ci_rust_policy import rust_needed

ROOT = Path(__file__).resolve().parent.parent


def workflow_script(step_name):
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    marker = f"      - name: {step_name}\n"
    if workflow.count(marker) != 1:
        raise AssertionError(f"Expected one CI step named {step_name!r}; update the fixture extractor after workflow restructuring")
    step = workflow.split(marker, 1)[1].split("\n      - name:", 1)[0]
    run_marker = "        run: |\n"
    if step.count(run_marker) != 1:
        raise AssertionError(f"Expected an indented run block in CI step {step_name!r}; update the fixture extractor after workflow restructuring")
    return textwrap.dedent(step.split(run_marker, 1)[1])


class RustSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spotty-rust-scope-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("remote", "add", "origin", str(self.root))
        self.write("Backend/spotty-playback/src/lib.rs", "// existing unpublished engine\n")
        self.write("Sources/Spotty/View.swift", "// app\n")
        self.write("Scripts/ci_rust_policy.py", (ROOT / "Scripts/ci_rust_policy.py").read_text())
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def write(self, name, body="changed\n"):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")
        return self.git("rev-parse", "HEAD")

    def test_app_pin_tests_assets_and_docs_skip_rust(self):
        for name in ("Sources/Spotty/View.swift", "Sources/SpottyApp/main.swift",
                     "Sources/SpottyDomain/Model.swift", "Tests/SpottyBoundaryTests/Example.swift",
                     "Tests/SpottyDomainTests/Example.swift", "Package.swift", "Package.resolved",
                     "Assets/icon.png", "Packaging/Info.plist", "docs/development/guide.md", "README.md",
                     ".swift-format", "AGENTS.md", "CONTRIBUTING.md", "PRIVACY.md", "SECURITY.md"):
            self.write(name)
        self.commit()
        self.assertFalse(rust_needed("pull_request", self.base, self.root))

    def test_engine_headers_ci_scripts_licenses_and_unknown_paths_run_rust(self):
        for name in ("Backend/spotty-playback/src/lib.rs", "Backend/spotty-playback/tests/new.rs",
                     "Backend/spotty-playback/Cargo.lock", "Sources/SpottyPlaybackCore/include/new.h",
                     "rust-toolchain.toml", ".github/workflows/ci.yml", "Scripts/check.sh",
                     "Scripts/test_playback_header.py", "Tests/ABI/example.txt", "LICENSE",
                     "NOTICE", "THIRD_PARTY_NOTICES.md", "new-build-input", ".cargo/config.toml"):
            with self.subTest(name=name):
                self.write(name)
                self.commit()
                self.assertTrue(rust_needed("pull_request", self.base, self.root))
                self.base = self.git("rev-parse", "HEAD")

    def test_deletion_and_rename_out_of_engine_scope_run_rust(self):
        source = self.root / "Backend/spotty-playback/src/lib.rs"
        source.rename(self.root / "docs-renamed.rs")
        self.commit()
        self.assertTrue(rust_needed("pull_request", self.base, self.root))
        # Repeat with an app destination: rename detection must not hide the old engine path.
        self.git("reset", "--hard", self.base)
        source.rename(self.root / "Sources/Spotty/renamed.swift")
        self.commit()
        self.assertTrue(rust_needed("pull_request", self.base, self.root))
        self.git("reset", "--hard", self.base)
        source.unlink()
        self.commit()
        self.assertTrue(rust_needed("pull_request", self.base, self.root))

    def test_filename_newline_does_not_hide_unknown_path(self):
        self.write("unexpected\nSources/Spotty/View.swift")
        self.commit()
        self.assertTrue(rust_needed("pull_request", self.base, self.root))

    def select_via_workflow(self):
        script = workflow_script("Select Rust verification")
        output = self.root / "selection-output"
        output.unlink(missing_ok=True)
        result = subprocess.run(["bash", "-c", script], cwd=self.root, capture_output=True, text=True,
                                env={**os.environ, "EVENT_NAME": "pull_request", "INPUT_BASE_SHA": self.base,
                                     "GITHUB_OUTPUT": str(output), "RUNNER_TEMP": str(self.root / "runner-temp")})
        return result, output.read_text() if output.exists() else ""

    def test_workflow_uses_base_policy_instead_of_changed_head_code(self):
        (self.root / "runner-temp").mkdir()
        self.write("Backend/spotty-playback/src/lib.rs", "// changed engine\n")
        self.write("Scripts/ci_rust_policy.py", 'print("rust_needed=false")\n')
        self.commit()
        result, output = self.select_via_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "rust_needed=true\n")

    def test_workflow_without_a_base_policy_requires_rust(self):
        (self.root / "Scripts/ci_rust_policy.py").unlink()
        self.base = self.commit()
        self.write("Sources/Spotty/View.swift", "// changed app\n")
        self.commit()
        result, output = self.select_via_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "rust_needed=true\n")

    def test_workflow_skips_app_only_changes_with_existing_base_policy(self):
        (self.root / "runner-temp").mkdir()
        self.write("Sources/Spotty/View.swift", "// changed app\n")
        self.commit()
        result, output = self.select_via_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "rust_needed=false\n")

    def test_main_and_other_events_always_run_without_a_base(self):
        for event in ("push", "workflow_dispatch", "unknown"):
            with self.subTest(event=event):
                self.assertTrue(rust_needed(event, "", self.root))

    def test_invalid_or_missing_pr_history_fails_closed(self):
        for base in ("", "0" * 40, "not-a-sha", "f" * 40):
            with self.subTest(base=base), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                rust_needed("pull_request", base, self.root)
        with patch("ci_rust_policy.subprocess.check_output", side_effect=subprocess.CalledProcessError(128, "git diff")):
            with self.assertRaises(subprocess.CalledProcessError):
                rust_needed("pull_request", self.base, self.root)


class AggregateGateTests(unittest.TestCase):
    def test_only_an_explicit_app_only_decision_allows_skipped_rust(self):
        script = workflow_script("Require every quality lane")
        env = {**os.environ, "POLICY_RESULT": "success", "CHECKS_RESULT": "success", "RELEASE_RESULT": "success"}
        for needed in ("true", "false", "", "invalid"):
            for result in ("success", "skipped", "failure", "cancelled", ""):
                with self.subTest(needed=needed, result=result):
                    completed = subprocess.run(["bash", "-e", "-c", script], capture_output=True,
                                               env={**env, "RUST_NEEDED": needed, "RUST_RESULT": result})
                    expected = (needed, result) in (("true", "success"), ("false", "skipped"))
                    self.assertEqual(completed.returncode == 0, expected)
        for lane in ("POLICY_RESULT", "CHECKS_RESULT", "RELEASE_RESULT"):
            with self.subTest(lane=lane):
                completed = subprocess.run(["bash", "-e", "-c", script], capture_output=True,
                                           env={**env, "RUST_NEEDED": "false", "RUST_RESULT": "skipped", lane: "failure"})
                self.assertNotEqual(completed.returncode, 0)


if __name__ == "__main__":
    unittest.main()
