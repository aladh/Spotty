"""Strict exact-selection regressions using bounded actual Swift Testing v0 records.

6.3 fixture: selected declarations/lifecycles and boundaries extracted from the
actual Apple Swift 6.3.3 CI full-Debug stream, run 36680770294 attempt 1 at
6cd179e42d371b0fa4c72e8f1d58cd8b840b3152. Its summary describes the full run;
only event identities establish the extracted parser fixture's selected function.
6.4 fixture: complete actual focused cold stream at source
6329922924fbe8f4be8b1b74a29549790be4e005, preserved in 589-before-swift64.
Absolute source paths, function IDs, event versions and timing records are retained.
These fixtures establish parser compatibility, not candidate native execution.
"""

import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
from unittest.mock import patch

import focused_selection_evidence as evidence
from test_package_graphs import full_manifest_fixture, graph_checks

EXPECTED = "SpottyGatewayTests.PlaylistLibraryTraversalTests/largeFolderLoadsInOneBoundedBatch()"
ACTUAL_633 = [{'kind': 'test', 'payload': {'displayName': 'Playlist library traversal', 'id': 'SpottyGatewayTests.PlaylistLibraryTraversalTests', 'kind': 'suite', 'name': 'PlaylistLibraryTraversalTests', 'sourceLocation': {'_filePath': '/Users/runner/work/Spotty/Spotty/Tests/SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'column': 2, 'fileID': 'SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'filePath': '/Users/runner/work/Spotty/Spotty/Tests/SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'line': 8}}, 'version': '6.3.0'}, {'kind': 'test', 'payload': {'id': 'SpottyGatewayTests.PlaylistLibraryTraversalTests/largeFolderLoadsInOneBoundedBatch()/PlaylistLibraryTraversalChecks.swift:10:6', 'isParameterized': False, 'kind': 'function', 'name': 'largeFolderLoadsInOneBoundedBatch()', 'sourceLocation': {'_filePath': '/Users/runner/work/Spotty/Spotty/Tests/SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'column': 6, 'fileID': 'SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'filePath': '/Users/runner/work/Spotty/Spotty/Tests/SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'line': 10}}, 'version': '6.3.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 374.196190708, 'since1970': 1790751566.56901}, 'kind': 'runStarted', 'messages': [{'symbol': 'default', 'text': 'Test run started.'}, {'symbol': 'details', 'text': 'Testing Library Version: 1902'}, {'symbol': 'details', 'text': 'Target Platform: arm64e-apple-macos14.0'}]}, 'version': '6.3.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 405.688189125, 'since1970': 1790751598.061008}, 'kind': 'testStarted', 'messages': [{'symbol': 'default', 'text': 'Suite "Playlist library traversal" started.'}], 'testID': 'SpottyGatewayTests.PlaylistLibraryTraversalTests'}, 'version': '6.3.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 405.688472416, 'since1970': 1790751598.061291}, 'kind': 'testStarted', 'messages': [{'symbol': 'default', 'text': 'Test largeFolderLoadsInOneBoundedBatch() started.'}], 'testID': 'SpottyGatewayTests.PlaylistLibraryTraversalTests/largeFolderLoadsInOneBoundedBatch()/PlaylistLibraryTraversalChecks.swift:10:6'}, 'version': '6.3.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 405.693273666, 'since1970': 1790751598.066092}, 'kind': 'testEnded', 'messages': [{'symbol': 'pass', 'text': 'Test largeFolderLoadsInOneBoundedBatch() passed after 0.004 seconds.'}], 'testID': 'SpottyGatewayTests.PlaylistLibraryTraversalTests/largeFolderLoadsInOneBoundedBatch()/PlaylistLibraryTraversalChecks.swift:10:6'}, 'version': '6.3.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 406.332444125, 'since1970': 1790751598.705263}, 'kind': 'testEnded', 'messages': [{'symbol': 'pass', 'text': 'Suite "Playlist library traversal" passed after 0.644 seconds.'}], 'testID': 'SpottyGatewayTests.PlaylistLibraryTraversalTests'}, 'version': '6.3.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 411.436865375, 'since1970': 1790751603.809684}, 'kind': 'runEnded', 'messages': [{'symbol': 'pass', 'text': 'Test run with 1100 tests in 208 suites passed after 37.240 seconds.'}]}, 'version': '6.3.0'}]
ACTUAL_64 = [{'kind': 'test', 'payload': {'displayName': 'Playlist library traversal', 'id': 'SpottyGatewayTests.PlaylistLibraryTraversalTests', 'kind': 'suite', 'name': 'PlaylistLibraryTraversalTests', 'sourceLocation': {'column': 2, 'fileID': 'SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'filePath': '/private/tmp/spotty-589-before-swift64-m0nh2b5v/checkout/.build/engine-free/package/Tests/SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'line': 8}, 'tags': []}, 'version': '6.4.0'}, {'kind': 'test', 'payload': {'id': 'SpottyGatewayTests.PlaylistLibraryTraversalTests/largeFolderLoadsInOneBoundedBatch()/PlaylistLibraryTraversalChecks.swift:10:6', 'isParameterized': False, 'kind': 'function', 'name': 'largeFolderLoadsInOneBoundedBatch()', 'sourceLocation': {'column': 6, 'fileID': 'SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'filePath': '/private/tmp/spotty-589-before-swift64-m0nh2b5v/checkout/.build/engine-free/package/Tests/SpottyGatewayTests/PlaylistLibraryTraversalChecks.swift', 'line': 10}, 'tags': []}, 'version': '6.4.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 125830.7315755, 'since1970': 1790749924.398337}, 'kind': 'runStarted', 'messages': [{'symbol': 'default', 'text': 'Test run started.'}, {'symbol': 'details', 'text': 'Testing Library Version: 2084'}, {'symbol': 'details', 'text': 'Target Platform: arm64e-apple-macos14.0'}]}, 'version': '6.4.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 125830.731749041, 'since1970': 1790749924.398509}, 'kind': 'testStarted', 'messages': [{'symbol': 'default', 'text': 'Suite "Playlist library traversal" started.'}], 'testID': 'SpottyGatewayTests.PlaylistLibraryTraversalTests'}, 'version': '6.4.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 125830.731904125, 'since1970': 1790749924.398664}, 'iteration': 1, 'kind': 'testStarted', 'messages': [], 'testID': 'SpottyGatewayTests.PlaylistLibraryTraversalTests/largeFolderLoadsInOneBoundedBatch()/PlaylistLibraryTraversalChecks.swift:10:6'}, 'version': '6.4.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 125830.738695166, 'since1970': 1790749924.405456}, 'iteration': 1, 'kind': 'testEnded', 'messages': [], 'testID': 'SpottyGatewayTests.PlaylistLibraryTraversalTests/largeFolderLoadsInOneBoundedBatch()/PlaylistLibraryTraversalChecks.swift:10:6'}, 'version': '6.4.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 125830.73884116599, 'since1970': 1790749924.4056008}, 'kind': 'testEnded', 'messages': [{'symbol': 'pass', 'text': 'Suite "Playlist library traversal" passed after 0.007 seconds.'}], 'testID': 'SpottyGatewayTests.PlaylistLibraryTraversalTests'}, 'version': '6.4.0'}, {'kind': 'event', 'payload': {'instant': {'absolute': 125830.73890016599, 'since1970': 1790749924.40566}, 'kind': 'runEnded', 'messages': [{'symbol': 'pass', 'text': 'Test run with 1 test in 1 suite passed after 0.007 seconds.'}]}, 'version': '6.4.0'}]


class NativeSelectionEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.events = self.root / "native.jsonl"

    def write(self, rows, *, trailing_newline=True):
        text = "\n".join(json.dumps(row) for row in rows)
        self.events.write_text(text + ("\n" if trailing_newline else ""))
        return self.events

    def assert_invalid(self, rows):
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_native(self.write(rows), EXPECTED)

    def test_actual_supported_toolchain_event_envelopes_prove_one_function(self):
        for rows, version in ((ACTUAL_633, "6.3.0"), (ACTUAL_64, "6.4.0")):
            with self.subTest(version=version):
                proof = evidence.validate_native(self.write(rows), EXPECTED)
                self.assertEqual(proof["event_version"], version)
                self.assertEqual(proof["completed_functions"], [EXPECTED + "/PlaylistLibraryTraversalChecks.swift:10:6"])
                self.assertEqual(proof["skipped_functions"], [])

    def test_only_source_location_suffix_is_normalized(self):
        rows = copy.deepcopy(ACTUAL_64)
        original = EXPECTED + "/PlaylistLibraryTraversalChecks.swift:10:6"
        moved = EXPECTED + "/MovedChecks.swift:901:32"
        for row in rows:
            for key in ("id", "testID"):
                if row["payload"].get(key) == original:
                    row["payload"][key] = moved
        self.assertEqual(evidence.validate_native(self.write(rows), EXPECTED)["completed_functions"], [moved])
        for wrong in (EXPECTED.replace("SpottyGatewayTests", "SpottyBoundaryTests"),
                      EXPECTED.replace("PlaylistLibraryTraversalTests", "AnotherSuite"),
                      EXPECTED.replace("largeFolderLoadsInOneBoundedBatch", "anotherFunction")):
            with self.subTest(wrong=wrong), self.assertRaises(evidence.EvidenceError):
                evidence.validate_native(self.events, wrong)

    def test_top_level_function_identity_retains_exact_module_and_lifecycle(self):
        # Observed form in the full actual 6.4 Gateway stream; these transformed
        # envelopes exercise the parser and are synthetic orchestration evidence.
        top = "SpottyGatewayTests.tokenEndpointRetries()"
        raw = top + "/TransportRetryChecks.swift:909:2"
        for fixture in (ACTUAL_633, ACTUAL_64):
            rows = copy.deepcopy(fixture)
            suite = next(row["payload"]["id"] for row in rows if row["payload"]["kind"] == "suite")
            old = next(row["payload"]["id"] for row in rows if row["payload"]["kind"] == "function")
            rows = [row for row in rows if row["payload"].get("id") != suite
                    and row["payload"].get("testID") != suite]
            for row in rows:
                for key in ("id", "testID"):
                    if row["payload"].get(key) == old:
                        row["payload"][key] = raw
            proof = evidence.validate_native(self.write(rows), top)
            self.assertEqual(proof["completed_functions"], [raw])
            for wrong in (top.replace("SpottyGatewayTests", "SpottyBoundaryTests"),
                          top.replace("tokenEndpointRetries", "otherFunction")):
                with self.subTest(wrong=wrong), self.assertRaises(evidence.EvidenceError):
                    evidence.validate_native(self.events, wrong)
            missing_end = [row for row in rows if not (row["payload"].get("testID") == raw
                                                       and row["payload"]["kind"] == "testEnded")]
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_native(self.write(missing_end), top)
        for malformed in ("tokenEndpointRetries()/TransportRetryChecks.swift:909:2",
                          top + "/nested/path/TransportRetryChecks.swift:909:2",
                          top + "/TransportRetryChecks.swift", top + "/TransportRetryChecks.swift:true:2"):
            with self.subTest(malformed=malformed), self.assertRaises(evidence.EvidenceError):
                evidence.function_identity(malformed)

    def test_missing_empty_truncated_and_malformed_records_fail_closed(self):
        for text in ("", "{}\n", "{broken}\n", "[]\n", "\n", "null\n", "{\"kind\":NaN}\n"):
            with self.subTest(text=text), self.assertRaises(evidence.EvidenceError):
                self.events.write_text(text)
                evidence.validate_native(self.events, EXPECTED)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_native(self.write(ACTUAL_64, trailing_newline=False), EXPECTED)
        self.events.unlink()
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_native(self.events, EXPECTED)
        self.events.write_bytes(b"\xff\n")
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_native(self.events, EXPECTED)

    def test_duplicate_json_keys_and_mixed_unknown_versions_fail(self):
        self.events.write_text('{"kind":"test","kind":"event","payload":{},"version":"6.4.0"}\n')
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_native(self.events, EXPECTED)
        for version in ("6.3.3", "7.0.0", 0, None):
            changed = copy.deepcopy(ACTUAL_64)
            changed[0]["version"] = version
            self.assert_invalid(changed)

    def test_duplicate_extra_and_unpaired_function_lifecycles_fail(self):
        function = next(row["payload"]["id"] for row in ACTUAL_64 if row["payload"]["kind"] == "function")
        ended = next(row for row in ACTUAL_64 if row["payload"].get("testID") == function and row["payload"]["kind"] == "testEnded")
        duplicate = copy.deepcopy(ACTUAL_64)
        duplicate.insert(-1, copy.deepcopy(ended))
        self.assert_invalid(duplicate)
        for kind in ("runStarted", "runEnded", "testStarted", "testEnded"):
            changed = [copy.deepcopy(row) for row in ACTUAL_64 if not (row["payload"]["kind"] == kind and
                       (kind.startswith("run") or row["payload"].get("testID") == function))]
            self.assert_invalid(changed)
        extra = copy.deepcopy(ACTUAL_64)
        second = function.replace("largeFolderLoadsInOneBoundedBatch", "anotherFunction")
        extra_declaration = next(copy.deepcopy(row) for row in extra if row["payload"]["kind"] == "function")
        extra_declaration["payload"]["id"] = second
        extra.insert(0, extra_declaration)
        for row in ACTUAL_64:
            if row["payload"].get("testID") == function:
                event = copy.deepcopy(row)
                event["payload"]["testID"] = second
                extra.insert(-1, event)
        self.assert_invalid(extra)
        self.assert_invalid([*copy.deepcopy(ACTUAL_64), copy.deepcopy(ACTUAL_64[-1])])

    def test_suites_cases_summaries_and_parameterized_declarations_do_not_prove_a_function(self):
        changed = [copy.deepcopy(row) for row in ACTUAL_64 if row["payload"].get("kind") != "function"
                   and "/" not in row["payload"].get("testID", "")]
        self.assert_invalid(changed)
        changed = copy.deepcopy(ACTUAL_64)
        next(row for row in changed if row["payload"]["kind"] == "function")["payload"]["isParameterized"] = True
        self.assert_invalid(changed)
        changed = copy.deepcopy(ACTUAL_64)
        next(row for row in changed if row["payload"]["kind"] == "testEnded" and "/" in row["payload"]["testID"])["payload"]["kind"] = "testCaseEnded"
        self.assert_invalid(changed)

    def test_issue_skip_nonfinite_and_backward_instants_fail(self):
        for mutation in ("issue", "skip", "nan", "backward", "undeclared"):
            changed = copy.deepcopy(ACTUAL_64)
            ended = next(row for row in changed if row["payload"]["kind"] == "testEnded" and "/" in row["payload"]["testID"])
            if mutation == "issue":
                ended["payload"]["kind"] = "issueRecorded"
            elif mutation == "skip":
                changed = [row for row in changed if not (row["payload"]["kind"] == "testStarted" and "/" in row["payload"]["testID"])]
                ended["payload"]["kind"] = "testSkipped"
            elif mutation == "nan":
                ended["payload"]["instant"]["absolute"] = float("nan")
            elif mutation == "backward":
                ended["payload"]["instant"]["absolute"] = -1
            else:
                ended["payload"]["testID"] = "UnknownSuite"
            self.assert_invalid(changed)

    def test_run_end_bounds_actual_function_case_and_skip_instants(self):
        for fixture in (ACTUAL_633, ACTUAL_64):
            changed = copy.deepcopy(fixture)
            started = next(row for row in changed if row["payload"]["kind"] == "runStarted")
            ended = next(row for row in changed if row["payload"]["kind"] == "runEnded")
            ended["payload"]["instant"]["absolute"] = started["payload"]["instant"]["absolute"]
            with self.assertRaisesRegex(evidence.EvidenceError, "runEnded precedes"):
                evidence.inspect_native(self.write(changed))

        for kind in ("testCaseEnded", "testSkipped"):
            changed = copy.deepcopy(ACTUAL_64)
            function = next(row["payload"]["id"] for row in changed if row["payload"]["kind"] == "function")
            run_end = next(row["payload"]["instant"]["absolute"] for row in changed if row["payload"]["kind"] == "runEnded")
            ended = next(row for row in changed if row["payload"].get("testID") == function and row["payload"]["kind"] == "testEnded")
            if kind == "testSkipped":
                changed = [row for row in changed if not (row["payload"].get("testID") == function and row["payload"]["kind"] == "testStarted")]
                ended["payload"]["kind"] = kind
                ended["payload"]["instant"]["absolute"] = run_end + 1
            else:
                case_start = copy.deepcopy(ended)
                case_start["payload"]["kind"] = "testCaseStarted"
                case_end = copy.deepcopy(ended)
                case_end["payload"]["kind"] = "testCaseEnded"
                case_end["payload"]["instant"]["absolute"] = run_end + 1
                index = changed.index(ended)
                changed[index:index] = [case_start, case_end]
            with self.subTest(kind=kind), self.assertRaisesRegex(evidence.EvidenceError, "runEnded precedes"):
                evidence.inspect_native(self.write(changed))

    def test_run_bound_does_not_impose_global_timestamp_order(self):
        changed = copy.deepcopy(ACTUAL_64)
        function_start = next(row["payload"]["instant"]["absolute"] for row in changed
                              if row["payload"]["kind"] == "testStarted" and "/" in row["payload"]["testID"])
        suite_start = next(row for row in changed if row["payload"]["kind"] == "testStarted" and "/" not in row["payload"]["testID"])
        suite_start["payload"]["instant"]["absolute"] = function_start + 0.000001
        evidence.validate_native(self.write(changed), EXPECTED)

    def test_cross_revision_shipping_lock_pin_and_native_inputs_must_match(self):
        identity = {"files": {"Package.resolved": "lock-digest"}, "native_swift_sha256": "swift-digest",
                    "playback_pin": ["immutable-url", "artifact-digest"]}
        identical = {"before": copy.deepcopy(identity), "after": copy.deepcopy(identity)}
        evidence.verify_comparison_inputs(identical)
        for field in ("lock", "native", "pin"):
            changed = copy.deepcopy(identical)
            if field == "lock":
                changed["after"]["files"]["Package.resolved"] = "different-lock-digest"
            elif field == "native":
                changed["after"]["native_swift_sha256"] = "different-swift-digest"
            else:
                changed["after"]["playback_pin"][1] = "different-artifact-digest"
            with self.subTest(field=field), self.assertRaises(evidence.EvidenceError):
                evidence.verify_comparison_inputs(changed)

    def test_negative_semantics_require_specific_failures_and_no_completions(self):
        boundaries = [row for row in ACTUAL_64 if row["payload"]["kind"] in {"runStarted", "runEnded"}]
        events = self.write(boundaries)
        proof = evidence.validate_outcome("zero-match", 1, evidence.NONEMPTY_DIAGNOSTIC, events, None)
        self.assertEqual(proof["completed_functions"], [])
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_outcome("zero-match", 1, "error: compiler failed", events, None)
        absent = self.root / "absent.jsonl"
        evidence.validate_outcome("unknown", 2, "Unknown --target 'TypoTests'", absent, None)
        evidence.validate_outcome("inspection", 0, "Listed tests", absent, None)
        for case, status, text in (("unknown", 0, "Unknown --target"),
                                   ("compiler", 1, "error: compiler failed"),
                                   ("inspection", 1, "Listed tests")):
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_outcome(case, status, text, absent, None)
        start = "swift-test-watchdog lane=focused repetition=1 timeout=300s command=swift test\n"
        evidence.validate_outcome("compiler", 73, start + "error: unknown argument", absent, None)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_outcome("compiler", 73, start * 2 + "error: unknown argument", absent, None)

    def test_record_preserves_original_failure_packet_and_does_not_retry(self):
        destination = self.root / "failed receipt"
        build = self.root / "owned scratch with spaces"
        metadata = build / "arm64-apple-macosx/release/description.json"
        metadata.parent.mkdir(parents=True)
        metadata.write_text('{"swiftCommands": {}}\n')
        diagnostic = metadata.with_name("SpottyGatewayTests.dia")
        diagnostic.write_bytes(b"synthetic compiler diagnostic; never compiled")
        identity = {"source": {"revision": "a" * 40}, "files": {"Package.resolved": "digest"}}
        argv = ["python3", "Scripts/verify.py", "test", "--filter", "literal value with spaces"]
        with patch.object(evidence, "snapshot", return_value=identity), \
             patch.object(evidence.subprocess, "run", return_value=subprocess.CompletedProcess(argv, 37)) as launch:
            with self.assertRaises(evidence.EvidenceError) as caught:
                evidence.record_invocation(self.root, destination, argv, expected=EXPECTED, build=build)
        self.assertEqual(caught.exception.status, 37)
        self.assertEqual(launch.call_count, 1)
        self.assertEqual(launch.call_args.args[0], argv)
        receipt = json.loads((destination / "receipt.json").read_text())
        self.assertEqual(receipt["status"], 37)
        self.assertFalse(receipt["success"])
        self.assertTrue((destination / "command.log").exists())
        self.assertIn("wall_seconds", receipt)
        packets = receipt["preserved_build_metadata"]
        self.assertEqual({Path(packet["source"]).name for packet in packets}, {metadata.name, diagnostic.name})
        for packet in packets:
            self.assertEqual(Path(packet["preserved"]).read_bytes(), Path(packet["source"]).read_bytes())
            self.assertEqual(packet["sha256"], hashlib.sha256(Path(packet["source"]).read_bytes()).hexdigest())

    def test_metadata_collection_error_cannot_replace_original_compiler_status(self):
        identity = {"source": {"revision": "a" * 40}, "files": {"Package.resolved": "digest"}}
        argv = ["python3", "Scripts/verify.py", "test"]
        destination = self.root / "metadata failed"
        with patch.object(evidence, "snapshot", return_value=identity), \
             patch.object(evidence.subprocess, "run", return_value=subprocess.CompletedProcess(argv, 73)) as launch, \
             patch.object(evidence, "preserve_build_metadata", side_effect=OSError("metadata unavailable")):
            with self.assertRaises(evidence.EvidenceError) as caught:
                evidence.record_invocation(self.root, destination, argv, expected=EXPECTED)
        self.assertEqual(caught.exception.status, 73)
        self.assertEqual(launch.call_count, 1)
        receipt = json.loads((destination / "receipt.json").read_text())
        self.assertEqual(receipt["status"], 73)
        self.assertFalse(receipt["success"])
        self.assertEqual(receipt["build_metadata_error"], "metadata unavailable")

    def test_terminal_receipt_write_preserves_failure_status_and_missing_success_receipt_fails_closed(self):
        identity = {"source": {"revision": "a" * 40}, "files": {"Package.resolved": "digest"}}
        argv = ["python3", "Scripts/verify.py", "test"]
        actual_write = evidence.write_json
        for case, process_status, expected_status in (("success", 73, 73), ("compiler", 73, 73), ("success", 0, 1)):
            with self.subTest(case=case, process_status=process_status):
                destination = self.root / f"receipt-{case}-{process_status}"
                writes = []

                def write(path, payload):
                    if path.name == "receipt.json":
                        writes.append(path)
                        if len(writes) == 2:
                            raise OSError("synthetic disk write failure")
                    actual_write(path, payload)

                def launch(command, **settings):
                    if process_status:
                        settings["stdout"].write(b"swift-test-watchdog lane=focused repetition=1 timeout=300s command=swift test\nerror: synthetic compiler failure\n")
                    else:
                        events = Path(settings["env"]["SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR"]) / "focused-repeat-1-events.jsonl"
                        events.write_text("".join(json.dumps(row) + "\n" for row in ACTUAL_64))
                    return subprocess.CompletedProcess(command, process_status)

                diagnostic = io.StringIO()
                with patch.object(evidence, "snapshot", return_value=identity), \
                     patch.object(evidence.subprocess, "run", side_effect=launch) as run, \
                     patch.object(evidence, "preserve_build_metadata", side_effect=OSError("metadata unavailable")), \
                     patch.object(evidence, "write_json", side_effect=write), \
                     patch.object(evidence.sys, "stderr", diagnostic):
                    with self.assertRaises(evidence.EvidenceError) as caught:
                        evidence.record_invocation(self.root, destination, argv, expected=EXPECTED, case=case)
                self.assertEqual(caught.exception.status, expected_status)
                self.assertEqual(run.call_count, 1)
                self.assertIn("Could not preserve required terminal evidence", diagnostic.getvalue())
                self.assertFalse(json.loads((destination / "receipt.json").read_text())["success"])

    def test_terminal_summary_write_preserves_failure_status_and_missing_success_summary_fails_closed(self):
        actual_write = evidence.write_json
        for failed in (True, False):
            with self.subTest(failed=failed):
                destination = self.root / f"summary-{failed}"
                writes = []

                def write(path, payload):
                    if path.name == "summary.json":
                        writes.append(path)
                        if len(writes) == 2:
                            raise OSError("synthetic disk write failure")
                    actual_write(path, payload)

                argv = ["focused_selection_evidence.py", "compatibility", "--root", str(self.root),
                        "--output", str(destination), "--source", str(self.root), "--head", "a" * 40,
                        "--swift-version", "6.3.3"]
                diagnostic = io.StringIO()
                with patch.object(evidence.sys, "argv", argv), \
                     patch.object(evidence.sys, "stderr", diagnostic), \
                     patch.object(evidence, "write_json", side_effect=write), \
                     patch.object(evidence, "run_compatibility", side_effect=evidence.EvidenceError("original failure", 73)
                                  if failed else None, return_value={"synthetic": True}) as run:
                    status = evidence.main()
                self.assertEqual(status, 73 if failed else 1)
                self.assertEqual(run.call_count, 1)
                self.assertIn("Could not preserve required terminal evidence", diagnostic.getvalue())
                self.assertFalse(json.loads((destination / "summary.json").read_text())["success"])

    def test_closed_stderr_cannot_replace_original_status_even_when_summary_write_also_fails(self):
        actual_write = evidence.write_json
        for sink_kind in ("broken-pipe", "closed-stream"):
            for failed_write in (False, True):
                with self.subTest(sink=sink_kind, failed_write=failed_write):
                    destination = self.root / f"stderr-{sink_kind}-{failed_write}"
                    writes = []

                    def write(path, payload):
                        if path.name == "summary.json":
                            writes.append(path)
                            if len(writes) == 2 and failed_write:
                                raise OSError("synthetic disk write failure")
                        actual_write(path, payload)

                    sink = unittest.mock.Mock()
                    sink.write.side_effect = BrokenPipeError("synthetic unavailable stderr")
                    if sink_kind == "closed-stream":
                        sink = io.StringIO()
                        sink.close()
                    argv = ["focused_selection_evidence.py", "compatibility", "--root", str(self.root),
                            "--output", str(destination), "--source", str(self.root), "--head", "a" * 40,
                            "--swift-version", "6.3.3"]
                    with patch.object(evidence.sys, "argv", argv), \
                         patch.object(evidence.sys, "stderr", sink), \
                         patch.object(evidence, "write_json", side_effect=write), \
                         patch.object(evidence, "run_compatibility", side_effect=evidence.EvidenceError("original failure", 73)) as run:
                        status = evidence.main()
                    self.assertEqual(status, 73)
                    self.assertEqual(run.call_count, 1)
                    summary = json.loads((destination / "summary.json").read_text())
                    self.assertFalse(summary["success"])
                    if not failed_write:
                        self.assertEqual(summary["error"], "original failure")

    def test_metadata_preservation_excludes_cache_dependency_and_symlink_trees(self):
        build = self.root / "scratch"
        build.mkdir()
        wanted = build / "release.yaml"
        wanted.write_text("synthetic command metadata; never compiled\n")
        for name in ("ModuleCache", "module-cache", "ModuleCache.noindex", "SwiftExplicitPrecompiledModules",
                     "SDKExplicitPrecompiledModules", "SDKModuleCaches", "checkouts", "artifacts", "package"):
            cache = build / name
            cache.mkdir()
            (cache / "description.json").write_text("unrelated cached input\n")
        (build / "linked-metadata.json").symlink_to(wanted)
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "description.json").write_text("unrelated outside input\n")
        (build / "linked-tree").symlink_to(outside, target_is_directory=True)
        packets = evidence.preserve_build_metadata(build, build / "preserved")
        self.assertEqual([packet["source"] for packet in packets], [str(wanted)])

    def test_metadata_budget_failure_preserves_partial_inventory_without_reading_large_file(self):
        build = self.root / "bounded scratch"
        build.mkdir()
        (build / "description.json").write_text("{}\n")
        with (build / "too-large.dia").open("wb") as output:
            output.truncate(32 * 1024 * 1024 + 1)
        destination = self.root / "bounded metadata"
        with self.assertRaisesRegex(evidence.EvidenceError, "bounded packet budget"):
            evidence.preserve_build_metadata(build, destination)
        inventory = json.loads((destination / "inventory.json").read_text())
        self.assertFalse(inventory["complete"])
        self.assertEqual([Path(packet["source"]).name for packet in inventory["files"]], ["description.json"])
        self.assertFalse((destination / "too-large.dia").exists())

    def test_optimized_configuration_requires_effective_O_nonwmo_and_testability(self):
        flags = list(evidence.OPTIMIZED_PROBE_FLAGS)
        self.assertEqual(flags[:4], ["--build-system", "native", "-c", "debug"])
        forwarded = [flags[index + 1] for index, value in enumerate(flags) if value == "-Xswiftc"]
        arguments = ["-Onone", "-DDEBUG", "-whole-module-optimization", *forwarded]
        native = {"GatewayTests": {"compiler_arguments": arguments}}
        swiftbuild = {"GatewayTests": {"compiler_argv": [["swiftc", *arguments]]}}
        for commands in (native, swiftbuild):
            self.assertEqual(evidence.verify_optimized_compilations(commands)["GatewayTests"],
                             {"optimization": "-O", "whole_module_optimization": False, "testable": True, "debug_hooks_compiled": True})
        evidence.verify_optimized_compilations({"GatewayTests": {"compiler_arguments": [*arguments, "-Xcc", "-Onone"]}})
        for wrong in ([*arguments, "-Onone"], [*arguments, "-Osize"], [*arguments, "-disable-testing"],
                      [flag for flag in arguments if flag != "-DDEBUG"],
                      [*arguments, "-whole-module-optimization"], [*arguments, "-wmo"],
                      [*arguments, "-Xfrontend", "-Onone"],
                      [flag for flag in arguments if flag != "-enable-testing"], []):
            with self.subTest(arguments=wrong), self.assertRaises(evidence.EvidenceError):
                evidence.verify_optimized_compilations({"GatewayTests": {"compiler_arguments": wrong}})

    def test_forwarded_testability_operands_do_not_prove_swift_testability(self):
        settings = ["-O", "-DDEBUG", "-no-whole-module-optimization"]
        for forwarding in ("-Xcc", "-Xlinker", "-Xfrontend"):
            with self.subTest(forwarding=forwarding), self.assertRaises(evidence.EvidenceError):
                evidence.verify_optimized_compilations({"GatewayTests": {
                    "compiler_arguments": [*settings, forwarding, "-enable-testing"]}})
        for control in ("-enable-testing", "-disable-testing"):
            with self.subTest(frontend_control=control), self.assertRaisesRegex(evidence.EvidenceError, "Ambiguous"):
                evidence.verify_optimized_compilations({"GatewayTests": {
                    "compiler_arguments": [*settings, "-enable-testing", "-Xfrontend", control]}})
        # Genuine Swift testability still works when Clang/linker operands use the same spelling.
        evidence.verify_optimized_compilations({"GatewayTests": {
            "compiler_arguments": [*settings, "-enable-testing", "-Xcc", "-enable-testing", "-Xlinker", "-enable-testing"]}})

    def test_native_release_requires_wmo_without_debug_and_final_testability(self):
        arguments = ["-O", "-whole-module-optimization", "-enable-testing"]
        expected = {"optimization": "-O", "whole_module_optimization": True,
                    "testable": True, "debug_hooks_compiled": False}
        self.assertEqual(evidence.verify_optimized_compilations(
            {"DomainTests": {"compiler_arguments": arguments}}, release=True)["DomainTests"], expected)
        for wrong in ([*arguments, "-DDEBUG"], [*arguments, "-D", "DEBUG"],
                      [*arguments, "-no-whole-module-optimization"], [*arguments, "-disable-testing"],
                      [*arguments, "-Onone"]):
            with self.subTest(arguments=wrong), self.assertRaises(evidence.EvidenceError):
                evidence.verify_optimized_compilations({"DomainTests": {"compiler_arguments": wrong}}, release=True)
        for debug in (["-DDEBUG"], ["-D", "DEBUG"]):
            evidence.verify_optimized_compilations({"GatewayTests": {"compiler_arguments":
                ["-O", "-no-whole-module-optimization", "-enable-testing", *debug]}})
        for forwarding in ("-Xcc", "-Xlinker", "-Xfrontend"):
            with self.subTest(forwarded_debug=forwarding), self.assertRaises(evidence.EvidenceError):
                evidence.verify_optimized_compilations({"GatewayTests": {"compiler_arguments":
                    ["-O", "-no-whole-module-optimization", "-enable-testing", forwarding, "-DDEBUG"]}})

    def test_workload_reports_require_all_bounded_rows_and_finite_observations(self):
        report = self.root / "workload.json"
        rows = [{"workload": name, "sample": sample, "cpuSeconds": 0.1, "wallSeconds": 0.2}
                for name in ("search-30", "playlist-300", "graphql-error") for sample in range(3)]
        payload = {"version": 1, "iterations": 500, "measurements": rows}
        report.write_text(json.dumps(payload))
        evidence.workload_report(report, "gateway")
        for change in ("duplicate", "iterations", "nan"):
            changed = copy.deepcopy(payload)
            if change == "duplicate":
                changed["measurements"][-1] = changed["measurements"][0]
            elif change == "iterations":
                changed["iterations"] = 1
            else:
                changed["measurements"][0]["wallSeconds"] = float("nan")
            report.write_text(json.dumps(changed))
            with self.assertRaises(evidence.EvidenceError):
                evidence.workload_report(report, "gateway")

