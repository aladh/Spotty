"""Read-only runtime admission before invoking the controlled Home AX controller."""
import json
import math
import os
from pathlib import Path
import time

import browsing_process


def _pulse(status, process, *, now, geometry, states, sections, on_home, detail_selected):
    """Missing/stale pulses may settle; malformed, unsafe or changed state never admits."""
    if not isinstance(status, dict):
        raise ValueError("malformed Home startup pulse")
    window, display, home = (status.get(key) for key in ("window", "display", "homeProbe"))
    if (type(status.get("schemaVersion")) is not int or status["schemaVersion"] != 1
            or status.get("runID") != process["runID"]
            or type(status.get("pid")) is not int or status["pid"] != process["pid"]
            or status.get("state") not in states or status.get("failureCode") is not None
            or status.get("syntheticDependencies") is not True
            or status.get("networkSandboxVerified") is not True
            or status.get("engineUsedForPlayback") is not False
            or any(type(status.get(key)) is not int or status[key] != 0
                   for key in ("commandCount", "mutationAttempts"))
            or not all(isinstance(item, dict) for item in (window, display, home))):
        raise ValueError("Home startup identity, state or isolation mismatch")
    if (window.get("visible") is not True or window.get("miniaturized") is not False
            or home.get("connected") is not True or home.get("onHome") is not on_home
            or home.get("exactDetailSelected") is not detail_selected
            or type(home.get("sectionCount")) is not int or home["sectionCount"] != sections
            or type(display.get("maximumFramesPerSecond")) is not int
            or display["maximumFramesPerSecond"] != 120 or display.get("reducedMotion") is not False
            or (window.get("width"), window.get("height"), display.get("scale")) != geometry):
        raise ValueError("Home startup gate or fixed geometry mismatch")
    recorded = status.get("recordedAtSeconds")
    if (type(recorded) not in (int, float) or not math.isfinite(recorded) or not math.isfinite(now)):
        raise ValueError("malformed Home startup clock")
    if recorded > now + 1:
        raise ValueError("Home startup pulse is from the future")
    return now - recorded <= 3


def ready_pulse(status, process, *, now, geometry):
    return _pulse(status, process, now=now, geometry=geometry, states=("ready",),
                  sections=0, on_home=True, detail_selected=False)


def finished_pulse(status, process, *, now, geometry, sections):
    if sections not in (12, 120):
        raise ValueError("invalid Home completion fixture")
    fresh = _pulse(status, process, now=now, geometry=geometry,
                   states=("workload-running", "workload-finished"),
                   sections=sections, on_home=False, detail_selected=True)
    return fresh and status["state"] == "workload-finished"


def wait_for_ready(run_root: Path, process: dict, *, deadline: float,
                   geometry=(1728, 1084, 2), clock=time.monotonic, wall_clock=time.time,
                   sleep=time.sleep, owned=browsing_process.matches, read_status=None):
    """Caller supplies min(batch deadline, startup origin+10s). No launches or request writes."""
    started = clock()
    if not math.isfinite(deadline) or not started < deadline <= started + 10:
        raise ValueError("Home startup requires a positive deadline of at most ten seconds")
    if not browsing_process.valid_record(process) or not isinstance(process.get("runID"), str):
        raise ValueError("invalid Home startup process identity")
    if read_status is None:
        def read_status():
            return json.loads((run_root / "run-status.json").read_text())
    attempts = 0
    while clock() < deadline:
        if not owned(process):
            raise ValueError("owned Home Demo changed or exited during startup")
        attempts += 1
        try:
            status = read_status()
        except FileNotFoundError:
            missing = True
        else:
            missing = False
        if not missing and ready_pulse(status, process, now=wall_clock(), geometry=geometry):
            if not owned(process):
                raise ValueError("owned Home Demo changed before startup admission")
            if clock() >= deadline or not ready_pulse(status, process, now=wall_clock(), geometry=geometry):
                raise ValueError("Home startup deadline or pulse freshness changed before admission")
            return {"pulse": status, "attempts": attempts, "elapsedSeconds": clock() - started,
                    "startupDeadlineMonotonic": deadline}
        remaining = deadline - clock()
        if remaining <= 0:
            break
        sleep(min(0.025, remaining))
    raise TimeoutError("Home startup pulse did not become fresh and ready within its original deadline")


