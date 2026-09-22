#!/usr/bin/env python3
"""Identify and stop only the exact macOS Demo process recorded for one run."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


PROCESS_QUERY_TIMEOUT_SECONDS = 2
DISCOVERY_TIMEOUT_SECONDS = 10
TERMINATION_TIMEOUT_SECONDS = 5


def executable_path(pid: int) -> str:
    """Read the kernel executable path, never a process name or command line."""
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidpath = library.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)  # PROC_PIDPATHINFO_MAXSIZE
    if proc_pidpath(pid, buffer, len(buffer)) <= 0:
        raise ProcessLookupError("Executable identity is unavailable")
    return str(Path(os.fsdecode(buffer.value)).resolve())


def query_timeout(deadline: float | None) -> float:
    if deadline is None:
        return PROCESS_QUERY_TIMEOUT_SECONDS
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("Demo did not launch with the requested executable before the deadline")
    return min(PROCESS_QUERY_TIMEOUT_SECONDS, remaining)


def start_identity(pid: int, *, deadline: float | None = None) -> str:
    environment = dict(os.environ, LC_ALL="C", LANG="C", TZ="UTC")
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "lstart="],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=query_timeout(deadline), check=False, env=environment,
    )
    identity = " ".join(result.stdout.split())
    if result.returncode or not re.fullmatch(
        r"[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}:\d{2} \d{4}", identity,
    ):
        raise ProcessLookupError("Process start identity is unavailable")
    return identity


def capture(pid: int, executable: str | Path, *, deadline: float | None = None) -> dict:
    if type(pid) is not int or pid <= 0:
        raise ValueError("Expected a positive process ID")
    expected = str(Path(executable).resolve())
    before = start_identity(pid, deadline=deadline)
    if executable_path(pid) != expected or start_identity(pid, deadline=deadline) != before:
        raise ProcessLookupError("Process identity changed or executable differs")
    return {"pid": pid, "startIdentity": before, "executable": expected}


def valid_record(record: dict) -> bool:
    return (
        isinstance(record, dict)
        and type(record.get("pid")) is int and record["pid"] > 0
        and isinstance(record.get("startIdentity"), str) and bool(record["startIdentity"])
        and isinstance(record.get("executable"), str) and Path(record["executable"]).is_absolute()
    )


def matches(record: dict) -> bool:
    if not valid_record(record):
        return False
    try:
        current = capture(record["pid"], record["executable"])
    except (OSError, ValueError, subprocess.SubprocessError):
        return False
    return all(current[key] == record[key] for key in current)


def process_ids(*, deadline: float | None = None) -> list[int]:
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid="], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        timeout=query_timeout(deadline), check=True,
    )
    return [int(value) for value in result.stdout.split() if value.isdecimal() and int(value) > 0]


def discover(executable: str | Path, timeout: float = DISCOVERY_TIMEOUT_SECONDS) -> dict:
    expected = str(Path(executable).resolve())
    deadline = time.monotonic() + timeout
    while True:
        found = []
        for pid in process_ids(deadline=deadline):
            query_timeout(deadline)
            try:
                if executable_path(pid) == expected:
                    found.append(capture(pid, expected, deadline=deadline))
            except (OSError, ValueError, subprocess.SubprocessError):
                continue  # Processes may exit while the inventory is read.
            if len(found) > 1:
                raise RuntimeError("Multiple processes use the requested Demo executable")
        query_timeout(deadline)
        if found:
            return found[0]
        time.sleep(min(0.1, query_timeout(deadline)))


def run_id(run_root: Path) -> str:
    manifest = json.loads((run_root / "manifest.json").read_text())
    value = manifest.get("runID") if isinstance(manifest, dict) else None
    if not isinstance(value, str) or not value:
        raise ValueError("Run manifest is missing its runID")
    return value


def load_record(run_root: Path) -> dict:
    record = json.loads((run_root / "process.json").read_text())
    if not valid_record(record) or record.get("runID") != run_id(run_root):
        raise ValueError("Process record does not belong to this run")
    return record


def write_record(run_root: Path, record: dict) -> None:
    if not valid_record(record):
        raise ValueError("Invalid process identity")
    owned = {key: record[key] for key in ("pid", "startIdentity", "executable")}
    owned["runID"] = run_id(run_root)
    temporary = run_root / "process.json.tmp"
    temporary.write_text(json.dumps(owned, sort_keys=True) + "\n")
    temporary.replace(run_root / "process.json")


def terminate(record: dict, timeout: float = TERMINATION_TIMEOUT_SECONDS) -> None:
    if not valid_record(record):
        raise ValueError("Invalid process identity")
    if not matches(record):
        return
    try:
        os.kill(record["pid"], signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + timeout
    while matches(record):
        if time.monotonic() >= deadline:
            raise RuntimeError("The owned Demo process did not terminate")
        time.sleep(0.1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    for operation in ("capture", "discover", "alive", "terminate"):
        command = commands.add_parser(operation)
        command.add_argument("run_root", type=Path)
        if operation == "capture":
            command.add_argument("pid", type=int)
        if operation in ("capture", "discover"):
            command.add_argument("executable", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "capture":
            write_record(args.run_root, capture(args.pid, args.executable))
        elif args.operation == "discover":
            write_record(args.run_root, discover(args.executable))
        elif args.operation == "alive":
            raise SystemExit(0 if matches(load_record(args.run_root)) else 1)
        else:
            terminate(load_record(args.run_root))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Demo process: {error}\n")


if __name__ == "__main__":
    main()