# Exact bounded MessagePack compiler-argv array extracted from the actual 6.4 task store.
ACTUAL_SWIFTBUILD_ARGV_PACKET = bytes.fromhex('dc0066b36275696c74696e2d5377696674447269766572a22d2dd95d2f4170706c69636174696f6e732f58636f64652e6170702f436f6e74656e74732f446576656c6f7065722f546f6f6c636861696e732f58636f646544656661756c742e7863746f6f6c636861696e2f7573722f62696e2f737769667463b12d70617273652d61732d6c696272617279ac2d6d6f64756c652d6e616d65ad53706f74747947617465776179a62d4f6e6f6e65d9d3402f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f4f626a656374732d6e6f726d616c2f61726d36342f53706f747479476174657761792e537769667446696c654c697374af2d4453574946545f5041434b414745a72d444445425547d92a2d4453574946545f4d4f44554c455f5245534f555243455f42554e444c455f554e415641494c41424c45a72d4458636f6465b32d7761726e696e67732d61732d6572726f7273be2d73706f7474792d696e76616c69642d73656c6563746f722d70726f6f66ac2d706c7567696e2d70617468d9712f4170706c69636174696f6e732f58636f64652e6170702f436f6e74656e74732f446576656c6f7065722f546f6f6c636861696e732f58636f646544656661756c742e7863746f6f6c636861696e2f7573722f6c69622f73776966742f686f73742f706c7567696e732f74657374696e67bc2d656e61626c652d6578706572696d656e74616c2d66656174757265b544656275674465736372697074696f6e4d6163726fa42d73646bd9622f4170706c69636174696f6e732f58636f64652e6170702f436f6e74656e74732f446576656c6f7065722f506c6174666f726d732f4d61634f53582e706c6174666f726d2f446576656c6f7065722f53444b732f4d61634f535832372e302e73646ba72d746172676574b561726d36342d6170706c652d6d61636f7332362e30a22d67b22d6d6f64756c652d63616368652d70617468d9762f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f4d6f64756c6543616368652e6e6f696e646578aa2d5866726f6e74656e64bc2d73657269616c697a652d646562756767696e672d6f7074696f6e73b02d64697361626c652d73616e64626f78af2d656e61626c652d74657374696e67b12d696e6465782d73746f72652d70617468d9622f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f7574a42d586363d9352d445f4c49424350505f48415244454e494e475f4d4f44453d5f4c49424350505f48415244454e494e475f4d4f44455f4445425547ae2d73776966742d76657273696f6ea136a22d49d9712f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f50726f64756374732f4465627567a82d4973797374656dd9562f4170706c69636174696f6e732f58636f64652e6170702f436f6e74656e74732f446576656c6f7065722f506c6174666f726d732f4d61634f53582e706c6174666f726d2f446576656c6f7065722f7573722f6c6962a22d46d9832f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f50726f64756374732f44656275672f5061636b6167654672616d65776f726b73a22d46d9712f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f50726f64756374732f4465627567a22d46d9612f4170706c69636174696f6e732f58636f64652e6170702f436f6e74656e74732f446576656c6f7065722f506c6174666f726d732f4d61634f53582e706c6174666f726d2f446576656c6f7065722f4c6962726172792f4672616d65776f726b73a22d63a42d6a3130b22d656e61626c652d62617463682d6d6f6465ac2d696e6372656d656e74616ca42d586363ae2d69766673737461746361636865a42d586363d9d82f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f53444b537461744361636865732e6e6f696e6465782f6d61636f737832372e302d3236413432352d613066616366616431313863316137613138663061616439343633663635343937323331663664663464656633336530323261653265623866373832646631612e73646b737461746361636865b02d6f75747075742d66696c652d6d6170d9d72f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f4f626a656374732d6e6f726d616c2f61726d36342f53706f747479476174657761792d4f757470757446696c654d61702e6a736f6eab2d736176652d74656d7073b52d6e6f2d636f6c6f722d646961676e6f7374696373b62d6578706c696369742d6d6f64756c652d6275696c64b22d6d6f64756c652d63616368652d70617468d9982f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53776966744578706c69636974507265636f6d70696c65644d6f64756c6573d9202d636c616e672d7363616e6e65722d6d6f64756c652d63616368652d70617468d9762f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f4d6f64756c6543616368652e6e6f696e646578b62d73646b2d6d6f64756c652d63616368652d70617468d9802f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f53444b4578706c69636974507265636f6d70696c65644d6f64756c6573b22d656d69742d646570656e64656e63696573ac2d656d69742d6d6f64756c65b12d656d69742d6d6f64756c652d70617468d9d02f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f4f626a656374732d6e6f726d616c2f61726d36342f53706f747479476174657761792e73776966746d6f64756c65b62d73657269616c697a652d646961676e6f7374696373d92b2d646570656e64656e63792d7363616e2d73657269616c697a652d646961676e6f73746963732d70617468d9d82f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f4f626a656374732d6e6f726d616c2f61726d36342f53706f747479476174657761792d646570656e64656e63792d7363616e2e646961bc2d76616c69646174652d636c616e672d6d6f64756c65732d6f6e6365b92d636c616e672d6275696c642d73657373696f6e2d66696c65d98f2f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f4d6f64756c6543616368652e6e6f696e6465782f53657373696f6e2e6d6f64756c6576616c69646174696f6ea42d586363be2d666d6f64756c65732d7072756e652d696e74657276616c3d3836343030a42d586363bc2d666d6f64756c65732d7072756e652d61667465723d333435363030ad2d7061636b6167652d6e616d65a77061636b616765b22d656d69742d636f6e73742d76616c756573bc2d636f6e73742d6761746865722d70726f746f636f6c732d6c697374d9e12f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f4f626a656374732d6e6f726d616c2f61726d36342f53706f747479476174657761795f636f6e73745f657874726163745f70726f746f636f6c732e6a736f6ea42d586363d97b2d492f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f50726f64756374732f44656275672f696e636c756465a42d586363d9bf2d492f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f44657269766564536f75726365732d6e6f726d616c2f61726d3634a42d586363d9b82d492f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f44657269766564536f75726365732f61726d3634a42d586363d9b22d492f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f44657269766564536f7572636573a42d586363af2d4453574946545f5041434b414745a42d586363a92d4444454255473d31b12d656d69742d6f626a632d686561646572b62d656d69742d6f626a632d6865616465722d70617468d9cc2f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f7474794761746577617954657374732f6f75742f496e7465726d656469617465732e6e6f696e6465782f53706f7474792e6275696c642f44656275672f53706f747479476174657761792d742e6275696c642f4f626a656374732d6e6f726d616c2f61726d36342f53706f747479476174657761792d53776966742e68b22d776f726b696e672d6469726563746f7279d95e2f707269766174652f746d702f73706f7474792d3538392d737769667436342d70726f6f662d357171316e3871732f636865636b6f75742f2e6275696c642f746573742d746172676574732f53706f747479476174657761795465737473d9242d6578706572696d656e74616c2d656d69742d6d6f64756c652d73657061726174656c79ac2d64697361626c652d636d6f')
ACTUAL_SWIFTBUILD_COMPILATION = {'tool': 'swift-driver-compilation', 'description': 'SwiftDriver Compilation SpottyGateway normal arm64 com.apple.xcode.tools.swift.compiler', 'inputs': ['/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/AuthCookieCleanup.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/CatalogMapping.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/ClientInstallationIDStore.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/ClientTokenProvider.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/ClientTokenRequest+Wire.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/ClientTokenRequest.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/KeymasterAuth.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/KeymasterFileStore.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/KeymasterSession.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/KeymasterTokenStore.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/LoopbackCallbackServer+RequestLine.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/LoopbackCallbackServer.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/Pagination.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PartnerAPI+PlaylistLibrary.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PartnerAPI.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PathfinderAlbum.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PathfinderArtist.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PathfinderHome.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PathfinderLibrary.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PathfinderOperations.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PathfinderPlaylist.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PathfinderSearch.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/PlaylistDescription.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/SpotifyCatalogGateway.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/SpotifyConnectAPI.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/SpotifyConnectWireCommand.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/SpotifyCredentials.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/SpotifyGatewayServices.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/SpotifyRequestAdmission.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/SpotifyTransientRetry.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/SpotifyWebPlayerAPI.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/TokenRequestTransport.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/Sources/SpottyGateway/ValidatedCatalogCollection.swift', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpottyGateway.SwiftFileList', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpottyGateway-OutputFileMap.json', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpottyGateway_const_extract_protocols.json', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/GeneratedModuleMaps/SpottyGateway.modulemap', '<ClangStatCache /private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/SDKStatCaches.noindex/macosx27.0-26A425-a0facfad118c1a7a18f0aad9463f65497231f6df4def33e022ae2eb8f782df1a.sdkstatcache>', '<target-SpottyGateway-PACKAGE-TARGET:SpottyGateway-SDKROOT:macosx:SDK_VARIANT:macos-generated-headers>', '<target-SpottyGateway-PACKAGE-TARGET:SpottyGateway-SDKROOT:macosx:SDK_VARIANT:macos-copy-headers-completion>', '<target-SpottyGateway-PACKAGE-TARGET:SpottyGateway-SDKROOT:macosx:SDK_VARIANT:macos-ModuleVerifierTaskProducer>', '<target-SpottyGateway-PACKAGE-TARGET:SpottyGateway-SDKROOT:macosx:SDK_VARIANT:macos-begin-compiling>', '<WorkspaceHeaderMapVFSFilesWritten>'], 'outputs': ['/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpottyGateway Swift Compilation Finished', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/AuthCookieCleanup.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/CatalogMapping.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ClientInstallationIDStore.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ClientTokenProvider.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ClientTokenRequest+Wire.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ClientTokenRequest.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/KeymasterAuth.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/KeymasterFileStore.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/KeymasterSession.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/KeymasterTokenStore.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/LoopbackCallbackServer+RequestLine.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/LoopbackCallbackServer.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/Pagination.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PartnerAPI+PlaylistLibrary.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PartnerAPI.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderAlbum.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderArtist.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderHome.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderLibrary.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderOperations.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderPlaylist.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderSearch.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PlaylistDescription.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyCatalogGateway.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyConnectAPI.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyConnectWireCommand.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyCredentials.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyGatewayServices.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyRequestAdmission.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyTransientRetry.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyWebPlayerAPI.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/TokenRequestTransport.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ValidatedCatalogCollection.o', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/AuthCookieCleanup.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/CatalogMapping.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ClientInstallationIDStore.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ClientTokenProvider.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ClientTokenRequest+Wire.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ClientTokenRequest.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/KeymasterAuth.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/KeymasterFileStore.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/KeymasterSession.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/KeymasterTokenStore.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/LoopbackCallbackServer+RequestLine.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/LoopbackCallbackServer.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/Pagination.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PartnerAPI+PlaylistLibrary.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PartnerAPI.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderAlbum.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderArtist.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderHome.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderLibrary.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderOperations.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderPlaylist.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PathfinderSearch.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/PlaylistDescription.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyCatalogGateway.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyConnectAPI.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyConnectWireCommand.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyCredentials.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyGatewayServices.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyRequestAdmission.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyTransientRetry.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/SpotifyWebPlayerAPI.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/TokenRequestTransport.swiftconstvalues', '/private/tmp/spotty-589-swift64-proof-5qq1n8qs/checkout/.build/test-targets/SpottyGatewayTests/out/Intermediates.noindex/Spotty.build/Debug/SpottyGateway-t.build/Objects-normal/arm64/ValidatedCatalogCollection.swiftconstvalues']}


