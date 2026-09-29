"""Exercise focused command dispatch without a compiler, engine, or live account."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import verify

from verify import focused_graph
from verification_package import prepare


ROOT = Path(__file__).resolve().parents[1]


class FocusedGraphSelectionTests(unittest.TestCase):
    def test_selection_is_exact_and_does_not_interpret_other_tools_arguments(self):
        for arguments, expected in (
            (["--test-product", "SpottyGatewayTests"], "engine-free"),
            (["--test-product=SpottyCatalogStorageTests"], "engine-free"),
            (["--test-product=SpottyTestSupportTests"], "engine-free"),
            (["--test-product=SpottyDomainTests"], "domain"),
            (["--test-product=SpottyBoundaryTests"], "full"),
            (["--test-product", "Unknown"], "full"),
            (["--test-product"], "full"),
            (["--test-product="], "full"),
            (["--test-product", "SpottyGatewayTests", "--test-product=SpottyGatewayTests"], "full"),
            (["--test-product", "--test-product=SpottyGatewayTests"], "full"),
            (["--", "--test-product=SpottyGatewayTests"], "full"),
            (["-Xswiftc", "--test-product=SpottyGatewayTests"], "full"),
            (["-Xcc", "--test-product", "SpottyGatewayTests"], "full"),
            (["--filter", "--test-product=SpottyGatewayTests"], "full"),
            (["--test-product=SpottyGatewayTests", "-Xswiftc"], "full"),
            (["--test-product=SpottyGatewayTests", "--scratch-path=custom"], "full"),
            (["--package-path", "another", "--test-product=SpottyGatewayTests"], "full"),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(focused_graph(arguments), expected)


class VerificationRoutingTests(unittest.TestCase):
    """Exercise actual CLI decisions at its existing execution boundary, without a child toolchain."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="spotty verify ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "Package.swift").write_text("// synthetic manifest\n")
        for relative in ("Sources/SpottyDomain", "Tests/SpottyDomainTests"):
            (self.root / relative).mkdir(parents=True)
        self.environment = {
            **os.environ,
            "SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR": str(self.root / "diagnostics"),
            "SPOTTY_CHECK_SCOPE": "rust-compiled", "SPOTTY_PACKAGE_GRAPH": "engine-free",
        }
        self.environment.pop("CI", None)
        self.environment.pop("SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS", None)

    def invoke(self, *arguments, platform="darwin", environment=None):
        ambient = self.environment if environment is None else environment
        with mock.patch.object(verify, "ROOT", self.root), mock.patch.object(verify.sys, "platform", platform), \
                mock.patch.dict(os.environ, ambient, clear=True), mock.patch.object(verify, "run", return_value=17) as run:
            self.assertEqual(verify.main(list(arguments)), 17)
            self.assertEqual(dict(os.environ), ambient, "Planning cannot modify its caller's environment")
        run.assert_called_once()
        return run.call_args.args

    def test_gates_select_scope_without_narrowing_full_or_clean(self):
        for action, script, scope in (
            ("check", "check.sh", "full"), ("swift", "check.sh", "swift"),
            ("rust", "check.sh", "rust"), ("clean", "check-clean.sh", "full"),
            ("source", "check-source-policy.sh", "rust-compiled"),
        ):
            with self.subTest(action=action):
                command, environment, artifacts = self.invoke(action)
                self.assertEqual(command, [str(self.root / "Scripts" / script)])
                self.assertEqual(environment["SPOTTY_CHECK_SCOPE"], scope)
                self.assertEqual(environment["SPOTTY_PACKAGE_GRAPH"], "full")
                self.assertEqual(artifacts, self.root / "diagnostics" if action in ("check", "swift", "clean") else None)

    def test_named_products_forms_and_skip_build_share_the_isolated_workspace(self):
        for product, graph in (("SpottyGatewayTests", "engine-free"), ("SpottyCatalogStorageTests", "engine-free"),
                               ("SpottyTestSupportTests", "engine-free"), ("SpottyDomainTests", "domain")):
            for selection in (["--test-product", product], [f"--test-product={product}"]):
                for extra in ([], ["--skip-build"]):
                    with self.subTest(product=product, selection=selection, extra=extra):
                        arguments = [*selection, *extra, "--filter", "example with spaces.*", "-Xswiftc", "-O"]
                        command, environment, artifacts = self.invoke("test", *arguments)
                        self.assertEqual(command[:3], ["zsh", "-eu", "-c"])
                        # The override must run inside the SDK shell, which first resets ambient narrowing.
                        self.assertEqual(command[4:7], ["verify", "env", f"SPOTTY_PACKAGE_GRAPH={graph}"])
                        self.assertEqual(environment["SPOTTY_PACKAGE_GRAPH"], "full")
                        self.assertEqual(environment["SPOTTY_BUILD_BROWSING_HARNESS"], "0")
                        self.assertEqual(command[command.index("swift"):], [
                            "swift", "test", "--no-parallel", "--disable-sandbox", "--package-path",
                            str(self.root / ".build" / graph / "package"), *arguments,
                            "--scratch-path", str(self.root / ".build" / graph),
                        ])
                        self.assertIn("--require-tests", command)
                        self.assertEqual(artifacts, self.root / "diagnostics")
                        self.assertTrue((self.root / ".build" / graph / "package/Package.swift").is_symlink())

    def test_explicit_paths_discovery_and_ambiguous_products_keep_the_full_graph(self):
        cases = (
            ("test", ["--test-product=SpottyGatewayTests", "--scratch-path", "custom builds"]),
            ("test", ["--test-product", "SpottyGatewayTests", "--scratch-path=custom builds"]),
            ("test", ["--test-product", "SpottyGatewayTests", "--package-path", "another package"]),
            ("test", ["--test-product=SpottyGatewayTests", "--package-path=another package"]),
            ("list", ["--test-product=SpottyGatewayTests"]),
            ("test", ["--test-product=SpottyGatewayTests", "--list-tests"]),
            ("test", ["list", "--test-product=SpottyGatewayTests"]),
            ("test", ["--filter", "SpottyGatewayTests"]), ("test", []),
            ("test", ["--test-product", "Unknown"]),
            ("test", ["--test-product=SpottyGatewayTests", "--test-product=SpottyDomainTests"]),
            ("test", ["-Xswiftc", "--test-product=SpottyGatewayTests"]),
        )
        for platform in ("darwin", "linux"):
            for action, arguments in cases:
                with self.subTest(platform=platform, action=action, arguments=arguments):
                    command, environment, _ = self.invoke(action, *arguments, platform=platform)
                    self.assertEqual(environment["SPOTTY_PACKAGE_GRAPH"], "full")
                    self.assertEqual(environment["SPOTTY_BUILD_BROWSING_HARNESS"], "1")
                    self.assertNotIn("SPOTTY_PACKAGE_GRAPH=engine-free", command)
                    expected = ["swift", "test", "list" if action == "list" else "--no-parallel",
                                "--disable-sandbox", "--package-path", str(self.root), *arguments]
                    if platform != "darwin":
                        expected += ["-Xswiftc", "-warnings-as-errors"]
                    self.assertEqual(command[command.index("swift"):], expected)
        self.assertFalse((self.root / ".build").exists())

    def test_non_darwin_named_product_and_explicit_domain_keep_their_distinct_graphs(self):
        product, env, _ = self.invoke("test", "--test-product=SpottyGatewayTests", platform="linux")
        self.assertEqual(product[0], sys.executable)
        self.assertEqual(env["SPOTTY_PACKAGE_GRAPH"], "full")
        self.assertEqual(env["SPOTTY_BUILD_BROWSING_HARNESS"], "1")
        domain, env, _ = self.invoke("domain", "--configuration", "release", platform="linux")
        self.assertEqual(domain[:2], ["env", "SPOTTY_PACKAGE_GRAPH=domain"])
        self.assertEqual(env["SPOTTY_BUILD_BROWSING_HARNESS"], "0")
        self.assertEqual(domain[domain.index("swift"):], [
            "swift", "test", "--no-parallel", "--disable-sandbox", "--package-path",
            str(self.root / ".build/domain/package"), "--configuration", "release",
            "--scratch-path", str(self.root / ".build/domain"), "-Xswiftc", "-warnings-as-errors",
        ])

    def test_all_inspection_forms_omit_execution_requirement_and_automatic_isolation(self):
        for option in ("--help", "--help-hidden", "-h", "-help", "--version", "--list-tests", "-l",
                       "--show-codecov-path", "--show-code-coverage-path", "--show-coverage-path", "list", "last"):
            with self.subTest(option=option):
                command, environment, _ = self.invoke("test", option, "--test-product=SpottyGatewayTests")
                self.assertNotIn("--require-tests", command)
                self.assertIn(str(self.root / "Scripts/swift_test_watchdog.py"), command)
                self.assertEqual(environment["SPOTTY_BUILD_BROWSING_HARNESS"], "1")
                self.assertNotIn("SPOTTY_PACKAGE_GRAPH=engine-free", command)
        self.assertFalse((self.root / ".build").exists())

    def test_forwarded_inspection_words_do_not_disable_test_execution(self):
        for option in ("-Xswiftc", "-Xcc", "-Xcxx", "-Xlinker", "-Xbuild-tools-swiftc", "--filter", "--skip"):
            for value in ("--help", "--version", "--list-tests"):
                with self.subTest(option=option, value=value):
                    command, environment, _ = self.invoke("test", "--test-product=SpottyGatewayTests", option, value)
                    self.assertIn("--require-tests", command)
                    self.assertEqual(environment["SPOTTY_BUILD_BROWSING_HARNESS"], "0")
                    self.assertIn("SPOTTY_PACKAGE_GRAPH=engine-free", command)
                    swift = command[command.index("swift"):]
                    self.assertEqual(swift[swift.index(option) + 1], value)
        for option in ("--package-path", "--scratch-path", "--test-product"):
            with self.subTest(option=option):
                command, _, _ = self.invoke("test", option, "--help")
                self.assertIn("--require-tests", command)
        # The first separator belongs to verify; the second is forwarded to SwiftPM.
        command, _, _ = self.invoke("test", "--", "--", "--help")
        self.assertIn("--require-tests", command)
        self.assertEqual(command[-2:], ["--", "--help"])

    def test_top_level_inspection_still_wins_after_a_forwarded_operand(self):
        for option in ("-Xswiftc", "--filter", "--skip"):
            with self.subTest(option=option):
                command, _, _ = self.invoke("test", option, "literal", "--help")
                self.assertNotIn("--require-tests", command)

    def test_timeout_defaults_and_overrides_reach_the_watchdog_unchanged(self):
        for ci, override, expected in (("", None, "1200"), ("true", None, "300"), ("false", None, "300"),
                                       ("true", "", "300"), ("", "27.5", "27.5")):
            with self.subTest(ci=ci, override=override):
                environment = {**self.environment, "CI": ci}
                if override is not None:
                    environment["SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS"] = override
                command, _, _ = self.invoke("test", environment=environment)
                self.assertEqual(command[command.index("--timeout-seconds") + 1], expected)

    def test_relative_diagnostics_belong_to_the_invoking_directory(self):
        # main runs here, while the delegated executor runs at the disposable repository ROOT.
        relative = Path("relative diagnostics")
        command, environment, artifacts = self.invoke(
            "test", environment={**self.environment, "SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR": str(relative)})
        self.assertEqual(artifacts, relative.resolve())
        self.assertNotEqual(artifacts, self.root / relative)
        self.assertEqual(environment["SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR"], str(artifacts))
        self.assertEqual(command[command.index("--log-dir") + 1], str(artifacts))
        self.assertEqual(command[command.index("--event-stream-path") + 1], str(artifacts / "focused-repeat-1-events.jsonl"))


class VerificationCommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        scripts = self.root / "Scripts"
        scripts.mkdir()
        self.command = scripts / "verify.py"
        shutil.copy2(ROOT / "Scripts/verify.py", self.command)
        shutil.copy2(ROOT / "Scripts/swift_test_watchdog.py", scripts / "swift_test_watchdog.py")
        shutil.copy2(ROOT / "Scripts/swiftpm-env.sh", scripts / "swiftpm-env.sh")
        shutil.copy2(ROOT / "Scripts/verification_package.py", scripts / "verification_package.py")
        (self.root / "Package.swift").write_text("// synthetic manifest\n")
        for relative in ("Sources/SpottyDomain", "Tests/SpottyDomainTests"):
            (self.root / relative).mkdir(parents=True)
        self.log = self.root / "commands.jsonl"
        stub = f"""#!{sys.executable}
import json, os, sys
if sys.argv[1:] == ['test', '--help-hidden']:
    print('--event-stream-output-path')
    raise SystemExit(0)
with open(os.environ['VERIFY_TEST_LOG'], 'a') as log:
    entry = {{'command': sys.argv, 'cwd': os.getcwd(),
              'scope': os.environ.get('SPOTTY_CHECK_SCOPE'),
              'graph': os.environ.get('SPOTTY_PACKAGE_GRAPH'),
              'harness': os.environ.get('SPOTTY_BUILD_BROWSING_HARNESS')}}
    if os.path.basename(sys.argv[0]) == 'swift':
        entry['build_environment'] = {{name: os.environ.get(name) for name in (
            'SDKROOT', 'CLANG_MODULE_CACHE_PATH', 'SWIFTPM_MODULECACHE_OVERRIDE')}}
    log.write(json.dumps(entry) + '\\n')
if os.path.basename(sys.argv[0]) == 'swift':
    print(os.environ.get('VERIFY_TEST_SUMMARY', '✔ Test example() passed after 0.001 seconds.'))
raise SystemExit(int(os.environ.get('VERIFY_TEST_STATUS', '0')))
"""
        for relative in (
            "Scripts/check.sh", "Scripts/check-clean.sh", "Scripts/check-source-policy.sh",
            "Scripts/script_tests.py", "swift",
        ):
            tool = self.root / relative
            tool.write_text(stub)
            tool.chmod(0o755)
        xcrun = self.root / "xcrun"
        xcrun.write_text(f"#!{sys.executable}\nprint({str(self.root / 'MacOSX.sdk')!r})\n")
        xcrun.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
            "VERIFY_TEST_LOG": str(self.log),
            "SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR": str(self.root / "diagnostics"),
            "SPOTTY_CHECK_SCOPE": "rust-compiled",
            "SPOTTY_PACKAGE_GRAPH": "engine-free",
        }

    def invoke(self, *arguments):
        result = subprocess.run(
            [sys.executable, str(self.command), *arguments],
            cwd=self.root.parent, env=self.environment, capture_output=True, text=True, timeout=10,
        )
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_discovery_uses_swiftpm_with_all_test_targets(self):
        result, calls = self.invoke("list", "--skip-build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0]["command"][1:], [
            "test", "list", "--disable-sandbox", "--package-path", str(self.root), "--skip-build",
            "-Xswiftc", "-warnings-as-errors",
        ])
        self.assertEqual(calls[0]["harness"], "1")
        self.assertEqual(calls[0]["graph"], "full")

    @unittest.skipUnless(sys.platform == "darwin", "macOS adapter graph")
    def test_isolated_failure_and_empty_selection_preserve_diagnostics(self):
        for status, summary, expected in ((17, "failed", 17), (0, "No matching test cases were run", 1)):
            with self.subTest(status=status):
                self.log.unlink(missing_ok=True)
                self.environment.update(VERIFY_TEST_STATUS=str(status), VERIFY_TEST_SUMMARY=summary)
                result, calls = self.invoke("test", "--test-product=SpottyGatewayTests", "--filter", "Missing")
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(calls[0]["graph"], "engine-free")
                self.assertTrue((self.root / "diagnostics/focused-repeat-1.log").is_file())

    def test_engine_free_workspace_has_live_inputs_and_preserves_both_lockfiles(self):
        lockfile = self.root / "Package.resolved"
        lockfile.write_text("app dependency state")
        source = self.root / "Sources/SpottyDomain/Example.swift"
        package = prepare(self.root, "engine-free")
        (package / "Package.resolved").write_text("isolated dependency state")
        for content in ("original", "updated"):
            source.write_text(content)
            self.assertEqual(prepare(self.root, "engine-free"), package)
            for relative in ("Package.swift", "Sources", "Tests"):
                self.assertTrue((package / relative).is_symlink())
                self.assertFalse((package / relative).readlink().is_absolute())
                self.assertEqual((package / relative).resolve(), self.root / relative)
            self.assertEqual((package / "Sources/SpottyDomain/Example.swift").read_text(), content)
            self.assertEqual(lockfile.read_text(), "app dependency state")
            self.assertEqual((package / "Package.resolved").read_text(), "isolated dependency state")

    def test_isolated_workspace_rejects_wrong_links_and_existing_directories(self):
        for graph in ("domain", "engine-free"):
            package = self.root / ".build" / graph / "package"
            package.mkdir(parents=True)
            link = package / "Package.swift"
            link.symlink_to(self.root / "not-the-manifest")
            with self.assertRaisesRegex(ValueError, "Unexpected .* package link"):
                prepare(self.root, graph)
            self.assertEqual(link.readlink(), self.root / "not-the-manifest")
            link.unlink()
            link.mkdir()
            with self.assertRaisesRegex(ValueError, "Expected .* package symlink"):
                prepare(self.root, graph)
            self.assertTrue(link.is_dir())

    def test_domain_tests_isolate_the_graph_and_preserve_filter_failure_and_diagnostics(self):
        self.environment["VERIFY_TEST_STATUS"] = "17"
        result, calls = self.invoke("domain", "--configuration", "release", "--filter", "PlaybackReducer")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(calls[0]["graph"], "domain")
        self.assertEqual(calls[0]["harness"], "0")
        self.assertEqual(calls[0]["command"][1:12], [
            "test", "--no-parallel", "--disable-sandbox", "--package-path", str(self.root / ".build/domain/package"),
            "--configuration", "release", "--filter", "PlaybackReducer",
            "--scratch-path", str(self.root / ".build/domain"),
        ])
        self.assertIn("status=17", (self.root / "diagnostics/focused-repeat-1.log").read_text())

    def test_domain_workspace_links_live_inputs_without_copying_the_app_lockfile(self):
        lockfile = self.root / "Package.resolved"
        lockfile.write_text("app dependency state")
        source = self.root / "Sources/SpottyDomain/Example.swift"
        source.write_text("original")
        for content in ("original", "updated"):
            source.write_text(content)
            package = prepare(self.root, "domain")
            for relative in ("Package.swift", "Sources/SpottyDomain", "Tests/SpottyDomainTests"):
                self.assertTrue((package / relative).is_symlink())
                self.assertFalse((package / relative).readlink().is_absolute())
                self.assertEqual((package / relative).resolve(), self.root / relative)
            self.assertEqual((package / "Sources/SpottyDomain/Example.swift").read_text(), content)
            self.assertFalse((package / "Package.resolved").exists())
            self.assertEqual(lockfile.read_text(), "app dependency state")

    def test_domain_workspace_refuses_to_overwrite_unexpected_content(self):
        manifest = self.root / ".build/domain/package/Package.swift"
        manifest.parent.mkdir(parents=True)
        manifest.write_text("existing content")
        result, calls = self.invoke("domain")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertIn("Expected domain package symlink", result.stderr)
        self.assertEqual(manifest.read_text(), "existing content")

    def test_harness_delegates_to_existing_suite_and_preserves_failure(self):
        for status in (0, 17):
            with self.subTest(status=status):
                self.log.unlink(missing_ok=True)
                self.environment["VERIFY_TEST_STATUS"] = str(status)
                result, calls = self.invoke("harness")
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(calls[0]["command"], [
                    str(self.root / "Scripts/script_tests.py"), "harness",
                ])
                self.assertEqual(calls[0]["cwd"], str(self.root))
                self.assertEqual(len(calls), 1)
                self.assertFalse((self.root / "diagnostics").exists())
                if status:
                    self.assertIn("Failed delegated command (exit 17)", result.stderr)

    def test_focused_zero_test_success_is_rejected(self):
        self.environment["VERIFY_TEST_SUMMARY"] = "warning: No matching test cases were run"
        result, calls = self.invoke("test", "--filter", "MissingTests")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("no executed tests reported", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_forwarded_compiler_version_cannot_turn_zero_tests_into_success(self):
        self.environment["VERIFY_TEST_SUMMARY"] = "No matching test cases were run"
        result, calls = self.invoke("test", "-Xswiftc", "--version")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("no executed tests reported", result.stdout)

    def test_inspection_can_succeed_without_executing_tests(self):
        self.environment["VERIFY_TEST_SUMMARY"] = "Synthetic SwiftPM help or test listing"
        result, _ = self.invoke("test", "--help")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_focused_failure_preserves_filter_status_command_and_native_artifacts(self):
        self.environment["VERIFY_TEST_STATUS"] = "17"
        selected = "ExampleTests/test 'quotes' \"$HOME\"; $(printf expansion).*"
        result, calls = self.invoke("test", "--filter", selected)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(calls[0]["command"][1:11], [
            "test", "--no-parallel", "--disable-sandbox", "--package-path", str(self.root),
            "--filter", selected, "-Xswiftc", "-warnings-as-errors", "--event-stream-output-path",
        ])
        diagnostics = self.root / "diagnostics"
        self.assertIn(str(diagnostics), result.stdout)
        self.assertIn(shlex.quote(selected), result.stderr)
        self.assertIn("Failed delegated command (exit 17)", result.stderr)
        self.assertIn("status=17", (diagnostics / "focused-repeat-1.log").read_text())

    @unittest.skipUnless(sys.platform == "darwin", "macOS build settings")
    def test_focused_commands_share_the_gate_sdk_and_module_caches(self):
        for action in ("list", "test", "domain"):
            with self.subTest(action=action):
                self.log.unlink(missing_ok=True)
                result, calls = self.invoke(action)
                self.assertEqual(result.returncode, 0, result.stderr)
                sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
                self.assertEqual(calls[0]["build_environment"], {
                    "SDKROOT": str(sdk if sdk.is_dir() else self.root / "MacOSX.sdk"),
                    "CLANG_MODULE_CACHE_PATH": str(self.root / ".build/module-cache"),
                    "SWIFTPM_MODULECACHE_OVERRIDE": str(self.root / ".build/module-cache"),
                })

    @unittest.skipUnless(sys.platform == "darwin", "macOS build settings")
    def test_sdk_discovery_failure_does_not_run_swift(self):
        (self.root / "xcrun").write_text(f"#!{sys.executable}\nraise SystemExit(19)\n")
        result, calls = self.invoke("test", "--filter", "ExampleTests")
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(calls, [])

    def test_gate_failure_preserves_status_and_exact_delegated_command(self):
        self.environment["VERIFY_TEST_STATUS"] = "23"
        result, _ = self.invoke("rust")
        self.assertEqual(result.returncode, 23)
        self.assertIn("Failed delegated command (exit 23): env SPOTTY_CHECK_SCOPE=rust", result.stderr)
        self.assertIn(str(self.root / "Scripts/check.sh"), result.stderr)

    def test_missing_executable_is_reported(self):
        (self.root / "Scripts/check.sh").unlink()
        result, calls = self.invoke("rust")
        self.assertEqual(result.returncode, 127)
        self.assertEqual(calls, [])
        self.assertIn("Could not launch command", result.stderr)

    def test_help_and_invalid_gate_arguments_execute_nothing(self):
        for arguments, status in (((), 0), (("--help",), 0), (("rust", "--filter", "x"), 2)):
            with self.subTest(arguments=arguments):
                result, calls = self.invoke(*arguments)
                self.assertEqual(result.returncode, status)
                self.assertEqual(calls, [])

    def test_preflight_only_discovers_and_honors_tool_overrides(self):
        self.environment["SPOTTY_CBINDGEN"] = str(self.root / "absent-cbindgen")
        result, calls = self.invoke("preflight")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, [])
        self.assertIn("cbindgen: missing", result.stdout)
        self.assertIn("Discovery only", result.stdout)
        self.assertFalse((self.root / "diagnostics").exists())

    def test_preflight_resolves_override_paths_from_the_gate_working_directory(self):
        tools = self.root / "local tools"
        tools.mkdir()
        for name, variable in (
            ("cargo", "SPOTTY_CARGO"), ("cbindgen", "SPOTTY_CBINDGEN"),
            ("ast-grep", "SPOTTY_AST_GREP"),
        ):
            tool = tools / name
            shutil.copy2(self.root / "swift", tool)
            self.environment[variable] = str(tool.relative_to(self.root))
        result, calls = self.invoke("preflight")
        for name in ("cargo", "cbindgen", "ast-grep"):
            self.assertIn(f"{name}: {tools / name}", result.stdout)
        self.assertEqual(calls, [])

    def test_preflight_does_not_find_path_only_overrides_on_path(self):
        tools = self.root / "path-tools"
        tools.mkdir()
        for name, variable in (("cargo", "SPOTTY_CARGO"), ("cbindgen", "SPOTTY_CBINDGEN")):
            shutil.copy2(self.root / "swift", tools / name)
            self.environment[variable] = name
        self.environment["PATH"] = str(tools) + os.pathsep + self.environment["PATH"]
        result, calls = self.invoke("preflight")
        self.assertEqual(result.returncode, 1)
        self.assertIn("cargo: missing", result.stdout)
        self.assertIn("cbindgen: missing", result.stdout)
        self.assertEqual(calls, [])

    def test_preflight_resolves_relative_path_entries_from_the_repository(self):
        tools = self.root / "path-tools"
        tools.mkdir()
        for name, variable in (
            ("cargo", "SPOTTY_CARGO"), ("cbindgen", "SPOTTY_CBINDGEN"),
            ("ast-grep", "SPOTTY_AST_GREP"),
        ):
            shutil.copy2(self.root / "swift", tools / name)
            self.environment.pop(variable, None)
        self.environment["PATH"] = "path-tools"
        result, calls = self.invoke("preflight")
        for name in ("cargo", "cbindgen", "ast-grep"):
            self.assertIn(f"{name}: {tools / name}", result.stdout)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
