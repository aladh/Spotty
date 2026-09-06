"""Keep producer C signature validation independent of Swift and engine compilation."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


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
