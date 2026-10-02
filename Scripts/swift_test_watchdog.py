#!/usr/bin/env python3
"""Run one Swift test invocation with owned-process timeout diagnostics."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
from dataclasses import asdict, dataclass
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time


TIMEOUT_EXIT = 124
SAMPLER_TIMEOUT_SECONDS = 12
CLEANUP_GRACE_SECONDS = 3
OBSERVATION_INTERVAL_SECONDS = .1


class TerminationRequested(Exception):
    def __init__(self, signal_number: int):
        super().__init__(signal_number)
        self.signal_number = signal_number


class SignalLatch:
    """Keep the first signal through diagnostics, deferred launches and owned cleanup."""

    def __init__(self):
        self.number = None
        self.raised = False
        self.deferred = 0
        self.caught = False

    def remember(self, interruption, *, raised=False):
        self.caught = True
        if self.number is None:
            self.number = (signal.SIGINT if isinstance(interruption, KeyboardInterrupt)
                           else interruption.signal_number)
        self.raised = self.raised or raised

    def request(self, number, frame):
        if self.number is not None:
            return
        self.number = number  # Latch before any handler installation or exception.
        self.check()

    def check(self):
        if self.number is not None and not self.raised and not self.deferred:
            self.raised = True
            raise TerminationRequested(self.number)


def set_signal_handler(number, handler, latch):
    # An old/default handler can interrupt the registration itself. Retain that
    # first signal and finish registration before entering or leaving owned work.
    while True:
        try:
            signal.signal(number, handler)
            return
        except (KeyboardInterrupt, TerminationRequested) as interruption:
            latch.remember(interruption)


@contextmanager
def deferred_signals(latch=None):
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    inherited = latch is not None
    if latch is None:
        latch = next((owner for handler in handlers.values()
                      if isinstance(owner := getattr(handler, "__self__", None), SignalLatch)), None)
        inherited = latch is not None
        latch = latch or SignalLatch()
    latch.deferred += 1
    try:
        for sig in handlers:
            set_signal_handler(sig, latch.request, latch)
        yield latch
    except (KeyboardInterrupt, TerminationRequested) as interruption:
        latch.remember(interruption, raised=True)
        raise
    finally:
        try:
            for sig, handler in handlers.items():
                set_signal_handler(sig, handler, latch)
        finally:
            latch.deferred -= 1
    # Invocation latches retain new cleanup signals. For an external caller,
    # preserve the previous ignore-during-cleanup contract; only an exception
    # from its original handler during setup/restoration propagates after joins.
    if inherited or latch.caught:
        latch.check()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lane", required=True)
    parser.add_argument("--repetition", required=True)
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("--log-dir", required=True, type=Path)
    parser.add_argument("--event-stream-path", type=Path)
    parser.add_argument("--require-tests", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    if not math.isfinite(args.timeout_seconds) or args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be finite and positive")
    return args


def swiftpm_supports_event_stream(command: list[str]) -> bool:
    if len(command) < 2 or Path(command[0]).name != "swift" or command[1] != "test":
        return False
    try:
        help_result = subprocess.run(
            command[:2] + ["--help-hidden"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
            check=False,
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return help_result.returncode == 0 and "--event-stream-output-path" in help_result.stdout


def command_with_event_stream(command: list[str], path: Path | None) -> tuple[list[str], bool]:
    if path is None or not swiftpm_supports_event_stream(command):
        return command, False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    return command + ["--event-stream-output-path", str(path)], True


def event_stream_reports_execution(path: Path) -> bool:
    functions: set[str] = set()
    try:
        with path.open(encoding="utf-8") as events:
            for line in events:
                record = json.loads(line)
                if not isinstance(record, dict) or not isinstance(record.get("payload"), dict):
                    continue
                payload = record["payload"]
                if record.get("kind") == "test" and payload.get("kind") == "function":
                    if isinstance(payload.get("id"), str):
                        functions.add(payload["id"])
                elif (record.get("kind") == "event" and payload.get("kind") == "testEnded"
                      and isinstance(payload.get("testID"), str) and payload["testID"] in functions):
                    return True
    except (OSError, UnicodeError, ValueError):
        return False
    return False


def reported_test_execution(log_path: Path, event_path: Path | None = None) -> bool:
    # Summaries count skipped tests too. Structured function completions support quiet output;
    # case reports also cover XCTest and toolchains without event streaming. Command status
    # still owns the overall outcome, including failures after an earlier test passed.
    if event_path is not None and event_stream_reports_execution(event_path):
        return True
    ansi = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
    passed = re.compile(
        r"^(?:✔ Test (?!run with [0-9]+ tests?\b).+\bpassed\b"
        r"|Test Case .+\bpassed\b)"
    )
    with log_path.open(encoding="utf-8", errors="replace") as log:
        for line in log:
            if passed.match(ansi.sub("", line).strip()):
                return True
    return False


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    ppid: int
    pgid: int
    birth: tuple[int, ...]
    executable: str

    def same_process(self, other: ProcessIdentity | None) -> bool:
        # Executing a new image, detaching and reparenting do not change kernel birth.
        return other is not None and self.pid == other.pid and self.birth == other.birth

    def same_image(self, other: ProcessIdentity | None) -> bool:
        return self.same_process(other) and self.executable == other.executable


class BSDInfo(ctypes.Structure):
    # Darwin's public proc_bsdinfo ABI; birth has microsecond resolution, unlike ps lstart.
    _fields_ = ([(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid",
        "svuid", "svgid", "reserved")]
        + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
        + [(name, ctypes.c_uint32) for name in (
            "nfiles", "pgid", "jobc", "tty", "ttygroup", "nice")]
        + [("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)])


_PROC = None


def process_identity(pid: int) -> ProcessIdentity | None:
    try:
        if platform.system() == "Darwin":
            global _PROC
            if _PROC is None:
                _PROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
                _PROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                              ctypes.c_void_p, ctypes.c_int]
                _PROC.proc_pidinfo.restype = ctypes.c_int
                _PROC.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
                _PROC.proc_pidpath.restype = ctypes.c_int
            before, after = BSDInfo(), BSDInfo()
            if _PROC.proc_pidinfo(pid, 3, 0, ctypes.byref(before), ctypes.sizeof(before)) != ctypes.sizeof(before):
                return None
            path = ctypes.create_string_buffer(4096)
            if _PROC.proc_pidpath(pid, path, len(path)) <= 0:
                return None
            if _PROC.proc_pidinfo(pid, 3, 0, ctypes.byref(after), ctypes.sizeof(after)) != ctypes.sizeof(after):
                return None
            if ((before.pid, before.start_sec, before.start_usec, before.ppid, before.pgid)
                    != (after.pid, after.start_sec, after.start_usec, after.ppid, after.pgid)):
                return None
            return ProcessIdentity(pid, after.ppid, after.pgid,
                                   (after.start_sec, after.start_usec), os.fsdecode(path.value))
        if platform.system() == "Linux":
            path = Path(f"/proc/{pid}")
            before = (path / "stat").read_text().rsplit(")", 1)[1].split()
            executable = os.readlink(path / "exe")
            after = (path / "stat").read_text().rsplit(")", 1)[1].split()
            if (before[1:3], before[19]) != (after[1:3], after[19]):
                return None
            return ProcessIdentity(pid, int(after[1]), int(after[2]), (int(after[19]),), executable)
    except (OSError, ValueError, IndexError):
        pass
    return None


def process_inventory(timeout_seconds: float = 1) -> tuple[dict[int, tuple[int, int, str]], str | None]:
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid=,ppid=,pgid=,command="], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout_seconds,
            check=False, text=True, errors="replace",
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {}, f"process tree unavailable: {error}"
    if result.returncode:
        return {}, f"process tree unavailable (status {result.returncode}): {result.stdout.strip()}"
    rows = {}
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            try:
                rows[int(fields[0])] = (int(fields[1]), int(fields[2]), fields[3])
            except ValueError:
                pass
    return rows, None


class OwnedProcesses:
    """Retain only birth-validated launch ancestry, including later detached descendants."""

    def __init__(self, process: subprocess.Popen):
        self.process = process
        self.root = process_identity(process.pid)
        self.identities: dict[int, ProcessIdentity] = {}
        self.ancestry: dict[int, list[int]] = {}
        self.commands: dict[int, str] = {}
        self.error = None
        self.next_observation = 0.0
        if self.root is not None:
            self.identities[process.pid] = self.root
            self.ancestry[process.pid] = [process.pid]

    def observe(self, *, force: bool = False, deadline: float | None = None) -> None:
        if not force and time.monotonic() < self.next_observation:
            return
        remaining = 1 if deadline is None else min(1, deadline - time.monotonic())
        if remaining <= 0:
            return
        self.next_observation = time.monotonic() + OBSERVATION_INTERVAL_SECONDS
        rows, self.error = process_inventory(remaining)
        # Revalidate parents as well as children. A stale PPID or reused owned PID cannot
        # recruit an unrelated process. No process-group or executable-name scan owns work.
        live = {pid: now for pid, old in self.identities.items()
                if old.same_process(now := process_identity(pid))}
        self.identities.update(live)
        pending = dict(rows)
        changed = True
        while changed:
            changed = False
            for pid, (parent, group, command) in list(pending.items()):
                if pid in live:
                    self.commands[pid] = command
                    del pending[pid]
                elif parent in live:
                    child = process_identity(pid)
                    parent_now = process_identity(parent)
                    if (child is not None and child.ppid == parent and child.pgid == group
                            and child.birth >= live[parent].birth
                            and live[parent].same_process(parent_now)):
                        self.identities[pid] = child
                        self.ancestry[pid] = self.ancestry[parent] + [pid]
                        self.commands[pid] = command
                        live[pid] = child
                        changed = True
                    del pending[pid]

    def live(self) -> list[ProcessIdentity]:
        return [now for old in self.identities.values()
                if old.same_process(now := process_identity(old.pid))]

    def signal(self, number: int) -> None:
        # The unreaped direct child cannot have its PID reused. Its fresh session/group is
        # owned until reaping; never signal that numeric group after poll/wait has reaped it.
        if self.process.returncode is None:
            try:
                # Popen has not reaped this child, so even a zombie/hidden executable
                # cannot make this PID reusable. Recheck its actual group each time.
                try:
                    group = os.getpgid(self.process.pid)
                except ProcessLookupError:
                    # Darwin can hide a zombie's group before wait reaps it. The PID is
                    # still reserved by our unreaped setsid child, so its original group
                    # cannot belong to a later launch with a reused leader PID.
                    group = self.process.pid
                if group == self.process.pid:
                    os.killpg(self.process.pid, number)
                else:
                    os.kill(self.process.pid, number)
            except (ProcessLookupError, PermissionError):
                pass
        for old in reversed(list(self.identities.values())):
            if old.pid == self.process.pid:
                continue
            if old.same_process(process_identity(old.pid)):
                try:
                    os.kill(old.pid, number)
                except (ProcessLookupError, PermissionError):
                    pass

    def cleanup(self) -> None:
        with deferred_signals():
            self.observe(force=True)
            self.signal(signal.SIGTERM)
            deadline = time.monotonic() + CLEANUP_GRACE_SECONDS
            while self.live() and time.monotonic() < deadline:
                time.sleep(.05)
                self.observe(deadline=deadline)
            self.signal(signal.SIGKILL)
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass


def process_tree(owned: OwnedProcesses) -> str:
    owned.observe(force=True)
    rows = [dict(asdict(identity), launchAncestry=owned.ancestry[identity.pid],
                 live=identity.same_process(process_identity(identity.pid)),
                 command=owned.commands.get(identity.pid, "unavailable"))
            for identity in owned.identities.values()]
    return json.dumps({"processes": rows, "limitation": owned.error,
                       "birthIdentity": "kernel start time; never ps lstart",
                       "ownershipLimit": "Descendants orphaned before an ancestry observation are unknown."}, indent=2) + "\n"


def native_event_state(path: Path | None) -> dict:
    state = {"available": False, "activeFunctions": [], "lastStarted": None,
             "lastCompleted": None, "partialRecords": 0, "invalidRecords": 0}
    if path is None:
        return state
    functions, active = set(), set()
    try:
        with path.open(encoding="utf-8", errors="replace") as events:
            state["available"] = True
            for line in events:
                try:
                    record = json.loads(line)
                except ValueError:
                    state["partialRecords" if not line.endswith("\n") else "invalidRecords"] += 1
                    continue
                if not isinstance(record, dict) or not isinstance(record.get("payload"), dict):
                    state["invalidRecords"] += 1
                    continue
                payload = record["payload"]
                if record.get("kind") == "test" and payload.get("kind") == "function":
                    if isinstance(payload.get("id"), str):
                        functions.add(payload["id"])
                elif (record.get("kind") == "event" and isinstance(payload.get("testID"), str)
                      and payload["testID"] in functions):
                    ident, kind = payload["testID"], payload.get("kind")
                    if kind == "testStarted":
                        active.add(ident)
                        state["lastStarted"] = payload
                    elif kind == "testEnded":
                        active.discard(ident)
                        state["lastCompleted"] = payload
                    elif kind == "testSkipped":
                        active.discard(ident)
    except OSError as error:
        state["limitation"] = str(error)
    state["activeFunctions"] = sorted(active)
    return state


def retain_bundle_events(owned: OwnedProcesses, output: Path) -> list[dict]:
    """Read only fresh owned loaders' conventional SwiftPM temporary streams."""
    retained = []
    temporary_root = Path(tempfile.gettempdir()).resolve()
    for identity in owned.live():
        command = owned.commands.get(identity.pid, "")
        if host_role(identity, command) is None:
            continue
        receipt = {"pid": identity.pid, "available": False}
        retained.append(receipt)
        try:
            arguments = shlex.split(command)
            flag = "--event-stream-output-path"
            if (arguments.count(flag) != 1
                    or any(item.startswith(flag + "=") for item in arguments)):
                raise ValueError("ambiguous native event operand")
            bundle = loader_test_bundle(command, require_existing=True)
            if bundle is None:
                raise ValueError("concrete bundle unavailable")
            raw = arguments[arguments.index(flag) + 1]
            path = Path(raw)
            if (not path.is_absolute() or any(part in {".", ".."} for part in raw.split("/"))
                    or path.parent.parent.resolve() != temporary_root
                    or not re.fullmatch(r"swiftpm-test-output-[A-Za-z0-9_.-]+", path.parent.name)
                    or not re.fullmatch(r"event-stream-[0-9]+-" + re.escape(bundle.stem) + r"\.jsonl", path.name)
                    or path.parent.is_symlink() or path.is_symlink()):
                raise ValueError("event path outside conventional SwiftPM temporary stream")
            if not identity.same_image(process_identity(identity.pid)):
                raise ValueError("loader birth/image changed")
            directory = os.open(temporary_root / path.parent.name,
                                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                if os.fstat(directory).st_uid != os.getuid():
                    raise ValueError("temporary directory belongs to another user")
                descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                     dir_fd=directory)
            finally:
                os.close(directory)
            with os.fdopen(descriptor, "rb") as stream:
                info = os.fstat(stream.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or info.st_size > 16 * 1024 * 1024):
                    raise ValueError("stream is not a bounded owned regular file")
                content = stream.read(16 * 1024 * 1024 + 1)
            if len(content) > 16 * 1024 * 1024:
                raise ValueError("stream exceeded retention bound")
            if not identity.same_image(process_identity(identity.pid)):
                raise ValueError("loader birth/image changed during read")
            output.mkdir(parents=True, exist_ok=True)
            copy = output / f"{identity.pid}-{path.name}"
            copy.write_bytes(content)
            receipt.update(available=True, retainedPath=str(copy), nativeEvents=native_event_state(copy))
        except (OSError, ValueError, IndexError) as error:
            receipt["limitation"] = str(error)
    return retained