def retirement_proof(process, *, deadline, clock=time.monotonic, exists=None,
                     birth=browsing_process.start_identity):
    """Read-only proof. An unavailable identity query never means the old owner retired."""
    if not browsing_process.valid_record(process) or clock() >= deadline:
        raise ValueError("invalid retirement identity or elapsed deadline")
    if exists is None:
        exists = lambda pid: os.kill(pid, 0)
    try:
        exists(process["pid"])
    except ProcessLookupError:
        if clock() >= deadline:
            raise ValueError("retirement proof exceeded deadline")
        return {"retired": True, "method": "kernel ESRCH"}
    try:
        first = birth(process["pid"], deadline=deadline)
        second = birth(process["pid"], deadline=deadline)
    except (ProcessLookupError, TimeoutError):
        # The owner may exit between the presence and birth queries. Missing birth
        # alone is inconclusive; only a fresh kernel ESRCH within this same bound proves exit.
        if clock() >= deadline:
            raise ValueError("retirement proof exceeded deadline")
        try:
            exists(process["pid"])
        except ProcessLookupError:
            if clock() >= deadline:
                raise ValueError("retirement proof exceeded deadline")
            return {"retired": True, "method": "kernel ESRCH after unavailable birth query"}
        raise
    if clock() >= deadline:
        raise ValueError("retirement proof exceeded deadline")
    if first == second and first != process["startIdentity"]:
        return {"retired": True, "method": "observed replacement birth identity", "replacementBirth": first}
    return {"retired": False, "method": "recorded owner still present or birth unstable"}


def wait_for_capture_shutdown(run_root, process, external, *, deadline, clock=time.monotonic,
                              sleep=time.sleep, owned=browsing_process.matches, read_failure=None):
    """After controller failure, observe bounded cooperative cleanup without any further action."""
    started = clock()
    if not started < deadline <= started + 13:
        raise ValueError("invalid cooperative capture cleanup deadline")
    pulse = external.get("rejectedSafetyObservation", {}).get("pulse", external.get("lastSafetyPulse", {}))
    if (external.get("passed") is not False or external.get("runID") != process["runID"]
            or external.get("pid") != process["pid"] or not isinstance(pulse, dict)
            or pulse.get("runID") != process["runID"] or pulse.get("pid") != process["pid"]
            or pulse.get("networkSandboxVerified") is not True or pulse.get("syntheticDependencies") is not True
            or pulse.get("engineUsedForPlayback") is not False
            or any(type(pulse.get(key)) is not int or pulse[key] != 0
                   for key in ("commandCount", "mutationAttempts"))):
        return {"confirmed": False, "waited": False, "reason": "synthetic isolation unavailable; retire directly"}
    if read_failure is None:
        def read_failure():
            return json.loads((run_root / "home-presented-measurement.failure.json").read_text())
    while clock() < deadline:
        if not owned(process):
            return {"confirmed": False, "waited": True, "reason": "owned identity unavailable during cleanup"}
        try:
            failure = read_failure()
        except FileNotFoundError:
            missing = True
        else:
            missing = False
        if not missing:
            if (not isinstance(failure, dict) or failure.get("launchRunID") != process["runID"]
                    or failure.get("externalRequestNonce") != external.get("nonce")):
                raise ValueError("cooperative capture receipt identity mismatch")
            if clock() >= deadline or not owned(process) or clock() >= deadline:
                raise ValueError("cooperative capture cleanup deadline or identity changed")
            return {"confirmed": failure.get("captureWasStarted") is True
                    and failure.get("captureStoppedAndDrained") is True,
                    "waited": True, "receipt": failure}
        remaining = deadline - clock()
        if remaining <= 0:
            break
        sleep(min(0.025, remaining))
    return {"confirmed": False, "waited": True, "reason": "cooperative capture cleanup deadline reached"}
