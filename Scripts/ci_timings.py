#!/usr/bin/env python3
"""Append opt-in verification phase timings without recording commands or environment."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import sys
import time


BUILD_SUMMARY = re.compile(r"Build complete! \(([0-9]+(?:\.[0-9]+)?) secs\.\)")


def test_observations(log_path: Path | None, event_path: Path | None) -> dict:
    observations = {}
    if log_path is not None:
        observations["watchdog_log"] = str(log_path)
        try:
            with log_path.open(encoding="utf-8", errors="replace") as log:
                builds = [float(match[1]) for line in log
                          if (match := BUILD_SUMMARY.search(line))]
            if builds:
                # SwiftPM reports its build duration; this includes planning and linking.
                observations["test_build_seconds"] = round(sum(builds), 6)
        except OSError:
            observations["watchdog_log_available"] = False
    if event_path is None:
        return observations
    observations["native_events"] = str(event_path)
    started = None
    durations = []
    functions = set()
    completed_functions = 0
    incomplete = False
    try:
        with event_path.open(encoding="utf-8") as events:
            for line in events:
                try:
                    record = json.loads(line)
                except ValueError:
                    incomplete = True
                    continue
                if not isinstance(record, dict) or not isinstance(record.get("payload"), dict):
                    continue
                payload = record["payload"]
                if record.get("kind") == "test" and payload.get("kind") == "function":
                    if isinstance(payload.get("id"), str):
                        functions.add(payload["id"])
                elif record.get("kind") == "event":
                    kind = payload.get("kind")
                    if (kind == "testEnded" and isinstance(payload.get("testID"), str)
                            and payload["testID"] in functions):
                        completed_functions += 1
                    if kind not in {"runStarted", "runEnded"}:
                        continue
                    instant = payload.get("instant", {})
                    absolute = instant.get("absolute") if isinstance(instant, dict) else None
                    if not isinstance(absolute, (int, float)) or not math.isfinite(absolute):
                        incomplete = True
                        continue
                    if kind == "runStarted":
                        if started is not None:
                            incomplete = True
                        started = absolute
                    elif started is None or absolute < started:
                        incomplete = True
                    else:
                        durations.append(absolute - started)
                        started = None
    except (OSError, UnicodeError):
        observations["native_events_available"] = False
        return observations
    observations["native_events_available"] = True
    observations["native_events_complete"] = bool(durations) and not incomplete and started is None
    observations["native_completed_runs"] = len(durations)
    observations["native_completed_test_functions"] = completed_functions
    if durations:
        # Sum complete native runs only. Missing/partial event streams do not imply zero work.
        observations["native_execution_seconds"] = round(sum(durations), 6)
    return observations


def append_record(report: Path, *, phase: str, start: str, status: int,
                  log_path: Path | None = None, event_path: Path | None = None) -> None:
    monotonic_ns, wall_ns = map(int, start.split(":"))
    record = {
        "schema_version": 1,
        "phase": phase,
        "started_at_unix_seconds": round(wall_ns / 1_000_000_000, 6),
        "elapsed_seconds": round(max(0, time.monotonic_ns() - monotonic_ns) / 1_000_000_000, 6),
        "status": status,
    }
    record.update(test_observations(log_path, event_path))
    encoded = (json.dumps(record, separators=(",", ":"), allow_nan=False) + "\n").encode()
    report.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(report, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        # One append keeps independent CI shell owners from interleaving JSONL rows.
        if os.write(descriptor, encoded) != len(encoded):
            raise OSError("incomplete timing append")
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("clock")
    record = subparsers.add_parser("record")
    record.add_argument("--report", required=True, type=Path)
    record.add_argument("--phase", required=True)
    record.add_argument("--start", required=True)
    record.add_argument("--status", required=True, type=int)
    record.add_argument("--swift-test-log", type=Path)
    record.add_argument("--native-events", type=Path)
    args = parser.parse_args()
    if args.action == "clock":
        print(f"{time.monotonic_ns()}:{time.time_ns()}")
        return 0
    try:
        append_record(args.report, phase=args.phase, start=args.start, status=args.status,
                      log_path=args.swift_test_log, event_path=args.native_events)
    except (OSError, ValueError):
        # Diagnostics are optional and must not replace the command's original outcome.
        print("ci-timings: timing report unavailable", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
