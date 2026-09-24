#!/usr/bin/env python3
"""Run one Swift test invocation with owned-process timeout diagnostics."""

from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import platform
import selectors
import shlex
import signal
import subprocess
import sys
import time


TIMEOUT_EXIT = 124


class TerminationRequested(Exception):
    def __init__(self, signal_number: int):
        super().__init__(signal_number)
        self.signal_number = signal_number


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lane", required=True)
    parser.add_argument("--repetition", required=True)
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("--log-dir", required=True, type=Path)
    parser.add_argument("--event-stream-path", type=Path)
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
    return command + ["--event-stream-output-path", str(path)], True


def process_tree(process_group: int) -> tuple[str, list[int]]:
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid=,ppid=,pgid=,etime=,stat=,command="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"process tree unavailable: {error}\n", []
    if result.returncode != 0:
        return f"process tree unavailable (status {result.returncode}): {result.stdout.strip()}\n", []
    selected: list[str] = []
    pids: list[int] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) < 4:
            continue
        try:
            pid = int(fields[0])
            pgid = int(fields[2])
        except ValueError:
            continue
        if pgid == process_group:
            selected.append(line)
            pids.append(pid)
    header = "PID PPID PGID ELAPSED STAT COMMAND\n"
    return header + "\n".join(selected) + ("\n" if selected else ""), pids


def sample_helper(root_pid: int, pids: list[int], output: Path) -> str:
    candidates = [pid for pid in pids if pid != root_pid]
    pid = candidates[-1] if candidates else root_pid
    injected_sampler = os.environ.get("SPOTTY_SWIFT_TEST_SAMPLER")
    if injected_sampler:
        command = [injected_sampler, str(pid), str(output)]
    elif platform.system() == "Darwin" and Path("/usr/bin/sample").is_file():
        command = ["/usr/bin/sample", str(pid), "5", "1", "-file", str(output)]
    else:
        return "sampler unavailable on this host"
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=12,
            check=False,
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"sampler unavailable or timed out: {error}"
    if result.returncode != 0:
        detail = result.stdout.strip()
        return f"sampler failed with status {result.returncode}" + (f": {detail}" if detail else "")
    return f"sampled descendant PID {pid} to {output}"


def terminate_owned_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    # The group may still contain a descendant after the direct child exits. Always follow the
    # grace period with a group-scoped KILL; ESRCH means TERM already emptied the owned group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass


def emit(message: str, log_file) -> None:
    line = message + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()
    log_file.write(line.encode())
    log_file.flush()


def run(args: argparse.Namespace) -> int:
    args.log_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{args.lane}-repeat-{args.repetition}"
    log_path = args.log_dir / f"{stem}.log"
    tree_path = args.log_dir / f"{stem}-process-tree.txt"
    sample_path = args.log_dir / f"{stem}-sample.txt"
    command, event_enabled = command_with_event_stream(args.command, args.event_stream_path)
    started = time.monotonic()

    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def request_termination(signal_number, _frame):
        raise TerminationRequested(signal_number)

    signal.signal(signal.SIGTERM, request_termination)
    try:
        return run_logged(args, command, event_enabled, started, log_path, tree_path, sample_path)
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)


def run_logged(
    args: argparse.Namespace,
    command: list[str],
    event_enabled: bool,
    started: float,
    log_path: Path,
    tree_path: Path,
    sample_path: Path,
) -> int:
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
            emit(f"swift-test-watchdog launch failed: {error}", log_file)
            emit(
                f"swift-test-watchdog lane={args.lane} repetition={args.repetition} "
                f"elapsed={time.monotonic() - started:.2f}s status=127",
                log_file,
            )
            return 127
        selector = None
        command_finished = False
        assert process.stdout is not None
        try:
            emit(f"swift-test-watchdog pid={process.pid} started", log_file)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            timed_out = False
            stdout_eof = False
            while True:
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
                    tree, pids = process_tree(process.pid)
                    tree_path.write_text(tree)
                    emit(
                        f"swift-test-watchdog status=timeout elapsed={time.monotonic() - started:.2f}s; "
                        f"process tree: {tree_path}",
                        log_file,
                    )
                    emit(sample_helper(process.pid, pids, sample_path), log_file)
                except (OSError, UnicodeError) as error:
                    emit(f"swift-test-watchdog status=timeout; diagnostics unavailable: {error}", log_file)
                return TIMEOUT_EXIT
            status = process.wait()
            command_finished = True
            emit(
                f"swift-test-watchdog lane={args.lane} repetition={args.repetition} "
                f"pid={process.pid} elapsed={time.monotonic() - started:.2f}s status={status}",
                log_file,
            )
            return status
        except KeyboardInterrupt:
            emit("swift-test-watchdog interrupted; terminating owned process group", log_file)
            emit(
                f"swift-test-watchdog lane={args.lane} repetition={args.repetition} "
                f"pid={process.pid} elapsed={time.monotonic() - started:.2f}s status=130",
                log_file,
            )
            return 130
        except TerminationRequested as interruption:
            emit(
                f"swift-test-watchdog interrupted by signal {interruption.signal_number}; "
                "terminating owned process group",
                log_file,
            )
            status = 128 + interruption.signal_number
            emit(
                f"swift-test-watchdog lane={args.lane} repetition={args.repetition} "
                f"pid={process.pid} elapsed={time.monotonic() - started:.2f}s status={status}",
                log_file,
            )
            return status
        finally:
            # Logging, pipe forwarding and diagnostics can fail too. They must never strand the
            # invocation, even when no timeout or interrupt handler was reached.
            try:
                if not command_finished:
                    terminate_owned_group(process)
            finally:
                if selector is not None:
                    selector.close()
                process.stdout.close()


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
