"""Validate the published consumer pin before any SwiftPM resolution."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "https://github.com/aladh/Spotty/releases/download/"
ASSET = "/SpottyPlaybackCore.xcframework.zip"


class PlaybackPinTests(unittest.TestCase):
    def test_only_canonical_versioned_release_urls_are_accepted(self):
        with tempfile.TemporaryDirectory(prefix="spotty-pin-") as directory:
            root = Path(directory)
            env = {**os.environ, "project_root": str(root), "PIN_HELPER": str(ROOT / "Scripts/playback-xcframework.sh")}
            for url, valid in ((PREFIX + "playback-v0.1.0" + ASSET, True),
                               (PREFIX + "playback-v12.20.300" + ASSET, True),
                               (PREFIX + "playback-v01.0.0" + ASSET, False),
                               (PREFIX + "v1.0.0" + ASSET, False),
                               (PREFIX + "playback-v1.0.0-beta" + ASSET, False),
                               (PREFIX + "playback-v1.0.0" + ASSET + "?redirect=1", False),
                               (PREFIX + "playback-v1.0.0/other.zip", False),
                               ("https://example.invalid/engine.zip", False)):
                with self.subTest(url=url):
                    (root / "Package.swift").write_text(f'private let generatedPlaybackArtifactURL = "{url}"\n')
                    result = subprocess.run(["sh", "-c", '. "$PIN_HELPER"; spotty_playback_pin_value url'],
                                            env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode == 0, valid, result.stderr)
                    if valid:
                        self.assertEqual(result.stdout, url + "\n")
                    else:
                        self.assertIn("canonical Spotty", result.stderr)

    def test_invalid_pin_never_invokes_swiftpm(self):
        with tempfile.TemporaryDirectory(prefix="spotty-pin-resolve-") as directory:
            root = Path(directory)
            (root / "Package.swift").write_text('private let generatedPlaybackArtifactURL = "https://example.invalid/engine.zip"\n')
            swift = root / "swift"
            swift.write_text('#!/bin/sh\ntouch "$project_root/swift-was-called"\nexit 1\n')
            swift.chmod(0o755)
            env = {**os.environ, "project_root": str(root), "PIN_HELPER": str(ROOT / "Scripts/playback-xcframework.sh"),
                   "PATH": str(root) + os.pathsep + os.environ["PATH"], "SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": ""}
            for url, checksum, message in (("https://example.invalid/engine.zip", "a" * 64, "canonical Spotty"),
                                           (PREFIX + "playback-v0.1.0" + ASSET, "bad", "64 hexadecimal")):
                with self.subTest(url=url, checksum=checksum):
                    (root / "Package.swift").write_text(
                        f'private let generatedPlaybackArtifactURL = "{url}"\n'
                        f'private let generatedPlaybackArtifactChecksum = "{checksum}"\n')
                    result = subprocess.run(["sh", "-c", '. "$PIN_HELPER"; spotty_playback_resolve_xcframework'],
                                            env=env, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertFalse((root / "swift-was-called").exists())

    def test_checksum_format_accepts_only_complete_hex_digests(self):
        with tempfile.TemporaryDirectory(prefix="spotty-checksum-") as directory:
            root = Path(directory)
            env = {**os.environ, "project_root": str(root), "PIN_HELPER": str(ROOT / "Scripts/playback-xcframework.sh")}
            for checksum, valid in (("a" * 64, True), ("A" * 64, True), ("a" * 63, False),
                                    ("a" * 65, False), ("g" * 64, False)):
                with self.subTest(checksum=checksum):
                    (root / "Package.swift").write_text(f'private let generatedPlaybackArtifactChecksum = "{checksum}"\n')
                    result = subprocess.run(["sh", "-c", '. "$PIN_HELPER"; spotty_playback_pin_value checksum'],
                                            env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_ci_override_assignments_are_rejected_but_comments_are_allowed(self):
        source = (ROOT / "Scripts/check.sh").read_text()
        start = source.index("if rg -q '^[[:space:]]*")
        guard = source[start:source.index("\nfi", start) + 3]
        cases = (("# SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK : forbidden", True),
                 ("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK : /tmp/framework", False),
                 ("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK: /tmp/framework", False),
                 ("export SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK=/tmp/framework", False))
        for line, valid in cases:
            with self.subTest(line=line):
                result = subprocess.run(["zsh", "-c", guard], capture_output=True,
                                        env={**os.environ, "checks_job": "  " + line, "release_job": ""})
                self.assertEqual(result.returncode == 0, valid)



if __name__ == "__main__":
    unittest.main()
