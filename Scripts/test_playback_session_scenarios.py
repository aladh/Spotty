"""Exercise the session runner with isolated fake tools; never build Swift or launch an app."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import textwrap
import unittest


SCRIPTS = Path(__file__).resolve().parent
TARGETS = [
    "SpottyDomainTests", "SpottyBoundaryTests", "SpottySessionRuntimeTests",
    "SpottyGatewayTests", "SpottyCatalogStorageTests", "SpottySessionTransportTests",
]
LIFECYCLE = {
    "version": 1, "deadlineMilliseconds": 125,
    "samples": [{"cooperativeMilliseconds": 0.25, "fencedNoncancelableMilliseconds": 126.0}],
}

FAKE_SWIFT = r'''
import json
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path.cwd()
arguments = sys.argv[1:]
with (root / ".fixture-calls.jsonl").open("a") as calls:
    calls.write(json.dumps(arguments) + "\n")
if arguments == ["--version"]:
    print("Swift version synthetic-fixture")
    sys.exit(0)
if not arguments or arguments[0] != "test":
    sys.exit("Unexpected swift operation")
config = json.loads((root / ".fixture-config.json").read_text())
xml = Path(arguments[arguments.index("--xunit-output") + 1])
number = int(xml.stem.split("-")[-1])
run = config["runs"][min(number - 1, len(config["runs"]) - 1)]
if "xml" in run:
    if run["xml"] is not None:
        xml.write_text(run["xml"])
else:
    def write_xml(path, cases, attributes=None):
        suites = ET.Element("testsuites")
        suite = ET.SubElement(suites, "testsuite", attributes or {})
        for item in cases:
            case = ET.SubElement(suite, "testcase", {
                "classname": item["suite"], "name": item.get("name", "syntheticCheck()"), "time": "0.001",
            })
            if item.get("status"):
                ET.SubElement(case, item["status"]).text = "synthetic diagnostic, not a source input"
        ET.ElementTree(suites).write(path, encoding="unicode")

    layout = run.get("xunitLayout", "split")
    if layout == "combined":
        write_xml(xml, run["cases"], run.get("suiteAttributes"))
    else:
        if layout != "swift-only":
            write_xml(xml, run.get("xctestCases", []))
        swift_xml = xml.with_name(xml.stem + "-swift-testing" + xml.suffix)
        write_xml(swift_xml, run["cases"], run.get("suiteAttributes"))
if run.get("lifecycle") is not None:
    report = Path(os.environ["SPOTTY_SWIFT_LIFECYCLE_REPORT"])
    value = run["lifecycle"]
    report.write_text(value if isinstance(value, str) else json.dumps(value))
for change in run.get("changes", []):
    path = root / change["path"]
    if change.get("delete"):
        path.unlink()
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(change["content"])
print("Synthetic test repetition " + str(number), flush=True)
sys.exit(run.get("exitCode", 0))
'''

FAKE_GIT = r'''
import json
import os
from pathlib import Path
import sys

root = Path.cwd()
if sys.argv[1:] == ["rev-parse", "HEAD"]:
    print("a" * 40)
elif sys.argv[1:] == ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]:
    names = set(json.loads((root / ".fixture-index.json").read_text()))
    for folder in ["Sources", "Tests", "Scripts", "script", "Backend", "Packaging", ".github"]:
        directory = root / folder
        if directory.exists() and not directory.is_symlink():
            names.update(str(path.relative_to(root)) for path in directory.rglob("*")
                         if not path.is_dir() or path.is_symlink())
    sys.stdout.buffer.write(b"".join(os.fsencode(name) + b"\0" for name in sorted(names)))
else:
    sys.exit("Unexpected git operation")
'''


@unittest.skipUnless(shutil.which("zsh"), "The macOS scenario entry point requires zsh")
class SessionScenarioRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory(prefix="spotty-session-runner-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.root = self.directory / "repository with spaces"
        self.root.mkdir()
        (self.root / "Scripts").mkdir()
        for script in ["check-session-scenarios.sh", "swiftpm-env.sh"]:
            shutil.copyfile(SCRIPTS / script, self.root / "Scripts" / script)
        (self.root / "Package.swift").write_text(
            'private let generatedPlaybackArtifactURL = "https://example.invalid/synthetic.zip"\n'
            + 'private let generatedPlaybackArtifactChecksum = "' + "b" * 64 + '"\n'
        )
        self.write_source("Sources/Runtime.swift", "let synthetic = 1\n")
        for index, target in enumerate(TARGETS):
            self.write_source(f"Tests/{target}/Checks.swift", self.suite_source(index))
        self.write_source("Tests/SpottyDomainTests/PlaybackReducerModelChecks.swift", """
