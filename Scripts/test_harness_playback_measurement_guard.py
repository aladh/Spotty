"""Synthetic scheduling/control checks. Never inspect or control a real app."""
from dataclasses import replace
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import playback_measurement_guard as guard


class FakeClock:
    def __init__(self):
        self.seconds, self.domain, self.jobs = 0.0, "synthetic-boot", []

    def __call__(self):
        return guard.ClockReading(self.seconds, self.domain)

    def at(self, deadline, callback):
        job = [deadline, callback, True]
        self.jobs.append(job)
        return lambda: job.__setitem__(2, False)

    def dispatch_before(self, deadline, pending, action):
        # Fake event loop serializes these operations. Not a production concurrency adapter.
        if self.seconds >= deadline or not pending():
            return False
        action()
        return True

    def advance(self, seconds):
        destination = self.seconds + seconds
        for job in sorted(self.jobs, key=lambda item: item[0]):
            if job[2] and job[0] <= destination:
                self.seconds, job[2] = job[0], False
                job[1]()
        self.seconds = destination


class FakeStop:
    capability = guard.StopCapability("synthetic-image", True, True, True)

    def __init__(self, clock):
        self.clock, self.requests, self.lost = clock, [], False

    def request_pause(self, target):
        self.requests.append((target, self.clock.seconds))
        if self.lost:
            raise RuntimeError("Synthetic response loss")


class Journal:
    def __init__(self):
        self.events = []

    def append(self, event):
        self.events.append(dict(event))


