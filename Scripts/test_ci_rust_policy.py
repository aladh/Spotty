"""Exercise Rust PR selection and the aggregate gate without any compiler toolchain."""

from functools import lru_cache
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from ci_rust_policy import verification_needed

ROOT = Path(__file__).resolve().parent.parent


@lru_cache(maxsize=1)
def workflow_jobs():
    # Parse the real YAML: a final run block must not swallow the following job.
    return json.loads(subprocess.check_output([
        "ruby", "-ryaml", "-rjson", "-e",
        "puts JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true).fetch('jobs'))",
        str(ROOT / ".github/workflows/ci.yml")], text=True))


def workflow_script(step_name):
    matches = [step for job in workflow_jobs().values() for step in job.get("steps", [])
               if step.get("name") == step_name]
    if len(matches) != 1 or not isinstance(matches[0].get("run"), str):
        raise AssertionError(f"Expected one executable CI step named {step_name!r}")
    return matches[0]["run"]


class RustSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spotty-rust-scope-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("remote", "add", "origin", str(self.root))
        self.write("Backend/spotty-playback/src/lib.rs", "// existing unpublished engine\n")
        self.write("Sources/Spotty/View.swift", "// app\n")
        self.write("Scripts/ci_rust_policy.py", (ROOT / "Scripts/ci_rust_policy.py").read_text())
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def write(self, name, body="changed\n"):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")
        return self.git("rev-parse", "HEAD")

    def test_app_pin_tests_assets_and_docs_skip_rust(self):
        for name in ('Sources/Spotty/View.swift', 'Package.swift', 'Assets/icon.png', 'README.md'):
            self.write(name)
        self.commit()
        self.assertEqual(verification_needed("pull_request", self.base, self.root),
                         {"rust_needed": False, "macos_needed": True})

    def test_documentation_and_nested_agent_guidance_skip_both_toolchains(self):
        for name in ('README.md', 'Backend/spotty-playback/AGENTS.md', 'docs/images/overview.png'):
            self.write(name)
        self.commit()
        self.assertEqual(verification_needed("pull_request", self.base, self.root),
                         {"rust_needed": False, "macos_needed": False})
        (self.root / "runner-temp").mkdir()
        result, output = self.select_via_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "rust_needed=false\nmacos_needed=false\n")

    def test_mixed_harness_and_engine_changes_keep_both_toolchains(self):
        self.write("Tests/BrowsingHarness/demo.json")
        self.write("Scripts/test_harness_trace_summary.py")
        self.write("Backend/spotty-playback/src/lib.rs")
        self.commit()
        self.assertEqual(verification_needed("pull_request", self.base, self.root),
                         {"rust_needed": True, "macos_needed": True})

    def test_mixed_docs_and_app_change_keeps_macos(self):
        self.write("Tests/AGENTS.md")
        self.write("Sources/Spotty/View.swift")
        self.commit()
        self.assertEqual(verification_needed("pull_request", self.base, self.root),
                         {"rust_needed": False, "macos_needed": True})

    def test_rename_engine_into_documentation_keeps_both_toolchains(self):
        (self.root / "Backend/spotty-playback/src/lib.rs").rename(self.root / "AGENTS.md")
        self.commit()
        self.assertEqual(verification_needed("pull_request", self.base, self.root),
                         {"rust_needed": True, "macos_needed": True})

    def test_unknown_documentation_extension_keeps_macos(self):
        self.write("docs/generator.py")
        self.commit()
        self.assertTrue(verification_needed("pull_request", self.base, self.root)["macos_needed"])

    def test_legacy_base_policy_without_macos_output_remains_supported(self):
        self.write("Scripts/ci_rust_policy.py", 'print("rust_needed=false")\n')
        self.base = self.commit()
        self.write("Tests/AGENTS.md")
        self.commit()
        (self.root / "runner-temp").mkdir()
        result, output = self.select_via_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "rust_needed=false\n")
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("macos_needed: ${{ steps.rust-scope.outputs.macos_needed != 'false' }}", workflow)

    def test_deletion_and_rename_out_of_engine_scope_run_rust(self):
        source = self.root / "Backend/spotty-playback/src/lib.rs"
        source.rename(self.root / "docs-renamed.rs")
        self.commit()
        self.assertTrue(verification_needed("pull_request", self.base, self.root)["rust_needed"])
        # Repeat with an app destination: rename detection must not hide the old engine path.
        self.git("reset", "--hard", self.base)
        source.rename(self.root / "Sources/Spotty/renamed.swift")
        self.commit()
        self.assertTrue(verification_needed("pull_request", self.base, self.root)["rust_needed"])
        self.git("reset", "--hard", self.base)
        source.unlink()
        self.commit()
        self.assertTrue(verification_needed("pull_request", self.base, self.root)["rust_needed"])
        self.git("reset", "--hard", self.base)
        harness = self.root / "Tests/BrowsingHarness/renamed.swift"
        harness.parent.mkdir(parents=True)
        source.rename(harness)
        self.commit()
        self.assertTrue(verification_needed("pull_request", self.base, self.root)["rust_needed"])

    def test_filename_newline_does_not_hide_unknown_path(self):
        self.write("README.md\nSources/Spotty/View.swift")
        self.commit()
        self.assertTrue(verification_needed("pull_request", self.base, self.root)["rust_needed"])

    def test_undecodable_filename_is_conservatively_classified(self):
        # Build the Git entry directly: macOS filesystems reject non-UTF-8 names that
        # can arrive in a tree committed on Linux. Classification reads the tree diff.
        blob = self.git("hash-object", "-w", "Scripts/ci_rust_policy.py")
        subprocess.run(["git", "update-index", "-z", "--index-info"], cwd=self.root, check=True,
                       input=f"100644 {blob}\t".encode() + b"unknown-\xff\0")
        self.git("commit", "-qm", "Non-UTF-8 filename")
        self.assertEqual(verification_needed("pull_request", self.base, self.root),
                         {"rust_needed": True, "macos_needed": True})

    def select_via_workflow(self):
        script = workflow_script("Select Rust verification")
        output = self.root / "selection-output"
        output.unlink(missing_ok=True)
        result = subprocess.run(["bash", "-c", script], cwd=self.root, capture_output=True, text=True,
                                env={**os.environ, "EVENT_NAME": "pull_request", "INPUT_BASE_SHA": self.base,
                                     "GITHUB_OUTPUT": str(output), "RUNNER_TEMP": str(self.root / "runner-temp")})
        return result, output.read_text() if output.exists() else ""

    def test_workflow_uses_base_policy_instead_of_changed_head_code(self):
        (self.root / "runner-temp").mkdir()
        self.write("Backend/spotty-playback/src/lib.rs", "// changed engine\n")
        self.write("Scripts/ci_rust_policy.py", 'print("rust_needed=false")\n')
        self.commit()
        result, output = self.select_via_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "rust_needed=true\nmacos_needed=true\n")

    def test_workflow_without_a_base_policy_requires_rust(self):
        (self.root / "Scripts/ci_rust_policy.py").unlink()
        self.base = self.commit()
        self.write("Sources/Spotty/View.swift", "// changed app\n")
        self.commit()
        result, output = self.select_via_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "rust_needed=true\nmacos_needed=true\n")

    def test_workflow_skips_app_only_changes_with_existing_base_policy(self):
        (self.root / "runner-temp").mkdir()
        self.write("Sources/Spotty/View.swift", "// changed app\n")
        self.commit()
        result, output = self.select_via_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "rust_needed=false\nmacos_needed=true\n")

    def test_unavailable_pr_history_and_failed_diff_fail_closed(self):
        with self.assertRaises(subprocess.CalledProcessError):
            verification_needed("pull_request", "f" * 40, self.root)
        with patch("ci_rust_policy.subprocess.check_output", side_effect=subprocess.CalledProcessError(128, "git diff")):
            with self.assertRaises(subprocess.CalledProcessError):
                verification_needed("pull_request", self.base, self.root)["rust_needed"]


