"""A restored build must still observe changed, new, and removed source inputs."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from ci_source_mtimes import restore, snapshot


class SourceTimestampTests(unittest.TestCase):
    def test_only_unchanged_tracked_regular_inputs_are_restored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "Sources").mkdir()
            for name in ("same", "changed", "removed", "link"):
                (root / "Sources" / name).write_text("old")
            (root / "Package.swift").write_text("manifest")
            (root / "README.md").write_text("old")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            old = 1_700_000_000_000_000_000
            new = old + 10_000_000_000
            for path in root.glob("Sources/*"):
                os.utime(path, ns=(old, old))
            saved = snapshot(root)
            (root / "Sources/changed").write_text("new")
            (root / "Sources/removed").unlink()
            (root / "Sources/link").unlink()
            (root / "Sources/link").symlink_to(root / "README.md")
            (root / "Sources/new").write_text("new")
            subprocess.run(["git", "add", "Sources/new"], cwd=root, check=True)
            for name in ("same", "changed", "new"):
                os.utime(root / "Sources" / name, ns=(new, new))
            docs_time = (root / "README.md").stat().st_mtime_ns
            # Even a content-matching manifest entry cannot change an excluded path.
            saved["README.md"] = {"sha256": hashlib.sha256(b"old").hexdigest(), "mtime_ns": old}
            restore(root, saved)
            self.assertEqual((root / "Sources/same").stat().st_mtime_ns, old)
            for name in ("changed", "new"):
                self.assertEqual((root / "Sources" / name).stat().st_mtime_ns, new)
            self.assertFalse((root / "Sources/removed").exists())
            self.assertEqual((root / "README.md").stat().st_mtime_ns, docs_time)

    def test_rust_scope_preserves_edits_and_excludes_swift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            backend = root / "Backend/spotty-playback/src"
            backend.mkdir(parents=True)
            for path in (backend / "lib.rs", backend / "changed.rs", root / "Package.swift"):
                path.write_text("old")
                os.utime(path, ns=(1_700_000_000_000_000_000,) * 2)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            saved = snapshot(root, "rust")
            self.assertNotIn("Package.swift", saved)
            (backend / "changed.rs").write_text("new")
            new = 1_800_000_000_000_000_000
            for path in backend.iterdir():
                os.utime(path, ns=(new, new))
            self.assertEqual(restore(root, saved, "rust"), 1)
            self.assertEqual((backend / "changed.rs").stat().st_mtime_ns, new)

    def test_invalid_or_future_timestamp_is_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            path = root / "Package.swift"
            path.write_text("manifest")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            saved = snapshot(root)
            original = path.stat().st_mtime_ns
            for timestamp in (None, True, -1, original + 1):
                saved["Package.swift"]["mtime_ns"] = timestamp
                self.assertEqual(restore(root, saved), 0)
                self.assertEqual(path.stat().st_mtime_ns, original)
