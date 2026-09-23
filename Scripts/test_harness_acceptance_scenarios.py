"""Acceptance evidence must fail closed independently of the tested implementation."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import acceptance_scenarios as acceptance
from harness_fixtures import launch_manifest
import profile_synthetic


class AcceptanceEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.manifest = acceptance.manifest()
        self.item = self.manifest["scenarios"][0]
        self.source = {"revision": "a" * 40, "prHeadRevision": "a" * 40, "dirty": False}

    def raw(self):
        return {"schemaVersion": 1, "scenarioID": self.item["id"], "scenarioVersion": 1,
                "passed": True, "failure": None,
                "checkpoints": [{"name": "account.signed-out", "expected": {"session": "signed-out"}, "observed": {"session": "signed-out"}, "passed": True}],
                "timeline": [{"sequence": 1, "kind": "action", "name": "restore", "state": {}}],
                "isolation": {"dependencyMode": "synthetic", "forbiddenMutationAttempts": 0, "networkSandboxVerified": None}}

    def normalize(self, raw, fallback=None):
        return acceptance.normalize(self.item, raw, self.source, "digest", fallback)

    def test_default_selection_excludes_holdout_and_explicit_selection_is_bounded(self):
        self.assertEqual(len(acceptance.selected_scenarios(self.manifest)), 3)
        self.assertEqual(len(acceptance.selected_scenarios(self.manifest, "all")), 4)
        with self.assertRaises(ValueError):
            acceptance.selected_scenarios(self.manifest, identifiers=["holdout.playback-stale-order"])
        with self.assertRaises(ValueError):
            acceptance.selected_scenarios(self.manifest, "all", ["invented"])

    def test_prepared_demo_retains_the_manifest_scenario_deadline(self):
        prepared = acceptance.scenario_input(self.item)
        self.assertEqual(prepared["timeoutSeconds"], 60)
        self.assertEqual(prepared["scenario"]["acceptanceTimeoutSeconds"], prepared["timeoutSeconds"])
        self.assertEqual(prepared["scenario"]["acceptanceScenarioID"], self.item["id"])
        self.assertEqual(prepared["scenario"]["acceptanceScenarioVersion"], self.item["version"])

    def test_missing_report_and_missing_run_produce_failure_packets(self):
        evidence = self.normalize(None)
        self.assertEqual(evidence["failure"]["code"], "missing-report")
        with tempfile.TemporaryDirectory() as directory:
            summary = acceptance.summarize(Path(directory) / "missing")
            self.assertEqual(summary["outcome"], "failed")
            self.assertEqual(summary["failure"]["checkpoint"], "corpus.start")
            self.assertTrue((Path(directory) / "missing/summary.json").exists())

    def test_report_identity_and_independent_isolation_override_pass_bit(self):
        self.assertEqual(self.normalize(self.raw())["outcome"], "passed")
        for change in ({"scenarioID": "wrong"}, {"scenarioVersion": 2}, {"schemaVersion": 2}):
            raw = self.raw() | change
            self.assertEqual(self.normalize(raw)["failure"]["code"], "invalid-report")
        for isolation in ({"dependencyMode": "live", "forbiddenMutationAttempts": 0},
                          {"dependencyMode": "synthetic", "forbiddenMutationAttempts": 1}, {}):
            self.assertEqual(self.normalize(self.raw() | {"isolation": isolation})["outcome"], "failed")

    def test_partial_checkpoints_survive_failure_and_failed_host_invalidates_green_report(self):
        raw = self.raw()
        raw["passed"] = False
        raw["failure"] = acceptance.failure("checkpoint-failed", "owner.stale", "current owner", "retired owner")
        evidence = self.normalize(raw)
        self.assertEqual(evidence["failure"]["checkpoint"], "owner.stale")
        self.assertEqual(evidence["checkpoints"], raw["checkpoints"])
        self.assertEqual(evidence["timeline"], raw["timeline"])
        host_failure = acceptance.failure("test-host-failed", "runtime.host", 0, 1)
        self.assertEqual(self.normalize(self.raw(), host_failure)["outcome"], "failed")

    def test_empty_or_malformed_checkpoints_cannot_pass(self):
        for checkpoints in ([], ["bad"], [{"passed": False}], None):
            self.assertEqual(self.normalize(self.raw() | {"checkpoints": checkpoints})["outcome"], "failed")

    def test_malformed_reports_isolation_and_failures_produce_structured_packets(self):
        for raw in ([], ["unexpected"], "unexpected", 1, True):
            with self.subTest(raw=raw):
                self.assertEqual(self.normalize(raw)["failure"]["code"], "invalid-report")
        for isolation in (None, [], "synthetic", {"dependencyMode": "synthetic", "forbiddenMutationAttempts": False}):
            self.assertEqual(self.normalize(self.raw() | {"isolation": isolation})["failure"]["code"], "isolation-failed")
        for problem in ("wrong shape", ["wrong shape"], {"checkpoint": "partial"}):
            result = self.normalize(self.raw() | {"failure": problem})
            self.assertEqual(result["failure"]["checkpoint"], "runtime.failure")
            self.assertEqual(result["outcome"], "failed")

    def test_declared_timeline_cannot_be_missing_or_malformed(self):
        for timeline in (None, [], [None], [{"state": {}}], "events"):
            result = self.normalize(self.raw() | {"timeline": timeline})
            self.assertEqual(result["failure"]["checkpoint"], "runtime.timeline")

    def test_timeline_retains_order_kind_and_state(self):
        for change in ({"sequence": True}, {"sequence": 0}, {"sequence": 2}, {"kind": ""}, {"state": None}):
            raw = self.raw()
            raw["timeline"][0].update(change)
            self.assertEqual(self.normalize(raw)["failure"]["checkpoint"], "runtime.timeline")

    def test_boolean_versions_do_not_substitute_for_integers(self):
        for field in ("schemaVersion", "scenarioVersion"):
            self.assertEqual(self.normalize(self.raw() | {field: True})["outcome"], "failed")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acceptance.write_json(root / "request.json", self.request() | {"schemaVersion": True})
            self.assertEqual(acceptance.summarize(root)["failure"]["code"], "invalid-request")

    def test_summary_rejects_malformed_run_request_without_losing_failure_packet(self):
        for contents in ("{", "[]", '{}', json.dumps({"schemaVersion": 1, "source": {}, "manifestDigest": "d",
                                                    "scenarios": [{"id": "../../escape", "version": 1, "corpus": "holdout"}]})):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "request.json").write_text(contents)
                result = acceptance.summarize(root)
                self.assertEqual(result["outcome"], "failed")
                self.assertEqual(result["failure"]["code"], "invalid-request")
                self.assertEqual(acceptance.read_json(root / "summary.json"), result)

    def request(self):
        return {"schemaVersion": 1, "source": self.source, "sourceUnchanged": True,
                "manifestDigest": "digest", "scenarios": [self.item]}

    def test_summary_revalidates_evidence_identity_assertions_and_source_stability(self):
        mutations = [
            lambda evidence: evidence.update(scenarioID="wrong"),
            lambda evidence: evidence.update(scenarioVersion=2),
            lambda evidence: evidence.update(schemaVersion=2),
            lambda evidence: evidence.update(corpus="holdout"),
            lambda evidence: evidence.update(source={}),
            lambda evidence: evidence.update(manifestDigest="other"),
            lambda evidence: evidence.update(outcome="skipped"),
            lambda evidence: evidence["checkpoints"][0].update(passed=False),
            lambda evidence: evidence.update(isolation={"dependencyMode": "live", "forbiddenMutationAttempts": 0}),
            lambda evidence: evidence.update(timeline=[]),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                acceptance.write_json(root / "request.json", self.request())
                evidence = self.normalize(self.raw())
                mutate(evidence)
                path = root / ("evidence-" + self.item["id"] + ".json")
                acceptance.write_json(path, evidence)
                summary = acceptance.summarize(root)
                self.assertEqual(summary["outcome"], "failed")
                self.assertEqual(summary["scenarios"][0]["outcome"], "failed")
                self.assertEqual(acceptance.read_json(path)["outcome"], "failed")
        for stability in (False, None, "true"):
            with self.subTest(stability=stability), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                acceptance.write_json(root / "request.json", self.request() | {"sourceUnchanged": stability})
                acceptance.write_json(root / ("evidence-" + self.item["id"] + ".json"), self.normalize(self.raw()))
                summary = acceptance.summarize(root)
                self.assertFalse(summary["sourceUnchanged"])
                self.assertEqual(summary["scenarios"][0]["failedCheckpoint"]["checkpoint"], "source.identity")

    def test_malformed_evidence_fails_and_valid_evidence_replays_the_same_summary(self):
        for malformed in ("{", "[]", "null"):
            with self.subTest(malformed=malformed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                acceptance.write_json(root / "request.json", self.request())
                (root / ("evidence-" + self.item["id"] + ".json")).write_text(malformed)
                result = acceptance.summarize(root)
                self.assertEqual(result["scenarios"][0]["failedCheckpoint"]["code"], "invalid-evidence")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acceptance.write_json(root / "request.json", self.request())
            acceptance.write_json(root / ("evidence-" + self.item["id"] + ".json"), self.normalize(self.raw()))
            first = acceptance.summarize(root)
            self.assertEqual(first["outcome"], "passed")
            self.assertEqual(acceptance.summarize(root), first)

    def test_summary_rendering_tolerates_a_malformed_external_failure(self):
        summary = {"outcome": "failed", "scenarios": [
            {"id": self.item["id"], "version": 1, "corpus": "representative",
             "outcome": "failed", "failedCheckpoint": "malformed"}]}
        with mock.patch("builtins.print") as printer:
            acceptance.print_summary(summary)
        self.assertIn("invalid failure packet", printer.call_args_list[1].args[0])

    def test_summary_requires_every_requested_scenario(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = self.request() | {"scenarios": self.manifest["scenarios"][:2]}
            acceptance.write_json(root / "request.json", request)
            acceptance.write_json(root / ("evidence-" + self.item["id"] + ".json"), self.normalize(self.raw()))
            summary = acceptance.summarize(root)
            self.assertEqual(summary["outcome"], "failed")
            self.assertEqual(summary["scenarios"][1]["failedCheckpoint"]["code"], "missing-report")

    def test_manifest_rejects_escaping_paths_unknown_versions_duplicates_and_relaxed_safety(self):
        variants = [None, [], ["schemaVersion", "scenarios"], 1, "manifest", self.manifest | {"schemaVersion": True}]
        bad = copy.deepcopy(self.manifest)
        bad["schemaVersion"] = 99
        variants.append(bad)
        bad = copy.deepcopy(self.manifest)
        bad["scenarios"].append(bad["scenarios"][0])
        variants.append(bad)
        for field, value in (("workload", "../../etc/passwd"), ("timeoutSeconds", 0),
                             ("safety", {"dependencies": "live", "liveMutations": False, "audioOutput": False}),
                             ("safety", {"dependencies": "synthetic", "liveMutations": 0, "audioOutput": 0})):
            bad = copy.deepcopy(self.manifest)
            bad["scenarios"][0][field] = value
            variants.append(bad)
        original_read = acceptance.read_json
        for value in variants:
            with self.subTest(value=value), mock.patch.object(acceptance, "read_json", side_effect=lambda path: value if Path(path) == acceptance.ROOT / acceptance.MANIFEST else original_read(path)):
                with self.assertRaises(ValueError):
                    acceptance.manifest()

    def test_failed_host_launch_still_writes_every_failure_packet(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(acceptance, "source_record", return_value=self.source), \
                mock.patch.object(acceptance.subprocess, "run", side_effect=FileNotFoundError), mock.patch("builtins.print"):
            root = Path(directory)
            args = mock.Mock(output=root, corpus="representative", scenario=None, timeout_seconds=60)
            self.assertEqual(acceptance.run_corpus(args), 1)
            summary = acceptance.read_json(root / "summary.json")
            self.assertEqual(len(summary["scenarios"]), 3)
            self.assertEqual(summary["outcome"], "failed")
            for item in summary["scenarios"]:
                self.assertEqual(item["failedCheckpoint"]["code"], "test-host-failed")
                self.assertTrue((root / item["evidence"]).exists())

    def demo_report(self):
        return {"passed": True, "networkSandboxVerified": True, "world": {"mutationAttempts": 0},
                "launch": launch_manifest(),
                "scenario": {"mode": "browsing", "version": 1},
                "samples": [{"checkpoint": "home.ready"}]}

    def demo_result(self, report, *, files=None, workload=None, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acceptance.write_json(root / "report.json", report)
            acceptance.write_json(root / "manifest.json", launch_manifest())
            for name, content in (files or {}).items():
                (root / name).write_text(content)
            workload_path = root / "workload.json" if workload is not None else None
            if workload_path:
                acceptance.write_json(workload_path, workload)
            status = acceptance.demo_evidence(mock.Mock(output=root, workload=workload_path, exit_code=exit_code))
            result = acceptance.read_json(root / "demo-evidence.json")
            self.assertEqual(status, 0 if result["outcome"] == "passed" else 1)
            self.assertEqual((root / "report.json").read_text(), (files or {}).get("report.json", json.dumps(report, indent=2, sort_keys=True) + "\n"))
            return result

    def test_valid_legacy_demo_passes_but_malformed_reports_always_leave_evidence(self):
        self.assertEqual(self.demo_result(self.demo_report())["outcome"], "passed")
        reports = [None, [], "report", 1]
        for field in ("launch", "scenario", "world", "samples"):
            for value in (None, [], "wrong", 1):
                reports.append(self.demo_report() | {field: value})
        for value in (None, [], 1):
            reports.append(self.demo_report() | {"scenario": {"mode": value, "version": 1}})
        reports.extend([self.demo_report() | {"samples": [None]},
                        self.demo_report() | {"samples": [{"checkpoint": 1}]},
                        self.demo_report() | {"launch": {"source": None}}])
        for report in reports:
            with self.subTest(report=report):
                result = self.demo_result(report)
                self.assertEqual(result["outcome"], "failed")
                self.assertIsInstance(result["failure"], dict)
        for name in ("report.json", "manifest.json"):
            for content in ("{", "[]", "null"):
                self.assertEqual(self.demo_result(self.demo_report(), files={name: content})["outcome"], "failed")

    def test_demo_success_requires_exact_isolation_and_no_contradictory_failure(self):
        for change in ({"world": {"mutationAttempts": False}}, {"world": {"mutationAttempts": 0.0}},
                       {"world": {"mutationAttempts": 1}}, {"networkSandboxVerified": 1},
                       {"failure": "checkpoint failed"}, {"failure": ""}, {"failure": False}, {"failure": []},
                       {"passed": 1}, {"samples": []}):
            self.assertEqual(self.demo_result(self.demo_report() | change)["outcome"], "failed")
        self.assertEqual(self.demo_result(self.demo_report(), exit_code=1)["outcome"], "failed")

    def test_named_demo_revalidates_runtime_identity_checkpoints_timeline_and_isolation(self):
        report = self.demo_report()
        report["scenario"].update(acceptanceScenarioID=self.item["id"], acceptanceScenarioVersion=self.item["version"])
        report["acceptanceRuntime"] = self.raw()
        self.assertEqual(self.demo_result(report)["outcome"], "passed")
        for change in ({"scenarioID": "wrong"}, {"scenarioVersion": True}, {"checkpoints": None},
                       {"checkpoints": []}, {"timeline": None}, {"isolation": {}},
                       {"failure": "malformed"}, {"passed": False}):
            self.assertEqual(self.demo_result(report | {"acceptanceRuntime": self.raw() | change})["outcome"], "failed")
        for runtime in (None, [], "unexpected", {"passed": True}):
            self.assertEqual(self.demo_result(report | {"acceptanceRuntime": runtime})["outcome"], "failed")
        for identifier in ([], 1, "../escape"):
            invalid = copy.deepcopy(report)
            invalid["scenario"]["acceptanceScenarioID"] = identifier
            self.assertEqual(self.demo_result(invalid)["outcome"], "failed")

    def test_demo_report_must_match_workload_and_recorded_run(self):
        report = self.demo_report()
        for field, changed in (("runID", "22222222-2222-4222-8222-222222222222"),
                               ("source", {**report["launch"]["source"], "revision": "b" * 40}),
                               ("build", {**report["launch"]["build"], "configuration": "debug"}),
                               ("engine", {**report["launch"]["engine"], "librarySHA256": "7" * 64}),
                               ("fixture", {**report["launch"]["fixture"], "sha256": "7" * 64}),
                               ("layout", {"forceSynchronousLayout": True})):
            manifest = launch_manifest() | {field: changed}
            result = self.demo_result(report, files={"manifest.json": json.dumps(manifest)})
            self.assertEqual(result["failure"]["checkpoint"], "demo.identity")
        self.assertEqual(self.demo_result(report, workload={"mode": "playback"})["failure"]["checkpoint"], "demo.scenario")

    def test_demo_cannot_pass_without_valid_launch_and_manifest_provenance(self):
        for invalid in ({}, {"schemaVersion": True}, {"source": {}}, {"runID": "invalid"}):
            with self.subTest(invalid=invalid):
                launch = {} if not invalid else launch_manifest() | invalid
                result = self.demo_result(self.demo_report() | {"launch": launch},
                                          files={"manifest.json": json.dumps(launch)})
                self.assertEqual(result["outcome"], "failed")
                self.assertEqual([check["name"] for check in result["checkpoints"]], ["home.ready"])
        report = self.demo_report()
        report.pop("launch")
        self.assertEqual(self.demo_result(report)["outcome"], "failed")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acceptance.write_json(root / "report.json", self.demo_report())
            self.assertEqual(acceptance.demo_evidence(mock.Mock(output=root, workload=None, exit_code=0)), 1)

    def test_demo_keeps_completed_checkpoints_when_a_later_sample_is_malformed(self):
        result = self.demo_result(self.demo_report() | {"samples": [{"checkpoint": "home.ready"}, None]})
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual([entry["name"] for entry in result["checkpoints"]], ["home.ready"])

    @unittest.skipUnless(shutil.which("zsh"), "Demo launcher requires zsh")
    def test_launcher_writes_final_evidence_only_after_outer_process_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            scripts.mkdir()
            shutil.copy2(acceptance.ROOT / "Scripts/browse-synthetic.sh", scripts / "browse-synthetic.sh")
            (scripts / "swiftpm-env.sh").write_text('SDKROOT=/synthetic/sdk\nspotty_swiftc_warnings_as_errors=()\n')
            (scripts / "embed-sparkle.sh").write_text(':\n')
            (scripts / "browsing_provenance.py").write_text('')
            (scripts / "profile_synthetic.py").write_text(
                'import json, os, pathlib, sys\n'
                'root = pathlib.Path(sys.argv[-1])\n'
                '(root / "profiler-state.json").write_text(json.dumps({"schemaVersion": 1, "state": "failed", "failureCode": "session-locked"}))\n'
                'with pathlib.Path(os.environ["DEMO_TEST_EVENTS"]).open("a") as stream:\n'
                '    stream.write("preflight\\n")\n'
                'sys.exit(43)\n')
            # A failed final report must fail the launcher, but cannot run during a lookup.
            (scripts / "acceptance_scenarios.py").write_text(
                'import json, os, pathlib, sys\n'
                'preparing = sys.argv[1] == "prepare-demo"\n'
                'with pathlib.Path(os.environ["DEMO_TEST_EVENTS"]).open("a") as stream:\n'
                '    stream.write("prepare\\n" if preparing else "evidence:" + sys.argv[-1] + "\\n")\n'
                'if preparing:\n'
                '    sys.exit(44)\n'
                'root = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])\n'
                '(root / "demo-evidence.json").write_text(json.dumps({"exitCode": int(sys.argv[-1])}))\n'
                'sys.exit(1)\n')
            scenario = root / "scenario.json"
            scenario.write_text('{}')
            binaries = root / "bin"
            binaries.mkdir()
            for name, body in {
                "security": 'print(\'  1) ABCDEF "Apple Development: Synthetic (TEAM)"\')\n',
                "swift": 'import os, pathlib\nwith pathlib.Path(os.environ["DEMO_TEST_EVENTS"]).open("a") as stream:\n    stream.write("build\\n")\nraise SystemExit(42)\n',
            }.items():
                path = binaries / name
                path.write_text(f'#!{sys.executable}\n' + body)
                path.chmod(0o755)
            events = root / "events.txt"
            pointer = root / "run-root.txt"
            environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                               DEMO_TEST_EVENTS=str(events), SPOTTY_BROWSING_RUN_ROOT_FILE=str(pointer))
            for key in ("SPOTTY_DEVELOPMENT_SIGNING_IDENTITY", "SPOTTY_SIGNING_IDENTITY"):
                environment.pop(key, None)
            for arguments, expected in (
                ([str(scenario)], ["build", "evidence:42"]),
                (["--profile", str(scenario)], ["preflight", "evidence:43"]),
                (["--scenario", "missing.scenario"], ["prepare", "evidence:44"]),
                ([str(root / "missing.json")], ["evidence:2"]),
            ):
                with self.subTest(arguments=arguments):
                    events.write_text("")
                    pointer.unlink(missing_ok=True)
                    result = subprocess.run(["zsh", str(scripts / "browse-synthetic.sh"), *arguments],
                                            env=environment, capture_output=True, text=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(events.read_text().splitlines(), expected, result.stderr)
                    run_root = Path(pointer.read_text().strip())
                    self.assertEqual(run_root.parent, (root / ".build/browsing-runs").resolve())
                    self.assertTrue(run_root.is_dir())
                    self.assertEqual(json.loads((run_root / "demo-evidence.json").read_text()),
                                     {"exitCode": int(expected[-1].split(":")[1])})
                    self.assertFalse((run_root / "process.json").exists())
                    if "--profile" in arguments:
                        codes, _ = profile_synthetic.capture_diagnostics(run_root, "left", profile_synthetic.InvalidRun("capture-incomplete"))
                        self.assertEqual(codes[0], "left.session-locked")

    def test_demo_requires_sandbox_and_preserves_legacy_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = {"passed": True, "networkSandboxVerified": False, "world": {"mutationAttempts": 0},
                      "scenario": {"mode": "browsing", "version": 1}, "samples": []}
            acceptance.write_json(root / "report.json", report)
            arguments = mock.Mock(output=root, workload=None, exit_code=0)
            acceptance.demo_evidence(arguments)
            self.assertEqual(acceptance.read_json(root / "demo-evidence.json")["outcome"], "failed")
            self.assertFalse((root / "evidence.json").exists())
            self.assertFalse((root / "summary.json").exists())
            self.assertEqual(acceptance.read_json(root / "report.json"), report)


if __name__ == "__main__":
    unittest.main()
