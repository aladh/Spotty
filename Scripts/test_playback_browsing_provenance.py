"""Demo evidence identity checks without compiling or launching any app."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import browsing_provenance


class BrowsingProvenanceTests(unittest.TestCase):
    def make_repository(self, root: Path) -> None:
        for command in (
            ["init", "--quiet"],
            ["config", "user.email", "synthetic@example.invalid"],
            ["config", "user.name", "Synthetic Fixture"],
        ):
            subprocess.run(["git", "-C", str(root), *command], check=True)
        (root / ".gitignore").write_text("ignored/\n")
        (root / "tracked.swift").write_text("let synthetic = 1\n")
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "--quiet", "-m", "Synthetic initial inputs"], check=True)

    def test_untracked_and_binary_changes_affect_source_identity(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repository(root)
            original = browsing_provenance.source_identity(root)
            self.assertEqual(original, browsing_provenance.source_identity(root))
            (root / "new.swift").write_text("let added = 2\n")
            added = browsing_provenance.source_identity(root)
            self.assertEqual(added["untrackedFileCount"], 1)
            self.assertNotEqual(original["sourceSHA256"], added["sourceSHA256"])
            self.assertEqual(original["diffSHA256"], added["diffSHA256"])
            (root / "new.swift").write_bytes(b"\0synthetic binary\xff")
            changed = browsing_provenance.source_identity(root)
            self.assertNotEqual(changed["sourceSHA256"], added["sourceSHA256"])
            (root / "ignored").mkdir()
            (root / "ignored" / "run.json").write_text("generated result")
            self.assertEqual(changed, browsing_provenance.source_identity(root))

    def test_symlink_input_includes_target_bytes_even_when_target_is_ignored(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repository(root)
            (root / "ignored").mkdir()
            target = root / "ignored" / "generated.swift"
            target.write_text("let synthetic = 1\n")
            (root / "linked.swift").symlink_to(target)
            before = browsing_provenance.source_identity(root)
            target.write_text("let synthetic = 2\n")
            self.assertNotEqual(before["sourceSHA256"], browsing_provenance.source_identity(root)["sourceSHA256"])

    def test_changed_build_inputs_refuse_launch_metadata(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "build-start.json").write_text(json.dumps({"source": {"sourceSHA256": "before"}}))
            with patch.object(browsing_provenance, "build_snapshot", return_value={"source": {"sourceSHA256": "after"}}):
                with self.assertRaisesRegex(ValueError, "changed during the build"):
                    browsing_provenance.write_launch(root, root, root, root, "release", True, False)
            self.assertFalse((root / "Contents/Resources/launch.json").exists())

    def test_launch_reports_optimized_build_and_engine_identities(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Demo.app"
            (app / "Contents/Resources").mkdir(parents=True)
            (app / "Contents/MacOS").mkdir()
            product = b"synthetic compiled product before signing"
            (app / "Contents/MacOS/SpottyDemo").write_bytes(product)
            snapshot = {
                "source": {"revision": "a" * 40, "diffSHA256": "b" * 64, "sourceSHA256": "c" * 64},
                "compilerVersion": "Synthetic compiler",
                "requestedSDKVersion": "26.5", "requestedSDKName": "macosx26.5",
                "localEngine": None,
            }
            engine = {"selection": "pinned", "librarySHA256": "d" * 64, "usedForPlayback": False}
            (root / "build-start.json").write_text(json.dumps(snapshot))
            with (
                patch.object(browsing_provenance, "build_snapshot", return_value=snapshot),
                patch.object(browsing_provenance, "engine_identity", return_value=engine),
                patch.object(browsing_provenance, "linked_sdk_version", return_value="15.0"),
            ):
                browsing_provenance.write_launch(root, root, root, app, "release", True, False)
            launch = json.loads((app / "Contents/Resources/launch.json").read_text())
            self.assertEqual(launch["build"]["configuration"], "release")
            self.assertEqual(launch["build"]["optimization"], "-O")
            self.assertTrue(launch["build"]["testabilityEnabled"])
            self.assertEqual(launch["build"]["requestedSDKVersion"], "26.5")
            self.assertEqual(launch["build"]["requestedSDKName"], "macosx26.5")
            self.assertEqual(launch["build"]["linkedSDKVersion"], "15.0")
            self.assertNotIn("sdkVersion", launch["build"])
            self.assertEqual(launch["build"]["buildProductSHA256"], hashlib.sha256(product).hexdigest())
            self.assertEqual(launch["engine"], engine)
            self.assertEqual(launch["source"], snapshot["source"])

    def test_sdk_settings_describe_requested_sdk_without_claiming_compiler_selection(self):
        with TemporaryDirectory() as directory:
            sdk = Path(directory)
            (sdk / "SDKSettings.json").write_text(json.dumps({"Version": "26.5", "CanonicalName": "macosx26.5"}))
            with (
                patch.dict(os.environ, {"SDKROOT": str(sdk)}),
                patch.object(browsing_provenance, "source_identity", return_value={}),
                patch.object(browsing_provenance, "engine_identity", return_value=None),
                patch.object(browsing_provenance.subprocess, "check_output", return_value="Synthetic compiler"),
            ):
                snapshot = browsing_provenance.build_snapshot(sdk)
            self.assertEqual(snapshot["requestedSDKVersion"], "26.5")
            self.assertEqual(snapshot["requestedSDKName"], "macosx26.5")
            self.assertNotIn("sdkVersion", snapshot)

    def test_linked_sdk_uses_macho_stamp_and_rejects_ambiguous_or_missing_values(self):
        command = "Load command 1\n      cmd LC_BUILD_VERSION\n platform 1\n    minos 15.0\n      sdk 27.0\n"
        with patch.object(browsing_provenance.subprocess, "check_output", return_value=command):
            self.assertEqual(browsing_provenance.linked_sdk_version(Path("SyntheticDemo")), "27.0")
        for invalid in ("", command.replace("sdk 27.0", "sdk n/a"), command + command.replace("sdk 27.0", "sdk 26.5")):
            with self.subTest(output=invalid), patch.object(browsing_provenance.subprocess, "check_output", return_value=invalid):
                with self.assertRaisesRegex(ValueError, "linked SDK"):
                    browsing_provenance.linked_sdk_version(Path("SyntheticDemo"))

    def test_local_engine_digests_are_verified_against_selected_archive_and_headers(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Package.swift").write_text(
                'private let generatedPlaybackArtifactURL = "https://example.invalid/engine.zip"\n'
                + 'private let generatedPlaybackArtifactChecksum = "' + "a" * 64 + '"\n'
            )
            artifact = root / "Synthetic.xcframework"
            (artifact / "macos-arm64").mkdir(parents=True)
            library = artifact / "macos-arm64/fixture.a"
            library.write_bytes(b"synthetic archive")
            headers = artifact / "macos-arm64/Headers"
            headers.mkdir()
            header_names = (
                "spotty_playback.h", "spotty_playback_generated.h", "spotty_playback_annotations.h", "module.modulemap",
            )
            for name in header_names:
                (headers / name).write_text(f"// Synthetic {name}\n")
            header_inputs = "".join(
                f"{name} {hashlib.sha256((headers / name).read_bytes()).hexdigest()}\n" for name in header_names
            )
            headers_sha = hashlib.sha256(header_inputs.encode()).hexdigest()
            (artifact / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [
                {"LibraryIdentifier": "macos-arm64", "LibraryPath": "fixture.a", "HeadersPath": "Headers"},
            ]}))
            provenance = {
                "libraryName": "fixture.a", "librarySHA256": hashlib.sha256(library.read_bytes()).hexdigest(),
                "source": {
                    "sourceRevision": "b" * 40, "engineInputDigest": "c" * 64, "librespotRevision": "d" * 40,
                    "canonicalHeadersSHA256": headers_sha,
                },
            }
            (artifact / "spotty_playback_provenance.json").write_text(json.dumps(provenance))
            with patch.dict(os.environ, {"SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": str(artifact)}):
                identity = browsing_provenance.engine_identity(root)
                self.assertEqual(identity["selection"], "local-override")
                self.assertEqual(identity["librarySHA256"], provenance["librarySHA256"])
                self.assertEqual(identity["canonicalHeadersSHA256"], headers_sha)
                library.write_bytes(b"changed archive")
                with self.assertRaisesRegex(ValueError, "archive digest differs"):
                    browsing_provenance.engine_identity(root)
                library.write_bytes(b"synthetic archive")
                for name in header_names:
                    with self.subTest(header=name):
                        header = headers / name
                        original = header.read_bytes()
                        header.write_bytes(original + b"// Changed compiled input\n")
                        with self.assertRaisesRegex(ValueError, "headers digest differs"):
                            browsing_provenance.engine_identity(root)
                        header.write_bytes(original)
                extra_header = headers / "unexpected.h"
                extra_header.write_text("// Unrecorded compiled input\n")
                with self.assertRaisesRegex(ValueError, "exactly the four canonical header files"):
                    browsing_provenance.engine_identity(root)


if __name__ == "__main__":
    unittest.main()
