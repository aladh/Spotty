import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest

from documentation_policy import check, violations, word_limit


class DocumentationPolicyTests(unittest.TestCase):
    def test_living_guides_and_new_pages_have_limits(self):
        self.assertEqual(word_limit("README.md"), 500)
        self.assertEqual(word_limit("Assets/README.md"), 1000)
        self.assertEqual(word_limit("Sources/NewTarget/README.md"), 1000)
        self.assertEqual(word_limit("AGENTS.md"), 400)
        self.assertEqual(word_limit("Sources/NewTarget/AGENTS.md"), 400)
        self.assertEqual(word_limit("PRIVACY.md"), 1000)
        self.assertEqual(word_limit("FAQ.md"), 1000)
        self.assertEqual(word_limit("docs/new-topic.md"), 1000)
        self.assertEqual(word_limit("docs/vendor/new-topic.md"), 1000)
        self.assertEqual(word_limit("docs/vendor/AGENTS.md"), 400)
        self.assertEqual(word_limit("docs/architecture/adrs/README.md"), 1000)
        self.assertEqual(word_limit("docs/releases/README.md"), 1000)

    def test_records_and_external_licenses_are_outside_the_budget(self):
        for name in [
            "THIRD_PARTY_NOTICES.md",
            "docs/releases/v0.4.0.md",
            "docs/architecture/adrs/ADR-008-headless-session-runtime.md",
            "docs/architecture/performance-baseline.md",
            "Backend/spotty-playback/vendor/librespot/AGENTS.md",
            "Scripts/playback-license-overrides/objc2-LICENSE.md",
        ]:
            with self.subTest(name=name):
                self.assertIsNone(word_limit(name))
        for name in [
            "docs/releases-notes.md",
            "docs/architecture/adrs/ADR-guide.md",
            "docs/architecture/performance-baseline-guide.md",
        ]:
            with self.subTest(name=name):
                self.assertEqual(word_limit(name), 1000)

    def test_exact_boundary_passes_and_oversize_names_the_document(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("word " * 500)
            self.assertEqual(violations(root, ["README.md"]), [])
            (root / "README.md").write_text("word " * 501)
            self.assertEqual(
                violations(root, ["README.md", "README.md"]),
                ["README.md: 501 words exceeds the 500-word limit"],
            )

    def test_code_and_comments_cannot_hide_growth(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text(
                "```\n" + "word " * 300 + "\n```\n<!-- " + "word " * 300 + " -->"
            )
            self.assertEqual(len(violations(root, ["README.md"])), 1)

    def test_gate_checks_tracked_and_new_docs_but_not_ignored_scratch_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "docs").mkdir()
            (root / "docs/tracked.md").write_text("word " * 1001)
            subprocess.run(["git", "add", "docs/tracked.md"], cwd=root, check=True)
            (root / "docs/new.md").write_text("word " * 1001)
            (root / "docs/scratch.md").write_text("word " * 1001)
            (root / ".gitignore").write_text("docs/tracked.md\ndocs/scratch.md\n")
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                self.assertEqual(check(root), 1)
            self.assertIn("docs/tracked.md", output.getvalue())
            self.assertIn("docs/new.md", output.getvalue())
            self.assertNotIn("docs/scratch.md", output.getvalue())
            (root / "docs/tracked.md").write_text("Short guide.\n")
            (root / "docs/new.md").write_text("Another short guide.\n")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(check(root), 0)


if __name__ == "__main__":
    unittest.main()
