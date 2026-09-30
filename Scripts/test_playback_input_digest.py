"""Check the engine identity command against its original ordered path/hash wire format."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path("Backend/spotty-playback/source-input-digest.sh")
FIXED_INPUTS = [
    "rust-toolchain.toml", "Backend/spotty-playback/Cargo.toml", "Backend/spotty-playback/Cargo.lock",
    "Backend/spotty-playback/cbindgen.toml", "Backend/spotty-playback/abi-signatures.txt",
    "Backend/spotty-playback/macos-deployment-target", "Backend/spotty-playback/build.sh",
    "Backend/spotty-playback/build-xcframework.sh", str(SCRIPT), "Scripts/ci-timings.sh",
    "Scripts/ci_timings.py", "Scripts/generate-c-header.sh",
    "Scripts/generate-playback-notices.py", "Scripts/playback-license-overrides.json",
    "Scripts/playback-notices-preamble.md", "Sources/SpottyPlaybackCore/include/module.modulemap",
    "Sources/SpottyPlaybackCore/include/spotty_playback.h",
    "Sources/SpottyPlaybackCore/include/spotty_playback_annotations.h",
    "Sources/SpottyPlaybackCore/include/spotty_playback_generated.h", "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md",
]


class PlaybackInputDigestTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="spotty-input-identity-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name in FIXED_INPUTS:
            self.write(name, f"fixture: {name}\n".encode())
        shutil.copy2(ROOT / SCRIPT, self.root / SCRIPT)
        self.dynamic = [
            "Backend/spotty-playback/src/a.rs", "Backend/spotty-playback/src/nested/é track.rs",
            "Backend/spotty-playback/vendor/crate/.hidden", "Backend/spotty-playback/vendor/crate/Cargo.toml",
            "Backend/spotty-playback/vendor/crate/slash\\name.rs",
            "Backend/spotty-playback/vendor/crate/src/lib.rs", "Scripts/playback-license-overrides/license.txt",
        ]
        for name in reversed(self.dynamic):  # Creation order must not become digest order.
            self.write(name, f"fixture: {name}\n".encode())
        self.write("Backend/spotty-playback/src/ignored.txt", b"not Rust")
        self.write("Backend/spotty-playback/vendor/crate/target/output.rs", b"build product")

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def invoke(self, *arguments, cwd=None):
        return subprocess.run(
            [str(self.root / SCRIPT), *arguments], cwd=cwd or self.root,
            text=True, capture_output=True, timeout=10,
        )

    def digest(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"\A[0-9a-f]{64}\n\Z")
        return result.stdout.strip()

    def reference(self):
        # shasum remains an independent reference for the old per-file hash values; batching
        # its arguments avoids reproducing the process-per-file cost in the test harness.
        paths = FIXED_INPUTS + self.dynamic
        lines = subprocess.check_output(
            ["shasum", "-a", "256", *paths], cwd=self.root,
            env={**os.environ, "LC_ALL": "C"}, text=True, timeout=10,
        ).splitlines()
        self.assertEqual(len(lines), len(paths))
        manifest = "".join(f"{path} {line.split()[0]}\n" for path, line in zip(paths, lines)).encode()
        return hashlib.sha256(manifest).hexdigest()

    def test_inventory_order_and_digest_preserve_the_existing_format(self):
        result = self.invoke("--print-inputs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), FIXED_INPUTS + self.dynamic)
        self.assertEqual(self.digest(), self.reference())
        elsewhere = self.invoke(cwd=self.root.parent)
        self.assertEqual(elsewhere.stdout.strip(), self.reference())

    def test_content_and_relative_path_both_participate(self):
        original = self.digest()
        path = self.dynamic[0]
        self.write(path, b"different bytes")
        changed = self.digest()
        self.assertNotEqual(original, changed)
        self.assertEqual(changed, self.reference())
        destination = "Backend/spotty-playback/src/b.rs"
        (self.root / path).rename(self.root / destination)
        self.dynamic[0] = destination
        self.assertNotEqual(changed, self.digest())
        self.assertEqual(self.digest(), self.reference())

    def test_app_pin_build_outputs_and_non_rust_source_files_are_excluded(self):
        original = self.digest()
        for name in ("Package.swift", "Backend/spotty-playback/vendor/crate/target/output.rs",
                     "Backend/spotty-playback/src/ignored.txt"):
            self.write(name, b"changed excluded input")
        self.assertEqual(self.digest(), original)
        self.write("Backend/spotty-playback/vendor/crate/src/lib.rs", b"changed vendor")
        self.assertNotEqual(self.digest(), original)
        self.assertEqual(self.digest(), self.reference())

    def test_large_binary_input_is_hashed_completely(self):
        self.write(self.dynamic[0], bytes(range(256)) * 8193)
        self.assertEqual(self.digest(), self.reference())

    def test_large_inventory_does_not_depend_on_the_argument_vector_limit(self):
        prefix = f"Backend/spotty-playback/src/{'fixture-' * 24}"
        path_size = len(os.fsencode(self.root / f"{prefix}0000.rs")) + 1
        count = min(10000, os.sysconf("SC_ARG_MAX") // path_size + 100)
        for index in range(count):
            name = f"{prefix}{index:04d}.rs"
            self.write(name, b"fixture")
        original = self.digest()
        self.write(name, b"changed final input")
        self.assertNotEqual(self.digest(), original)

    def test_missing_input_fails_without_publishing_an_identity(self):
        (self.root / "Backend/spotty-playback/Cargo.toml").unlink()
        for arguments in ((), ("--print-inputs",)):
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("Playback artifact input is missing", result.stderr)

    def test_invalid_arguments_fail_without_publishing_an_identity(self):
        for arguments in (("--unknown",), ("--print-inputs", "extra")):
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
