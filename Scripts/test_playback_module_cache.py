"""Exercise playback-only Xcode module invalidation without compiling or resolving artifacts."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from playback_module_cache import invalidate_stale_modules


HEADERS = (
    "spotty_playback.h", "spotty_playback_generated.h", "spotty_playback_annotations.h", "module.modulemap",
)


class PlaybackModuleCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="spotty-module-cache-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.build = self.root / "checkout/.build"
        self.headers = self.root / "selected artifact.xcframework/macos-arm64/Headers"
        self.headers.mkdir(parents=True)
        for name in HEADERS:
            (self.headers / name).write_bytes(b"selected header")
        self.cache = self.build / "out/Intermediates.noindex/SwiftExplicitPrecompiledModules"
        self.cache.mkdir(parents=True)
        self.module = self.cache / "SpottyPlaybackCore-first.pcm"
        self.module.write_bytes(b"compiled module")

    def stage(self, configuration="debug"):
        staged = self.build / f"out/Products/{configuration.capitalize()}/include"
        staged.mkdir(parents=True, exist_ok=True)
        for name in HEADERS:
            (staged / name).write_bytes((self.headers / name).read_bytes())
        return staged

    def invalidate(self, configuration="debug"):
        return invalidate_stale_modules(self.build, self.headers, configuration)

    def test_changed_bytes_in_each_header_invalidate_only_playback_pcm(self):
        unrelated = [self.cache / name for name in (
            "SwiftShims-first.pcm", "SpottyPlaybackCoreOther-first.pcm", "SpottyPlaybackCore-first.dia",
        )]
        unrelated += [self.build / "out/Products/Debug/Spotty", self.build / "module-cache/other.pcm"]
        for path in unrelated:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"preserved")
        for configuration in ("debug", "release"):
            for name in HEADERS:
                with self.subTest(configuration=configuration, header=name):
                    staged = self.stage(configuration)
                    # Identical length and normalized timestamp must not hide changed contents.
                    (staged / name).write_bytes(b"previous header")
                    for path in (staged / name, self.headers / name):
                        os.utime(path, (946684800, 946684800))
                    self.module.write_bytes(b"old module")
                    second = self.cache / "SpottyPlaybackCore-second.pcm"
                    second.write_bytes(b"another configuration")
                    self.assertEqual(self.invalidate(configuration), 2)
                    self.assertFalse(self.module.exists())
                    self.assertFalse(second.exists())
                    self.assertEqual((staged / name).read_bytes(), b"previous header")
                    self.assertEqual((self.headers / name).read_bytes(), b"selected header")
                    self.assertTrue(all(path.read_bytes() == b"preserved" for path in unrelated))

    def test_unchanged_selected_configuration_preserves_cached_module(self):
        self.stage()
        other_configuration = self.stage("release")
        (other_configuration / HEADERS[0]).write_bytes(b"older release header")
        before = self.module.stat()
        self.assertEqual(self.invalidate(), 0)
        self.assertEqual(self.module.read_bytes(), b"compiled module")
        self.assertEqual(self.module.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.module.stat().st_ino, before.st_ino)

    def test_missing_or_incomplete_staged_headers_do_not_remove_modules(self):
        self.assertEqual(self.invalidate(), 0)
        for name in HEADERS:
            with self.subTest(missing=name):
                staged = self.stage()
                (staged / HEADERS[0]).write_bytes(b"older header")
                (staged / name).unlink()
                self.assertEqual(self.invalidate(), 0)
                self.assertTrue(self.module.exists())

    def test_missing_selected_header_fails_before_removing_anything(self):
        staged = self.stage()
        (staged / HEADERS[0]).write_bytes(b"older header")
        (self.headers / HEADERS[-1]).unlink()
        with self.assertRaises(FileNotFoundError):
            self.invalidate()
        self.assertTrue(self.module.exists())

    def test_symlinks_and_directories_are_not_removed_as_pcm_files(self):
        staged = self.stage()
        (staged / HEADERS[0]).write_bytes(b"older header")
        external = self.root / "external.pcm"
        external.write_bytes(b"unrelated module")
        alias = self.cache / "SpottyPlaybackCore-symlink.pcm"
        alias.symlink_to(external)
        directory = self.cache / "SpottyPlaybackCore-directory.pcm"
        directory.mkdir()
        self.assertEqual(self.invalidate(), 1)
        self.assertTrue(alias.is_symlink())
        self.assertEqual(external.read_bytes(), b"unrelated module")
        self.assertTrue(directory.is_dir())

    def test_symlinked_cache_ancestor_is_not_followed(self):
        staged = self.stage()
        (staged / HEADERS[0]).write_bytes(b"older header")
        original = self.cache.parent
        external = self.root / "external-intermediates"
        original.rename(external)
        original.symlink_to(external, target_is_directory=True)
        self.assertEqual(self.invalidate(), 0)
        self.assertEqual(self.module.read_bytes(), b"compiled module")

    def test_symlinked_staged_header_does_not_trigger_invalidation(self):
        staged = self.stage()
        path = staged / HEADERS[0]
        path.unlink()
        external = self.root / "external.h"
        external.write_bytes(b"older header")
        path.symlink_to(external)
        self.assertEqual(self.invalidate(), 0)
        self.assertTrue(self.module.exists())

    def test_cli_preserves_paths_with_spaces_and_reports_invalidation(self):
        staged = self.stage()
        (staged / HEADERS[0]).write_bytes(b"older header")
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("playback_module_cache.py")),
             str(self.build), str(self.headers), "--configuration", "debug"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Removed 1 stale SpottyPlaybackCore compiled modules", result.stderr)
        self.assertFalse(self.module.exists())


if __name__ == "__main__":
    unittest.main()
