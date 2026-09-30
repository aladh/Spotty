"""Pure protocol tests: no process launch, kernel inventory, sampler or compiler."""

import json
import os
from pathlib import Path
import signal
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import swift_test_host_observation as observation
from swift_test_watchdog import ProcessIdentity, TerminationRequested


class HostObservationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.bundle = self.root / "build" / "arm64-apple-macosx" / "debug" / "SpottyPackageTests.xctest"
        self.bundle.mkdir(parents=True)
        self.event_dir = self.root / "native"
        self.event_dir.mkdir()
        self.event = self.event_dir / "debug-repeat-1-events.jsonl"
        self.function_id = observation.FUNCTION + "/TestHostObservationChecks.swift:9:6"
        self.host = ProcessIdentity(13, 12, 13, (1700000000, 800),
                                    "/toolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
        self.process = SimpleNamespace(pid=11)
        self.owned = SimpleNamespace(
            process=self.process, live=lambda: [self.host], ancestry={13: [11, 12, 13]},
            commands={12: f"swift test --event-stream-output-path {self.event}",
                      13: f"swiftpm-testing-helper --test-bundle-path {self.bundle}"},
        )
        self.report = {"nonce": "fresh", "function": observation.FUNCTION,
                       "pid": 13, "ppid": 12, "pgid": 13}
        self.completions = observation.NativeCompletions(self.event_dir)

    def records(self, function_id=None, source=None):
        ident = function_id or self.function_id
        return [
            {"kind": "test", "payload": {"kind": "function", "id": ident,
             "name": "reportsExecutingHost()", "sourceLocation": {"filePath": str(source or observation.SOURCE)}}},
            {"kind": "event", "payload": {"kind": "testStarted", "testID": ident}},
            {"kind": "event", "payload": {"kind": "testEnded", "testID": ident}},
        ]

    def write_events(self, records=None, path=None):
        (path or self.event).write_text("".join(json.dumps(item) + "\n" for item in records or self.records()))
        self.completions.observe()

    def correlate(self, report=None, current=None):
        return observation.correlate(report or self.report, "fresh", self.owned, self.completions,
                                     self.root / "build", read_identity=lambda _: current or self.host)

    def test_detached_owned_host_aggregate_and_per_target_layouts(self):
        self.write_events()
        for filename in ("SpottyPackageTests.xctest", "SpottyGatewayTests.xctest"):
            with self.subTest(filename=filename):
                bundle = self.bundle.with_name(filename)
                bundle.mkdir(exist_ok=True)
                self.owned.commands[13] = f"swiftpm-testing-helper --test-bundle-path {bundle}"
                proof, _ = self.correlate()
                self.assertEqual(proof["reporter"]["pgid"], 13)
                self.assertEqual(proof["launchAncestry"], [11, 12, 13])
                self.assertEqual(proof["testBundle"], str(bundle))
                self.assertNotIn("command", proof["ownedSnapshot"][0])

    def test_actual_bundle_binary_operand_correlates_to_existing_produced_bundle(self):
        self.write_events()
        binary = self.bundle / "Contents/MacOS" / self.bundle.stem
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"synthetic native binary fixture")
        self.owned.commands[13] = f"swiftpm-testing-helper --test-bundle-path {binary} {binary}"
        proof, reason = self.correlate()
        self.assertIsNotNone(proof, reason)
        self.assertEqual(proof["testBundle"], str(self.bundle))

    def test_bundle_binary_must_exist_and_cannot_escape_through_symlink(self):
        self.write_events()
        binary = self.bundle / "Contents/MacOS" / self.bundle.stem
        self.owned.commands[13] = f"swiftpm-testing-helper --test-bundle-path {binary}"
        self.assertIsNone(self.correlate()[0])
        binary.parent.mkdir(parents=True)
        foreign = self.root / "foreign-binary"
        foreign.write_bytes(b"synthetic foreign binary fixture")
        binary.symlink_to(foreign)
        self.assertIsNone(self.correlate()[0])

    def test_pid_name_and_group_cannot_recruit_foreign_host(self):
        self.write_events()
        self.owned.live = lambda: []
        proof, reason = self.correlate()
        self.assertIsNone(proof)
        self.assertIn("fresh owned", reason)

    def test_nonce_function_and_report_identity_are_required(self):
        self.write_events()
        for update in ({"nonce": "stale"}, {"function": "wrong"}, {"pid": "13"},
                       {"pid": True}, {"ppid": 1}, {"pgid": 11}):
            with self.subTest(update=update):
                self.assertIsNone(self.correlate({**self.report, **update})[0])

    def test_birth_and_image_are_revalidated_after_event_correlation(self):
        self.write_events()
        for current in (ProcessIdentity(13, 12, 13, (1700000000, 801), self.host.executable),
                        ProcessIdentity(13, 12, 13, self.host.birth, "/bin/unrelated")):
            self.assertIsNone(self.correlate(current=current)[0])

    def test_missing_or_foreign_launch_ancestry_is_unavailable(self):
        self.write_events()
        for ancestry in ([], [13], [99, 12, 13], [11, 12, 99]):
            self.owned.ancestry[13] = ancestry
            self.assertIsNone(self.correlate()[0])

    def test_concrete_existing_loader_bundle_must_be_under_actual_build_root(self):
        self.write_events()
        foreign = self.root / "unrelated.xctest"
        foreign.mkdir()
        for command in (
                "swiftpm-testing-helper", f"swiftpm-testing-helper --test-bundle-path {foreign}",
                "swiftpm-testing-helper --test-bundle-path relative.xctest",
                f"swiftpm-testing-helper --test-bundle-path {self.bundle} --test-bundle-path {self.bundle}",
                f"swiftpm-testing-helper --test-bundle-path {self.bundle.with_name('missing.xctest')}",
                'swiftpm-testing-helper --test-bundle-path "'):
            with self.subTest(command=command):
                self.owned.commands[13] = command
                self.assertIsNone(self.correlate()[0])

    def test_symlink_cannot_escape_produced_build_tree(self):
        self.write_events()
        foreign = self.root / "foreign.xctest"
        foreign.mkdir()
        link = self.bundle.with_name("link.xctest")
        link.symlink_to(foreign)
        self.owned.commands[13] = f"swiftpm-testing-helper --test-bundle-path {link}"
        self.assertIsNone(self.correlate()[0])

    def test_started_skipped_or_foreign_source_is_not_completed_proof(self):
        for records in (self.records()[:2],
                        [*self.records()[:2], {"kind": "event", "payload": {
                            "kind": "testSkipped", "testID": self.function_id}}],
                        self.records(source=self.root / "TestHostObservationChecks.swift"),
                        self.records(function_id="OtherModule/reportsExecutingHost()/file.swift:1:1")):
            self.completions = observation.NativeCompletions(self.event_dir)
            self.write_events(records)
            self.assertIsNone(self.correlate()[0])

    def test_prior_repetition_cannot_prove_current_host(self):
        self.write_events()
        self.owned.commands[12] = f"swift test --event-stream-output-path {self.event_dir / 'debug-repeat-2-events.jsonl'}"
        self.assertIsNone(self.correlate()[0])

    def test_ambiguous_native_paths_or_duplicate_function_start_fail_closed(self):
        self.write_events()
        second = self.event_dir / "debug-repeat-2-events.jsonl"
        self.owned.commands[11] = f"watchdog --event-stream-path {second}"
        self.assertIsNone(self.correlate()[0])
        self.owned.commands.pop(11)
        with self.event.open("a") as stream:
            stream.write(json.dumps(self.records()[1]) + "\n")
        self.completions.observe()
        self.assertIsNone(self.correlate()[0])

    def test_partial_event_line_is_buffered_without_false_completion(self):
        records = self.records()
        self.write_events(records[:2])
        ended = json.dumps(records[2])
        with self.event.open("a") as stream:
            stream.write(ended[:20])
        self.completions.observe()
        self.assertIsNone(self.correlate()[0])
        with self.event.open("a") as stream:
            stream.write(ended[20:] + "\n")
        self.completions.observe()
        self.assertIsNotNone(self.correlate()[0])

    def test_replaced_or_truncated_event_file_is_rejected(self):
        self.write_events()
        self.event.write_text("")
        with self.assertRaisesRegex(ValueError, "replaced or truncated"):
            self.completions.observe()

    def test_ci_explicitly_refuses_real_or_inherited_sampler(self):
        for environment in ({"CI": "true"}, {"GITHUB_ACTIONS": "true"},
                            {"CI": "1", "SPOTTY_SWIFT_TEST_SAMPLER": "/custom/sampler"}):
            env = observation.invocation_environment(self.root, "nonce", environment)
            self.assertEqual(env["SPOTTY_SWIFT_TEST_SAMPLER"], "/usr/bin/false")
            self.assertEqual(env["SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS"], "300")
        self.assertNotIn("SPOTTY_HOST_OBSERVATION_DIR", os.environ)

    def run_mocked(self, *, command_status=0, interrupt=False, write_failure=False, timeout=False,
                   launch_interrupt=False, observation_failure=False, proof=False, output_failure=False,
                   first_signal=None, second_signal=None, first_during_cleanup=False,
                   second_during_receipt=False):
        output = self.root / "output"
        args = SimpleNamespace(output_dir=output, build_root=self.root / "build",
                               timeout_seconds=.01 if timeout else 900,
                               command=["./Scripts/check.sh"])
        process = SimpleNamespace(pid=11, returncode=None,
                                  poll=mock.Mock(return_value=None if timeout else command_status))
        owned = SimpleNamespace(observe=mock.Mock(), live=mock.Mock(return_value=[]))
        if interrupt:
            owned.observe.side_effect = TerminationRequested(signal.SIGINT)
        if observation_failure:
            owned.observe.side_effect = OSError("synthetic observation failure")
        joins = []
        signal_injected = [False]
        interrupted = [False]
        def original_int(number, frame):
            raise KeyboardInterrupt()

        def original_term(number, frame):
            raise observation.watchdog.TerminationRequested(number)

        fake_handlers = {signal.SIGINT: original_int, signal.SIGTERM: original_term}
        original_handlers = dict(fake_handlers)

        def install(number, handler):
            if interrupted[0] and not signal_injected[0] and not second_during_receipt:
                signal_injected[0] = True
                current = fake_handlers[second_signal]
                if callable(current):
                    current(second_signal, None)
            fake_handlers[number] = handler

        if first_signal is not None:
            def observe(**keywords):
                if not interrupted[0]:
                    interrupted[0] = True
                    fake_handlers[first_signal](first_signal, None)
            owned.observe.side_effect = None if first_during_cleanup else observe
            def owned_cleanup():
                if first_during_cleanup:
                    interrupted[0] = True
                    fake_handlers[first_signal](first_signal, None)
                joins.extend([20, 11])
                process.returncode = command_status
                owned.live.return_value = []
            owned.cleanup = owned_cleanup

        def launch(*arguments, **keywords):
            if proof:
                environment = keywords["env"]
                report = {**self.report, "nonce": environment["SPOTTY_HOST_OBSERVATION_NONCE"]}
                (Path(environment["SPOTTY_HOST_OBSERVATION_DIR"]) / "host-13.json").write_text(json.dumps(report))
                event = Path(environment["SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR"]) / self.event.name
                event.write_text("".join(json.dumps(item) + "\n" for item in self.records()))
                owned.process = process
                owned.ancestry = self.owned.ancestry
                owned.commands = {**self.owned.commands, 12: f"swift test --event-stream-output-path {event}"}
                owned.live.return_value = [self.host]
            if launch_interrupt:
                signal.getsignal(signal.SIGINT)(signal.SIGINT, None)
            return process

        def cleanup(child, tracker):
            self.assertIs(child, process)
            self.assertIs(tracker, owned)
            process.returncode = command_status
            owned.live.return_value = []

        original_write = Path.write_text

        def write(path, data, *arguments, **keywords):
            if path.name == "result.json" and second_during_receipt and not signal_injected[0]:
                signal_injected[0] = True
                fake_handlers[second_signal](second_signal, None)
            if write_failure and path.name == "result.json":
                raise OSError("synthetic receipt failure")
            return original_write(path, data, *arguments, **keywords)

        original_terminate = observation.watchdog.terminate_owned_group
        with mock.patch.object(observation.subprocess, "Popen", side_effect=launch) as popen, \
                mock.patch.object(observation.watchdog, "OwnedProcesses", return_value=owned), \
                mock.patch.object(observation.watchdog, "terminate_owned_group", side_effect=original_terminate if first_signal is not None else cleanup) as terminate, \
                mock.patch.object(observation.watchdog, "process_identity", return_value=self.host), \
                mock.patch.object(Path, "write_text", write), \
                mock.patch.object(observation.time, "sleep"), \
                mock.patch("builtins.print", side_effect=output_failure if isinstance(output_failure, BaseException)
                           else OSError("synthetic output failure") if output_failure else None), \
                mock.patch.object(observation.signal, "getsignal", side_effect=fake_handlers.get), \
                mock.patch.object(observation.signal, "signal", side_effect=install):
            if timeout:
                with mock.patch.object(observation.time, "monotonic", side_effect=[0, 1, 2]):
                    status = observation.run(args)
            else:
                status = observation.run(args)
        self.assertEqual(popen.call_args.args[0], ["./Scripts/check.sh"])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertNotIn("stdout", popen.call_args.kwargs)
        terminate.assert_called_once()
        self.assertEqual(fake_handlers, original_handlers)
        if first_signal is not None:
            self.assertTrue(signal_injected[0])
            self.assertEqual(joins, [20, 11])
        receipt = json.loads((output / "result.json").read_text()) if not write_failure else None
        return status, receipt

    def test_original_check_status_and_observer_failure_are_separate(self):
        status, receipt = self.run_mocked(command_status=7)
        self.assertEqual(status, 7)
        self.assertEqual(receipt["commandStatus"], 7)
        self.assertEqual(receipt["observerStatus"], 1)
        self.assertTrue(receipt["directChildJoined"])

    def test_complete_contemporaneous_proof_succeeds_without_changing_command(self):
        status, receipt = self.run_mocked(proof=True)
        self.assertEqual(status, 0)
        self.assertEqual(receipt["commandStatus"], 0)
        self.assertEqual(receipt["observerStatus"], 0)
        self.assertEqual(receipt["proofs"]["host-13.json"]["reporter"]["pid"], 13)
        self.assertEqual(receipt["unavailable"], {})
        self.assertEqual(receipt["remainingOwnedPIDs"], [])

    def test_successful_command_with_missing_proof_fails_closed(self):
        status, receipt = self.run_mocked()
        self.assertEqual(status, 1)
        self.assertEqual(receipt["commandStatus"], 0)
        self.assertIn("host", receipt["unavailable"])

    def test_launch_interrupt_is_deferred_until_child_is_owned(self):
        status, receipt = self.run_mocked(launch_interrupt=True)
        self.assertEqual(status, 130)
        self.assertTrue(receipt["directChildJoined"])

    def test_first_sigint_survives_sigterm_during_owned_cleanup_setup(self):
        status, receipt = self.run_mocked(first_signal=signal.SIGINT, second_signal=signal.SIGTERM)
        self.assertEqual(status, 130)
        self.assertEqual(receipt["commandStatus"], 130)
        self.assertTrue(receipt["directChildJoined"])

    def test_first_sigterm_survives_sigint_during_owned_cleanup_setup(self):
        status, receipt = self.run_mocked(first_signal=signal.SIGTERM, second_signal=signal.SIGINT)
        self.assertEqual(status, 143)
        self.assertEqual(receipt["commandStatus"], 143)
        self.assertTrue(receipt["directChildJoined"])

    def test_first_sigterm_survives_default_sigint_during_terminal_receipt_write(self):
        status, receipt = self.run_mocked(first_signal=signal.SIGTERM, second_signal=signal.SIGINT,
                                        second_during_receipt=True)
        self.assertEqual(status, 143)
        self.assertEqual(receipt["commandStatus"], 143)
        self.assertEqual(receipt["interruptionStatus"], 143)
        self.assertTrue(receipt["directChildJoined"])

    def test_first_signal_during_terminal_write_keeps_command_status_and_records_interruption(self):
        status, receipt = self.run_mocked(proof=True, second_signal=signal.SIGINT,
                                        second_during_receipt=True)
        self.assertEqual(status, 130)
        self.assertEqual(receipt["commandStatus"], 0)
        self.assertEqual(receipt["interruptionStatus"], 130)
        self.assertEqual(receipt["observerStatus"], 1)

    def test_first_sigint_during_cleanup_keeps_original_command_status_independently(self):
        status, receipt = self.run_mocked(first_signal=signal.SIGINT, second_signal=signal.SIGTERM,
                                        first_during_cleanup=True)
        self.assertEqual(status, 130)
        self.assertEqual(receipt["commandStatus"], 0)
        self.assertEqual(receipt["interruptionStatus"], 130)
        self.assertTrue(receipt["directChildJoined"])

    def test_first_sigterm_during_cleanup_keeps_original_command_failure_independently(self):
        status, receipt = self.run_mocked(command_status=7, first_signal=signal.SIGTERM,
                                        second_signal=signal.SIGINT, first_during_cleanup=True)
        self.assertEqual(status, 143)
        self.assertEqual(receipt["commandStatus"], 7)
        self.assertEqual(receipt["interruptionStatus"], 143)
        self.assertTrue(receipt["directChildJoined"])

    def test_observer_error_does_not_replace_original_command_exit(self):
        status, receipt = self.run_mocked(command_status=8, observation_failure=True)
        self.assertEqual(status, 8)
        self.assertEqual(receipt["commandStatus"], 8)
        self.assertEqual(receipt["observerStatus"], 1)
        self.assertIn("synthetic observation failure", receipt["observerErrors"][0])

    def test_unavailable_terminal_does_not_replace_check_status_or_receipt(self):
        status, receipt = self.run_mocked(command_status=9, output_failure=True)
        self.assertEqual(status, 9)
        self.assertEqual(receipt["commandStatus"], 9)

    def test_closed_terminal_preserves_check_status_and_receipt(self):
        status, receipt = self.run_mocked(command_status=9,
                                        output_failure=ValueError("I/O operation on closed file"))
        self.assertEqual(status, 9)
        self.assertEqual(receipt["commandStatus"], 9)

    def test_interruption_timeout_and_receipt_error_still_cleanup_and_join(self):
        status, receipt = self.run_mocked(interrupt=True)
        self.assertEqual(status, 130)
        self.assertTrue(receipt["directChildJoined"])
        (self.root / "output").rename(self.root / "interrupted")
        status, receipt = self.run_mocked(timeout=True)
        self.assertEqual(status, 124)
        self.assertTrue(receipt["directChildJoined"])
        (self.root / "output").rename(self.root / "timed-out")
        status, _ = self.run_mocked(command_status=9, write_failure=True)
        self.assertEqual(status, 9)


if __name__ == "__main__":
    unittest.main()
