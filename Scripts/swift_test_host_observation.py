"""Opt-in observer around an unchanged verification command; never recruits by PID/name/PGID.

This reports executing-host proof, not a stall cause. The immediate native reporter does
not wait for observation: a host which exits too quickly is explicitly unavailable.
"""

import argparse
from dataclasses import asdict
import json
import math
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
import uuid

import swift_test_watchdog as watchdog


FUNCTION = "SpottyGatewayTests.TestHostObservationChecks/reportsExecutingHost()"
SOURCE = Path(__file__).resolve().parents[1] / "Tests/SpottyGatewayTests/TestHostObservationChecks.swift"
UNAVAILABLE_EXIT = 1


class NativeCompletions:
    """Read append-only event files incrementally; only an exact declared function counts."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.streams = {}
        self.completed = {}
        self.errors = []

    def observe(self):
        for path in sorted(self.directory.glob("*-events.jsonl")):
            stat = path.stat()
            state = self.streams.setdefault(path, {
                "identity": (stat.st_dev, stat.st_ino), "offset": 0, "tail": b"",
                "functions": set(), "started": set(), "completed": set(),
            })
            if state["identity"] != (stat.st_dev, stat.st_ino) or stat.st_size < state["offset"]:
                raise ValueError("native event file replaced or truncated")
            with path.open("rb") as stream:
                stream.seek(state["offset"])
                data = stream.read()
                state["offset"] = stream.tell()
            lines = (state["tail"] + data).split(b"\n")
            state["tail"] = lines.pop()
            for line in lines:
                try:
                    record = json.loads(line)
                    payload = record["payload"]
                    if not isinstance(payload, dict):
                        raise ValueError("invalid payload")
                    if record.get("kind") == "test" and payload.get("kind") == "function":
                        ident = payload.get("id", "")
                        location = payload.get("sourceLocation", {})
                        if (isinstance(ident, str) and ident.startswith(FUNCTION + "/")
                                and payload.get("name") == "reportsExecutingHost()"
                                and Path(location.get("filePath", "")).resolve() == SOURCE):
                            state["functions"].add(ident)
                    elif record.get("kind") == "event" and payload.get("testID") in state["functions"]:
                        ident = payload["testID"]
                        if payload.get("kind") == "testStarted":
                            if ident in state["started"]:
                                raise ValueError("duplicate diagnostic function start")
                            state["started"].add(ident)
                        elif payload.get("kind") == "testEnded" and ident in state["started"]:
                            state["completed"].add(ident)
                except (ValueError, KeyError, TypeError, AttributeError):
                    if len(self.errors) < 20:
                        self.errors.append(f"invalid native event in {path.name}")
            self.completed[path] = sorted(state["completed"])


def bundle_path(identity, command: str, build_root: Path) -> Path | None:
    if watchdog.host_role(identity, command) is None:
        return None
    bundle = watchdog.loader_test_bundle(command, require_existing=True)
    # The watchdog owns both loader layouts. Observation additionally requires
    # the existing, resolved bundle to belong to this actual produced build tree.
    return bundle if bundle is not None and bundle.is_relative_to(build_root) else None


def correlate(report: dict, nonce: str, owned, completions: NativeCompletions,
              build_root: Path, read_identity=None) -> tuple[dict | None, str]:
    read_identity = read_identity or watchdog.process_identity
    if not isinstance(report, dict) or report.get("nonce") != nonce or report.get("function") != FUNCTION:
        return None, "report nonce/function mismatch"
    if any(type(report.get(key)) is not int or report[key] <= 0 for key in ("pid", "ppid", "pgid")):
        return None, "report identity fields unavailable"
    live = owned.live()
    matches = [item for item in live if item.pid == report["pid"]]
    if len(matches) != 1:
        return None, "reporter has no fresh owned kernel identity"
    host = matches[0]
    ancestry = owned.ancestry.get(host.pid, [])
    if (len(ancestry) < 2 or ancestry[0] != owned.process.pid or ancestry[-1] != host.pid
            or (host.ppid, host.pgid) != (report["ppid"], report["pgid"])):
        return None, "reporter launch ancestry/PPID/PGID mismatch"
    bundle = bundle_path(host, owned.commands.get(host.pid, ""), build_root)
    if bundle is None:
        return None, "concrete owned loader bundle under produced build root unavailable"
    # Bind events to the concrete invocation in this host's observed launch chain.
    # A prior repetition's completed function cannot prove a later reporter.
    event_paths = set()
    for pid in ancestry:
        try:
            arguments = shlex.split(owned.commands.get(pid, ""))
            for flag in ("--event-stream-path", "--event-stream-output-path"):
                if arguments.count(flag) == 1:
                    raw = Path(arguments[arguments.index(flag) + 1])
                    if raw.is_absolute():
                        event_paths.add(raw.resolve())
        except (ValueError, IndexError):
            return None, "native event launch arguments unavailable"
    completed = [(path, ident) for path, identities in completions.completed.items()
                 if path.resolve() in event_paths for ident in identities]
    if len(event_paths) != 1:
        return None, "native event path is not bound to this owned launch ancestry"
    if len(completed) != 1 or completions.errors:
        return None, "exact native function completion unavailable or ambiguous"
    if not host.same_image(read_identity(host.pid)):
        return None, "reporter kernel birth/image changed during correlation"
    path, ident = completed[0]
    return {
        "reporter": asdict(host), "launchAncestry": ancestry,
        "testBundle": str(bundle), "nativeEventPath": str(path), "completedFunction": ident,
        "ownedSnapshot": [dict(asdict(item), launchAncestry=owned.ancestry.get(item.pid, [])) for item in live],
        "capturedAtUnixSeconds": time.time(),
    }, "proven owned executing host"


def invocation_environment(output: Path, nonce: str, environment: dict) -> dict:
    result = dict(environment)
    result.update(SPOTTY_HOST_OBSERVATION_DIR=str(output / "reports"),
                  SPOTTY_HOST_OBSERVATION_NONCE=nonce,
                  SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR=str(output / "native"),
                  SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS="300")
    if result.get("CI", "").lower() in ("1", "true") or result.get("GITHUB_ACTIONS") == "true":
        # The frozen native watchdog accepts a sampler executable. Explicitly
        # refuse real sampling in CI, including inherited injected samplers.
        result["SPOTTY_SWIFT_TEST_SAMPLER"] = "/usr/bin/false"
    return result


def result_status(command_status: int, observer_status: int) -> int:
    return command_status if command_status else observer_status


def announce(message: str, *, file=None):
    try:
        print(message, file=file)
    except (OSError, ValueError):
        # The durable receipt is independent of an unavailable terminal sink.
        pass


def run(args) -> int:
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    latch = watchdog.SignalLatch()
    latch.deferred = 1
    try:
        status = run_observed(args, handlers, latch)
    finally:
        # Keep the latch installed through native inventory, durable receipts and
        # terminal notification. Restore original handlers at the final boundary.
        latch.deferred += 1
        try:
            for sig, handler in handlers.items():
                watchdog.set_signal_handler(sig, handler, latch)
        finally:
            latch.deferred = 0
    return 128 + latch.number if latch.number is not None else status


def run_observed(args, handlers, latch) -> int:
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    for directory in ("reports", "native"):
        (output / directory).mkdir()
    nonce = uuid.uuid4().hex
    env = invocation_environment(output, nonce, os.environ)
    receipt = {
        "schemaVersion": 1, "nonce": nonce, "command": args.command,
        "buildRoot": str(args.build_root.resolve()), "outerDeadlineSeconds": args.timeout_seconds,
        "nativeDeadlineSeconds": 300, "commandStatus": None, "observerStatus": UNAVAILABLE_EXIT,
        "proofs": {}, "unavailable": {}, "observerErrors": [],
        "sampling": "refused in CI; adapter never launches a sampler",
        "limitations": ["Reporter immediately returns; exited or unobserved ancestry cannot be proved.",
                        "Native events identify a function, not PID; proof requires the nonce self-report too.",
                        "Snapshot is sequentially revalidated, not an atomic kernel/event transaction.",
                        "This does not attribute either historical stall or establish its runtime cause."],
    }
    (output / "ready.json").write_text(json.dumps({"nonce": nonce, "prearmed": True}) + "\n")
    started = time.monotonic()
    deadline = started + args.timeout_seconds
    process = owned = None
    completions = NativeCompletions(output / "native")
    observers_ok = True

    try:
        for sig in handlers:
            watchdog.set_signal_handler(sig, latch.request, latch)
        # Inherit output directly: observation never owns a pipe or delays/drains native output.
        # Defer signals across creation/ownership setup so an interrupt cannot orphan
        # a successfully forked child before Popen returns its handle.
        process = subprocess.Popen(args.command, env=env, stdin=subprocess.DEVNULL, start_new_session=True)
        owned = watchdog.OwnedProcesses(process)
        latch.deferred = 0
        latch.check()
        while True:
            try:
                owned.observe(deadline=deadline)
                completions.observe()
                for path in sorted((output / "reports").glob("*.json")):
                    if path.name in receipt["proofs"]:
                        continue
                    report = json.loads(path.read_text())
                    proof, reason = correlate(report, nonce, owned, completions, args.build_root.resolve())
                    if proof is not None:
                        receipt["proofs"][path.name] = proof
                        receipt["unavailable"].pop(path.name, None)
                        (output / "proofs.json").write_text(json.dumps(receipt["proofs"], indent=2) + "\n")
                    else:
                        receipt["unavailable"][path.name] = reason
            except (OSError, ValueError) as error:
                # Observation failure must not change or terminate an otherwise valid check.
                observers_ok = False
                if len(receipt["observerErrors"]) < 20:
                    receipt["observerErrors"].append(f"{type(error).__name__}: {error}")
            status = process.poll()
            if status is not None:
                receipt["commandStatus"] = status if status >= 0 else 128 - status
                break
            if time.monotonic() >= deadline:
                receipt["commandStatus"] = watchdog.TIMEOUT_EXIT
                receipt["observerErrors"].append("outer command deadline expired")
                break
            time.sleep(min(.05, max(0, deadline - time.monotonic())))
    except (KeyboardInterrupt, watchdog.TerminationRequested) as error:
        latch.remember(error, raised=True)
        receipt["commandStatus"] = 128 + latch.number
        receipt["observerErrors"].append("observer interrupted")
    except (OSError, ValueError) as error:
        receipt["observerErrors"].append(f"launch/observer unavailable: {type(error).__name__}: {error}")
    finally:
        latch.deferred += 1
        if process is not None:
            watchdog.terminate_owned_group(process, owned)
            receipt["directChildJoined"] = process.returncode is not None
            receipt["remainingOwnedPIDs"] = [item.pid for item in owned.live()] if owned else []
    if latch.number is not None:
        receipt["interruptionStatus"] = 128 + latch.number
        if "observer interrupted" not in receipt["observerErrors"]:
            receipt["observerErrors"].append("observer interrupted during owned cleanup or handler restoration")
    receipt["elapsedSeconds"] = time.monotonic() - started
    receipt["observerStatus"] = (0 if observers_ok and receipt["proofs"] and not receipt["unavailable"]
                                 and not receipt["observerErrors"] and not completions.errors
                                 and receipt.get("directChildJoined")
                                 and not receipt.get("remainingOwnedPIDs") else UNAVAILABLE_EXIT)
    receipt["invalidNativeEvents"] = completions.errors[:20]
    try:
        receipt["nativeEvents"] = {path.name: watchdog.native_event_state(path)
                                   for path in sorted((output / "native").glob("*-events.jsonl"))}
    except OSError as error:
        receipt["observerStatus"] = UNAVAILABLE_EXIT
        receipt["observerErrors"].append(f"final native diagnostics unavailable: {error}")
    if not receipt["proofs"]:
        receipt["unavailable"]["host"] = "no contemporaneous complete owned host proof"
    if receipt["commandStatus"] is None:
        receipt["commandStatus"] = 1
    status = receipt.get("interruptionStatus", result_status(receipt["commandStatus"], receipt["observerStatus"]))
    try:
        (output / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    except OSError as error:
        announce(f"host-observation receipt unavailable: {error}", file=sys.stderr)
        status = status or UNAVAILABLE_EXIT
    announce(f"host-observation command-status={receipt['commandStatus']} "
             f"observer-status={receipt['observerStatus']} result={output / 'result.json'}")
    if latch.number is not None and "interruptionStatus" not in receipt:
        # A first signal during terminal emission is deferred too. Once latched,
        # later requests return, so persist its independent disposition once.
        receipt["interruptionStatus"] = status = 128 + latch.number
        receipt["observerStatus"] = UNAVAILABLE_EXIT
        receipt["observerErrors"].append("observer interrupted during terminal evidence emission")
        try:
            (output / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
        except OSError as error:
            announce(f"host-observation interruption receipt unavailable: {error}", file=sys.stderr)
    return status


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="new invocation-owned directory")
    parser.add_argument("--build-root", type=Path, required=True, help="actual produced build tree")
    parser.add_argument("--timeout-seconds", type=float, default=900)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command or not math.isfinite(args.timeout_seconds) or not 0 < args.timeout_seconds <= 900:
        parser.error("require a command and finite outer timeout in (0, 900]")
    return args


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
