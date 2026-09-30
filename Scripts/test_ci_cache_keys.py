"""A compatible cache may reuse dependencies only across an unchanged build contract."""

import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
from unittest.mock import patch

from ci_cache_keys import (
    RUST_BUILD_INPUTS, SWIFT_BUILD_INPUTS, cache_keys, main, sdk_identity, toolchain_identity,
)


REVISION = "1" * 40
COMMON_TOOLCHAIN = {
    "architecture": "arm64", "xcode": "26.6", "xcode_build": "17F80",
    "sdk": "26.5", "sdk_build": "25F70", "sdk_settings": "a" * 64,
    "clang": "17.0.0", "clang_build": "clang-1700.4.4.1", "clang_target": "arm64-apple-darwin25.0.0",
}
SWIFT_TOOLCHAIN = {**COMMON_TOOLCHAIN, "swift": "6.3.3", "swift_build": "swiftlang-6.3.3.1.1 clang-1700.4.4.1",
                   "swift_target": "arm64-apple-macosx26.0", "sdk_role": "wrapper-selected",
                   "xcode_sdk": "27.0", "xcode_sdk_build": "26A425", "xcode_sdk_settings": "b" * 64}
RUST_TOOLCHAIN = {**COMMON_TOOLCHAIN, "rust": "1.98.1", "rust_commit": "2" * 40,
                  "rust_host": "aarch64-apple-darwin", "rust_llvm": "22.1.8",
                  "cargo": "1.98.1", "cargo_commit": "3" * 40, "cargo_host": "aarch64-apple-darwin"}
MANIFEST = '''// swift-tools-version: 6.3
private let generatedPlaybackArtifactURL =
    "https://github.com/aladh/Spotty/releases/download/playback-v0.2.1/SpottyPlaybackCore.xcframework.zip"
private let generatedPlaybackArtifactChecksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
let package = Package(platforms: [.macOS(.v26)])
'''


class CacheKeyTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="spotty-cache-key-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.environment = {"CARGO_HOME": str(self.root / "cargo-home")}
        for name in set(SWIFT_BUILD_INPUTS + RUST_BUILD_INPUTS):
            self.write(name, "fixed build input")
        self.write("Package.swift", MANIFEST)
        self.write("Package.resolved", '{"pins": [{"version": "2.10.0"}]}')
        self.write("Backend/spotty-playback/macos-deployment-target", "26.0\n")
        self.write("Backend/spotty-playback/Cargo.toml", '[profile.release]\nopt-level = 3\nlto = true\n')
        self.write("Backend/spotty-playback/Cargo.lock", "locked dependency graph")
        self.write("Backend/spotty-playback/build.sh", "fixed release flags")
        self.write("Backend/spotty-playback/build-xcframework.sh", "fixed archive build")
        self.write("Backend/spotty-playback/src/lib.rs", "original bridge")
        self.write("Backend/spotty-playback/vendor/dependency/src/lib.rs", "dependency source")
        self.write("Backend/spotty-playback/vendor/dependency/build.rs", "dependency build script")

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        return path

    def swift(self, **arguments):
        return cache_keys("swift", self.root, arguments.pop("identity", SWIFT_TOOLCHAIN),
                          lane=arguments.pop("lane", "tests"), revision=arguments.pop("revision", REVISION),
                          environment=arguments.pop("environment", self.environment), **arguments)

    def rust(self, **arguments):
        return cache_keys("rust", self.root, arguments.pop("identity", RUST_TOOLCHAIN),
                          environment=arguments.pop("environment", self.environment), **arguments)

    def assert_input_changes(self, scope, name):
        method = self.swift if scope == "swift" else self.rust
        key = "SWIFT_CACHE_PREFIX" if scope == "swift" else "RUST_RELEASE_COMPATIBILITY_KEY"
        before = method()[key]
        path = self.root / name
        old = path.read_text() if path.exists() else None
        self.write(name, (old or "") + "\nchanged input\n")
        try:
            self.assertNotEqual(before, method()[key], name)
        finally:
            if old is None:
                path.unlink()
            else:
                path.write_text(old)

    def test_every_actual_toolchain_dimension_isolates_both_scopes(self):
        for scope, identity, method, key in (
            ("swift", SWIFT_TOOLCHAIN, self.swift, "SWIFT_CACHE_PREFIX"),
            ("rust", RUST_TOOLCHAIN, self.rust, "RUST_RELEASE_COMPATIBILITY_KEY"),
        ):
            before = method()[key]
            for dimension in identity:
                with self.subTest(scope=scope, dimension=dimension):
                    changed = {**identity, dimension: identity[dimension] + "-changed"}
                    self.assertNotEqual(before, method(identity=changed)[key])

    def test_swift_exact_revision_changes_without_widening_fallback(self):
        before = self.swift()
        after = self.swift(revision="4" * 40)
        self.assertNotEqual(before["SWIFT_CACHE_KEY"], after["SWIFT_CACHE_KEY"])
        self.assertEqual(before["SWIFT_CACHE_PREFIX"], after["SWIFT_CACHE_PREFIX"])
        self.assertTrue(before["SWIFT_CACHE_KEY"].startswith(before["SWIFT_CACHE_PREFIX"]))

    def test_each_sdk_version_build_and_settings_isolate_every_swift_lane(self):
        for lane in ("contracts", "tests", "release"):
            before = self.swift(lane=lane)["SWIFT_CACHE_PREFIX"]
            for dimension in ("sdk", "sdk_build", "sdk_settings", "xcode_sdk", "xcode_sdk_build",
                              "xcode_sdk_settings"):
                with self.subTest(lane=lane, dimension=dimension):
                    changed = {**SWIFT_TOOLCHAIN, dimension: SWIFT_TOOLCHAIN[dimension] + "-changed"}
                    self.assertNotEqual(before, self.swift(lane=lane, identity=changed)["SWIFT_CACHE_PREFIX"])

    def test_swift_source_edit_can_reuse_only_compatible_build_contract(self):
        before = self.swift()["SWIFT_CACHE_PREFIX"]
        self.write("Sources/Spotty/Updated.swift", "changed implementation")
        self.write("Tests/SpottyBoundaryTests/Updated.swift", "changed test")
        self.assertEqual(before, self.swift()["SWIFT_CACHE_PREFIX"])
        for name in SWIFT_BUILD_INPUTS:
            with self.subTest(input=name):
                self.assert_input_changes("swift", name)

    def test_swift_lanes_and_build_systems_never_share_a_restore_prefix(self):
        prefixes = {self.swift(lane=lane, build_system=build_system)["SWIFT_CACHE_PREFIX"]
                    for lane in ("contracts", "tests", "release")
                    for build_system in ("default", "native", "xcode")}
        self.assertEqual(len(prefixes), 9)
        self.assertNotEqual(self.swift()["SWIFT_CACHE_PREFIX"],
                            self.swift(environment={"SPOTTY_BUILD_CONFIGURATION": "release"})["SWIFT_CACHE_PREFIX"])

    def test_swift_pin_checksum_and_deployment_are_isolated(self):
        before = self.swift()["SWIFT_CACHE_PREFIX"]
        for old, new in (("playback-v0.2.1", "playback-v0.2.2"), ("a" * 64, "b" * 64),
                         (".v26", ".v27")):
            with self.subTest(change=new):
                self.write("Package.swift", MANIFEST.replace(old, new))
                self.assertNotEqual(before, self.swift()["SWIFT_CACHE_PREFIX"])
        self.write("Package.swift", MANIFEST)

    def test_swift_missing_pin_lock_and_local_artifact_fail_closed(self):
        for manifest in (MANIFEST.replace("https://github.com/", "https://untrusted.invalid/"),
                         MANIFEST.replace("a" * 64, "missing")):
            self.write("Package.swift", manifest)
            with self.assertRaises(ValueError):
                self.swift()
        self.write("Package.swift", MANIFEST)
        with self.assertRaises(ValueError):
            self.swift(environment={"SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": "private-override"})
        with self.assertRaises(ValueError):
            self.swift(environment={"SPOTTY_SIGNING_IDENTITY": "private-identity"})
        (self.root / "Package.resolved").unlink()
        with self.assertRaises(ValueError):
            self.swift()

    def test_only_bridge_rust_source_edits_additions_and_deletions_retain_dependencies_key(self):
        before = self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"]
        self.write("Backend/spotty-playback/src/lib.rs", "changed bridge")
        nested = self.write("Backend/spotty-playback/src/nested/new.rs", "new bridge module")
        self.assertEqual(before, self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"])
        nested.unlink()
        (self.root / "Backend/spotty-playback/src/lib.rs").unlink()
        self.assertEqual(before, self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"])

    def test_rust_vendor_source_build_scripts_locks_profiles_flags_and_headers_invalidate(self):
        for name in (*(name for name in RUST_BUILD_INPUTS if not name.endswith("macos-deployment-target")),
                     "Backend/spotty-playback/Cargo.toml",
                     "Backend/spotty-playback/Cargo.lock", "Backend/spotty-playback/build.sh",
                     "Backend/spotty-playback/build-xcframework.sh", "Backend/spotty-playback/build.rs",
                     "Backend/spotty-playback/vendor/dependency/src/lib.rs",
                     "Backend/spotty-playback/vendor/dependency/build.rs",
                     "Backend/spotty-playback/src/embedded-data.json", ".cargo/config.toml",
                     "Backend/spotty-playback/.cargo/config"):
            with self.subTest(input=name):
                self.assert_input_changes("rust", name)

    def test_bundle_policy_changes_invalidate_every_consumer_without_changing_toolchain_identity(self):
        before = self.rust()
        swift_before = {lane: self.swift(lane=lane) for lane in ("contracts", "tests", "release")}
        self.write("Scripts/ci_cache_bundle.py", "changed transfer policy")
        after = self.rust()
        self.assertNotEqual(before["RUST_RELEASE_COMPATIBILITY_KEY"], after["RUST_RELEASE_COMPATIBILITY_KEY"])
        self.assertNotEqual(before["RUST_CACHE_TRANSFER_KEY"], after["RUST_CACHE_TRANSFER_KEY"])
        self.assertEqual(before["RUST_TOOLCHAIN_KEY"], after["RUST_TOOLCHAIN_KEY"])
        for lane, previous in swift_before.items():
            with self.subTest(lane=lane):
                changed = self.swift(lane=lane)
                self.assertNotEqual(previous["SWIFT_CACHE_KEY"], changed["SWIFT_CACHE_KEY"])
                self.assertNotEqual(previous["SWIFT_CACHE_PREFIX"], changed["SWIFT_CACHE_PREFIX"])
                self.assertEqual(previous["SWIFT_TOOLCHAIN_KEY"], changed["SWIFT_TOOLCHAIN_KEY"])

    def test_missing_or_symlinked_bundle_policy_cannot_identify_any_consumer_cache(self):
        bundle = self.root / "Scripts/ci_cache_bundle.py"
        bundle.unlink()
        for method in (self.swift, self.rust):
            with self.assertRaises(ValueError):
                method()
        bundle.symlink_to(self.root / "Package.swift")
        for method in (self.swift, self.rust):
            with self.assertRaises(ValueError):
                method()

    def test_new_rust_release_family_cannot_restore_the_old_immutable_generation(self):
        key = self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"]
        self.assertRegex(key, r"^macos-rust-release-v4-[0-9a-f]{64}$")
        old = key.replace("-v4-", "-v3-") + "-" + "a" * 64
        self.assertFalse(old.startswith(key + "-"))

    def test_actual_workflow_debug_keys_change_with_bundle_policy(self):
        workflow = RustCacheWorkflowTests.workflow()
        debug = RustCacheWorkflowTests.step(workflow, "Restore Rust verification products")
        before = self.rust()
        self.write("Scripts/ci_cache_bundle.py", "changed transfer policy")
        after = self.rust()
        for field in ("key", "restore-keys"):
            template = RustCacheWorkflowTests.cache_field(debug, field)
            rendered_before = template.replace("${{ env.RUST_CACHE_TRANSFER_KEY }}", before["RUST_CACHE_TRANSFER_KEY"])
            rendered_after = template.replace("${{ env.RUST_CACHE_TRANSFER_KEY }}", after["RUST_CACHE_TRANSFER_KEY"])
            self.assertNotEqual(rendered_before, rendered_after, field)

    def test_rust_deployment_incremental_and_cargo_user_configuration_invalidate(self):
        before = self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"]
        self.write("Backend/spotty-playback/macos-deployment-target", "27.0\n")
        self.assertNotEqual(before, self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"])
        self.write("Backend/spotty-playback/macos-deployment-target", "26.0\n")
        self.assertNotEqual(before, self.rust(environment={**self.environment, "CARGO_INCREMENTAL": "0"})[
            "RUST_RELEASE_COMPATIBILITY_KEY"])
        self.write("cargo-home/config.toml", '[build]\nrustflags = ["--cfg", "different"]\n')
        self.assertNotEqual(before, self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"])

    def test_rust_target_and_profile_features_fixed_contract_invalidate(self):
        before = self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"]
        for name, value in (("RUST_TARGET", "x86_64-apple-darwin"), ("RUST_FIXED_FLAGS", "-C opt-level=2")):
            with self.subTest(dimension=name), patch("ci_cache_keys." + name, value):
                self.assertNotEqual(before, self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"])
        for declaration in ('[features]\ndefault = ["new-feature"]\n', '[profile.release]\nlto = "thin"\n'):
            self.write("Backend/spotty-playback/Cargo.toml", declaration)
            self.assertNotEqual(before, self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"])

    def test_rust_unrecognized_flag_profile_or_deployment_overrides_fail_closed(self):
        for name in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_WRAPPER", "CFLAGS",
                     "CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS", "CARGO_BUILD_TARGET",
                     "CARGO_PROFILE_RELEASE_LTO", "MACOSX_DEPLOYMENT_TARGET"):
            with self.subTest(override=name), self.assertRaises(ValueError):
                self.rust(environment={**self.environment, name: "unkeyed-override"})

    def test_build_products_are_not_compatibility_inputs(self):
        before = self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"]
        self.write("Backend/spotty-playback/target/aarch64-apple-darwin/release/libspotty_playback.a", "old archive")
        self.write("Backend/spotty-playback/vendor/dependency/target/debug/libdependency.rlib", "product")
        self.assertEqual(before, self.rust()["RUST_RELEASE_COMPATIBILITY_KEY"])
        self.assertNotIn("PLAYBACK_INPUT_DIGEST", self.rust())

    def test_missing_and_symlinked_compiler_inputs_fail_closed(self):
        header = self.root / "Sources/SpottyPlaybackCore/include/spotty_playback.h"
        header.unlink()
        for method in (self.swift, self.rust):
            with self.assertRaises(ValueError):
                method()
        header.symlink_to(self.root / "Package.swift")
        for method in (self.swift, self.rust):
            with self.assertRaises(ValueError):
                method()
        header.unlink()
        header.write_text("restored")
        link = self.root / "Backend/spotty-playback/vendor/dependency/link"
        link.symlink_to(self.root / "Sources", target_is_directory=True)
        with self.assertRaises(ValueError):
            self.rust()

    def test_cli_env_and_report_contain_only_compact_keys_and_sanitized_identity(self):
        env_path, report = self.root / "github-env", self.root / "report.json"
        env_path.write_text("EXISTING=value\n")
        with patch("ci_cache_keys.toolchain_identity", return_value=SWIFT_TOOLCHAIN), \
                patch("ci_cache_keys.Path.cwd", return_value=self.root), \
                patch.dict(os.environ, {"PRIVATE_TOKEN": "must-not-appear"}, clear=True), \
                patch("sys.argv", ["ci_cache_keys.py", "swift", "--lane", "tests", "--revision", REVISION,
                                   "--github-env", str(env_path), "--report", str(report)]), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            main()
        result = json.loads(output.getvalue())
        self.assertEqual(result, json.loads(report.read_text()))
        lines = env_path.read_text().splitlines()
        self.assertEqual(lines[0], "EXISTING=value")
        self.assertEqual(set(line.split("=", 1)[0] for line in lines[1:]),
                         {"SWIFT_CACHE_KEY", "SWIFT_CACHE_PREFIX", "SWIFT_TOOLCHAIN_KEY"})
        self.assertNotIn("must-not-appear", report.read_text() + env_path.read_text())
        self.assertNotIn(str(self.root), report.read_text())


class ActualIdentityParsingTests(unittest.TestCase):
    def probe(self, arguments, root):
        values = {
            ("xcodebuild", "-version"): "Xcode 26.6\nBuild version 17F80\nPRIVATE_TOKEN=secret",
            ("xcrun", "--show-sdk-path"): "/selected/actual-sdk",
            ("env", "-u", "SDKROOT", "xcrun", "--sdk", "macosx", "--show-sdk-path"): "/selected/xcode-sdk",
            ("xcrun", "clang", "--version"): "Apple clang version 17.0.0 (clang-1700.4.4.1)\nTarget: arm64-apple-darwin25.0.0",
            ("swift", "--version"): "swift-driver version: 1.168.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.1 clang-1700.4.4.1)\nTarget: arm64-apple-macosx26.0",
            ("rustc", "-vV"): f"release: 1.98.1\ncommit-hash: {'2' * 40}\nhost: aarch64-apple-darwin\nLLVM version: 22.1.8",
            ("cargo", "-vV"): f"cargo 1.98.1 (abc 2026-08-05)\ncommit-hash: {'3' * 40}\nhost: aarch64-apple-darwin",
        }
        return values[tuple(arguments)]

    def test_actual_version_fields_are_whitelisted_without_environment_or_paths(self):
        for scope, expected in (("swift", SWIFT_TOOLCHAIN), ("rust", RUST_TOOLCHAIN)):
            with self.subTest(scope=scope):
                identity = toolchain_identity(scope, Path.cwd(), probe=self.probe, environment={}, machine="arm64",
                                              read_sdk=lambda path: {
                                                  key: SWIFT_TOOLCHAIN[f"xcode_{key}"] if path == "/selected/xcode-sdk"
                                                  else COMMON_TOOLCHAIN[key]
                                                  for key in ("sdk", "sdk_build", "sdk_settings")})
                self.assertEqual(identity, expected)
                self.assertNotIn("secret", json.dumps(identity))
                self.assertNotIn("actual-sdk", json.dumps(identity))

    def test_ambiguous_or_noncanonical_version_output_fails_closed(self):
        for output in ("Xcode unknown\nBuild version abc", "Xcode 26.6\nXcode 27.0\nBuild version abc"):
            def probe(arguments, root):
                return output if arguments == ["xcodebuild", "-version"] else self.probe(arguments, root)
            with self.subTest(output=output), self.assertRaises(ValueError):
                toolchain_identity("swift", Path.cwd(), probe=probe, environment={}, machine="arm64")

    def test_sdk_selection_matches_each_build_owner(self):
        selected = []

        def read_sdk(path):
            selected.append(path)
            return {key: COMMON_TOOLCHAIN[key] for key in ("sdk", "sdk_build", "sdk_settings")}

        with patch("ci_cache_keys.Path.is_dir", return_value=True):
            for scope, environment in (("swift", {"SDKROOT": "/ignored-by-swift"}),
                                       ("rust", {"SDKROOT": "/explicit-rust-sdk"}), ("rust", {})):
                toolchain_identity(scope, Path.cwd(), probe=self.probe, environment=environment,
                                   machine="arm64", read_sdk=read_sdk)
        self.assertEqual(selected, ["/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk", "/selected/xcode-sdk",
                                    "/explicit-rust-sdk", "/selected/actual-sdk"])

    def test_xcode_sdk_probe_removes_sdkroot_without_mutating_process_environment(self):
        invocations = []

        def probe(arguments, root):
            invocations.append(arguments)
            return self.probe(arguments, root)

        with patch.dict(os.environ, {"SDKROOT": "/private/wrapper-sdk"}), \
                patch("ci_cache_keys.Path.is_dir", return_value=True):
            toolchain_identity("swift", Path.cwd(), probe=probe, environment=dict(os.environ), machine="arm64",
                               read_sdk=lambda path: {key: COMMON_TOOLCHAIN[key]
                                                      for key in ("sdk", "sdk_build", "sdk_settings")})
            self.assertEqual(os.environ["SDKROOT"], "/private/wrapper-sdk")
        self.assertIn(["env", "-u", "SDKROOT", "xcrun", "--sdk", "macosx", "--show-sdk-path"], invocations)

    def test_equal_sdk_identities_retain_selection_labels_without_claiming_effective_builder_sdk(self):
        identity = toolchain_identity("swift", Path.cwd(), probe=self.probe, environment={}, machine="arm64",
                                      read_sdk=lambda path: {key: COMMON_TOOLCHAIN[key]
                                                             for key in ("sdk", "sdk_build", "sdk_settings")})
        self.assertEqual(identity["sdk_role"], "wrapper-selected")
        for field in ("sdk", "sdk_build", "sdk_settings"):
            self.assertEqual(identity[field], identity[f"xcode_{field}"])
        self.assertNotIn("effective_sdk", identity)

    def test_missing_invalid_and_unreadable_xcode_sdk_metadata_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = root / "SDKSettings.json"
            system = root / "System/Library/CoreServices/SystemVersion.plist"
            system.parent.mkdir(parents=True)
            system.write_bytes(plistlib.dumps({"ProductBuildVersion": "26A425"}))

            def read_sdk(path):
                return sdk_identity(root) if path == "/selected/xcode-sdk" else {
                    key: COMMON_TOOLCHAIN[key] for key in ("sdk", "sdk_build", "sdk_settings")}

            for contents in (None, "not-json", '{"Version":"unknown"}', '{"Version":"27.0"}'):
                with self.subTest(contents=contents):
                    if contents is None:
                        self.assertFalse(settings.exists())
                    else:
                        settings.write_text(contents)
                    if contents == '{"Version":"27.0"}':
                        system.write_bytes(plistlib.dumps({"ProductBuildVersion": "invalid build"}))
                    with self.assertRaises((OSError, ValueError)):
                        toolchain_identity("swift", Path.cwd(), probe=self.probe, environment={}, machine="arm64",
                                           read_sdk=read_sdk)

    def test_failed_xcode_sdk_probe_does_not_fall_back_to_wrapper_sdk(self):
        def probe(arguments, root):
            if arguments[0] == "env":
                raise ValueError("Xcode SDK lookup failed")
            return self.probe(arguments, root)

        with self.assertRaises(ValueError):
            toolchain_identity("swift", Path.cwd(), probe=probe, environment={}, machine="arm64",
                               read_sdk=lambda path: {key: COMMON_TOOLCHAIN[key]
                                                      for key in ("sdk", "sdk_build", "sdk_settings")})

    def test_selected_sdk_metadata_build_and_settings_have_content_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            (sdk / "SDKSettings.json").write_text('{"Version":"26.5","CanonicalName":"macosx26.5"}')
            system = sdk / "System/Library/CoreServices/SystemVersion.plist"
            system.parent.mkdir(parents=True)
            system.write_bytes(plistlib.dumps({"ProductBuildVersion": "25F70"}))
            before = sdk_identity(sdk)
            self.assertEqual(before["sdk"], "26.5")
            self.assertEqual(before["sdk_build"], "25F70")
            (sdk / "SDKSettings.json").write_text('{"Version":"26.5","CanonicalName":"changed"}')
            self.assertNotEqual(before["sdk_settings"], sdk_identity(sdk)["sdk_settings"])
            system.write_bytes(plistlib.dumps({"ProductBuildVersion": "25F71"}))
            self.assertNotEqual(before["sdk_build"], sdk_identity(sdk)["sdk_build"])


class RustCacheWorkflowTests(unittest.TestCase):
    @staticmethod
    def workflow():
        return (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text()

    @staticmethod
    def step(workflow, name):
        matches = re.findall(r"(?m)^      - name: " + re.escape(name) + r"\n.*?(?=^      - name: |^  [a-z_]+:|\Z)",
                             workflow, re.DOTALL)
        if len(matches) != 1:
            raise AssertionError(f"Expected one workflow step named {name}")
        return matches[0]

    @staticmethod
    def cache_field(step, name):
        matches = re.findall(r"(?m)^          " + re.escape(name) + r": (.+)$", step)
        if len(matches) != 1:
            raise AssertionError(f"Expected one cache {name}")
        return matches[0]

    def assert_rust_cache_linkage(self, workflow):
        identify = self.step(workflow, "Identify Rust cache compatibility")
        self.assertIn("ci_cache_keys.py rust", identify)
        self.assertIn('--github-env "$GITHUB_ENV"', identify)
        debug = self.step(workflow, "Restore Rust verification products")
        prefix = ("macos-rust-debug-lean-v3-${{ runner.arch }}-${{ env.RUST_DEBUG_TOOLCHAIN_KEY }}-"
                  "${{ env.RUST_CACHE_TRANSFER_KEY }}-${{ hashFiles('Backend/spotty-playback/Cargo.lock') }}-")
        self.assertEqual(self.cache_field(debug, "key"), prefix + "${{ github.sha }}")
        self.assertEqual(self.cache_field(debug, "restore-keys"), prefix)
        release = self.step(workflow, "Restore Rust release build products")
        self.assertEqual(self.cache_field(release, "key"),
                         "${{ env.RUST_RELEASE_COMPATIBILITY_KEY }}-${{ env.PLAYBACK_INPUT_DIGEST }}")
        self.assertEqual(self.cache_field(release, "restore-keys"), "${{ env.RUST_RELEASE_COMPATIBILITY_KEY }}-")

    def test_actual_workflow_uses_only_new_compatible_families(self):
        self.assert_rust_cache_linkage(self.workflow())

    def test_old_family_missing_transfer_identity_and_broad_fallbacks_are_rejected(self):
        workflow = self.workflow()
        mutations = (
            workflow.replace("macos-rust-debug-lean-v3-", "macos-rust-debug-lean-v2-"),
            workflow.replace("${{ env.RUST_CACHE_TRANSFER_KEY }}-", ""),
            workflow.replace('--github-env "$GITHUB_ENV" --report "$RUNNER_TEMP/spotty-timings/toolchain.json"',
                             '--report "$RUNNER_TEMP/spotty-timings/toolchain.json"'),
            workflow.replace("restore-keys: ${{ env.RUST_RELEASE_COMPATIBILITY_KEY }}-",
                             "restore-keys: macos-rust-release-"),
        )
        for index, changed in enumerate(mutations):
            with self.subTest(mutation=index), self.assertRaises(AssertionError):
                self.assert_rust_cache_linkage(changed)


if __name__ == "__main__":
    unittest.main()