def diagnostic_state(owned: OwnedProcesses | None, event_path: Path | None,
                     bundle_output: Path | None = None) -> str:
    tree = json.loads(process_tree(owned)) if owned is not None else {"limitation": "Launch identity unavailable"}
    candidates = []
    if owned is not None:
        for identity in owned.live():
            role = host_role(identity, owned.commands.get(identity.pid, ""))
            if role is not None:
                candidates.append({"pid": identity.pid, "role": role})
        tree["driverPID"] = owned.process.pid
    tree["hostCandidates"] = candidates
    tree["hostAttribution"] = ("one owned loader candidate" if len(candidates) == 1
                               else "unavailable; driver fallback")
    tree["nativeEvents"] = native_event_state(event_path)
    if owned is not None and bundle_output is not None:
        tree["bundleNativeEvents"] = retain_bundle_events(owned, bundle_output)
    tree["eventAttributionLimit"] = "Native events identify functions, not a process PID."
    tree["samplingLimit"] = "Identity is revalidated before launch; PID-based samplers cannot atomically bind birth."
    return json.dumps(tree, indent=2) + "\n"


def write_interruption_diagnostics(owned, args, event_enabled, tree_path, log_file):
    try:
        tree_path.write_text(diagnostic_state(owned, args.event_stream_path if event_enabled else None,
                                              tree_path.with_suffix(".events")))
    except (OSError, UnicodeError) as error:
        emit_diagnostic(f"swift-test-watchdog diagnostics unavailable: {error}", log_file)