class ParallelWorkflowTests(unittest.TestCase):
    def test_parallel_verification_and_serial_cache_publication_keep_one_required_check(self):
        jobs = workflow_jobs()
        verify = {"macos_engine", "macos_contracts", "macos_swift", "macos_release"}
        self.assertEqual({key for key, job in jobs.items() if job["runs-on"].startswith("macos-")},
                         verify | {"cache_publisher"})
        for key in verify:
            self.assertEqual(jobs[key]["needs"], ["policy"], key)
        quality = {"policy", "domain_linux", "playback_python"} | verify
        self.assertEqual(set(jobs["quality_gate"]["needs"]), quality)
        self.assertEqual(set(jobs["cache_publisher"]["needs"]), verify | {"quality_gate"})
        self.assertEqual(set(jobs["macos"]["needs"]), {"quality_gate", "cache_publisher"})
        self.assertEqual(jobs["macos"]["name"], "macOS checks")
        self.assertEqual(jobs["macos"]["runs-on"], "ubuntu-latest")
        self.assertIn("github.ref == 'refs/heads/main'", jobs["cache_publisher"]["if"])
        saves = [(key, step) for key, job in jobs.items() for step in job.get("steps", [])
                 if step.get("uses", "").startswith("actions/cache/save@")]
        self.assertEqual(len(saves), 6)
        self.assertTrue(all(key == "cache_publisher" for key, _ in saves))

    def test_swift_consumers_remain_independent_of_engine_producer(self):
        jobs = workflow_jobs()
        debug = workflow_script("Run checks").strip()
        normal_debug = "SPOTTY_CHECK_SCOPE=swift-compiled SPOTTY_CHECK_PHASE=tests ./Scripts/check.sh"
        self.assertEqual(debug.count(normal_debug), 1)
        self.assertIn(f"false) {normal_debug} ;;", debug)
        self.assertIn("-- ./Scripts/check.sh", debug)
        expected = {
            "macos_contracts": "SPOTTY_CHECK_SCOPE=swift-compiled SPOTTY_CHECK_PHASE=contracts ./Scripts/check.sh",
            "macos_swift": debug,
            "macos_release": "./Scripts/compile-release-spotty.sh",
            "macos_engine": "SPOTTY_CHECK_SCOPE=rust-compiled ./Scripts/check.sh",
        }
        all_commands = [step.get("run", "").strip() for job in jobs.values() for step in job.get("steps", [])]
        for key, command in expected.items():
            self.assertEqual(all_commands.count(command), 1)
            self.assertIn(command, [step.get("run", "").strip() for step in jobs[key]["steps"]])
        self.assertIn("--corpus all", workflow_script("Run acceptance scenarios"))
        self.assertIn("candidate_needed == 'true'", next(
            step["if"] for step in jobs["macos_engine"]["steps"] if step.get("id") == "candidate_build"))


class CheckScopeOwnershipTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        scripts = self.root / "Scripts"
        scripts.mkdir()
        script = (ROOT / "Scripts/check.sh").read_text()
        # Scope routing is Bash-compatible; the policy job needs no zsh or compiler.
        root_assignment = 'project_root="${0:A:h:h}"'
        self.assertEqual(script.count(root_assignment), 1)
        print_fixture = 'print() { printf "%s\\n" "$*" >&2; }\n'
        (scripts / "check.sh").write_text(print_fixture + script.replace(root_assignment, 'project_root="$PWD"'))
        shutil.copy(ROOT / "Scripts/ci-timings.sh", scripts)
        for name in ("swiftpm-env.sh", "playback-xcframework.sh"):
            (scripts / name).write_text("# Toolchain-free scope fixture\n")
        (scripts / "script_tests.py").write_text(
            'import os, sys\nprint(sys.argv[1])\n'
            'sys.exit(73 if sys.argv[1] == os.environ.get("SPOTTY_FAIL_HELPER") else 0)\n')
        for name, status in (("check-source-policy.sh", 0), ("generate-c-header.sh", 74),
                             ("format-swift-self-test.sh", 0), ("format-swift.sh", 75)):
            path = scripts / name
            path.write_text(f'#!/bin/sh\necho "{name}"\nexit {status}\n')
            path.chmod(0o755)

    def run_scope(self, scope, failing_helper="", phase="all"):
        return subprocess.run(["bash", str(self.root / "Scripts/check.sh")], cwd=self.root,
                              capture_output=True, text=True,
                              env={**os.environ, "SPOTTY_CHECK_SCOPE": scope, "SPOTTY_FAIL_HELPER": failing_helper,
                                   "SPOTTY_BUILD_CONFIGURATION": "debug", "SPOTTY_CHECK_PHASE": phase})

    def test_harness_failure_stops_normal_scopes_before_compilation(self):
        for scope in ("full", "swift", "rust", "rust-compiled", "swift-compiled"):
            with self.subTest(scope=scope):
                result = self.run_scope(scope, failing_helper="harness")
                status = {"rust-compiled": 74, "swift-compiled": 75}.get(scope, 73)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual("harness" in result.stdout, status == 73)

    def test_only_ci_scopes_omit_portable_checks_and_swift_still_checks_format(self):
        expected = {
            "full": ["check-source-policy.sh", "harness", "watchdog", "format-swift-self-test.sh", "format-swift.sh"],
            "swift": ["harness", "watchdog", "format-swift-self-test.sh", "format-swift.sh"],
            "swift-compiled": ["format-swift.sh"],
            "rust": ["harness", "playback", "generate-c-header.sh"],
            "rust-compiled": ["generate-c-header.sh"],
        }
        for scope, commands in expected.items():
            with self.subTest(scope=scope):
                result = self.run_scope(scope)
                self.assertEqual(result.returncode, 74 if scope.startswith("rust") else 75, result.stderr)
                self.assertEqual(result.stdout.splitlines(), commands)

    def test_partitioned_phases_are_rejected_outside_explicit_ci_scope(self):
        for scope in ("full", "swift", "rust", "rust-compiled"):
            for phase in ("contracts", "tests", "unknown"):
                with self.subTest(scope=scope, phase=phase):
                    result = self.run_scope(scope, phase=phase)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stdout, "")
        result = self.run_scope("swift-compiled", phase="contracts")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["format-swift.sh"])
        result = self.run_scope("swift-compiled", phase="tests")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("format-swift.sh", result.stdout)
        self.assertNotIn("harness", result.stdout)

    def test_playback_source_checks_run_once_and_only_ci_compiled_scope_skips_them(self):
        script = (ROOT / "Scripts/check.sh").read_text()
        python_check = 'python3 -B "$project_root/Scripts/script_tests.py" playback'
        header_check = '"$project_root/Scripts/generate-c-header.sh" --check'
        scope_start = script.index('if [[ "$check_scope" != swift && "$check_scope" != swift-compiled ]]; then')
        python_guard = script.index('if [[ "$check_scope" != rust-compiled ]]; then', scope_start)
        rust_exit = script.index('if [[ "$check_scope" == rust || "$check_scope" == rust-compiled ]]; then', scope_start)

        self.assertEqual(script.count(python_check), 1)
        self.assertEqual(script.count(header_check), 1)
        self.assertIn("full|rust|rust-compiled|swift", script)
        self.assertLess(scope_start, python_guard)
        self.assertLess(python_guard, script.index(python_check))
        self.assertLess(script.index(python_check), script.index(header_check))
        self.assertLess(script.index(header_check), rust_exit)