class MeasurementGuardChecks(unittest.TestCase):
    def prepare(self, **limits):
        self.clock, self.journal = FakeClock(), Journal()
        self.stop = FakeStop(self.clock)
        self.plays = []

        def play(target):
            self.assertEqual(self.journal.events[-1]["event"], "guard-armed")
            self.plays.append((target, self.clock.seconds))

        self.owner = guard.Coordinator(self.clock, self.clock, self.stop, play, self.journal,
                                       target="synthetic-image", device="local", output="fixed", **limits)
        self.observation(False)

    def observation(self, playing, **changes):
        observation = guard.Observation(self.clock.seconds, self.owner.generation,
                                        "synthetic-image", "local", "fixed", True, True, playing, True)
        self.owner.observe(replace(observation, **changes))

    def run_seconds(self, count, playing):
        for _ in range(count):
            self.clock.advance(1)
            self.observation(playing)

    def reasons(self):
        return [event.get("reason") for event in self.journal.events if event["event"] == "excluded"]

    def test_delayed_ack_requires_full_settling_then_full_sample(self):
        self.prepare()
        self.owner.begin(True, True)
        self.run_seconds(2, None)
        self.observation(True)
        self.run_seconds(14, True)
        self.assertEqual(self.owner.phase, "settling")
        self.run_seconds(1, True)
        self.assertEqual(self.owner.phase, "sampling")
        self.run_seconds(15, True)
        self.assertEqual(self.owner.phase, "await-paused")
        self.clock.advance(0.5)
        self.observation(False)
        self.assertEqual(self.owner.phase, "complete")
        self.assertEqual(self.owner.charged, 32.5)
        self.assertEqual(len(self.stop.requests), 1)

    def test_missing_or_late_ack_stops_without_sampling_or_retry(self):
        for late in (False, True):
            with self.subTest(late=late):
                self.prepare()
                self.owner.begin(True, True)
                self.run_seconds(3, None)
                self.clock.advance(0.1)
                if late:
                    self.observation(True)
                else:
                    self.owner.poll()
                self.assertIn("independent-stop-during-cell", self.reasons())
                self.assertEqual(len(self.stop.requests), 1)
                self.assertNotIn("sample-start", [x["event"] for x in self.journal.events])
                with self.assertRaises(RuntimeError):
                    self.owner.begin(True, True)

    def test_independent_deadline_fires_while_gui_and_owner_are_unavailable(self):
        self.prepare(playing_cap=40)
        self.owner.begin(True, True)
        # No Pause label, observation or owner poll exists during this blocked tool call.
        self.clock.advance(50)
        self.assertEqual(self.stop.requests, [("synthetic-image", 3)])
        self.assertEqual(self.owner.charged, 0)
        self.assertIsNotNone(self.owner.play_started)
        self.owner.poll()
        self.assertIn("playing-cap", self.reasons())
        self.observation(False)
        self.assertEqual(self.owner.charged, 50)
        self.assertIn("playing-cap-exceeded", self.reasons())
        self.assertEqual(len(self.stop.requests), 1)

    def test_gui_reset_preserves_clock_budget_and_rejects_old_generation(self):
        self.prepare()
        self.owner.begin(True, True)
        self.run_seconds(1, True)
        self.owner.reset_gui()
        self.assertEqual(self.owner.origin.seconds, 0)
        self.assertEqual(len(self.stop.requests), 1)
        self.clock.advance(2)
        self.observation(False, gui_generation=0)
        self.assertIsNotNone(self.owner.play_started)
        self.observation(False)
        self.assertEqual(self.owner.charged, 3)
        self.assertTrue(self.owner.failed)

    def test_paused_observation_after_play_does_not_disarm_unacknowledged_command(self):
        self.prepare()
        self.owner.begin(True, True)
        self.run_seconds(2, False)
        self.assertIsNotNone(self.owner.play_started)
        self.assertEqual(self.owner.charged, 0)
        self.clock.advance(1)
        self.assertEqual(self.stop.requests, [("synthetic-image", 3)])
        self.clock.advance(0.125)
        self.observation(False)
        self.assertTrue(self.owner.failed)
        self.assertEqual(self.owner.charged, 3.125)

    def test_acknowledged_play_has_independent_cell_stop_even_without_owner_poll(self):
        self.prepare()
        self.owner.begin(True, True)
        self.observation(True)
        self.clock.advance(100)
        self.assertEqual(self.stop.requests, [("synthetic-image", 33)])
        self.assertIsNotNone(self.owner.play_started)
        self.observation(False)
        self.assertTrue(self.owner.failed)
        self.assertEqual(self.owner.charged, 100)

    def test_lost_play_response_and_pause_response_remain_charged(self):
        self.prepare()
        self.stop.lost = True

        def unavailable(_):
            self.clock.advance(2)
            raise RuntimeError("Synthetic GUI runtime reset")

        self.owner.play = unavailable
        self.owner.begin(True, True)
        self.assertTrue(self.owner.failed)
        self.assertIsNotNone(self.owner.play_started)
        self.clock.advance(5)
        self.observation(False)
        self.assertEqual(self.owner.charged, 7)
        self.assertIn("pause-request-failed", [x["event"] for x in self.journal.events])

    def test_profile_ending_or_context_changing_during_sample_excludes_cell(self):
        for change in ({"profiler_active": False}, {"local_device": "remote"},
                       {"output": "different"}, {"window_open": False}, {"window_exposed": False}):
            with self.subTest(change=change):
                self.prepare()
                self.owner.begin(True, True)
                self.observation(True)
                self.run_seconds(15, True)
                self.clock.advance(1)
                self.observation(True, **change)
                self.assertTrue(self.owner.failed)
                self.assertEqual(len(self.stop.requests), 1)
                self.assertNotIn("cell-complete", [x["event"] for x in self.journal.events])

    def test_paused_closed_cell_needs_coverage_and_runs_no_transport_controls(self):
        self.prepare()
        self.observation(False, window_open=False, window_exposed=False)
        self.owner.begin(False, False)
        for _ in range(30):
            self.clock.advance(1)
            self.observation(False, window_open=False, window_exposed=False)
        self.assertEqual(self.owner.phase, "complete")
        self.assertEqual(self.plays + self.stop.requests, [])
        self.owner.begin(False, False)
        self.clock.advance(2)
        self.observation(False, window_open=False, window_exposed=False)
        self.assertIn("coverage-gap", self.reasons())

    def test_delayed_delivery_cannot_hide_a_gap_between_observation_timestamps(self):
        self.prepare()
        self.owner.begin(False, True)
        self.clock.advance(1.4)
        self.observation(False, at=0)
        self.assertFalse(self.owner.failed)
        self.clock.advance(1.4)
        self.observation(False)
        self.assertIn("coverage-gap", self.reasons())
        self.assertNotEqual(self.owner.phase, "complete")
        # Timely actual observations with the same1.4s delivery delay remain comparable.
        self.prepare()
        self.owner.begin(False, True)
        self.clock.advance(1.4)
        self.observation(False, at=0)
        self.clock.advance(1.4)
        self.observation(False, at=1.4)
        self.assertFalse(self.owner.failed)

    def test_missing_independent_exact_closed_stop_denies_admission(self):
        for field, value in (("idempotent", False), ("independent_of_gui", False),
                             ("works_with_window_closed", False), ("exact_target", "other")):
            with self.subTest(field=field):
                clock, stop = FakeClock(), FakeStop(FakeClock())
                stop.capability = replace(stop.capability, **{field: value})
                with self.assertRaises(ValueError):
                    guard.Coordinator(clock, clock, stop, lambda _: self.fail("Play forbidden"), Journal(),
                                      target="synthetic-image", device="local", output="fixed")

    def test_insufficient_budget_and_session_deadline_cannot_start_or_retry(self):
        self.prepare(playing_cap=35)
        self.owner.begin(True, True)
        self.assertEqual(self.plays, [])
        self.assertIn("insufficient-budget", self.reasons())
        self.prepare(session_cap=40)
        self.clock.advance(10)
        self.observation(False)
        self.owner.begin(False, True)
        self.assertIn("insufficient-budget", self.reasons())

    def test_exact_reserve_fit_cannot_start_or_retry(self):
        for limits in ({"playing_cap": 36}, {"session_cap": 36}):
            with self.subTest(limits=limits):
                self.prepare(**limits)
                self.owner.begin(True, True)
                self.assertIn("insufficient-budget", self.reasons())
                self.assertEqual(self.plays + self.stop.requests, [])
                with self.assertRaises(RuntimeError):
                    self.owner.begin(True, True)
        self.prepare(session_cap=36)
        self.owner.begin(False, True)
        self.assertIn("insufficient-budget", self.reasons())
        self.assertEqual(self.plays + self.stop.requests, [])
        with self.assertRaises(RuntimeError):
            self.owner.begin(False, True)

    def test_clock_rollback_domain_change_or_nonfinite_time_stops(self):
        for seconds, domain in ((-1, "synthetic-boot"), (1, "different-boot"), (float("nan"), "synthetic-boot")):
            with self.subTest(seconds=seconds, domain=domain):
                self.prepare()
                self.owner.begin(True, True)
                self.clock.seconds, self.clock.domain = seconds, domain
                with self.assertRaises(RuntimeError):
                    self.owner.poll()
                self.assertEqual(len(self.stop.requests), 1)
                self.assertIn("clock-discontinuity", self.reasons())

    def test_journal_close_is_idempotent_and_append_cannot_use_replacement_descriptor(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            journal = guard.PrivateJournal(root / "closed.jsonl")
            journal.close()
            replacement = os.open(root / "replacement", os.O_WRONLY | os.O_CREAT, 0o600)
            try:
                journal.close()
                os.fstat(replacement)
                with self.assertRaises(ValueError):
                    journal.append({"mustNotWrite": True})
                self.assertEqual((root / "replacement").read_bytes(), b"")
            finally:
                os.close(replacement)

    def test_journal_rejects_symlink_ancestors_final_component_and_parent_traversal(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "actual").mkdir()
            (root / "redirect").symlink_to(root / "actual", target_is_directory=True)
            with self.assertRaises(OSError):
                guard.PrivateJournal(root / "redirect" / "receipt.jsonl")
            self.assertFalse((root / "actual" / "receipt.jsonl").exists())
            (root / "existing").write_text("preserved")
            (root / "link").symlink_to(root / "existing")
            with self.assertRaises(OSError):
                guard.PrivateJournal(root / "link")
            self.assertEqual((root / "existing").read_text(), "preserved")
            with self.assertRaises(ValueError):
                guard.PrivateJournal(root / "actual" / ".." / "receipt.jsonl")

    def test_pause_receipt_gap_and_inflight_call_cannot_confirm_earlier_paused_sample(self):
        for during_call in (False, True):
            self.prepare()
            self.owner.begin(True, True)
            self.observation(True)
            self.run_seconds(29, True)
            original_append = self.journal.append
            original_pause = self.stop.request_pause
            def gap():
                self.clock.seconds += 0.5
                self.observation(False, at=self.clock.seconds - 0.25)
                self.assertIsNotNone(self.owner.play_started)
                self.assertIsNone(self.owner.guard.pause_finished_at)
            def append(event):
                if not during_call and event["event"] == "pause-requested":
                    gap()
                original_append(event)
            def pause(target):
                if during_call:
                    gap()
                original_pause(target)
            self.journal.append, self.stop.request_pause = append, pause
            self.run_seconds(1, True)
            self.assertEqual(self.owner.phase, "await-paused")
            self.observation(False, at=self.clock.seconds - 0.25)
            self.assertIsNotNone(self.owner.play_started)
            self.clock.advance(0.125)
            self.observation(False)
            self.assertEqual(self.owner.phase, "complete")
            self.assertEqual(self.owner.charged, 30.625)

    def test_exact_playing_cap_is_excluded_for_observe_and_poll_order(self):
        for poll_first in (False, True):
            self.prepare(playing_cap=37)
            self.owner.begin(True, True)
            self.observation(True)
            self.run_seconds(30, True)
            self.clock.advance(7)
            if poll_first:
                self.owner.poll()
            self.observation(False)
            self.owner.poll()
            self.assertTrue(self.owner.failed)
            self.assertEqual(self.owner.charged, 37)
            self.assertNotIn("cell-complete", [event["event"] for event in self.journal.events])

    def test_lost_pause_reply_cannot_qualify_cell_even_after_confirmed_paused(self):
        self.prepare()
        self.owner.begin(True, True)
        self.observation(True)
        self.stop.lost = True
        self.run_seconds(30, True)
        self.clock.advance(0.125)
        self.observation(False)
        self.assertTrue(self.owner.failed)
        self.assertIsNone(self.owner.play_started)
        self.assertIn("pause-request-unconfirmed", self.reasons())
        self.assertNotIn("cell-complete", [event["event"] for event in self.journal.events])

    def test_stop_clock_fault_is_recorded_excluded_and_fresh_pause_can_settle_charge(self):
        for failing_read in (1, 2, 3):
            self.prepare()
            self.owner.begin(True, True)
            self.observation(True)
            self.run_seconds(29, True)
            readings = []
            def clock():
                readings.append(True)
                if len(readings) == failing_read:
                    raise RuntimeError("Synthetic clock read fault")
                return self.clock()
            self.owner.guard.clock = clock
            self.run_seconds(1, True)
            self.assertEqual(len(self.stop.requests), 1)
            self.observation(False)
            self.assertIsNotNone(self.owner.play_started)
            self.clock.advance(0.125)
            self.observation(False)
            self.assertIsNone(self.owner.play_started)
            self.assertTrue(self.owner.failed)
            self.assertIn("stop-clock-unavailable", self.reasons())
            self.assertNotIn("cell-complete", [x["event"] for x in self.journal.events])
            self.assertTrue(any(x.get("clockUnavailable") is True or x["event"] == "pause-clock-unavailable"
                                for x in self.journal.events))

    def test_backward_or_foreign_stop_clock_cannot_accept_sample_before_finished_call(self):
        for reading in (guard.ClockReading(1, "synthetic-boot"), guard.ClockReading(30, "foreign-boot")):
            self.prepare()
            self.owner.begin(True, True)
            self.observation(True)
            self.run_seconds(29, True)
            self.owner.guard.clock = lambda: reading
            original = self.stop.request_pause
            def pause(target):
                self.clock.seconds += 1
                original(target)
            self.stop.request_pause = pause
            self.run_seconds(1, True)
            self.observation(False, at=30.75)
            self.assertTrue(self.owner.failed)
            self.assertIsNotNone(self.owner.play_started)
            self.observation(False, at=31)
            self.assertIsNotNone(self.owner.play_started, "same cutoff sample cannot be reused")
            self.clock.advance(0.1)
            self.observation(False)
            self.assertIsNone(self.owner.play_started)
            self.assertEqual(self.owner.charged, 31.1)
            self.assertNotIn("cell-complete", [x["event"] for x in self.journal.events])

    def test_owner_clock_read_exception_excludes_active_cell_and_reaches_pause(self):
        self.prepare()
        self.owner.begin(True, True)
        self.observation(True)
        readings = []
        def clock():
            readings.append(True)
            if len(readings) == 1:
                raise RuntimeError("Synthetic one-shot read failure")
            return self.clock()
        self.owner.clock = clock
        with self.assertRaises(RuntimeError):
            self.owner.poll()
        self.assertTrue(self.owner.failed)
        self.assertIn("clock-read-failed", self.reasons())
        self.assertEqual(len(self.stop.requests), 1)
        with self.assertRaises(RuntimeError):
            self.owner.begin(True, True)

    def test_poll_excludes_known_stop_clock_fault_without_observation(self):
        self.prepare()
        self.owner.begin(True, True)
        self.observation(True)
        self.run_seconds(29, True)
        self.owner.guard.clock = lambda: guard.ClockReading(1, "synthetic-boot")
        self.run_seconds(1, True)
        self.assertEqual(self.owner.phase, "await-paused")
        self.assertTrue(self.owner.guard.clock_failed)
        self.owner.poll()
        self.assertTrue(self.owner.failed)
        self.assertIn("stop-clock-unavailable", self.reasons())
        self.assertIsNotNone(self.owner.play_started)
        self.assertEqual(len(self.stop.requests), 1)
        self.assertNotIn("cell-complete", [x["event"] for x in self.journal.events])

    def test_private_journal_preserves_order_and_refuses_overwrite(self):
        with TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "receipt.jsonl"
            journal = guard.PrivateJournal(path)
            try:
                journal.append({"event": "first"})
                journal.append({"event": "second"})
            finally:
                journal.close()
            self.assertEqual([json.loads(x)["event"] for x in path.read_text().splitlines()], ["first", "second"])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                guard.PrivateJournal(path)

    def test_invalid_observation_never_publishes_or_qualifies(self):
        for changes in ({"at": float("nan")}, {"at": float("inf")}, {"at": "1"},
                        {"playing": 1}, {"window_exposed": "yes"}, {"gui_generation": False}):
            with self.subTest(changes=changes):
                self.prepare()
                admitted = self.owner.latest
                self.owner.begin(True, True)
                supplied_playing = changes.get("playing", True)
                self.observation(supplied_playing, **{key: value for key, value in changes.items() if key != "playing"})
                self.assertIs(self.owner.latest, admitted)
                self.assertIn("invalid-observation", self.reasons())
                self.assertEqual(len(self.stop.requests), 1)

    def test_receipt_failure_at_sample_end_reset_or_timer_still_requests_stop(self):
        for failure_event in ("sample-end", "gui-reset", "pause-requested"):
            with self.subTest(failure_event=failure_event):
                self.prepare()
                self.owner.begin(True, True)
                self.observation(True)
                self.run_seconds(15, True)
                original = self.journal.append

                def fail_receipt(event):
                    if event["event"] == failure_event:
                        raise OSError("Synthetic disk failure")
                    original(event)

                self.journal.append = fail_receipt
                with self.assertRaises(OSError):
                    if failure_event == "sample-end":
                        self.run_seconds(15, True)
                    elif failure_event == "gui-reset":
                        self.owner.reset_gui()
                    else:
                        self.clock.advance(18)
                self.assertTrue(self.owner.failed)
                self.assertEqual(len(self.stop.requests), 1)
                self.assertIsNotNone(self.owner.play_started)

    def test_inline_expiry_or_slow_journal_cannot_send_play_after_stop(self):
        for mode in ("inline", "slow-journal"):
            with self.subTest(mode=mode):
                self.prepare()
                if mode == "inline":
                    original_at = self.clock.at

                    def inline_at(deadline, callback):
                        cancel = original_at(deadline, callback)
                        callback()
                        return cancel

                    self.clock.at = inline_at
                else:
                    original_append = self.journal.append

                    def slow_append(event):
                        original_append(event)
                        if event["event"] == "guard-armed":
                            self.clock.advance(4)

                    self.journal.append = slow_append
                self.owner.begin(True, True)
                self.assertEqual(self.plays, [])
                self.assertEqual(len(self.stop.requests), 1)
                self.assertIn("play-dispatch-expired", self.reasons())

    def test_late_pause_ack_or_paused_sample_end_cannot_complete_beyond_session_cap(self):
        self.prepare(session_cap=40)
        self.owner.begin(True, True)
        self.observation(True)
        self.run_seconds(30, True)
        self.clock.advance(20)
        self.observation(False)
        self.assertIn("session-cap", self.reasons())
        self.assertNotEqual(self.owner.phase, "complete")
        self.prepare(session_cap=40)
        self.owner.begin(False, True)
        self.run_seconds(29, False)
        self.clock.advance(11)
        self.observation(False)
        self.assertIn("session-cap", self.reasons())
        self.assertNotEqual(self.owner.phase, "complete")

    def test_initial_arm_replacement_or_cancellation_failure_excludes_and_stops(self):
        for mode in ("initial", "replacement", "cancel", "inline-replacement"):
            with self.subTest(mode=mode):
                self.prepare()
                original_at = self.clock.at
                calls = []

                def failing_at(deadline, callback):
                    calls.append(deadline)
                    if (mode == "initial" or (mode == "replacement" and len(calls) == 2)):
                        raise OSError("Synthetic scheduler failure")
                    original_cancel = original_at(deadline, callback)
                    if mode == "inline-replacement" and len(calls) == 2:
                        callback()

                    def cancel():
                        if mode == "cancel":
                            raise OSError("Synthetic cancellation failure")
                        original_cancel()

                    return cancel

                self.clock.at = failing_at
                self.owner.begin(True, True)
                if mode != "initial":
                    self.observation(True)
                self.assertTrue(self.owner.failed)
                self.assertEqual(len(self.stop.requests), 1)
                self.assertIsNotNone(self.owner.play_started)
                if mode == "initial":
                    self.assertEqual(self.plays, [])
                self.assertNotIn("sample-start", [event["event"] for event in self.journal.events])

    def test_idle_gui_reset_requires_new_generation_admission(self):
        self.prepare()
        self.owner.reset_gui()
        with self.assertRaises(RuntimeError):
            self.owner.begin(True, True)
        self.assertEqual(self.plays, [])
        self.observation(False)
        self.owner.begin(True, True)
        self.assertEqual(len(self.plays), 1)

    def test_retired_timer_callbacks_cannot_stop_replacement_or_later_cell(self):
        self.prepare()
        self.owner.begin(True, True)
        original_ack_callback = self.clock.jobs[0][1]
        self.observation(True)
        original_ack_callback()
        self.assertEqual(self.stop.requests, [])
        replacement_callback = self.clock.jobs[1][1]
        self.run_seconds(30, True)
        self.clock.advance(0.125)
        self.observation(False)
        self.assertEqual(len(self.stop.requests), 1)
        self.owner.begin(True, True)
        original_ack_callback()
        replacement_callback()
        self.assertEqual(len(self.stop.requests), 1)
        self.assertFalse(self.owner.guard.requested)

    def test_equal_timestamp_cached_pause_cannot_confirm_completed_control_call(self):
        self.prepare()
        self.owner.begin(True, True)
        self.observation(True)
        cached = []
        append = self.journal.append
        def capture_before_pause(event):
            append(event)
            if event["event"] == "pause-requested":
                cached.append(guard.Observation(self.clock.seconds, self.owner.generation,
                                                "synthetic-image", "local", "fixed", True, True, False, True))
        self.journal.append = capture_before_pause
        self.run_seconds(30, True)
        self.assertEqual(cached[0].at, self.owner.guard.pause_finished_at)
        self.owner.observe(cached[0])
        self.assertEqual(self.owner.phase, "await-paused")
        self.assertIsNotNone(self.owner.play_started)
        self.clock.advance(0.1)
        self.observation(False)
        self.assertEqual(self.owner.phase, "complete")
        self.assertIsNone(self.owner.play_started)

    def test_three_rotated_repetitions_cover_all_four_cells_under_fake_immediate_controls(self):
        self.prepare()
        cells = [(False, True), (True, True), (False, False), (True, False)]
        for repetition in range(3):
            order = cells[repetition:] + cells[:repetition]
            for playing, window_open in order:
                self.observation(False, window_open=window_open, window_exposed=window_open)
                self.owner.begin(playing, window_open)
                self.observation(playing, window_open=window_open, window_exposed=window_open)
                for _ in range(30):
                    self.clock.advance(1)
                    self.observation(playing, window_open=window_open, window_exposed=window_open)
                if playing:
                    self.clock.advance(0.125)
                    self.observation(False, window_open=window_open, window_exposed=window_open)
                self.assertEqual(self.owner.phase, "complete")
        self.assertEqual(self.owner.charged, 180.75)
        self.assertEqual(len(self.plays), 6)
        self.assertEqual(len(self.stop.requests), 6)
        self.assertEqual(sum(event["event"] == "cell-complete" for event in self.journal.events), 12)
        # Zero fake dispatch/ack latency does not establish native feasibility under188 seconds.


if __name__ == "__main__":
    unittest.main()