class CompatibilityProofTests(unittest.TestCase):
    """Synthetic orchestration checks; no compiler/native support is established here."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / "compatibility"
        self.destination.mkdir()
        self.head = "a" * 40
        self.identity = {"source": {"revision": self.head, "diffSHA256": hashlib.sha256(b"").hexdigest(),
                                    "untrackedFileCount": 0}, "files": {"Package.resolved": "synthetic-lock"}}
        self.calls = []
        self.full = full_manifest_fixture()

    def run_proof(self, *, full=None, fail_release=False, optimized_fetch=None):
        manifest = self.full if full is None else full

        def clone(source, head, root):
            self.calls.append(("clone", head))
            (root / "Scripts").mkdir(parents=True)
            (root / "Scripts/check-package-graphs.py").write_text("# Synthetic validator input; never compiled.\n")
            (root / "Scripts/focused_selection_evidence.py").write_bytes(Path(evidence.__file__).read_bytes())

        def full_validator(value):
            self.calls.append(("full-preflight",))
            graph_checks["verify_full_manifest"](value)

        def record(root, destination, argv, **settings):
            self.calls.append(("record", destination.name, argv, settings))
            if fail_release and destination.name == "gateway-optimized-debug-native":
                raise evidence.EvidenceError("synthetic original compiler failure", 73)
            destination.mkdir()
            if settings.get("case") == "inspection":
                (destination / "command.log").write_text("SpottyGatewayTests.SyntheticChecks/existingFunction()\n")
            return {"fetch_lines": ["Fetching synthetic forbidden dependency"] if destination.name == optimized_fetch else [], "argv": argv}

        def graph(root, target, destination, **settings):
            self.calls.append(("graph", target, settings))
            return {"engine_free": target in {"SpottyDomainTests", "SpottyTestSupportTests", "SpottyGatewayTests", "SpottyCatalogStorageTests"}}

        owner = {**graph_checks, "verify_full_manifest": full_validator,
                 "swift": lambda *args, **kwargs: subprocess.CompletedProcess([], 0, stdout=json.dumps(manifest))}
        with patch.object(evidence, "snapshot", return_value=self.identity), \
             patch.object(evidence, "toolchain", return_value={"synthetic": True}), \
             patch.object(evidence, "immutable_clone", side_effect=clone), \
             patch.object(evidence.runpy, "run_path", return_value=owner), \
             patch.object(evidence, "selected_build", side_effect=lambda root, target: root / ".build/test-targets" / target), \
             patch.object(evidence, "record_invocation", side_effect=record), \
             patch.object(evidence, "graph_proof", side_effect=graph), \
             patch.object(evidence, "workload_report", return_value={"synthetic": True}):
            return evidence.run_compatibility(self.root, self.destination, str(self.root), self.head, "6.3.3")

    def test_full_current_inventory_precedes_seven_exact_cuts_and_three_explicit_optimized_builds(self):
        proof = self.run_proof()
        self.assertEqual(self.calls[:2], [("clone", self.head), ("full-preflight",)])
        records = [call for call in self.calls if call[0] == "record"]
        success = [call for call in records if call[3].get("case", "success") == "success"]
        builds = [call for call in success if "--skip-build" not in call[2]]
        self.assertEqual(len(builds), 10)
        self.assertEqual({call[2][4] for call in builds if "--build-system" not in call[2]},
                         {"SpottyGatewayTests", *(target for target, _ in evidence.PROBES)})
        for call in builds:
            self.assertIsNotNone(call[3]["expected"])
        for call in success:
            if "--build-system" in call[2]:
                self.assertIn("-O", call[2])
                self.assertIn("-enable-testing", call[2])
                configuration = call[2][call[2].index("-c") + 1]
                if call[2][4] == "SpottyDomainTests":
                    self.assertEqual(configuration, "release")
                    self.assertNotIn("-no-whole-module-optimization", call[2])
                else:
                    self.assertEqual(configuration, "debug")
                    self.assertIn("-no-whole-module-optimization", call[2])
        optimized_skips = [call for call in success if "--build-system" in call[2] and "--skip-build" in call[2]]
        self.assertEqual(len(optimized_skips), 3)
        optimized_graphs = [call for call in self.calls if call[0] == "graph" and call[2].get("optimized")]
        self.assertEqual({call[1] for call in optimized_graphs},
                         {"SpottyGatewayTests", "SpottyBoundaryTests", "SpottyDomainTests"})
        self.assertEqual([call[1] for call in optimized_graphs if call[2].get("optimized_release")],
                         ["SpottyDomainTests"])
        self.assertEqual(len(proof["module_probes"]), 7)
        self.assertEqual(proof["head"], self.head)
        self.assertTrue(proof["full_reference"]["full_reference_validated"])
        self.assertEqual({call[3].get("case") for call in records if "case" in call[3]},
                         {"zero-match", "skipped", "inspection", "unknown", "conflict", "compiler"})

    def test_invalid_full_reference_stops_before_any_selected_invocation(self):
        broken = copy.deepcopy(self.full)
        broken["targets"] = [target for target in broken["targets"] if target["name"] != "SpottyBoundaryTests"]
        with self.assertRaises(ValueError):
            self.run_proof(full=broken)
        self.assertFalse(any(call[0] == "record" for call in self.calls))

    def test_optimized_failure_is_terminal_without_retry_or_remaining_probes(self):
        with self.assertRaises(evidence.EvidenceError) as caught:
            self.run_proof(fail_release=True)
        self.assertEqual(caught.exception.status, 73)
        records = [call for call in self.calls if call[0] == "record"]
        self.assertEqual([call[1] for call in records if "--build-system" in call[2]], ["gateway-optimized-debug-native"])

    def test_optimized_gateway_build_and_skip_build_reject_dependency_fetches(self):
        for label in ("gateway-optimized-debug-native", "gateway-optimized-debug-native-skip-build"):
            with self.subTest(label=label):
                self.destination = self.root / label
                self.destination.mkdir()
                self.calls = []
                with self.assertRaisesRegex(evidence.EvidenceError, "engine-free Gateway probe fetched"):
                    self.run_proof(optimized_fetch=label)
                optimized = [call[1] for call in self.calls if call[0] == "record" and "--build-system" in call[2]]
                self.assertEqual(optimized, ["gateway-optimized-debug-native"] if label == "gateway-optimized-debug-native" else ["gateway-optimized-debug-native", label])
                self.assertFalse(any(call[0] == "graph" and call[2].get("optimized") for call in self.calls))


class ReferenceGraphProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.workspace = self.root / ".build/test-targets/SpottyDomainTests"
        self.package = self.workspace / "package"
        self.package.mkdir(parents=True)
        (self.package / "Package.swift").write_text("// Synthetic probe input; never compiled.\n")
        (self.root / "Scripts").mkdir()
        (self.root / "Scripts/check-package-graphs.py").write_text("# Synthetic legacy probe owner.\n")
        self.full = full_manifest_fixture()
        names, _ = graph_checks["dependency_closure"](
            {item["name"]: item for item in self.full["targets"]}, "SpottyDomainTests")
        self.focused = {"name": "Spotty", "targets": [copy.deepcopy(item) for item in self.full["targets"]
                                                   if item["name"] in names], "dependencies": [], "products": []}

    def probe(self, full):
        calls = []

        def swift(package, graph, operation, **environment):
            calls.append((package, graph, operation, environment))
            manifest = full if graph == "full" else self.focused
            return subprocess.CompletedProcess([], 0, stdout=json.dumps(manifest))

        selection = unittest.mock.Mock(wraps=graph_checks["verify_selection"])
        # Deliberately emulate the immutable baseline's legacy API. The current
        # assessment owner must provide full-inventory validation independently.
        probe_owner = {"swift": swift, "succeeded": graph_checks["succeeded"], "verify_selection": selection}

        def owner(path):
            if Path(path).name == "verification_package.py":
                return {"workspace": lambda root, graph: self.workspace}
            return graph_checks if Path(path) == Path(evidence.__file__).with_name("check-package-graphs.py") else probe_owner

        destination = self.root / "proof"
        with patch.object(evidence.runpy, "run_path", side_effect=owner), \
             patch.object(evidence, "build_observations") as compilation:
            with self.assertRaises((ValueError, evidence.EvidenceError)) as error:
                evidence.graph_proof(self.root, "SpottyDomainTests", destination, environment={
                    "SPOTTY_PACKAGE_GRAPH": "test-target:SpottyGatewayTests",
                    "SPOTTY_BUILD_BROWSING_HARNESS": "0",
                    "SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": "/synthetic/missing.xcframework"})
        compilation.assert_not_called()
        return destination, calls, selection, str(error.exception)

    def test_full_reference_probe_overrides_selected_environment_and_uses_current_validator(self):
        destination, calls, selection, error = self.probe(self.full)
        self.assertIn("Missing actual build description", error)
        self.assertEqual(len(calls), 2)
        package, graph, operation, environment = calls[1]
        self.assertEqual((package, graph, operation), (self.root, "full", "dump-package"))
        self.assertEqual(environment["SPOTTY_PACKAGE_GRAPH"], "full")
        self.assertEqual(environment["SPOTTY_BUILD_BROWSING_HARNESS"], "1")
        self.assertNotIn("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK", environment)
        self.assertEqual(calls[0][3]["SPOTTY_PACKAGE_GRAPH"], "test-target:SpottyDomainTests")
        self.assertIn("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK", calls[0][3])
        selection.assert_called_once()
        self.assertEqual(selection.call_args.args[:2], (self.full, self.focused))
        self.assertEqual(json.loads((destination / "full-manifest.json").read_text()), self.full)
        assessment = json.loads((destination / "reference-assessment.json").read_text())
        self.assertTrue(assessment["full_reference_validated"])
        self.assertFalse(assessment["probe_owner"]["has_full_manifest_validator"])
        self.assertEqual(assessment["validator"]["source"],
                         str(Path(evidence.__file__).with_name("check-package-graphs.py")))

    def test_selected_or_truncated_reference_is_rejected_before_selection_and_compiler_proof(self):
        for mode in ("self", "missing_test", "duplicate", "no_external"):
            with self.subTest(mode=mode):
                # Each failed proof owns a new packet, exactly as actual invocations do.
                full = copy.deepcopy(self.full)
                if mode == "self":
                    full = self.focused
                elif mode == "missing_test":
                    full["targets"] = [item for item in full["targets"] if item["name"] != "SpottyGatewayTests"]
                elif mode == "duplicate":
                    full["targets"].append(copy.deepcopy(full["targets"][0]))
                else:
                    full["dependencies"] = []
                destination, _, selection, error = self.probe(full)
                self.assertIn("Full verification", error)
                selection.assert_not_called()
                self.assertEqual(json.loads((destination / "full-manifest.json").read_text()), full)
                self.assertFalse(json.loads((destination / "reference-assessment.json").read_text())[
                    "full_reference_validated"])
                destination.rename(self.root / f"failed-{mode}")


class ActualBuildDescriptionTests(unittest.TestCase):
    def test_actual_swiftbuild_compiler_packet_retains_module_sdk_and_flags(self):
        decoded = evidence.decode_msgpack(ACTUAL_SWIFTBUILD_ARGV_PACKET)
        argv = evidence.compiler_arguments(decoded)
        self.assertEqual(len(argv), 1)
        actual = argv[0]
        module = actual[actual.index("-module-name") + 1]
        self.assertEqual(module, "SpottyGateway")
        self.assertEqual(actual[actual.index("-sdk") + 1],
                         "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk")
        self.assertIn("-warnings-as-errors", actual)
        self.assertIn("-Onone", actual)
        proof = evidence.build_observations({"commands": {"actual-task": ACTUAL_SWIFTBUILD_COMPILATION}})
        self.assertEqual(set(proof["compilations"]), {module})
        compiler = proof["compilations"][module]
        self.assertEqual(compiler["compiler_sdk_stat_caches"][0]["version"], "27.0")
        self.assertEqual(compiler["compiler_sdk_stat_caches"][0]["build"], "26A425")
        self.assertTrue(compiler["source_inputs"])
        # There are no -module-name operands in the JSON manifest. Structured
        # compilation tasks and actual MessagePack argv must agree instead.
        self.assertNotIn("args", ACTUAL_SWIFTBUILD_COMPILATION)

    def test_truncated_unsupported_oversized_duplicate_or_ambiguous_metadata_fails(self):
        for raw in (ACTUAL_SWIFTBUILD_ARGV_PACKET[:-1], b"\xc1", b"\x81", b"x" * (32 * 1024 * 1024 + 1),
                    b"\x82\xa1a\x01\xa1a\x02"):
            with self.subTest(size=len(raw)), self.assertRaises(evidence.EvidenceError):
                evidence.decode_msgpack(raw)
        actual = evidence.compiler_arguments(evidence.decode_msgpack(ACTUAL_SWIFTBUILD_ARGV_PACKET))[0]
        for change in (actual + ["-module-name", "Fake"], actual[:-1] + ["-sdk"],
                       ["unknown-wrapper", *actual[1:]]):
            with self.assertRaises(evidence.EvidenceError):
                evidence.compiler_arguments(change)

    def test_scope_requires_exact_targets_and_bounds_generated_runner_sources(self):
        scratch = Path("/tmp/owned selection scratch")
        targets = {"Domain": {"type": "regular"}, "SelectedTests": {"type": "test"},
                   "PinnedBinary": {"type": "binary"}}
        compilations = {"Domain": {"source_inputs": ["/source/Domain.swift"]},
                        "SelectedTests": {"source_inputs": ["/source/SelectedTests.swift"]}}
        self.assertEqual(evidence.verify_compile_scope(compilations, targets, scratch, package_name="Spotty"), [])
        # Synthetic SwiftPM aggregate runner shape. This establishes the narrow
        # contract, not an actual 6.3.3 build receipt; CI must prove that backend.
        runner = {**compilations, "SpottyPackageTests": {
            "source_inputs": [str(scratch / "debug/SpottyPackageTests.derived/runner.swift")]},
            "SpottyPackageDiscoveredTests": {"source_inputs": [
                str(scratch / "debug/SpottyPackageDiscoveredTests.derived/SelectedTests.swift"),
                str(scratch / "debug/SpottyPackageDiscoveredTests.derived/all-discovered-tests.swift")]}}
        self.assertEqual(evidence.verify_compile_scope(runner, targets, scratch, package_name="Spotty"),
                         ["SpottyPackageDiscoveredTests", "SpottyPackageTests"])
        for changed in ({"Domain": compilations["Domain"]},
                        {**compilations, "UnrelatedTests": {"source_inputs": ["/source/Other.swift"]}},
                        {**compilations, "ArbitraryExtra": {"source_inputs": [
                            str(scratch / "debug/ArbitraryExtra.derived/runner.swift")]}},
                        {**compilations, "SpottyPackageTests": {"source_inputs": []}},
                        {**compilations, "SpottyPackageTests": {"source_inputs": [
                            "/elsewhere/SpottyPackageTests.derived/runner.swift"]}},
                        {**compilations, "SpottyPackageTests": {"source_inputs": [
                            str(scratch / "debug/UnrelatedTests.derived/runner.swift")]}},
                        {**compilations, "SpottyPackageTests": {"source_inputs": [
                            str(scratch / "debug/SpottyPackageTests.derived/runner.swift"), "/source/Real.swift"]}},
                        {**compilations, "AnotherPackageTests": {"source_inputs": [
                            str(scratch / "debug/AnotherPackageTests.derived/runner.swift")]}}):
            with self.assertRaises(evidence.EvidenceError):
                evidence.verify_compile_scope(changed, targets, scratch, package_name="Spotty")


if __name__ == "__main__":
    unittest.main()