class SelectionValidationTests(unittest.TestCase):
    def test_only_consistent_boolean_selections_or_legacy_output_are_accepted(self):
        script = workflow_script("Validate verification selection")
        for rust in ("true", "false", "", "invalid"):
            for macos in ("true", "false", "", "invalid"):
                with self.subTest(rust=rust, macos=macos):
                    result = subprocess.run(["bash", "-c", script], capture_output=True,
                                            env={**os.environ, "RUST_NEEDED": rust, "MACOS_NEEDED": macos})
                    expected = (rust, macos) in (("true", "true"), ("false", "true"),
                                                ("false", "false"), ("true", ""), ("false", ""))
                    self.assertEqual(result.returncode == 0, expected)


class CbindgenCacheTests(unittest.TestCase):
    def test_verified_binary_reuse_and_missing_or_wrong_version_repair(self):
        script = workflow_script("Install pinned cbindgen")
        for cached in (None, "0.29.3", "0.29.4"):
            with self.subTest(cached=cached), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary = root / "spotty-cbindgen/bin/cbindgen"
                binary.parent.mkdir(parents=True)
                if cached:
                    binary.write_text(f'#!/bin/sh\necho "cbindgen {cached}"\n')
                    binary.chmod(0o755)
                cargo = root / "cargo"
                cargo.write_text('''#!/bin/sh
set -eu
echo invoked >> "$RUNNER_TEMP/cargo-calls"
printf '#!/bin/sh\\necho "cbindgen %s"\\n' "$CBINDGEN_VERSION" > "$RUNNER_TEMP/spotty-cbindgen/bin/cbindgen"
chmod +x "$RUNNER_TEMP/spotty-cbindgen/bin/cbindgen"
''')
                cargo.chmod(0o755)
                env = {**os.environ, "PATH": f"{root}:/usr/bin:/bin", "RUNNER_TEMP": str(root),
                       "CBINDGEN_VERSION": "0.29.4", "GITHUB_PATH": str(root / "github-path")}
                result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((root / "cargo-calls").exists(), cached != "0.29.4")
                self.assertEqual((root / "github-path").read_text(), str(binary.parent) + "\n")


