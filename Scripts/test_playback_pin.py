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
            result = subprocess.run(["sh", "-c", '. "$PIN_HELPER"; spotty_playback_resolve_xcframework'],
                                    env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical Spotty", result.stderr)
            self.assertFalse((root / "swift-was-called").exists())


if __name__ == "__main__":
    unittest.main()
