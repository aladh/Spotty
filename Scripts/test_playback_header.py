"""Keep producer C signature validation independent of Swift and engine compilation."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ArtifactConsumptionTests(unittest.TestCase):
    def check_consumption(self, selected, producer, calls, *, fixture_text=None):
        with tempfile.TemporaryDirectory(prefix="spotty-abi-consumption-") as directory:
            root = Path(directory)
            symbols = root / "selected-symbols"
            symbols.write_text("".join(f"spotty_playback_{name}\n" for name in sorted(selected)))
            fixture = root / "abi-signatures.txt"
            fixture.write_text(fixture_text if fixture_text is not None else "".join(
                f"spotty_playback_{name}|int32_t (void)\n" for name in producer
            ))
            adapter = root / "PlaybackCore.swift"
            adapter.write_text("\n".join(f"spotty_playback_{name}()" for name in calls)
                               + '\n// spotty_playback_unused()\nlet note = "spotty_playback_unused()"\n')
            return subprocess.run([
                "zsh", "-c", 'set -euo pipefail; source "$1"; spotty_abi_check_consumption "$2" "$3" "$4"',
                "abi-consumption", str(ROOT / "Scripts/abi-signature-fixture.sh"),
                str(symbols), str(adapter), str(fixture),
            ], capture_output=True, text=True)

    def test_retired_export_in_older_pin_needs_no_call(self):
        result = self.check_consumption(["pause", "resume"], ["pause"], ["pause"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_future_producer_export_needs_no_old_pin_call(self):
        result = self.check_consumption(["pause"], ["pause", "future"], ["pause"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shared_unused_export_still_fails_with_current_or_older_pin(self):
        for selected in (["pause", "unused"], ["pause", "unused", "retired"]):
            with self.subTest(selected=selected):
                result = self.check_consumption(selected, ["pause", "unused"], ["pause"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not called from PlaybackCore.swift", result.stderr)
                self.assertIn("spotty_playback_unused", result.stderr)

    def test_call_missing_from_selected_artifact_fails_even_when_produced(self):
        result = self.check_consumption(["pause"], ["pause", "future"], ["pause", "future"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("calls exports missing from the selected artifact", result.stderr)
        self.assertIn("spotty_playback_future", result.stderr)

    def test_retired_export_can_still_be_consumed_from_older_pin(self):
        result = self.check_consumption(["pause", "resume"], ["pause"], ["pause", "resume"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_producer_fixture_cannot_exempt_exports(self):
        for fixture in ("", "# empty\n", "spotty_playback_pause|invalid\n",
                        "spotty_playback_pause|int32_t (void)\n" * 2):
            with self.subTest(fixture=fixture):
                result = self.check_consumption(["pause", "unused"], [], ["pause"], fixture_text=fixture)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("C ABI signature fixture", result.stderr)


class GeneratedHeaderSignatureTests(unittest.TestCase):
    def test_generated_header_types_must_match_producer_fixture(self):
        with tempfile.TemporaryDirectory(prefix="spotty-header-policy-") as directory:
            root = Path(directory)
            for name in ("Scripts/generate-c-header.sh", "Scripts/abi-signature-fixture.sh",
                         "Backend/spotty-playback/abi-signatures.txt", "Backend/spotty-playback/cbindgen.toml"):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            shutil.copytree(ROOT / "Sources/SpottyPlaybackCore/include", root / "Sources/SpottyPlaybackCore/include")
            stub = root / "cbindgen-fixture"
            stub.write_text('''#!/usr/bin/env python3
import os, shutil, sys
if sys.argv[1:] == ["--version"]:
    print("cbindgen 0.29.4")
else:
    shutil.copyfile(os.environ["FIXTURE_HEADER"], sys.argv[sys.argv.index("--output") + 1])
''')
            stub.chmod(0o755)
            header = root / "Sources/SpottyPlaybackCore/include/spotty_playback_generated.h"
            env = {**os.environ, "SPOTTY_CBINDGEN": str(stub), "FIXTURE_HEADER": str(header)}
            command = [str(root / "Scripts/generate-c-header.sh"), "--check"]
            valid = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            fixture = root / "Backend/spotty-playback/abi-signatures.txt"
            fixture.write_text(fixture.read_text().replace(
                "spotty_playback_authorize_streaming|int32_t (const char *)",
                "spotty_playback_authorize_streaming|int64_t (const char *)",
            ))
            invalid = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("spotty_playback_authorize_streaming ABI", invalid.stderr)
            self.assertIn("Clang rejected one or more C ABI signatures", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