def loader_test_bundle(command: str, *, require_existing: bool = False) -> Path | None:
    """Normalize the loader's single absolute bundle-directory or conventional binary operand."""
    try:
        arguments = shlex.split(command)
        if (arguments.count("--test-bundle-path") != 1
                or any(argument.startswith("--test-bundle-path=") for argument in arguments)):
            return None
        operand = arguments[arguments.index("--test-bundle-path") + 1]
        raw = Path(operand)
        if not raw.is_absolute() or any(part in {".", ".."} for part in operand.split("/")):
            return None
        bundle = raw
        if raw.suffix != ".xctest":
            bundle = raw.parent.parent.parent
            if (raw.parent.name != "MacOS" or raw.parent.parent.name != "Contents"
                    or bundle.suffix != ".xctest" or raw.name != bundle.stem):
                return None
        if require_existing:
            bundle = bundle.resolve(strict=True)
            if bundle.suffix != ".xctest" or not bundle.is_dir():
                return None
            if raw.suffix != ".xctest":
                binary = raw.resolve(strict=True)
                if (not binary.is_file() or binary.parent != bundle / "Contents/MacOS"
                        or binary.name != bundle.stem):
                    return None
        return bundle
    except (OSError, ValueError, IndexError):
        return None


def host_role(identity: ProcessIdentity, command: str) -> str | None:
    # SwiftPM's loader protocol binds the helper to a concrete test bundle. A bare process
    # name, arbitrary child, or a driver that merely forwards events is not host proof.
    executable = Path(identity.executable)
    if (executable.name == "swiftpm-testing-helper"
            and executable.parent.as_posix().endswith("/libexec/swift/pm")
            and loader_test_bundle(command) is not None):
        return "SwiftPM test-bundle loader"
    return None


