"""Home launch sequencing without a native process, display or AX action."""
import copy
from pathlib import Path
import unittest

import synthetic_home_startup as startup


class HomeStartupTests(unittest.TestCase):
    def setUp(self):
        self.process = {"pid": 42, "runID": "synthetic-run", "startIdentity": "synthetic-start",
                        "executable": "/SyntheticDemo"}
        self.pulse = {"schemaVersion": 1, "runID": "synthetic-run", "pid": 42, "state": "ready",
                      "syntheticDependencies": True, "networkSandboxVerified": True,
                      "engineUsedForPlayback": False, "commandCount": 0, "mutationAttempts": 0,
                      "recordedAtSeconds": 100,
                      "window": {"visible": True, "miniaturized": False, "width": 1728, "height": 1084},
                      "display": {"scale": 2, "maximumFramesPerSecond": 120, "reducedMotion": False},
                      "homeProbe": {"connected": True, "onHome": True, "exactDetailSelected": False, "sectionCount": 0}}
        self.elapsed = 0

    def sleep(self, seconds):
        self.elapsed += seconds

    def wait(self, reader, owned=lambda _: True, deadline=0.1):
        return startup.wait_for_ready(Path("/synthetic"), self.process, deadline=deadline,
                                      read_status=reader, owned=owned, clock=lambda: self.elapsed,
                                      wall_clock=lambda: 100 + self.elapsed, sleep=self.sleep)

    def test_delayed_first_pulse_is_awaited_before_controller_can_be_invoked(self):
        calls = []
        def reader():
            calls.append("read")
            if self.elapsed < 0.05:
                raise FileNotFoundError()
            return self.pulse
        # The previous orchestration's immediate runtime read fails this same delayed fixture.
        with self.assertRaises(FileNotFoundError):
            reader()
        calls.clear()
        evidence = self.wait(reader)
        calls.append("controller")
        self.assertEqual(calls, ["read", "read", "read", "controller"])
        self.assertEqual(evidence["attempts"], 3)
        self.assertEqual(evidence["pulse"], self.pulse)

    def test_missing_pulse_expires_without_extending_deadline_or_invoking_controller(self):
        def missing():
            raise FileNotFoundError()
        with self.assertRaises(TimeoutError):
            self.wait(missing)
        self.assertEqual(self.elapsed, 0.1)

    def test_stale_pulse_waits_for_fresh_replacement_within_same_deadline(self):
        stale = dict(self.pulse, recordedAtSeconds=96)
        evidence = self.wait(lambda: stale if self.elapsed < 0.05 else self.pulse)
        self.assertEqual(evidence["attempts"], 3)
        self.assertEqual(evidence["pulse"]["recordedAtSeconds"], 100)

    def test_stale_pulse_never_admits_without_fresh_replacement(self):
        with self.assertRaises(TimeoutError):
            self.wait(lambda: dict(self.pulse, recordedAtSeconds=96))

    def test_unsafe_failed_foreign_or_malformed_pulses_fail_without_waiting(self):
        changes = [{"pid": 43}, {"runID": "foreign"}, {"state": "failed"}, {"state": "workload-running"},
                   {"commandCount": 1}, {"mutationAttempts": 1}, {"commandCount": False},
                   {"networkSandboxVerified": False}, {"syntheticDependencies": False},
                   {"engineUsedForPlayback": True}, {"recordedAtSeconds": float("nan")},
                   {"recordedAtSeconds": 102}, {"window": None}, {"homeProbe": {}}, {"schemaVersion": True}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.wait(lambda: dict(self.pulse, **change))
        for malformed in [[], None]:
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                self.wait(lambda: malformed)
        self.assertEqual(self.elapsed, 0)

    def test_gate_and_geometry_changes_fail_even_on_fresh_pulses(self):
        for group, key, value in [("homeProbe", "sectionCount", 120), ("homeProbe", "connected", False),
                                  ("homeProbe", "onHome", False), ("homeProbe", "exactDetailSelected", True),
                                  ("window", "visible", False), ("window", "miniaturized", True),
                                  ("window", "width", 960), ("display", "scale", 1),
                                  ("display", "maximumFramesPerSecond", 60), ("display", "reducedMotion", True)]:
            pulse = copy.deepcopy(self.pulse)
            pulse[group][key] = value
            with self.subTest(group=group, key=key), self.assertRaises(ValueError):
                self.wait(lambda: pulse)

    def test_identity_loss_or_deadline_expiry_during_read_prevents_admission(self):
        owned_calls = []
        def owned(_):
            owned_calls.append(True)
            return len(owned_calls) == 1
        with self.assertRaises(ValueError):
            self.wait(lambda: self.pulse, owned=owned)
        def delayed():
            self.elapsed = 0.1
            return self.pulse
        with self.assertRaises(ValueError):
            self.wait(delayed)

    def test_oversized_or_elapsed_startup_deadlines_are_refused(self):
        for deadline in [0, 10.1, float("inf")]:
            with self.subTest(deadline=deadline), self.assertRaises(ValueError):
                self.wait(lambda: self.pulse, deadline=deadline)

    def test_report_completion_requires_a_fresh_safe_finished_pulse(self):
        pulse = copy.deepcopy(self.pulse)
        pulse["homeProbe"].update(sectionCount=120, onHome=False, exactDetailSelected=True)
        pulse["state"] = "workload-running"
        validate = lambda: startup.finished_pulse(pulse, self.process, now=100,
                                                 geometry=(1728, 1084, 2), sections=120)
        self.assertFalse(validate())
        pulse["state"] = "workload-finished"
        self.assertTrue(validate())
        pulse["recordedAtSeconds"] = 96
        self.assertFalse(validate())
        pulse["recordedAtSeconds"] = 100
        pulse["commandCount"] = 1
        with self.assertRaises(ValueError):
            validate()

    def test_final_ownership_query_cannot_outlive_deadline_or_pulse_freshness(self):
        for elapsed, deadline in [(0.1, 0.1), (4, 5)]:
            self.elapsed = 0
            calls = []
            def owned(_):
                calls.append(True)
                if len(calls) == 2:
                    self.elapsed = elapsed
                return True
            with self.subTest(elapsed=elapsed), self.assertRaises(ValueError):
                self.wait(lambda: self.pulse, owned=owned, deadline=deadline)
            self.assertEqual(len(calls), 2)

    def test_retirement_requires_kernel_absence_or_observed_replacement_birth(self):
        def absent(_):
            raise ProcessLookupError()
        proof = startup.retirement_proof(self.process, deadline=1, clock=lambda: 0, exists=absent)
        self.assertTrue(proof["retired"])
        for identity, expected in [("synthetic-start", False), ("replacement-start", True)]:
            proof = startup.retirement_proof(self.process, deadline=1, clock=lambda: 0,
                                             exists=lambda _: None, birth=lambda *_, **__: identity)
            self.assertEqual(proof["retired"], expected)

    def test_unavailable_permission_denied_or_late_retirement_probes_never_prove_exit(self):
        def unavailable(*_, **__):
            raise TimeoutError("identity query unavailable")
        with self.assertRaises(TimeoutError):
            startup.retirement_proof(self.process, deadline=1, clock=lambda: 0,
                                     exists=lambda _: None, birth=unavailable)
        def denied(_):
            raise PermissionError()
        with self.assertRaises(PermissionError):
            startup.retirement_proof(self.process, deadline=1, clock=lambda: 0, exists=denied)
        def late_absence(_):
            self.elapsed = 1
            raise ProcessLookupError()
        with self.assertRaises(ValueError):
            startup.retirement_proof(self.process, deadline=1, clock=lambda: self.elapsed, exists=late_absence)

    def test_exit_between_presence_and_either_birth_query_requires_fresh_kernel_absence(self):
        for failed_query in (1, 2):
            probes = []
            births = []
            def exists(_):
                probes.append(True)
                if len(probes) == 2:
                    raise ProcessLookupError()
            def birth(*_, **__):
                births.append(True)
                if len(births) == failed_query:
                    raise ProcessLookupError("birth unavailable")
                return "synthetic-start"
            with self.subTest(failed_query=failed_query):
                result = startup.retirement_proof(self.process, deadline=1, clock=lambda: 0,
                                                  exists=exists, birth=birth)
                self.assertTrue(result["retired"])
                self.assertEqual(len(probes), 2)
                self.assertEqual(len(births), failed_query)

    def test_unavailable_birth_reprobe_cannot_prove_exit_if_present_denied_or_late(self):
        for outcome in ("present", "denied", "late", "already-expired"):
            self.elapsed = 0
            probes = []
            def exists(_):
                probes.append(True)
                if len(probes) == 2:
                    if outcome == "denied":
                        raise PermissionError()
                    if outcome == "late":
                        self.elapsed = 1
                        raise ProcessLookupError()
            def birth(*_, **__):
                if outcome == "already-expired":
                    self.elapsed = 1
                raise ProcessLookupError("birth unavailable")
            expected = PermissionError if outcome == "denied" else (
                ValueError if outcome in ("late", "already-expired") else ProcessLookupError)
            with self.subTest(outcome=outcome), self.assertRaises(expected):
                startup.retirement_proof(self.process, deadline=1, clock=lambda: self.elapsed,
                                         exists=exists, birth=birth)
            self.assertEqual(len(probes), 1 if outcome == "already-expired" else 2)

    def cleanup_wait(self, reader, external=None, owned=lambda _: True):
        if external is None:
            external = {"runID": self.process["runID"], "pid": 42, "nonce": "owned-nonce", "passed": False,
                        "rejectedSafetyObservation": {"pulse": self.pulse}}
        return startup.wait_for_capture_shutdown(Path("/synthetic"), self.process, external,
                                                  deadline=0.1, clock=lambda: self.elapsed,
                                                  sleep=self.sleep, owned=owned, read_failure=reader)

    def test_delayed_cooperative_failure_reports_capture_stop_before_retirement(self):
        def reader():
            if self.elapsed < 0.05:
                raise FileNotFoundError()
            return {"launchRunID": "synthetic-run", "externalRequestNonce": "owned-nonce",
                    "captureWasStarted": True, "captureStoppedAndDrained": True}
        result = self.cleanup_wait(reader)
        self.assertTrue(result["confirmed"])
        self.assertEqual(self.elapsed, 0.05)

    def test_unsafe_rejection_skips_cooperative_wait_and_never_claims_drain(self):
        pulse = dict(self.pulse, networkSandboxVerified=False)
        external = {"runID": "synthetic-run", "pid": 42, "nonce": "owned-nonce", "passed": False,
                    "rejectedSafetyObservation": {"pulse": pulse}}
        def forbidden():
            self.fail("unsafe isolation must not wait for capture evidence")
        result = self.cleanup_wait(forbidden, external=external)
        self.assertFalse(result["confirmed"])
        self.assertFalse(result["waited"])

    def test_missing_cleanup_receipt_expires_and_identity_loss_cannot_prove_drain(self):
        def missing():
            raise FileNotFoundError()
        self.assertFalse(self.cleanup_wait(missing)["confirmed"])
        self.assertEqual(self.elapsed, 0.1)
        self.elapsed = 0
        self.assertFalse(self.cleanup_wait(missing, owned=lambda _: False)["confirmed"])

    def test_foreign_malformed_or_failed_capture_stop_receipts_never_qualify_cleanup(self):
        for failure in [None, [], {"launchRunID": "foreign", "externalRequestNonce": "owned-nonce"},
                        {"launchRunID": "synthetic-run", "externalRequestNonce": "foreign"}]:
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                self.cleanup_wait(lambda: failure)
        failure = {"launchRunID": "synthetic-run", "externalRequestNonce": "owned-nonce",
                   "captureWasStarted": True, "captureStoppedAndDrained": False, "captureStopError": "synthetic"}
        result = self.cleanup_wait(lambda: failure)
        self.assertFalse(result["confirmed"])
        self.assertIn("captureStopError", result["receipt"])


if __name__ == "__main__":
    unittest.main()
