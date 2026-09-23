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


ROOT = Path(__file__).resolve().parents[1]


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
        self.log = self.root / "commands.jsonl"
        stub = f"""#!{sys.executable}
import json, os, sys
if sys.argv[1:] == ['test', '--help-hidden']:
    print('--event-stream-output-path')
    raise SystemExit(0)
with open(os.environ['VERIFY_TEST_LOG'], 'a') as log:
    log.write(json.dumps({{'command': sys.argv, 'cwd': os.getcwd(),
                         'scope': os.environ.get('SPOTTY_CHECK_SCOPE'),
                         'harness': os.environ.get('SPOTTY_BUILD_BROWSING_HARNESS')}}) + '\\n')
raise SystemExit(int(os.environ.get('VERIFY_TEST_STATUS', '0')))
"""
        for relative in (
            "Scripts/check.sh", "Scripts/check-clean.sh", "Scripts/check-source-policy.sh",
            "Scripts/script_tests.py", "swift",
        ):
            tool = self.root / relative
            tool.write_text(stub)
            tool.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
            "VERIFY_TEST_LOG": str(self.log),
            "SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR": str(self.root / "diagnostics"),
            "SPOTTY_CHECK_SCOPE": "rust-compiled",
        }

    def invoke(self, *arguments):
        result = subprocess.run(
            [sys.executable, str(self.command), *arguments],
            cwd=self.root.parent, env=self.environment, capture_output=True, text=True, timeout=10,
        )
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_gates_delegate_without_narrowing_the_full_or_clean_gate(self):
        for action, script, scope in (
            ("check", "check.sh", "full"), ("swift", "check.sh", "swift"),
            ("rust", "check.sh", "rust"), ("clean", "check-clean.sh", "full"),
            ("source", "check-source-policy.sh", "rust-compiled"),
        ):
            with self.subTest(action=action):
                self.log.unlink(missing_ok=True)
                result, calls = self.invoke(action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [{
                    "command": [str(self.root / "Scripts" / script)], "cwd": str(self.root),
                    "scope": scope, "harness": self.environment.get("SPOTTY_BUILD_BROWSING_HARNESS"),
                }])

    def test_discovery_uses_swiftpm_with_all_test_targets(self):
        result, calls = self.invoke("list", "--skip-build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0]["command"][1:], [
            "test", "list", "--disable-sandbox", "--package-path", str(self.root), "--skip-build",
        ])
        self.assertEqual(calls[0]["harness"], "1")

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

    def test_focused_failure_preserves_filter_status_command_and_native_artifacts(self):
        self.environment["VERIFY_TEST_STATUS"] = "17"
        selected = "ExampleTests/test example.*"
        result, calls = self.invoke("test", "--filter", selected)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(calls[0]["command"][1:9], [
            "test", "--no-parallel", "--disable-sandbox", "--package-path", str(self.root),
            "--filter", selected, "--event-stream-output-path",
        ])
        diagnostics = self.root / "diagnostics"
        self.assertIn(str(diagnostics), result.stdout)
        self.assertIn(shlex.quote(selected), result.stderr)
        self.assertIn("Failed delegated command (exit 17)", result.stderr)
        self.assertIn("status=17", (diagnostics / "focused-repeat-1.log").read_text())

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