def sample_helper(owned: OwnedProcesses, output: Path) -> str:
    owned.observe(force=True)
    hosts = [(identity, role) for identity in owned.live()
             if (role := host_role(identity, owned.commands.get(identity.pid, ""))) is not None]
    if len(hosts) == 1:
        target, role = hosts[0]
        attribution = f"host PID {target.pid} ({role})"
    else:
        target = next((item for item in owned.live() if item.pid == owned.process.pid), None)
        attribution = f"driver fallback; host attribution unavailable ({len(hosts)} loader candidates)"
    if target is None or not target.same_image(process_identity(target.pid)):
        return attribution + "; sampler refused: target identity unavailable or changed"
    injected_sampler = os.environ.get("SPOTTY_SWIFT_TEST_SAMPLER")
    if injected_sampler:
        command = [injected_sampler, str(target.pid), str(output)]
    elif platform.system() == "Darwin" and Path("/usr/bin/sample").is_file():
        command = ["/usr/bin/sample", str(target.pid), "5", "1", "-file", str(output)]
    else:
        return attribution + "; sampler unavailable on this host"
    sampler = None
    tracker = None
    deadline = time.monotonic() + SAMPLER_TIMEOUT_SECONDS
    try:
        with deferred_signals() as handoff:
            # Validate again immediately before launching the sampler; it receives only this
            # owned identity. Sampling APIs cannot make PID targeting atomic across process exit.
            if not target.same_image(process_identity(target.pid)):
                return attribution + "; sampler refused: target identity changed"
            sampler = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True, bufsize=0)
            tracker = OwnedProcesses(sampler)
        # External callers also surface a deferred launch signal after retaining
        # both handles; finally can now terminate and join the sampler safely.
        handoff.check()
        assert sampler.stdout is not None
        data = bytearray()
        eof = False
        with selectors.DefaultSelector() as selector:
            selector.register(sampler.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                tracker.observe(deadline=deadline)
                for key, _ in selector.select(timeout=min(.1, max(0, deadline - time.monotonic()))):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if chunk:
                        data.extend(chunk[:max(0, 65536 - len(data))])
                    else:
                        selector.unregister(key.fileobj)
                        eof = True
                if eof and sampler.poll() is not None:
                    break
            else:
                return attribution + "; sampler unavailable or timed out"
        if sampler.returncode:
            detail = data.decode(errors="replace").strip()
            return attribution + f"; sampler failed with status {sampler.returncode}" + (f": {detail}" if detail else "")
        return f"sampled {attribution} to {output}; target birth={target.birth} executable={target.executable}"
    except OSError as error:
        return attribution + f"; sampler unavailable: {error}"
    finally:
        if sampler is not None:
            terminate_owned_group(sampler, tracker)
        if sampler is not None and sampler.stdout is not None:
            sampler.stdout.close()


def terminate_owned_group(process: subprocess.Popen[bytes], owned: OwnedProcesses | None = None) -> None:
    # Protect even initial ownership setup when an earlier interrupt preceded its creation.
    with deferred_signals():
        (owned or OwnedProcesses(process)).cleanup()


def emit(message: str, log_file) -> None:
    line = message + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()
    log_file.write(line.encode())
    log_file.flush()


def emit_diagnostic(message: str, log_file) -> None:
    # Each sink is optional after a timeout. Bypass buffering so failed writes cannot raise again
    # while closing the log or flushing stdout at interpreter shutdown and replace status 124.
    line = (message + "\n").encode(errors="replace")
    for sink in (sys.stdout, log_file):
        try:
            descriptor = sink.fileno()
            remaining = memoryview(line)
            while remaining:
                written = os.write(descriptor, remaining)
                if written <= 0:
                    break
                remaining = remaining[written:]
        except (OSError, ValueError):
            pass


def run(args: argparse.Namespace) -> int:
    args.log_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{args.lane}-repeat-{args.repetition}"
    log_path = args.log_dir / f"{stem}.log"
    tree_path = args.log_dir / f"{stem}-process-tree.txt"
    sample_path = args.log_dir / f"{stem}-sample.txt"
    if args.require_tests and args.event_stream_path is None:
        args.event_stream_path = args.log_dir / f"{stem}-events.jsonl"
    command, event_enabled = command_with_event_stream(args.command, args.event_stream_path)
    started = time.monotonic()

    latch = SignalLatch()
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        latch.deferred += 1
        try:
            for sig in handlers:
                set_signal_handler(sig, latch.request, latch)
        finally:
            latch.deferred -= 1
        latch.check()
        status = run_logged(args, command, event_enabled, started, log_path, tree_path, sample_path, latch)
    except (KeyboardInterrupt, TerminationRequested) as interruption:
        latch.remember(interruption, raised=True)
        status = 128 + latch.number
    finally:
        latch.deferred += 1
        try:
            for sig, handler in handlers.items():
                set_signal_handler(sig, handler, latch)
        finally:
            latch.deferred -= 1
    return 128 + latch.number if latch.number is not None else status


def run_logged(
    args: argparse.Namespace,
    command: list[str],
    event_enabled: bool,
    started: float,
    log_path: Path,
    tree_path: Path,
    sample_path: Path,
    latch: SignalLatch | None = None,
) -> int:
    latch = latch or SignalLatch()
    with log_path.open("wb") as log_file:
        emit(
            f"swift-test-watchdog lane={args.lane} repetition={args.repetition} "
            f"timeout={args.timeout_seconds:g}s command={shlex.join(command)}",
            log_file,
        )
        emit(
            f"swift-test-watchdog event-stream={'enabled' if event_enabled else 'unsupported-or-disabled'}"
            + (f" path={args.event_stream_path}" if args.event_stream_path else ""),
            log_file,
        )
        latch.deferred += 1
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                bufsize=0,
            )
        except OSError as error:
            latch.deferred -= 1
            emit(f"swift-test-watchdog launch failed: {error}", log_file)
            emit(
                f"swift-test-watchdog lane={args.lane} repetition={args.repetition} "
                f"elapsed={time.monotonic() - started:.2f}s status=127",
                log_file,
            )
            return 127
        owned = None
        selector = None
        launch_deferred = True
        assert process.stdout is not None
        try:
            owned = OwnedProcesses(process)
            launch_deferred = False
            latch.deferred -= 1
            latch.check()
            emit(f"swift-test-watchdog pid={process.pid} started", log_file)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            timed_out = False
            stdout_eof = False
            while True:
                owned.observe(deadline=started + args.timeout_seconds)
                elapsed = time.monotonic() - started
                if stdout_eof and process.poll() is not None:
                    break
                if elapsed >= args.timeout_seconds:
                    timed_out = True
                    break
                for key, _ in selector.select(timeout=min(0.1, args.timeout_seconds - elapsed)):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if chunk:
                        sys.stdout.buffer.write(chunk)
                        sys.stdout.buffer.flush()
                        log_file.write(chunk)
                        log_file.flush()
                    else:
                        selector.unregister(key.fileobj)
                        stdout_eof = True
            if timed_out:
                try:
                    tree = diagnostic_state(owned, args.event_stream_path if event_enabled else None,
                                            tree_path.with_suffix(".events"))
                    tree_path.write_text(tree)
                    emit_diagnostic(
                        f"swift-test-watchdog status=timeout elapsed={time.monotonic() - started:.2f}s; "
                        f"process tree: {tree_path}",
                        log_file,
                    )
                    emit_diagnostic(sample_helper(owned, sample_path), log_file)
                except (OSError, UnicodeError) as error:
                    emit_diagnostic(f"swift-test-watchdog status=timeout; diagnostics unavailable: {error}", log_file)
                return TIMEOUT_EXIT
            status = process.wait()
            if status == 0 and args.require_tests and not reported_test_execution(
                log_path, args.event_stream_path if event_enabled else None,
            ):
                emit("swift-test-watchdog: no executed tests reported; check the filter and skipped tests", log_file)
                status = 1
            emit(
                f"swift-test-watchdog lane={args.lane} repetition={args.repetition} "
                f"pid={process.pid} elapsed={time.monotonic() - started:.2f}s status={status}",
                log_file,
            )
            return status
        except (KeyboardInterrupt, TerminationRequested) as interruption:
            # The first interrupt owns the result. Diagnostics can suspend before cleanup
            # starts, so ignore subsequent interrupts throughout both operations.
            latch.remember(interruption, raised=True)
            status = 128 + latch.number
            message = ("swift-test-watchdog interrupted; terminating owned processes"
                       if isinstance(interruption, KeyboardInterrupt) else
                       f"swift-test-watchdog interrupted by signal {interruption.signal_number}; "
                       "terminating owned processes")
            emit_diagnostic(message, log_file)
            write_interruption_diagnostics(owned, args, event_enabled, tree_path, log_file)
            emit_diagnostic(
                f"swift-test-watchdog lane={args.lane} repetition={args.repetition} "
                f"pid={process.pid} elapsed={time.monotonic() - started:.2f}s status={status}",
                log_file,
            )
            return status
        finally:
            # Logging, pipe forwarding and diagnostics can fail too. They must never strand the
            # invocation, even when no timeout or interrupt handler was reached.
            try:
                if launch_deferred:
                    latch.deferred -= 1
                terminate_owned_group(process, owned)
            finally:
                try:
                    if selector is not None:
                        selector.close()
                finally:
                    process.stdout.close()


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
