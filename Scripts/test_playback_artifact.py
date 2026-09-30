"""Exercise batched playback checks and the shell gate's remaining binary/archive checks."""

import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

from playback_artifact import HEADER_NAMES, METADATA_LIMIT, metadata, resolve, verify


ROOT = Path(__file__).resolve().parents[1]
URL = "https://github.com/aladh/Spotty/releases/download/playback-v0.2.1/SpottyPlaybackCore.xcframework.zip"
CHECKSUM = "b" * 64


class PlaybackArtifactTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="spotty-artifact-checks-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.artifact = self.root / "Selected.xcframework"
        self.slice = self.artifact / "macos-arm64"
        self.headers = self.slice / "Headers"
        self.headers.mkdir(parents=True)
        for name in HEADER_NAMES:
            (self.headers / name).write_text(f"// fixture {name}\n")
        self.source_digest = "a" * 64
        self.library_bytes = b"fixture static archive"
        self.library_digest = hashlib.sha256(self.library_bytes).hexdigest()
        self.library_name = f"libSpottyPlaybackCore_{self.source_digest}_{self.library_digest}.a"
        (self.slice / self.library_name).write_bytes(self.library_bytes)
        self.info = {
            "CFBundlePackageType": "XFWK", "LibraryType": "static", "ModuleName": "SpottyPlaybackCore",
            "MinimumOSVersion": "26.0", "AvailableLibraries": [{
                "LibraryIdentifier": "macos-arm64", "SupportedPlatform": "macos",
                "SupportedArchitectures": ["arm64"], "LibraryPath": self.library_name,
                "BinaryPath": self.library_name, "HeadersPath": "Headers",
            }],
        }
        manifest = "".join(f"{name} {hashlib.sha256((self.headers / name).read_bytes()).hexdigest()}\n"
                           for name in HEADER_NAMES)
        self.provenance = {
            "target": "aarch64-apple-darwin", "module": "SpottyPlaybackCore", "platform": "macOS",
            "minimumOSVersion": "26.0", "libraryType": "static", "libraryName": self.library_name,
            "librarySHA256": self.library_digest, "source": {
                "engineInputDigest": self.source_digest, "sourceDirty": False,
                "canonicalHeadersSHA256": hashlib.sha256(manifest.encode()).hexdigest(),
            },
        }
        self.write_info()
        self.write_provenance()

    def write_info(self, info=None, *, fmt=plistlib.FMT_XML):
        (self.artifact / "Info.plist").write_bytes(plistlib.dumps(info or self.info, fmt=fmt))

    def write_provenance(self, provenance=None):
        (self.artifact / "spotty_playback_provenance.json").write_text(json.dumps(provenance or self.provenance))

    def test_xml_binary_and_json_metadata_accept_the_same_artifact(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(format=fmt):
                self.write_info(fmt=fmt)
                self.assertEqual(metadata(self.artifact),
                                 ("26.0", self.library_name, self.source_digest, self.library_digest))
                verify(self.artifact, self.source_digest, for_publish=True)
        (self.artifact / "Info.plist").write_text(json.dumps(self.info))
        verify(self.artifact)

    def test_every_metadata_relationship_is_checked(self):
        changes = [
            ("package type", None, "CFBundlePackageType", "wrong"),
            ("library type", None, "LibraryType", "dynamic"),
            ("module name", None, "ModuleName", "AnotherModule"),
            ("minimum OS version", None, "MinimumOSVersion", ""),
            ("available library count", None, "AvailableLibraries", []),
            ("available library count", None, "AvailableLibraries", [{}, {}]),
            ("library identifier", 0, "LibraryIdentifier", "ios-arm64"),
            ("supported platform", 0, "SupportedPlatform", "ios"),
            ("architecture count", 0, "SupportedArchitectures", ["arm64", "x86_64"]),
            ("architecture", 0, "SupportedArchitectures", ["x86_64"]),
            ("binary path", 0, "BinaryPath", "another.a"),
            ("headers path", 0, "HeadersPath", "../Headers"),
        ]
        for label, index, key, value in changes:
            with self.subTest(label=label):
                info = copy.deepcopy(self.info)
                target = info if index is None else info["AvailableLibraries"][index]
                target[key] = value
                self.write_info(info)
                with self.assertRaisesRegex(ValueError, label):
                    metadata(self.artifact)

    def test_library_name_carries_both_exact_digests_and_a_safe_path(self):
        for name in ("legacy.a", f"../{self.library_name}", f"/{self.library_name}",
                     self.library_name.replace(self.source_digest, "a" * 63),
                     self.library_name.replace(self.library_digest, "g" * 64),
                     self.library_name + "\nother"):
            with self.subTest(name=name):
                info = copy.deepcopy(self.info)
                info["AvailableLibraries"][0].update(LibraryPath=name, BinaryPath=name)
                self.write_info(info)
                with self.assertRaises(ValueError):
                    metadata(self.artifact)

    def test_every_provenance_relationship_is_checked(self):
        for key in ("target", "module", "platform", "minimumOSVersion", "libraryType", "libraryName", "librarySHA256"):
            with self.subTest(key=key):
                provenance = copy.deepcopy(self.provenance)
                provenance[key] = "wrong"
                self.write_provenance(provenance)
                with self.assertRaisesRegex(ValueError, "provenance"):
                    verify(self.artifact)
        for key in ("engineInputDigest", "canonicalHeadersSHA256"):
            with self.subTest(key=key):
                provenance = copy.deepcopy(self.provenance)
                provenance["source"][key] = "c" * 64
                self.write_provenance(provenance)
                with self.assertRaises(ValueError):
                    verify(self.artifact, self.source_digest)

    def test_changed_header_and_library_bytes_cannot_reuse_recorded_digests(self):
        for name in HEADER_NAMES:
            with self.subTest(header=name):
                path = self.headers / name
                original = path.read_bytes()
                path.write_bytes(original + b"changed")
                with self.assertRaisesRegex(ValueError, "header digest"):
                    verify(self.artifact)
                path.write_bytes(original)
        (self.slice / self.library_name).write_bytes(self.library_bytes + b"changed")
        with self.assertRaisesRegex(ValueError, "library digest"):
            verify(self.artifact)

    def test_publication_requires_boolean_clean_source_and_current_input_digest(self):
        for dirty in (True, "false", 0, None):
            with self.subTest(dirty=dirty):
                provenance = copy.deepcopy(self.provenance)
                provenance["source"]["sourceDirty"] = dirty
                self.write_provenance(provenance)
                verify(self.artifact)  # A released consumer does not compare current checkout state.
                with self.assertRaisesRegex(ValueError, "source dirty flag"):
                    verify(self.artifact, self.source_digest, for_publish=True)
        self.write_provenance()
        with self.assertRaisesRegex(ValueError, "source input digest"):
            verify(self.artifact, "c" * 64)

    def test_invalid_missing_duplicate_and_oversized_metadata_fail_closed(self):
        path = self.artifact / "spotty_playback_provenance.json"
        for data in (b"not json", b"[]", b'{"source":{},"source":{}}', b'{"unknown":NaN}',
                     b"<?xml version='1.0'?><plist><dict>broken", b" " * (METADATA_LIMIT + 1)):
            with self.subTest(data=data[:30]):
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    verify(self.artifact)
        path.unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            verify(self.artifact)

    def test_hashes_remain_tied_to_the_inspected_library_and_deployment_declaration(self):
        with self.assertRaisesRegex(ValueError, "inspected minimum OS version"):
            verify(self.artifact, expected_minimum="15.0", expected_name=self.library_name)
        with self.assertRaisesRegex(ValueError, "inspected library name"):
            verify(self.artifact, expected_minimum="26.0", expected_name="another.a")

    def workspace(self, entries):
        path = self.root / "workspace-state.json"
        path.write_text(json.dumps({"object": {"artifacts": entries}}))
        return path

    def entry(self, *, path=None):
        return {"targetName": "SpottyPlaybackCore", "path": path or str(self.artifact),
                "source": {"type": "remote", "url": URL, "checksum": CHECKSUM}}

    def test_workspace_selects_exact_remote_pin_and_resolves_relative_or_symlink_paths(self):
        for path in (str(self.artifact), self.artifact.name):
            entry = self.entry(path=path)
            entry["source"]["checksum"] = CHECKSUM.upper()
            for source_type in ("remote", "url"):
                with self.subTest(path=path, source_type=source_type):
                    entry["source"]["type"] = source_type
                    self.assertEqual(resolve(self.root, self.workspace([{"targetName": "Sparkle"}, entry]),
                                             URL, CHECKSUM), self.artifact)
        alias = self.root / "Alias.xcframework"
        alias.symlink_to(self.artifact)
        self.assertEqual(resolve(self.root, self.workspace([self.entry(path=str(alias))]), URL, CHECKSUM), self.artifact)

    def test_workspace_refuses_missing_duplicate_nonremote_stale_or_unsafe_entries(self):
        invalid = [[], [self.entry(), self.entry()], [{}], [self.entry()] * 65]
        for key, value in (("type", "local"), ("url", URL + "?stale"), ("checksum", "d" * 64),
                           ("url", ""), ("checksum", None)):
            entry = self.entry()
            entry["source"][key] = value
            invalid.append([entry])
        for path in (str(self.root / "Missing.xcframework"), str(self.root), "name\n.xcframework"):
            invalid.append([self.entry(path=path)])
        for entries in invalid:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                resolve(self.root, self.workspace(entries), URL, CHECKSUM)

    def prepare_shell_gate(self):
        backend = self.root / "Backend/spotty-playback"
        scripts = self.root / "Scripts"
        backend.mkdir(parents=True)
        scripts.mkdir()
        for name in ("Backend/spotty-playback/validate-xcframework.sh", "Scripts/playback_artifact.py",
                     "Scripts/playback_deployment.py", "Scripts/playback-xcframework.sh"):
            shutil.copy2(ROOT / name, self.root / name)
        (backend / "macos-deployment-target").write_text("26.0\n")
        source_script = backend / "source-input-digest.sh"
        source_script.write_text(f'#!/bin/sh\nprintf "%s\\n" "{self.source_digest}"\n')
        source_script.chmod(0o755)
        canonical = self.root / "Sources/SpottyPlaybackCore/include"
        canonical.mkdir(parents=True)
        for name in HEADER_NAMES:
            shutil.copy2(self.headers / name, canonical / name)
        notices = self.artifact / "Notices"
        (notices / "source").mkdir(parents=True)
        (notices / "licenses").mkdir()
        for name in ("ThirdPartyNotices.md", "manifest.json", "source/LICENSE", "source/NOTICE", "source/THIRD_PARTY_NOTICES.md"):
            (notices / name).write_text("fixture notice")
        binary_tools = self.root / "bin"
        binary_tools.mkdir()
        for name, output in (("lipo", "arm64"), ("otool", "Load command 1\n cmd LC_BUILD_VERSION\n minos 26.0\n sdk 27.0")):
            path = binary_tools / name
            path.write_text(f'#!/bin/sh\nprintf "%s\\n" "{output}"\nprintf "%s\\n" "{name} $*" >> "$BINARY_INSPECTION_LOG"\n')
            path.chmod(0o755)
        return {**os.environ, "PATH": str(binary_tools) + os.pathsep + os.environ["PATH"],
                "BINARY_INSPECTION_LOG": str(self.root / "binary-inspection.log")}

    def invoke_gate(self, env, *flags):
        return subprocess.run([str(self.root / "Backend/spotty-playback/validate-xcframework.sh"),
                               str(self.artifact), *flags], env=env, capture_output=True, text=True, timeout=10)

    def archive(self, path, *, extra=None):
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(self.artifact.name + "/", b"")
            for child in self.artifact.rglob("*"):
                archive.write(child, self.artifact.name + "/" + child.relative_to(self.artifact).as_posix())
            if extra:
                archive.writestr(*extra)

    def test_shell_preserves_real_binary_commands_source_pair_notices_and_archive_checks(self):
        env = self.prepare_shell_gate()
        archive = self.root / "artifact.zip"
        self.archive(archive)
        result = self.invoke_gate(env, "--archive", str(archive), "--for-publish")
        self.assertEqual(result.returncode, 0, result.stderr)
        inspections = (self.root / "binary-inspection.log").read_text()
        self.assertIn(f"lipo -archs {self.slice / self.library_name}", inspections)
        self.assertIn(f"otool -l {self.slice / self.library_name}", inspections)
        for extra in (("outside.txt", b"outside"), ("../unsafe", b"unsafe")):
            with self.subTest(extra=extra):
                self.archive(archive, extra=extra)
                self.assertNotEqual(self.invoke_gate(env, "--published", "--archive", str(archive)).returncode, 0)
        self.archive(archive)
        (self.headers / HEADER_NAMES[0]).write_text("changed")
        result = self.invoke_gate(env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from canonical", result.stderr)

    def test_shell_preserves_published_vs_source_ownership_and_publication_requirements(self):
        env = self.prepare_shell_gate()
        source_script = self.root / "Backend/spotty-playback/source-input-digest.sh"
        source_script.write_text(f'#!/bin/sh\nprintf "%s\\n" "{"c" * 64}"\n')
        self.assertEqual(self.invoke_gate(env, "--published").returncode, 0)
        result = self.invoke_gate(env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source input digest", result.stderr)
        source_script.write_text(f'#!/bin/sh\nprintf "%s\\n" "{self.source_digest}"\n')
        canonical = self.root / "Sources/SpottyPlaybackCore/include" / HEADER_NAMES[0]
        canonical.write_text("current producer header differs from released pin")
        self.assertEqual(self.invoke_gate(env, "--published").returncode, 0)
        result = self.invoke_gate(env, "--published", "--for-publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from canonical", result.stderr)
        shutil.copy2(self.headers / HEADER_NAMES[0], canonical)
        result = self.invoke_gate(env, "--for-publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--for-publish requires --archive", result.stderr)

    def test_shell_rejects_incompatible_binary_and_missing_notice(self):
        env = self.prepare_shell_gate()
        lipo = self.root / "bin/lipo"
        original = lipo.read_text()
        lipo.write_text(original.replace('"arm64"', '"arm64 x86_64"'))
        result = self.invoke_gate(env, "--published")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain only arm64", result.stderr)
        lipo.write_text(original)
        otool = self.root / "bin/otool"
        original = otool.read_text()
        otool.write_text(original.replace("minos 26.0", "minos 27.0"))
        result = self.invoke_gate(env, "--published")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deployment target is invalid", result.stderr)
        otool.write_text(original)
        (self.artifact / "Notices/source/NOTICE").unlink()
        result = self.invoke_gate(env, "--published")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("licensing file is missing", result.stderr)

    def test_resolver_rechecks_pin_after_every_actual_resolve(self):
        env = self.prepare_shell_gate()
        (self.root / "Package.swift").write_text(
            f'private let generatedPlaybackArtifactURL = "{URL}"\n'
            f'private let generatedPlaybackArtifactChecksum = "{CHECKSUM}"\n')
        (self.root / ".build").mkdir()
        state = self.root / ".build/workspace-state.json"
        state.write_text(json.dumps({"object": {"artifacts": [self.entry()]}}))
        swift = self.root / "bin/swift"
        swift.write_text('#!/bin/sh\nprintf "%s\\n" "$SPOTTY_PACKAGE_GRAPH $*" >> "$project_root/resolves"\n')
        swift.chmod(0o755)
        env.update(project_root=str(self.root), SPOTTY_PACKAGE_GRAPH="engine-free", SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK="")
        command = ["sh", "-c", '. "$project_root/Scripts/playback-xcframework.sh"; spotty_playback_resolve_xcframework']
        for _ in range(2):
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(self.artifact))
        package = self.root / "Package.swift"
        package.write_text(package.read_text().replace(CHECKSUM, "e" * 64))
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match Package.swift", result.stderr)
        calls = (self.root / "resolves").read_text().splitlines()
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(call == f"full package resolve --package-path {self.root}" for call in calls))


if __name__ == "__main__":
    unittest.main()
