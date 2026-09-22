#!/usr/bin/env python3
"""Preflight, own, save and summarize one isolated Demo Instruments recording."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import browsing_process
from summarize_synthetic_trace import summarize

WORKLOAD_TIMEOUT_SECONDS = 600
RECORDER_START_TIMEOUT_SECONDS = 50
RECORDER_SAVE_TIMEOUT_SECONDS = 180
EXPORT_TIMEOUT_SECONDS = 90

REASONS = {
    "recorder-unavailable": "Select an Xcode installation that includes xctrace and Animation Hitches.",
    "toolchain-unavailable": "Select an installed Xcode and macOS SDK before recording.",
    "session-unknown": "Run from the logged-in desktop session so its lock state can be read.",
    "session-locked": "The desktop session is locked; prepare an unlocked session before retrying.",
    "session-inactive": "The target desktop session is not active on the console.",
    "display-unavailable": "An active display is required for a visible rendering experiment.",
    "window-ineligible": "Keep the Demo window visible and not minimized before starting measurement.",
    "process-identity-mismatch": "The recorded Demo PID or executable identity no longer matches this run.",
    "invalid-manifest": "The run manifest or status is incomplete or belongs to another process.",
    "app-not-ready": "The Demo did not publish measurement readiness before its deadline.",
    "recorder-start-failed": "The recorder did not become ready; inspect the local profiler log and tracing grants.",
    "recorder-ended-early": "The recorder ended before the owned workload completed.",
    "workload-failed": "The owned Demo workload failed; inspect its local report.",
    "workload-timeout": "The owned Demo workload exceeded its bounded deadline.",
    "recorder-save-failed": "The recorder did not finish saving a complete trace.",
    "trace-export-failed": "Required trace tables could not be exported or lacked complete application frames.",
    "interrupted": "The recording was interrupted and cannot be accepted as performance evidence.",
    "capture-incomplete": "Both layout captures must finish before a comparison can be accepted.",
    "comparison-output-invalid": "Use a new output directory outside the checkout or beneath its ignored .build directory.",
}


class InvalidRun(RuntimeError):
    def __init__(self, code):
        self.code = code
        super().__init__(f"{code}: {REASONS[code]}")


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def read_json(path):
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise ValueError("Expected an object")
        return value
    except (OSError, ValueError) as error:
        raise InvalidRun("invalid-manifest") from error


def command_output(command, code, timeout=30):
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL, timeout=timeout).strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise InvalidRun(code) from error


def preflight(root):
    # Neither this probe nor the recorder handshake requests or changes any grant.
    command_output(["xcrun", "--find", "xctrace"], "recorder-unavailable")
    templates = command_output(["xcrun", "xctrace", "list", "templates"], "recorder-unavailable")
    if "Animation Hitches" not in templates:
        raise InvalidRun("recorder-unavailable")
    xcode = command_output(["xcodebuild", "-version"], "toolchain-unavailable")
    sdk = command_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "toolchain-unavailable")
    native = session_preflight()
    result = {"schemaVersion": 1, "xcodeVersion": xcode, "selectedSDKVersion": sdk, **native}
    write_json(root / "preflight.json", result)
    return result


def session_preflight():
    try:
        native = json.loads(command_output(
            ["xcrun", "swift", str(Path(__file__).with_name("browsing_preflight.swift"))], "session-unknown"))
    except ValueError as error:
        raise InvalidRun("session-unknown") from error
    session = native.get("session", {})
    if native.get("schemaVersion") != 1 or type(session.get("locked")) is not bool:
        raise InvalidRun("session-unknown")
    if session.get("locked") is True:
        raise InvalidRun("session-locked")
    if session.get("onConsole") is not True or session.get("loginDone") is not True:
        raise InvalidRun("session-inactive")
    if not isinstance(native.get("displayCount"), int) or native["displayCount"] <= 0:
        raise InvalidRun("display-unavailable")
    return native


def validate_status(manifest, process, status):
    if (manifest.get("schemaVersion") != 1 or status.get("schemaVersion") != 1
            or not manifest.get("runID") or status.get("runID") != manifest["runID"]
            or process.get("runID") != manifest["runID"] or status.get("pid") != process.get("pid")):
        raise InvalidRun("invalid-manifest")
    if not browsing_process.matches(process):
        raise InvalidRun("process-identity-mismatch")
    window = status.get("window", {})
    display = status.get("display", {})
    if (window.get("visible") is not True or window.get("miniaturized") is not False
            or not isinstance(window.get("width"), (int, float)) or window["width"] <= 0
            or not isinstance(window.get("height"), (int, float)) or window["height"] <= 0):
        raise InvalidRun("window-ineligible")
    if display.get("scale", 0) <= 0 or display.get("maximumFramesPerSecond", 0) <= 0:
        raise InvalidRun("display-unavailable")
    return {"window": window, "display": display}


def wait_for_measurement(root, manifest, process):
    deadline = time.monotonic() + WORKLOAD_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if not browsing_process.matches(process):
            raise InvalidRun("process-identity-mismatch")
        path = root / "run-status.json"
        if path.exists():
            status = read_json(path)
            if status.get("state") == "failed":
                raise InvalidRun("workload-failed")
            if status.get("state") == "measurement-ready":
                return validate_status(manifest, process, status)
        time.sleep(0.1)
    raise InvalidRun("app-not-ready")


def interruptible_child():
    signal.signal(signal.SIGINT, signal.SIG_DFL)


def stop_recorder(recorder):
    if recorder.poll() is None:
        recorder.send_signal(signal.SIGINT)
    try:
        recorder.wait(timeout=RECORDER_SAVE_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        recorder.terminate()
        try:
            recorder.wait(timeout=5)
        except subprocess.TimeoutExpired:
            recorder.kill()
            recorder.wait(timeout=5)
        raise InvalidRun("recorder-save-failed") from error
    if recorder.returncode != 0:
        raise InvalidRun("recorder-save-failed")


def export_trace(root):
    schemas = {"signposts": "os-signpost", "hitches": "hitches", "hitches-updates": "hitches-updates",
               "hitches-frame-lifetimes": "hitches-frame-lifetimes"}
    for suffix, schema in schemas.items():
        command_output(
            ["xcrun", "xctrace", "export", "--input", str(root / "animation.trace"), "--xpath",
             f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
             "--output", str(root / f"trace-{suffix}.xml")], "trace-export-failed", EXPORT_TIMEOUT_SECONDS)
    try:
        summary = summarize(root / "trace")
    except (OSError, ValueError, KeyError) as error:
        raise InvalidRun("trace-export-failed") from error
    write_json(root / "trace-summary.json", summary)


def profile(root):
    manifest = read_json(root / "manifest.json")
    try:
        process = browsing_process.load_record(root)
    except (OSError, ValueError) as error:
        raise InvalidRun("invalid-manifest") from error
    started = time.monotonic()
    history = []
    evidence = None

    def state(value, failure=None):
        history.append({"state": value, "elapsedSeconds": round(time.monotonic() - started, 3)})
        write_json(root / "profiler-state.json", {
            "schemaVersion": 1, "runID": manifest.get("runID"), "pid": process.get("pid"),
            "state": value, "failureCode": failure, "history": history, "evidence": evidence,
        })

    state("preparing")
    recorder = None
    try:
        evidence = wait_for_measurement(root, manifest, process)
        preflight(root)
        # Re-read readiness after the native/tool probes; a stale visible window is not admission.
        evidence = validate_status(manifest, process, read_json(root / "run-status.json"))
        log_path = root / "profiler.log"
        with log_path.open("w") as log:
            recorder = subprocess.Popen(
                ["xcrun", "xctrace", "record", "--template", "Animation Hitches", "--instrument", "os_signpost",
                 "--attach", str(process["pid"]), "--time-limit",
                 f"{WORKLOAD_TIMEOUT_SECONDS + RECORDER_START_TIMEOUT_SECONDS + 10}s",
                 "--output", str(root / "animation.trace")],
                stdout=log, stderr=subprocess.STDOUT, preexec_fn=interruptible_child,
                env={**os.environ, "LC_ALL": "C"})
            deadline = time.monotonic() + RECORDER_START_TIMEOUT_SECONDS
            while "Ctrl-C to stop the recording" not in log_path.read_text():
                if recorder.poll() is not None or time.monotonic() >= deadline:
                    raise InvalidRun("recorder-start-failed")
                time.sleep(0.1)
            # Recorder admission can take many seconds. Window/session/process evidence from
            # before that wait cannot authorize releasing a now-ineligible workload.
            session_preflight()
            status = read_json(root / "run-status.json")
            if status.get("state") != "measurement-ready":
                raise InvalidRun("app-not-ready")
            evidence = validate_status(manifest, process, status)
            if recorder.poll() is not None:
                raise InvalidRun("recorder-ended-early")
            # A successful attach is the read-only proof that required tracing grants are usable.
            state("recording")
            (root / "profiler-ready").touch()
            deadline = time.monotonic() + WORKLOAD_TIMEOUT_SECONDS
            while True:
                status = read_json(root / "run-status.json")
                validate_status(manifest, process, status)
                if status.get("state") == "failed":
                    raise InvalidRun("workload-failed")
                if status.get("state") == "workload-finished":
                    report = read_json(root / "report.json")
                    if report.get("passed") is not True or report.get("launch", {}).get("runID") != manifest["runID"]:
                        raise InvalidRun("workload-failed")
                    break
                if recorder.poll() is not None:
                    raise InvalidRun("recorder-ended-early")
                if time.monotonic() >= deadline:
                    raise InvalidRun("workload-timeout")
                time.sleep(0.1)
            state("workload-finished")
            state("saving")
            stop_recorder(recorder)
            recorder = None
            if "[Error]" in log_path.read_text() or not (root / "animation.trace").exists():
                raise InvalidRun("recorder-save-failed")
        export_trace(root)
        state("complete")
    except BaseException as error:
        if recorder is not None:
            state("saving")
            try:
                stop_recorder(recorder)
            except (InvalidRun, OSError):
                pass
        code = error.code if isinstance(error, InvalidRun) else "interrupted" if isinstance(error, KeyboardInterrupt) else "recorder-start-failed"
        state("failed", code)
        # A partial export from this attempt must never retain an accepted summary.
        (root / "trace-summary.json").unlink(missing_ok=True)
        raise InvalidRun(code) from error


def capture_diagnostics(root, side, error):
    """Retain the capture stage and validator's bounded per-side evidence failures."""
    from compare_synthetic_profiles import load_run

    code = error.code if isinstance(error, InvalidRun) else "capture-incomplete"
    failures = []
    if root is not None:
        try:
            state = read_json(root / "profiler-state.json")
            manifest_path = root / "manifest.json"
            # Preflight can fail before a manifest exists. Later status must bind that run.
            if manifest_path.exists():
                run_id = read_json(manifest_path).get("runID")
                identity_matches = isinstance(run_id, str) and bool(run_id) and state.get("runID") == run_id
            else:
                identity_matches = state.get("runID") is None
            if (state.get("schemaVersion") == 1 and state.get("state") == "failed"
                    and identity_matches and isinstance(state.get("failureCode"), str)
                    and state["failureCode"] in REASONS):
                code = state["failureCode"]
        except InvalidRun:
            pass
        _, failures = load_run(root, side)
    return list(dict.fromkeys([f"{side}.{code}", *(failure["code"] for failure in failures)])), failures


