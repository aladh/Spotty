"""Comparison gates reject unsuitable evidence without a recorder or a display."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from compare_synthetic_profiles import compare, main


def completed_run(run_id):
    environment = {
        "window": {"visible": True, "miniaturized": False, "key": True,
                   "width": 1440, "height": 900, "inspector": "queue"},
        "display": {"scale": 2, "maximumFramesPerSecond": 120, "reducedMotion": False},
    }
    manifest = {
        "schemaVersion": 1, "runID": run_id,
        "source": {"revision": "a" * 40, "sourceSHA256": "b" * 64, "diffSHA256": "c" * 64,
                   "includesUntrackedNonignoredFiles": True},
        "build": {"configuration": "release", "optimization": "-O", "testabilityEnabled": True,
                  "compilerVersion": "Swift version 6.2", "requestedSDKVersion": "26.0",
                  "requestedSDKName": "macosx26.0", "linkedSDKVersion": "26.0", "buildProductSHA256": "d" * 64},
        "engine": {"selection": "pinned", "pinURL": "https://example.invalid/engine.zip",
                   "pinChecksum": "e" * 64, "librarySHA256": "f" * 64, "canonicalHeadersSHA256": "0" * 64,
                   "sourceRevision": "1" * 40, "engineInputDigest": "2" * 64,
                   "librespotRevision": "3" * 40, "usedForPlayback": False},
        "fixture": {"sha256": "4" * 64, "workloadSHA256": "5" * 64},
        "layout": {"forceSynchronousLayout": False},
    }
    state = {"schemaVersion": 1, "runID": run_id, "pid": 100, "failureCode": None}
    return {
        "manifest": manifest,
        "profiler-state": {**state, "state": "complete", "evidence": deepcopy(environment)},
        "run-status": {**state, "state": "workload-finished", **deepcopy(environment)},
        "report": {"passed": True, "launch": deepcopy(manifest), "samples": [{"checkpoint": "finished"}],
                   "responsiveness": {"displayCallbackCount": 600, "callbackGapP95Milliseconds": 17,
                                      "callbackGapP99Milliseconds": 18, "maximumCallbackGapMilliseconds": 20,
                                      "nominalFramesPerSecond": 120, "reducedMotion": False,
                                      "windowVisibleAtStart": True, "windowVisibleAtEnd": True,
                                      "observedTargetFramesPerSecond": {"minimum": 60, "p50": 60, "maximum": 120}}},
        "trace-summary": {"workloadSeconds": 10, "completeApplicationFrames": 600,
                          "completeFrameLifetimesMilliseconds": {"count": 600, "minimum": 8, "p50": 16,
                                                                 "p95": 17, "p99": 18, "maximum": 20},
                          "framesWithHitches": 0, "hitchFreeFramePercent": 100},
    }


class ProfileComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.left = Path(self.temporary.name) / "left"
        self.right = Path(self.temporary.name) / "right"
        self.left.mkdir()
        self.right.mkdir()
        self.write(self.left, completed_run("11111111-1111-4111-8111-111111111111"))
        self.write(self.right, completed_run("22222222-2222-4222-8222-222222222222"))

    def write(self, root, documents):
        for name, value in documents.items():
            (root / f"{name}.json").write_text(json.dumps(value))

    def change(self, name, mutate):
        path = self.right / f"{name}.json"
        value = json.loads(path.read_text())
        mutate(value)
        path.write_text(json.dumps(value))
        if name == "manifest":
            self.change("report", lambda report: report.update(launch=deepcopy(value)))

    def test_completed_matching_runs_are_comparable(self):
        result = compare(self.left, self.right)
        self.assertEqual(result["classification"], "comparable")
        self.assertEqual(result["reasonCodes"], [])

    def test_same_run_cannot_provide_two_independent_recordings(self):
        self.assertIn("duplicate-run-identity", compare(self.left, self.left)["reasonCodes"])

    def test_swift_optional_failure_code_may_be_omitted(self):
        self.change("run-status", lambda value: value.pop("failureCode"))
        self.assertEqual(compare(self.left, self.right)["classification"], "comparable")

    def test_unknown_inspector_state_stays_explicitly_descriptive(self):
        self.change("profiler-state", lambda value: value["evidence"]["window"].update(inspector="unobserved"))
        self.change("run-status", lambda value: value["window"].update(inspector="unobserved"))
        result = compare(self.left, self.right)
        self.assertEqual(result["classification"], "descriptive-only")
        self.assertIn("inspector-unobserved", result["reasonCodes"])

    def test_matching_source_revision_does_not_hide_changed_inputs(self):
        self.change("manifest", lambda value: value["source"].update(sourceSHA256="6" * 64))
        result = compare(self.left, self.right)
        self.assertEqual(result["classification"], "descriptive-only")
        self.assertIn("source.sourceSHA256", result["conditionDifferences"])

    def test_explicit_layout_variant_accepts_only_matching_workload(self):
        self.change("manifest", lambda value: value["layout"].update(forceSynchronousLayout=True))
        self.change("manifest", lambda value: value["fixture"].update(sha256="6" * 64))
        self.assertEqual(compare(self.left, self.right)["classification"], "descriptive-only")
        result = compare(self.left, self.right, "layout.forceSynchronousLayout")
        self.assertEqual(result["classification"], "comparable")
        self.assertEqual(result["declaredVariant"]["right"], True)
        self.change("manifest", lambda value: value["fixture"].update(workloadSHA256="7" * 64))
        self.assertEqual(compare(self.left, self.right, "layout.forceSynchronousLayout")["classification"], "descriptive-only")

    def test_adaptive_cadence_change_is_explicit_despite_matching_nominal_capability(self):
        self.change("report", lambda value: value["responsiveness"]["observedTargetFramesPerSecond"].update(p50=120))
        result = compare(self.left, self.right)
        self.assertEqual(result["classification"], "descriptive-only")
        self.assertIn("observed-target-cadence-differs", result["reasonCodes"])
        self.assertEqual(result["observedTargetFramesPerSecond"]["left"]["p50"], 60)

    def test_scheduler_rounding_and_actual_latency_are_measurements_not_condition_changes(self):
        self.change("report", lambda value: value["responsiveness"].update(
            callbackGapP95Milliseconds=24, callbackGapP99Milliseconds=30, maximumCallbackGapMilliseconds=40,
            observedTargetFramesPerSecond={"minimum": 60.01, "p50": 60.01, "maximum": 120.01}))
        self.assertEqual(compare(self.left, self.right)["classification"], "comparable")

    def test_changed_build_engine_or_display_is_descriptive(self):
        for name, mutate, difference in (
            ("manifest", lambda value: value["build"].update(configuration="debug"), "build.configuration"),
            ("manifest", lambda value: value["engine"].update(librarySHA256="7" * 64), "engine.librarySHA256"),
        ):
            with self.subTest(difference=difference):
                self.write(self.right, completed_run("22222222-2222-4222-8222-222222222222"))
                self.change(name, mutate)
                result = compare(self.left, self.right)
                self.assertEqual(result["classification"], "descriptive-only")
                self.assertIn(difference, result["conditionDifferences"])

    def test_report_file_cannot_accept_saving_failed_or_missing_recorder_evidence(self):
        for state in ("saving", "recording", "failed"):
            with self.subTest(state=state):
                self.change("profiler-state", lambda value: value.update(state=state))
                result = compare(self.left, self.right)
                self.assertEqual(result["classification"], "invalid")
                self.assertIn("right.profiler-state-invalid", result["reasonCodes"])
        (self.right / "profiler-state.json").unlink()
        self.assertIn("right.profiler-state-missing", compare(self.left, self.right)["reasonCodes"])

    def test_every_evidence_file_is_required(self):
        for path in sorted(self.right.iterdir()):
            contents = path.read_text()
            with self.subTest(name=path.name):
                path.unlink()
                result = compare(self.left, self.right)
                self.assertEqual(result["classification"], "invalid")
                self.assertIn(f"right.{path.stem}-missing", result["reasonCodes"])
            path.write_text(contents)

    def test_unbound_or_replaced_process_artifacts_are_rejected(self):
        for update, reason in (({"runID": "unrelated"}, "run-identity-mismatch"),
                               ({"pid": 101}, "process-identity-mismatch")):
            with self.subTest(reason=reason):
                self.write(self.right, completed_run("22222222-2222-4222-8222-222222222222"))
                self.change("run-status", lambda value: value.update(update))
                self.assertIn(f"right.{reason}", compare(self.left, self.right)["reasonCodes"])

    def test_report_cannot_contradict_its_manifest_with_matching_run_id(self):
        self.change("report", lambda value: value["launch"]["source"].update(sourceSHA256="6" * 64))
        self.assertIn("right.report-manifest-mismatch", compare(self.left, self.right)["reasonCodes"])

    def test_window_occlusion_or_environment_change_cannot_be_accepted(self):
        self.change("report", lambda value: value["responsiveness"].update(windowVisibleAtEnd=False))
        self.assertEqual(compare(self.left, self.right)["classification"], "invalid")
        self.write(self.right, completed_run("22222222-2222-4222-8222-222222222222"))
        self.change("run-status", lambda value: value["window"].update(width=1200))
        self.assertIn("right.window-changed-during-workload", compare(self.left, self.right)["reasonCodes"])

    def test_missing_or_empty_trace_and_nonfinite_measurements_are_invalid(self):
        for name, mutate in (
            ("trace-summary", lambda value: value.update(completeApplicationFrames=0)),
            ("trace-summary", lambda value: value.update(workloadSeconds=float("nan"))),
            ("report", lambda value: value["responsiveness"].pop("observedTargetFramesPerSecond")),
            ("report", lambda value: value["responsiveness"].update(displayCallbackCount=0)),
            ("manifest", lambda value: value["source"].pop("sourceSHA256")),
        ):
            with self.subTest(name=name):
                self.write(self.right, completed_run("22222222-2222-4222-8222-222222222222"))
                self.change(name, mutate)
                self.assertEqual(compare(self.left, self.right)["classification"], "invalid")

    def test_malformed_json_is_structured_invalid_evidence(self):
        (self.right / "report.json").write_text("{")
        self.assertIn("right.report-unreadable", compare(self.left, self.right)["reasonCodes"])

    def test_cli_requires_explicit_descriptive_acceptance_and_never_accepts_invalid(self):
        def invoke(*options):
            output = io.StringIO()
            with redirect_stdout(output):
                status = main([str(self.left), str(self.right), *options])
            return status, json.loads(output.getvalue())

        self.assertEqual(invoke()[0], 0)
        self.change("manifest", lambda value: value["source"].update(sourceSHA256="6" * 64))
        self.assertEqual(invoke()[0], 1)
        self.assertEqual(invoke("--allow-descriptive")[0], 0)
        (self.right / "trace-summary.json").unlink()
        status, result = invoke("--allow-descriptive")
        self.assertEqual(status, 2)
        self.assertEqual(result["classification"], "invalid")