for seed in UInt64(1)...UInt64(3) {
    if let violation = runModelTrace(seed: seed, steps: 50, commandHeavy: false) {}
}
for seed in UInt64(1_001)...UInt64(1_003) {
    if let violation = runModelTrace(seed: seed, steps: 25, commandHeavy: true) {}
}
""")
        # Keep deleted tracked files represented, while fake git discovers new source files.
        (self.root / ".fixture-index.json").write_text(json.dumps([
            str(path.relative_to(self.root)) for path in self.root.rglob("*") if path.is_file()
        ]))
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name, source in {
            "swift": FAKE_SWIFT,
            "git": FAKE_GIT,
            "xcrun": 'print("/synthetic-sdk-parent/MacOSX.sdk")\n',
        }.items():
            tool = self.bin / name
            tool.write_text("#!" + sys.executable + "\n" + textwrap.dedent(source))
            tool.chmod(0o755)

    @staticmethod
    def suite_source(index, display=None):
        return f'@Suite("{display or f"Synthetic suite {index}"}")\nstruct Checks{index} {{\n' + \
            '    @Test func syntheticCheck() {}\n}\n'

    def write_source(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_fixture(self, runs=None, *, repeats="1", arguments=(), environment=None):
        default = {"cases": [{"suite": target} for target in TARGETS], "lifecycle": LIFECYCLE}
        (self.root / ".fixture-config.json").write_text(json.dumps({
            "runs": [default | run for run in (runs or [{}])],
        }))
        env = dict(os.environ)
        for name in ["SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK", "SPOTTY_CHECK_REPEATS"]:
            env.pop(name, None)
        env.update({"PATH": str(self.bin) + os.pathsep + env["PATH"], "SPOTTY_CHECK_REPEATS": repeats})
        env.update(environment or {})
        before = set(self.root.glob(".build/session-scenarios/*/evidence.json"))
        result = subprocess.run(
            [shutil.which("zsh"), str(self.root / "Scripts/check-session-scenarios.sh"), *arguments],
            cwd=self.directory, env=env, capture_output=True, text=True, timeout=30,
        )
        paths = set(self.root.glob(".build/session-scenarios/*/evidence.json")) - before
        self.assertLessEqual(len(paths), 1, result.stdout + result.stderr)
        evidence = json.loads(next(iter(paths)).read_text()) if paths else None
        if evidence is not None:
            self.assertIsNotNone(evidence["finishedAt"])
            self.assertEqual(evidence["outcome"], "passed" if result.returncode == 0 else "failed")
            for run in evidence["runs"]:
                self.assertIn(run["outcome"], ["passed", "failed"])
                self.assertIsNotNone(run["finishedAt"])
        return result, evidence

    def calls(self):
        path = self.root / ".fixture-calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_success_runs_every_target_and_preserves_build_flags_and_evidence(self):
        result, evidence = self.run_fixture(repeats="2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence["expected"]["targets"], TARGETS)
        self.assertEqual(evidence["expected"]["repetitions"], 2)
        self.assertEqual(evidence["expected"]["generatedTraces"], [
            {"source": "Tests/SpottyDomainTests/PlaybackReducerModelChecks.swift",
             "seedRangeInclusive": [1, 3], "stepsPerSeed": 50, "commandHeavy": False},
            {"source": "Tests/SpottyDomainTests/PlaybackReducerModelChecks.swift",
             "seedRangeInclusive": [1001, 1003], "stepsPerSeed": 25, "commandHeavy": True},
        ])
        self.assertTrue(evidence["sourceUnchanged"])
        self.assertTrue(evidence["engineUnchanged"])
        self.assertEqual(evidence["engine"]["selection"], "pinned-remote")
        self.assertEqual(len(evidence["runs"]), 2)
        compatible_sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
        sdk = compatible_sdk if compatible_sdk.is_dir() else Path("/synthetic-sdk-parent/MacOSX.sdk")
        self.assertEqual(evidence["environment"]["sdk"], sdk.name)
        self.assertEqual(evidence["environment"]["sdkSelection"], "explicit-swiftpm-option")
        directory = self.root / ".build/session-scenarios" / evidence["runID"]
        for number, (run, command) in enumerate(zip(evidence["runs"], self.calls()[1:]), 1):
            self.assertEqual(run["repetition"], number)
            self.assertEqual(run["observed"]["counts"], {"passed": 6, "failed": 0, "skipped": 0})
            self.assertEqual(run["lifecycle"]["sampleCount"], 1)
            self.assertEqual(run["xunitFiles"], [f"tests-{number}.xml", f"tests-{number}-swift-testing.xml"])
            self.assertEqual({case["xunit"] for case in run["observed"]["tests"]},
                             {f"tests-{number}-swift-testing.xml"})
            self.assertEqual((directory / run["log"]).read_text(), f"Synthetic test repetition {number}\n")
            self.assertEqual(command, [
                "test", "--disable-sandbox", "--no-parallel", "--package-path", str(self.root),
                "--sdk", str(sdk),
                "--configuration", "debug", "--filter", "^(" + "|".join(TARGETS) + ")[./]",
                "--xunit-output", str(directory / run["xunit"]), "-Xswiftc", "-warnings-as-errors",
            ])

    def test_each_target_must_have_observed_test_coverage(self):
        for missing in TARGETS:
            with self.subTest(missing=missing):
                result, evidence = self.run_fixture([
                    {"cases": [{"suite": target} for target in TARGETS if target != missing]},
                ])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(evidence["runs"][0]["observed"]["missingTargets"], [missing])

    def test_missing_empty_and_malformed_xunit_fail_closed(self):
        for xml in [None, "", "<testsuites/>", "<testsuites>"]:
            with self.subTest(xml=xml):
                result, evidence = self.run_fixture([{"xml": xml}])
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNotNone(evidence)
                if xml is None:
                    self.assertIn("did not produce xUnit", evidence["runs"][0]["observed"]["error"])

    def test_failure_error_skip_and_nonzero_swift_status_fail_even_with_other_passes(self):
        for status in ["failure", "error", "skipped", "nonzero"]:
            with self.subTest(status=status):
                cases = [{"suite": target} for target in TARGETS]
                override = {"cases": cases}
                if status == "nonzero":
                    override["exitCode"] = 7
                else:
                    cases[0]["status"] = status
                result, evidence = self.run_fixture([override])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(evidence["runs"][0]["outcome"], "failed")

    def test_failed_repetition_is_not_hidden_by_later_success(self):
        result, evidence = self.run_fixture([{"exitCode": 3}, {}], repeats="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([run["outcome"] for run in evidence["runs"]], ["failed", "passed"])

    def test_split_xunit_reports_combine_framework_coverage_and_failures(self):
        cases = [{"suite": target} for target in TARGETS]
        result, evidence = self.run_fixture([{"cases": cases[:-1], "xctestCases": cases[-1:]}])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence["runs"][0]["observed"]["counts"]["passed"], 6)
        result, evidence = self.run_fixture([{"xctestCases": [
            {"suite": TARGETS[0], "name": "xctestFailure()", "status": "failure"},
        ]}])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(evidence["runs"][0]["observed"]["counts"]["failed"], 1)
        for layout in ["combined", "swift-only"]:
            with self.subTest(layout=layout):
                result, evidence = self.run_fixture([{"xunitLayout": layout}])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(evidence["runs"][0]["xunitFiles"]), 1)

    def test_suite_summary_issues_fail_even_when_testcases_pass(self):
        for field in ["failures", "errors", "skipped"]:
            with self.subTest(field=field):
                result, evidence = self.run_fixture([{"suiteAttributes": {field: "1"}}])
                self.assertNotEqual(result.returncode, 0)
                observed = evidence["runs"][0]["observed"]
                self.assertEqual(observed["counts"]["passed"], 6)
                self.assertEqual(observed["suiteSummaryIssues"], [field])
        result, evidence = self.run_fixture([{"suiteAttributes": {"failures": "not a count"}}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid xUnit suite summary", evidence["runnerError"])

    def test_accepts_unique_type_display_and_qualified_xunit_names(self):
        for form in ["type", "display", "qualified", "slash", "test-name"]:
            with self.subTest(form=form):
                cases = []
                for index, target in enumerate(TARGETS):
                    cases.append({
                        "suite": {"type": f"Checks{index}", "display": f"Synthetic suite {index}",
                                  "qualified": target + f".Checks{index}", "slash": target + "/Checks",
                                  "test-name": ""}[form],
                        "name": target + "/check()" if form == "test-name" else "check()",
                    })
                result, evidence = self.run_fixture([{"cases": cases}])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(evidence["runs"][0]["observed"]["missingTargets"], [])

    def test_ambiguous_suite_alias_cannot_credit_multiple_targets(self):
        for index, target in enumerate(TARGETS):
            self.write_source(f"Tests/{target}/Checks.swift", self.suite_source(index, "Shared suite"))
        result, evidence = self.run_fixture([{"cases": [{"suite": "Shared suite"}]}])
        self.assertNotEqual(result.returncode, 0)
        observed = evidence["runs"][0]["observed"]
        self.assertEqual(observed["missingTargets"], sorted(TARGETS))
        self.assertEqual(observed["ambiguousTests"], 1)
        # A fully qualified target still supplies unambiguous attribution despite shared display names.
        result, _ = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_and_invalid_lifecycle_reports_fail_closed(self):
        reports = [None, "", "{", {}, [], LIFECYCLE | {"samples": []},
                   LIFECYCLE | {"version": True}, LIFECYCLE | {"deadlineMilliseconds": 0},
                   LIFECYCLE | {"samples": [{"cooperativeMilliseconds": 1}]},
                   LIFECYCLE | {"samples": [{"cooperativeMilliseconds": -1,
                                             "fencedNoncancelableMilliseconds": 1}]},
                   LIFECYCLE | {"samples": [{"cooperativeMilliseconds": 1,
                                             "fencedNoncancelableMilliseconds": float("nan")}]},
                   LIFECYCLE | {"samples": [{"cooperativeMilliseconds": True,
                                             "fencedNoncancelableMilliseconds": 1}]}]
        for report in reports:
            with self.subTest(report=report):
                result, evidence = self.run_fixture([{"lifecycle": report}])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(evidence["runs"][0]["lifecycleReportPresent"], report is not None)

    def test_tracked_edits_deletions_and_new_sources_invalidate_success(self):
        for change in [
            {"path": "Sources/Runtime.swift", "content": "let changed = 2\n"},
            {"path": "Sources/Runtime.swift", "delete": True},
            {"path": "Sources/NewInput.swift", "content": "let added = 3\n"},
        ]:
            with self.subTest(change=change):
                self.write_source("Sources/Runtime.swift", "let synthetic = 1\n")
                result, evidence = self.run_fixture([{"changes": [change]}])
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(evidence["sourceUnchanged"])
                self.assertEqual(evidence["runs"][0]["outcome"], "passed")

    def test_evidence_excludes_private_files_source_contents_and_environment_values(self):
        marker = "SYNTHETIC-PRIVATE-MARKER-MUST-NOT-APPEAR"
        self.write_source("Sources/Runtime.swift", 'let synthetic = "' + marker + '"\n')
        result, evidence = self.run_fixture([
            {"changes": [{"path": ".build/private.json", "content": marker},
                         {"path": "private-account/session.json", "content": marker}]},
        ], environment={"SYNTHETIC_PRIVATE_VALUE": marker})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(evidence["sourceUnchanged"])
        self.assertNotIn(marker, json.dumps(evidence))
        self.assertNotIn(str(self.root), json.dumps(evidence))

    def test_symlinked_source_and_ancestor_fail_before_swift_or_external_source_read(self):
        private = self.directory / "private-source"
        private.mkdir()
        (private / "Checks.swift").write_text('@Suite("SYNTHETIC-PRIVATE-SUITE")\nstruct Secret {}\n')
        source = self.root / "Tests/SpottyGatewayTests/Checks.swift"
        source.unlink()
        source.symlink_to(private / "Checks.swift")
        result, evidence = self.run_fixture()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertIn("symlinked source", evidence["runnerError"])
        self.assertNotIn("SYNTHETIC-PRIVATE-SUITE", json.dumps(evidence))
        source.unlink()
        source.parent.rmdir()
        source.parent.symlink_to(private, target_is_directory=True)
        result, evidence = self.run_fixture()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertIn("symlinked source", evidence["runnerError"])

    def test_invalid_repetitions_and_arguments_never_start_swift(self):
        for value in ["0", "26", "-1", "01", "", "1.5", "1\n", "anything"]:
            with self.subTest(repeats=value):
                result, evidence = self.run_fixture(repeats=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SPOTTY_CHECK_REPEATS must be between 1 and 25", result.stderr)
                self.assertIsNone(evidence)
                self.assertEqual(self.calls(), [])
        result, evidence = self.run_fixture(arguments=["--filter", "OnlyOneTarget"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)
        self.assertIsNone(evidence)
        self.assertEqual(self.calls(), [])

    def test_nonregular_source_fails_without_reading_or_testing(self):
        os.mkfifo(self.root / "Sources/Nonregular.swift")
        result, evidence = self.run_fixture()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nonregular source", evidence["runnerError"])
        self.assertEqual(self.calls(), [])

    def test_maximum_repetitions_are_supported(self):
        result, evidence = self.run_fixture(repeats="25")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(evidence["runs"]), 25)
        self.assertEqual(len([call for call in self.calls() if call[0] == "test"]), 25)

    def local_engine(self):
        artifact = self.root / "Fixture.xcframework"
        (artifact / "macos-arm64").mkdir(parents=True)
        library = artifact / "macos-arm64/fixture.a"
        library.write_bytes(b"synthetic playback archive")
        (artifact / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [
            {"LibraryIdentifier": "macos-arm64", "LibraryPath": "fixture.a"},
        ]}))
        (artifact / "spotty_playback_provenance.json").write_text(json.dumps({
            "source": {"engineInputDigest": "c" * 64},
            "librarySHA256": hashlib.sha256(library.read_bytes()).hexdigest(),
        }))
        return artifact, library

    def test_local_engine_provenance_matches_archive_and_detects_drift(self):
        artifact, library = self.local_engine()
        environment = {"SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": artifact.name}
        result, evidence = self.run_fixture(environment=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(evidence["engine"]["provenanceMatchesArchive"])
        self.assertEqual(evidence["engine"]["selection"], "explicit-local-override")
        result, evidence = self.run_fixture([
            {"changes": [{"path": str(library.relative_to(self.root)), "content": "changed engine"}]},
        ], environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(evidence["sourceUnchanged"])
        self.assertFalse(evidence["engineUnchanged"])
        result, evidence = self.run_fixture(environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(evidence["engine"]["provenanceMatchesArchive"])

    def test_invalid_bootstrap_identity_writes_failed_evidence_without_testing(self):
        (self.root / "Package.swift").write_text("// missing engine pin\n")
        result, evidence = self.run_fixture()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(evidence["runs"], [])
        self.assertIn("Expected one playback url pin", evidence["runnerError"])
        self.assertEqual(self.calls(), [])

    def test_invalid_local_provenance_and_unbounded_archive_path_fail_before_testing(self):
        artifact, _ = self.local_engine()
        environment = {"SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": str(artifact)}
        info = artifact / "Info.plist"
        for name in ["../outside.a", "/outside.a", "", ".", ".."]:
            with self.subTest(name=name):
                info.write_bytes(plistlib.dumps({"AvailableLibraries": [
                    {"LibraryIdentifier": "macos-arm64", "LibraryPath": name},
                ]}))
                result, evidence = self.run_fixture(environment=environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("bounded macos-arm64", evidence["runnerError"])
                self.assertEqual(self.calls(), [])
        (artifact / "spotty_playback_provenance.json").write_text(json.dumps({
            "source": {"engineInputDigest": "invalid"}, "librarySHA256": "d" * 64,
        }))
        result, evidence = self.run_fixture(environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid engine provenance", evidence["runnerError"])
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