def compare_layouts(scenario, output):
    """Prepare both inputs before building, then reuse the existing bounded capture workflow."""
    from compare_synthetic_profiles import compare

    project = Path(__file__).resolve().parents[1]
    output = output.resolve()
    if output.is_relative_to(project) and not output.is_relative_to(project / ".build"):
        raise ValueError("Comparison output inside this checkout must be under ignored .build")
    # A new directory makes stale captures and partially overwritten comparisons impossible.
    output.mkdir(parents=True, exist_ok=False)
    fixture = read_json(scenario)
    labels = ("synchronous", "scheduled")
    for label, enabled in zip(labels, (True, False)):
        write_json(output / f"{label}.json", {**fixture, "forceSynchronousLayout": enabled})
    runs = {}
    result = {"schemaVersion": 1, "classification": "invalid", "reasonCodes": ["capture-incomplete"]}
    try:
        for side, label in zip(("left", "right"), labels):
            pointer = output / f"{label}-run.txt"
            run_root = None
            try:
                completed = subprocess.run(
                    [str(project / "Scripts/browse-synthetic.sh"), "--optimized", "--profile", str(output / f"{label}.json")],
                    cwd=project, env={**os.environ, "SPOTTY_BROWSING_RUN_ROOT_FILE": str(pointer)}, timeout=1800,
                )
                if not pointer.is_file():
                    raise InvalidRun("capture-incomplete")
                candidate = Path(pointer.read_text().strip()).resolve()
                if candidate.parent != project / ".build/browsing-runs":
                    raise InvalidRun("invalid-manifest")
                run_root = candidate
                runs[label] = run_root
                if completed.returncode != 0:
                    raise InvalidRun("capture-incomplete")
            finally:
                # The launcher's recorded identity is the only authority to stop a Demo.
                if run_root is None and pointer.is_file():
                    candidate = Path(pointer.read_text().strip()).resolve()
                    if candidate.parent == project / ".build/browsing-runs":
                        run_root = candidate
                        runs[label] = run_root
                if run_root is not None and (run_root / "process.json").is_file():
                    browsing_process.terminate(browsing_process.load_record(run_root))
        result = compare(runs[labels[0]], runs[labels[1]], "layout.forceSynchronousLayout")
        return result
    except (InvalidRun, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        result["reasonCodes"], result["invalidEvidence"] = capture_diagnostics(run_root, side, error)
        result["failedCapture"] = {"side": side, "variant": label}
        return result
    finally:
        result["runRoots"] = {label: str(root) for label, root in runs.items()}
        write_json(output / "comparison.json", result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", action="store_true", help="Reject unsuitable tools/session before building the Demo")
    parser.add_argument("--compare-layouts", type=Path, metavar="SCENARIO", help="Prepare, record and compare both layout variants with identical source/workload inputs")
    parser.add_argument("--output", type=Path, help="New directory for prepared layout fixtures and comparison result")
    parser.add_argument("run_root", type=Path, nargs="?")
    args = parser.parse_args()
    if args.compare_layouts is not None:
        if args.output is None or args.run_root is not None or args.preflight:
            parser.error("--compare-layouts requires --output and cannot combine with a run root or --preflight")
        try:
            result = compare_layouts(args.compare_layouts, args.output)
        except (OSError, ValueError, InvalidRun) as error:
            code = error.code if isinstance(error, InvalidRun) else "comparison-output-invalid"
            print(json.dumps({"passed": False, "failureCode": code, "remediation": REASONS[code]}), file=sys.stderr)
            return 2
        print(json.dumps(result, indent=2, sort_keys=True))
        return {"comparable": 0, "descriptive-only": 1, "invalid": 2}[result["classification"]]
    if args.run_root is None or args.output is not None:
        parser.error("provide a run root, or use --compare-layouts SCENARIO --output DIRECTORY")
    try:
        if args.preflight:
            preflight(args.run_root)
        else:
            profile(args.run_root)
    except InvalidRun as error:
        if args.preflight:
            write_json(args.run_root / "profiler-state.json", {"schemaVersion": 1, "state": "failed", "failureCode": error.code})
        print(json.dumps({"passed": False, "failureCode": error.code, "remediation": REASONS[error.code]}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    sys.exit(main())