class AggregateGateTests(unittest.TestCase):
    @staticmethod
    def execute(name, outcomes):
        return subprocess.run(["bash", "-e", "-c", workflow_script(name)], capture_output=True,
                              text=True, env={**os.environ, **outcomes})

    @staticmethod
    def valid_quality_outcomes():
        portable = {"POLICY_RESULT": "success", "DOMAIN_LINUX_RESULT": "success", "PLAYBACK_PYTHON_RESULT": "success"}
        absent_engine = {"RUST_NEEDED": "false", "ENGINE_RESULT": "skipped", "RUST_RESULT": "",
                         "CANDIDATE_SELECTION_RESULT": "", "CANDIDATE_NEEDED": "",
                         "CANDIDATE_BUILD_RESULT": "", "CANDIDATE_UPLOAD_RESULT": ""}
        swift = {"MACOS_NEEDED": "true", "CONTRACTS_RESULT": "success", "SWIFT_RESULT": "success", "RELEASE_RESULT": "success"}
        docs = {"MACOS_NEEDED": "false", "CONTRACTS_RESULT": "skipped", "SWIFT_RESULT": "skipped", "RELEASE_RESULT": "skipped"}
        engine = {"RUST_NEEDED": "true", "ENGINE_RESULT": "success", "RUST_RESULT": "success",
                  "CANDIDATE_SELECTION_RESULT": "success"}
        candidate = {"CANDIDATE_NEEDED": "true", "CANDIDATE_BUILD_RESULT": "success", "CANDIDATE_UPLOAD_RESULT": "success"}
        no_candidate = {"CANDIDATE_NEEDED": "false", "CANDIDATE_BUILD_RESULT": "skipped", "CANDIDATE_UPLOAD_RESULT": "skipped"}
        return [
            {**portable, **absent_engine, **docs},
            {**portable, **absent_engine, **swift},
            {**portable, **swift, **engine, **candidate},
            {**portable, **swift, **engine, **no_candidate},
        ]

    def test_docs_app_and_both_engine_candidate_cases_pass_without_fabricated_skips(self):
        for outcomes in self.valid_quality_outcomes():
            with self.subTest(outcomes=outcomes):
                result = self.execute("Require every quality lane", outcomes)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_failed_cancelled_or_inconsistent_quality_results_fail_closed(self):
        valid = self.valid_quality_outcomes()
        for base in valid:
            for field in base:
                values = ("true", "false", "invalid", "") if field.endswith("NEEDED") else ("success", "skipped", "failure", "cancelled", "")
                for value in values:
                    mutated = {**base, field: value}
                    if mutated in valid:
                        continue
                    with self.subTest(base=base, field=field, value=value):
                        result = self.execute("Require every quality lane", mutated)
                        self.assertNotEqual(result.returncode, 0)

    def test_engine_only_selection_cannot_skip_swift_consumers(self):
        for engine in self.valid_quality_outcomes()[2:]:
            result = self.execute("Require every quality lane", {
                **engine, "MACOS_NEEDED": "false", "CONTRACTS_RESULT": "skipped",
                "SWIFT_RESULT": "skipped", "RELEASE_RESULT": "skipped"})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Invalid compiler verification selection", result.stderr)

    def test_engine_gate_requires_actual_rust_source_proof_selection_build_and_upload(self):
        valid = [
            {"RUST_RESULT": "success", "SOURCE_PROOF_RESULT": "success", "SELECTION_RESULT": "success", "CANDIDATE_NEEDED": "true", "BUILD_RESULT": "success", "UPLOAD_RESULT": "success"},
            {"RUST_RESULT": "success", "SOURCE_PROOF_RESULT": "success", "SELECTION_RESULT": "success", "CANDIDATE_NEEDED": "false", "BUILD_RESULT": "skipped", "UPLOAD_RESULT": "skipped"},
        ]
        for base in valid:
            self.assertEqual(self.execute("Require engine results", base).returncode, 0)
            without_proof = {field: value for field, value in base.items() if field != "SOURCE_PROOF_RESULT"}
            with patch.dict(os.environ):
                os.environ.pop("SOURCE_PROOF_RESULT", None)
                self.assertNotEqual(self.execute("Require engine results", without_proof).returncode, 0)
            for field in base:
                values = ("true", "false", "invalid", "") if field == "CANDIDATE_NEEDED" else ("success", "skipped", "failure", "cancelled", "")
                for value in values:
                    if value != base[field]:
                        with self.subTest(base=base, field=field, value=value):
                            self.assertNotEqual(self.execute("Require engine results", {**base, field: value}).returncode, 0)

    def test_swift_gate_requires_tests_and_complete_acceptance_evidence(self):
        required = {key: "success" for key in (
            "CHECKS_RESULT", "ACCEPTANCE_RESULT", "ACCEPTANCE_SUMMARY_RESULT", "ACCEPTANCE_UPLOAD_RESULT",
            "FOCUSED_SMOKE_RESULT", "SELECTION_UPLOAD_RESULT")}
        for requested, result in (("false", "skipped"), ("true", "success")):
            for host_requested, host_result in (("false", "skipped"), ("true", "success")):
                valid = {**required, "SELECTION_EXPERIMENT_REQUESTED": requested,
                         "SELECTION_EXPERIMENT_RESULT": result, "HOST_OBSERVATION_REQUESTED": host_requested,
                         "HOST_OBSERVATION_UPLOAD_RESULT": host_result}
                self.assertEqual(self.execute("Require Swift test evidence", valid).returncode, 0)
                for field in valid:
                    values = ("true", "false", "invalid", "") if field.endswith("REQUESTED") else (
                        "success", "skipped", "failure", "cancelled", "")
                    for value in values:
                        if value != valid[field]:
                            with self.subTest(requested=requested, host_requested=host_requested, field=field, value=value):
                                self.assertNotEqual(self.execute("Require Swift test evidence", {**valid, field: value}).returncode, 0)

    def test_required_check_accepts_only_verified_main_publication_or_explicit_pr_skip(self):
        valid = [
            {"QUALITY_RESULT": "success", "CACHE_RESULT": "success", "MAIN_REF": "refs/heads/main"},
            {"QUALITY_RESULT": "success", "CACHE_RESULT": "skipped", "MAIN_REF": "refs/pull/123/merge"},
            {"QUALITY_RESULT": "success", "CACHE_RESULT": "skipped", "MAIN_REF": "refs/pull/456/merge"},
        ]
        for base in valid:
            result = self.execute("Require completed verification and cache publication", base)
            self.assertEqual(result.returncode, 0, result.stderr)
            for field in ("QUALITY_RESULT", "CACHE_RESULT"):
                for value in ("success", "failure", "skipped", "cancelled", ""):
                    changed = {**base, field: value}
                    if changed not in valid:
                        with self.subTest(base=base, field=field, value=value):
                            self.assertNotEqual(self.execute("Require completed verification and cache publication", changed).returncode, 0)
        for ref in ("refs/heads/feature", "refs/tags/test", "", "refs/pull"):
            result = self.execute("Require completed verification and cache publication", {
                "QUALITY_RESULT": "success", "CACHE_RESULT": "skipped", "MAIN_REF": ref})
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
