"""Validate the published consumer pin before any SwiftPM resolution."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "https://github.com/aladh/Spotty/releases/download/"
ASSET = "/SpottyPlaybackCore.xcframework.zip"


class PlaybackPinTests(unittest.TestCase):
    def test_clean_resets_the_graph_before_its_first_swift_command(self):
        # This zsh entry point belongs to the playback lane, which installs its interpreter.
        # Invoke it directly: verify.py's own reset would mask a missing reset in the script.
        with tempfile.TemporaryDirectory(prefix="spotty-clean-graph-") as directory:
            root = Path(directory).resolve()
            (root / "Scripts").mkdir()
            script = root / "Scripts/check-clean.sh"
            shutil.copy2(ROOT / "Scripts/check-clean.sh", script)
            log = root / "commands.jsonl"
            swift = root / "swift"
            swift.write_text(f"""#!{sys.executable}
import json, os, sys
with open(os.environ['VERIFY_TEST_LOG'], 'a') as log:
    log.write(json.dumps({{'command': sys.argv, 'graph': os.environ.get('SPOTTY_PACKAGE_GRAPH')}}) + '\\n')
raise SystemExit(17)
""")
            swift.chmod(0o755)
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "VERIFY_TEST_LOG": str(log), "SPOTTY_PACKAGE_GRAPH": "engine-free"}
            result = subprocess.run([str(script)], env=env, capture_output=True, text=True, timeout=10)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(result.returncode, 17, result.stderr)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0]["graph"], "full")
            self.assertEqual(calls[0]["command"][1:], ["package", "--package-path", str(root), "clean"])

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

    def test_artifact_resolution_uses_full_graph_even_after_domain_only_work(self):
        with tempfile.TemporaryDirectory(prefix="spotty-pin-graph-") as directory:
            root = Path(directory)
            (root / "Package.swift").write_text(
                f'private let generatedPlaybackArtifactURL = "{PREFIX}playback-v1.0.0{ASSET}"\n'
                f'private let generatedPlaybackArtifactChecksum = "{"a" * 64}"\n')
            swift = root / "swift"
            swift.write_text('#!/bin/sh\nprintf "%s" "$SPOTTY_PACKAGE_GRAPH" > "$project_root/graph"\nexit 1\n')
            swift.chmod(0o755)
            env = {**os.environ, "project_root": str(root), "PIN_HELPER": str(ROOT / "Scripts/playback-xcframework.sh"),
                   "PATH": str(root) + os.pathsep + os.environ["PATH"], "SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": "",
                   "SPOTTY_PACKAGE_GRAPH": "engine-free"}
            result = subprocess.run(["sh", "-c", '. "$PIN_HELPER"; spotty_playback_resolve_xcframework'],
                                    env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("could not resolve", result.stderr)
            self.assertEqual((root / "graph").read_text(), "full")


if __name__ == "__main__":
    unittest.main()
