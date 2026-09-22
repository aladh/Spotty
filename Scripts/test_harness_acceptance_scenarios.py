"""Acceptance evidence must fail closed independently of the tested implementation."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import acceptance_scenarios as acceptance


class AcceptanceEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.manifest = acceptance.manifest()
        self.item = self.manifest["scenarios"][0]
        self.source = {"revision": "a" * 40, "prHeadRevision": "a" * 40, "dirty": False}

    def raw(self):
        return {"schemaVersion": 1, "scenarioID": self.item["id"], "scenarioVersion": 1,
                "passed": True, "failure": None,
                "checkpoints": [{"name": "account.signed-out", "expected": {"session": "signed-out"}, "observed": {"session": "signed-out"}, "passed": True}],
                "timeline": [{"name": "restore"}],
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
        variants = []
        bad = copy.deepcopy(self.manifest)
        bad["schemaVersion"] = 99
        variants.append(bad)
        bad = copy.deepcopy(self.manifest)
        bad["scenarios"].append(bad["scenarios"][0])
        variants.append(bad)
        for field, value in (("workload", "../../etc/passwd"), ("timeoutSeconds", 0),
                             ("safety", {"dependencies": "live", "liveMutations": False, "audioOutput": False})):
            bad = copy.deepcopy(self.manifest)
            bad["scenarios"][0][field] = value
            variants.append(bad)
        original_read = acceptance.read_json
        for value in variants:
            with self.subTest(value=value), mock.patch.object(acceptance, "read_json", side_effect=lambda path: value if Path(path) == acceptance.ROOT / acceptance.MANIFEST else original_read(path)):
                with self.assertRaises(ValueError):
                    acceptance.manifest()

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
