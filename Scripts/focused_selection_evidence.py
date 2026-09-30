#!/usr/bin/env python3
"""Record bounded, actual-native focused selection evidence; never retry a command."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import runpy
import shutil
import statistics
import struct
import subprocess
import sys
import time

from browsing_provenance import engine_identity, playback_pin, source_identity
from ci_timings import test_observations


GATEWAY = "PlaylistLibraryTraversalTests/largeFolderLoadsInOneBoundedBatch"
SMOKE = "WaitUntilTests/requireEventuallyAcceptsAnEstablishedPrerequisite"
# This is a bounded list of proof functions, not a second dependency/selector map.
PROBES = (
    ("SpottyDomainTests", "SpotifyURITests/identityMatchesRequestedKind"),
    ("SpottyTestSupportTests", SMOKE),
    ("SpottyCatalogStorageTests", "CatalogSQLiteStatementChecks/executionsClearBindingsIncludingAfterBindFailure"),
    ("SpottyEngineAdapterTests", "RehydrationLoadSequenceTests/firstQueuedTargetStopsTheSequence"),
    ("SpottySessionRuntimeTests", "RuntimeCatalogMetadataTests/queueOccurrenceChangesDoNotPublishUnchangedPlaybackLabels"),
    ("SpottyBoundaryTests", "FormattingTests/testFormatting"),
)
NONEMPTY_DIAGNOSTIC = "no executed tests reported; check the filter and skipped tests"
# One explicit optimized probe configuration on both supported compilers. Never
# switch configuration after a failure; these testable measurements are not shipping WMO.
OPTIMIZED_PROBE_FLAGS = (
    "--build-system", "native", "-c", "debug", "-Xswiftc", "-O", "-Xswiftc", "-enable-testing",
    "-Xswiftc", "-no-whole-module-optimization",
)
DOMAIN_RELEASE_PROBE_FLAGS = (
    "--build-system", "native", "-c", "release", "-Xswiftc", "-O", "-Xswiftc", "-enable-testing",
)


class EvidenceError(ValueError):
    def __init__(self, message: str, status: int = 1):
        super().__init__(message)
        self.status = status


def function_identity(raw: str) -> str:
    """Only source location may differ between revisions. Retain raw IDs in receipts."""
    if not isinstance(raw, str) or not re.fullmatch(r"[A-Za-z_]\w*\.[^/]+/(?:[^/]+/)?[^/]+\.swift:\d+:\d+", raw):
        raise EvidenceError(f"Invalid native function ID: {raw!r}")
    return raw.rsplit("/", 1)[0]


def strict_json(value: str):
    def pairs(items):
        result = {}
        for key, item in items:
            if key in result:
                raise EvidenceError(f"Duplicate JSON key: {key}")
            result[key] = item
        return result

    def invalid_constant(value):
        raise EvidenceError(f"Non-finite JSON number: {value}")

    return json.loads(value, object_pairs_hook=pairs, parse_constant=invalid_constant)


def inspect_native(path: Path) -> dict:
    """Validate the complete Swift Testing v0 JSONL lifecycle, including negative runs."""
    declarations, starts, ends, skipped, cases = {}, {}, {}, [], {}
    run_start = run_end = version = latest_execution_instant = None
    count = 0
    try:
        with path.open(encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                if not line.endswith("\n") or not line.strip():
                    raise EvidenceError(f"Truncated or empty native record at line {number}")
                record = strict_json(line)
                if not isinstance(record, dict) or set(record) != {"kind", "payload", "version"}:
                    raise EvidenceError(f"Malformed native envelope at line {number}")
                current_version = record["version"]
                if current_version not in {"6.3.0", "6.4.0"}:
                    raise EvidenceError(f"Unproved native event version: {current_version!r}")
                if version is not None and version != current_version:
                    raise EvidenceError("Mixed native event versions")
                version = current_version
                payload = record["payload"]
                if not isinstance(payload, dict):
                    raise EvidenceError("Malformed native payload")
                kind = payload.get("kind")
                count += 1
                if run_end is not None:
                    raise EvidenceError("Native records after runEnded")
                if record["kind"] == "test":
                    identifier = payload.get("id")
                    if kind not in {"suite", "function"} or not isinstance(identifier, str) or not identifier:
                        raise EvidenceError("Malformed native declaration")
                    if identifier in declarations or run_start is not None:
                        raise EvidenceError("Duplicate or late native declaration")
                    if kind == "function":
                        function_identity(identifier)
                        if not isinstance(payload.get("isParameterized"), bool):
                            raise EvidenceError("Missing function parameterization declaration")
                    declarations[identifier] = payload
                    continue
                if record["kind"] != "event":
                    raise EvidenceError("Unknown native envelope kind")
                instant = payload.get("instant")
                absolute = instant.get("absolute") if isinstance(instant, dict) else None
                if isinstance(absolute, bool) or not isinstance(absolute, (int, float)) or not math.isfinite(absolute):
                    raise EvidenceError("Native event has no finite absolute instant")
                messages = payload.get("messages", [])
                if not isinstance(messages, list) or any(not isinstance(message, dict) for message in messages):
                    raise EvidenceError("Malformed native messages")
                if any(message.get("symbol") in {"fail", "warning", "skip"} for message in messages) and kind != "testSkipped":
                    raise EvidenceError("Native issue/failure message")
                if kind == "runStarted":
                    if run_start is not None or "testID" in payload:
                        raise EvidenceError("Duplicate/malformed native runStarted")
                    run_start = absolute
                    latest_execution_instant = absolute
                    continue
                if run_start is None or absolute < run_start:
                    raise EvidenceError("Native event outside its run")
                if kind == "runEnded":
                    if "testID" in payload or set(starts) != set(ends) or any(cases.values()):
                        raise EvidenceError("Unpaired native lifecycle at runEnded")
                    if absolute < latest_execution_instant:
                        raise EvidenceError("Native runEnded precedes an execution instant")
                    run_end = absolute
                    continue
                if kind not in {"testStarted", "testEnded", "testSkipped", "testCaseStarted", "testCaseEnded"}:
                    raise EvidenceError(f"Unexpected native event/issue: {kind!r}")
                # Bound the run without requiring a total order among independent
                # test lifecycles, which can execute concurrently.
                latest_execution_instant = max(latest_execution_instant, absolute)
                identifier = payload.get("testID")
                if identifier not in declarations:
                    raise EvidenceError("Native event references undeclared test")
                if kind == "testStarted":
                    if identifier in starts or identifier in skipped:
                        raise EvidenceError("Duplicate native testStarted")
                    starts[identifier] = absolute
                elif kind == "testEnded":
                    if identifier not in starts or identifier in ends or absolute < starts[identifier] or cases.get(identifier):
                        raise EvidenceError("Duplicate or unpaired native testEnded")
                    ends[identifier] = absolute
                elif kind == "testSkipped":
                    if identifier in skipped or identifier in starts or declarations[identifier]["kind"] != "function":
                        raise EvidenceError("Duplicate or conflicting native skip")
                    skipped.append(identifier)
                elif kind == "testCaseStarted":
                    if identifier not in starts or identifier in ends or cases.get(identifier):
                        raise EvidenceError("Unpaired native case start")
                    cases[identifier] = absolute
                else:
                    if identifier not in cases or cases[identifier] is None or absolute < cases[identifier]:
                        raise EvidenceError("Unpaired native case end")
                    cases[identifier] = None
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError) as error:
        raise EvidenceError(f"Invalid native stream {path}: {error}") from error
    if run_start is None or run_end is None:
        raise EvidenceError("Missing or incomplete native run")
    functions = {key: value for key, value in declarations.items() if value["kind"] == "function"}
    if set(functions) != (set(ends) | set(skipped)) & set(functions):
        raise EvidenceError("Declared function did not complete or skip")
    return {"event_version": version, "records": count, "completed_runs": 1,
            "completed_functions": [key for key in ends if key in functions],
            "skipped_functions": skipped, "declared_functions": list(functions),
            "parameterized_functions": [key for key, value in functions.items() if value["isParameterized"]]}


def validate_native(path: Path, expected: str) -> dict:
    proof = inspect_native(path)
    completed = proof["completed_functions"]
    # Accept a raw ID or its location-independent identity, never a broad filter.
    identity = function_identity(expected) if re.search(r"\.swift:\d+:\d+$", expected) else expected
    if len(completed) != 1 or function_identity(completed[0]) != identity:
        raise EvidenceError(f"Expected exactly one completed function {identity!r}; got {completed!r}")
    if proof["skipped_functions"] or proof["parameterized_functions"] or len(proof["declared_functions"]) != 1:
        raise EvidenceError("Exact native proof includes skips, parameterized or extra functions")
    return proof


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def output(command: list[str], root: Path) -> str:
    return subprocess.check_output(command, cwd=root, text=True, stderr=subprocess.STDOUT).strip()


def snapshot(root: Path) -> dict:
    tracked = output(["git", "ls-files", "Sources", "Tests"], root).splitlines()
    native = [[name, hashlib.sha256((root / name).read_bytes()).hexdigest()]
              for name in tracked if name.endswith(".swift")]
    files = ("Package.swift", "Package.resolved", "Scripts/verify.py", "Scripts/verification_package.py",
             "Scripts/swiftpm-env.sh", "Scripts/swift_test_watchdog.py", "Scripts/ci_timings.py")
    return {"source": source_identity(root), "playback_pin": playback_pin(root),
            "native_swift_sha256": hashlib.sha256(json.dumps(native).encode()).hexdigest(),
            "files": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files},
            "owned_build_exists": (root / ".build").exists()}


def clean_environment() -> dict[str, str]:
    # Do not inherit primary-merge output/source/acceptance selectors into immutable clones.
    return {key: value for key, value in os.environ.items() if not key.startswith("SPOTTY_")}


def toolchain(root: Path, expected: str) -> dict:
    version = output(["swift", "--version"], root)
    if expected not in {"6.3.3", "6.4"} or not re.search(r"Apple Swift version " + re.escape(expected) + r"(?:\.0)?\s", version):
        raise EvidenceError(f"Expected actual Apple Swift {expected}; found {version}")
    wrapper_sdk = output(["zsh", "-eu", "-c", 'project_root="$PWD"; source Scripts/swiftpm-env.sh; print -r -- "$SDKROOT"'], root)
    sdk_settings = strict_json((Path(wrapper_sdk) / "SDKSettings.json").read_text())
    return {"swift_executable": str(Path(shutil.which("swift") or "swift").resolve()), "swift_version": version,
            "xcode_version": output(["xcodebuild", "-version"], root),
            "xcode_path": output(["xcode-select", "-p"], root),
            "wrapper_sdkroot": wrapper_sdk, "wrapper_sdk_settings": sdk_settings,
            "os": platform.platform(), "architecture": platform.machine(),
            "ci": {key: os.environ.get(key) for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB", "GITHUB_SHA", "ImageOS", "ImageVersion")},
            "dependency_cache_inventory": cache_inventory()}


def cache_inventory() -> dict:
    result = {}
    for path in (Path.home() / "Library/Caches/org.swift.swiftpm", Path.home() / ".swiftpm"):
        # Inventory metadata, not dependency/cache contents or credential files.
        entries = sorted(str(child.relative_to(path)) for child in path.rglob("*") if child.is_file()) if path.exists() else []
        result[str(path)] = {"files": entries, "file_count": len(entries)}
    return result


def native_expected(target: str, selector: str) -> str:
    return f"{target}.{selector}()"


def validate_outcome(case: str, status: int, text: str, events: Path, expected: str | None) -> dict | None:
    if case == "success":
        if status:
            raise EvidenceError(f"Contributor invocation failed with original status {status}", status)
        if expected is None:
            raise EvidenceError("Successful execution requires an exact native identity")
        return validate_native(events, expected)
    proof = inspect_native(events) if events.exists() else None
    completed = proof["completed_functions"] if proof else []
    skipped = proof["skipped_functions"] if proof else []
    if case == "inspection":
        if status or completed or skipped:
            raise EvidenceError("Inspection produced failure or fabricated execution")
    elif status == 0 or completed:
        raise EvidenceError("Expected bounded negative invocation failed to fail without execution")
    elif case == "zero-match":
        if NONEMPTY_DIAGNOSTIC not in text or skipped:
            raise EvidenceError("Zero-match invocation lacks its nonempty-execution diagnostic")
    elif case == "skipped":
        if NONEMPTY_DIAGNOSTIC not in text or len(skipped) != 1 or function_identity(skipped[0]) != expected:
            raise EvidenceError("Entirely skipped invocation lacks exact skip/nonempty proof")
    elif case in {"unknown", "conflict"}:
        diagnostic = "Unknown --target" if case == "unknown" else "cannot be combined with --package-path"
        if diagnostic not in text or "swift-test-watchdog lane=" in text or proof:
            raise EvidenceError("Selector rejection was not the expected pre-compilation failure")
    elif case == "compiler":
        starts = re.findall(r"^swift-test-watchdog lane=.* command=", text, re.MULTILINE)
        if len(starts) != 1 or "error:" not in text or NONEMPTY_DIAGNOSTIC in text:
            raise EvidenceError("Compiler failure lacks original compiler diagnostic/single attempt")
    else:
        raise EvidenceError(f"Unknown evidence case: {case}")
    return proof


def record_invocation(root: Path, destination: Path, argv: list[str], *, expected: str | None,
                      case: str = "success", environment: dict[str, str] | None = None,
                      build: Path | None = None) -> dict:
    destination.mkdir(parents=True, exist_ok=False)
    diagnostics = destination / "diagnostics"
    diagnostics.mkdir()
    env = clean_environment()
    env.update(environment or {})
    env["SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR"] = str(diagnostics)
    env["SPOTTY_CI_TIMINGS_REPORT"] = str(destination / "phases.jsonl")
    before = snapshot(root)
    receipt = {"schema_version": 1, "argv": argv, "cwd": str(root), "case": case,
               "expected_function": expected, "before": before, "success": False,
               "selected_environment": {key: value for key, value in env.items() if key.startswith("SPOTTY_")},
               "started_at_unix_seconds": time.time()}
    write_json(destination / "receipt.json", receipt)
    start = time.monotonic()
    failure = None
    try:
        with (destination / "command.log").open("wb") as log:
            process = subprocess.run(argv, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        status = process.returncode if process.returncode >= 0 else 128 - process.returncode
        receipt["status"] = status
        receipt["wall_seconds"] = round(time.monotonic() - start, 6)
        receipt["finished_at_unix_seconds"] = time.time()
        events = diagnostics / "focused-repeat-1-events.jsonl"
        receipt.update(test_observations(destination / "command.log", events))
        attributed = receipt.get("test_build_seconds", 0) + receipt.get("native_execution_seconds", 0)
        receipt["unattributed_seconds"] = round(receipt["wall_seconds"] - attributed, 6)
        receipt["after"] = snapshot(root)
        if receipt["after"]["source"] != before["source"] or receipt["after"]["files"] != before["files"]:
            raise EvidenceError("Contributor invocation mutated tracked sources or shipping lockfile", status or 1)
        text = (destination / "command.log").read_text(encoding="utf-8", errors="replace")
        receipt["fetch_lines"] = [line for line in text.splitlines() if re.search(r"Fetching |Downloading |Checking out |Resolving ", line)]
        receipt["native_proof"] = validate_outcome(case, status, text, events, expected)
        receipt["success"] = True
    except (OSError, ValueError, KeyboardInterrupt) as error:
        receipt["error"] = str(error)
        receipt.setdefault("status", 130 if isinstance(error, KeyboardInterrupt) else 127)
        status = receipt["status"] or (error.status if isinstance(error, EvidenceError) else 1)
        failure = EvidenceError(str(error), status)
        raise failure from error
    finally:
        # Failed compilation still has useful actual command/diagnostic metadata.
        # Collection must never replace its original terminal status or error.
        try:
            receipt["preserved_build_metadata"] = preserve_build_metadata(build or root / ".build", destination / "build-metadata")
        except (OSError, ValueError) as error:
            receipt["build_metadata_error"] = str(error)
        write_final_json(destination / "receipt.json", receipt, failure=failure, status=receipt.get("status", 0))
    return receipt


def write_final_json(path: Path, payload: dict, *, failure: BaseException | None = None, status: int = 0) -> None:
    """Missing terminal evidence fails closed without masking an original failure."""
    try:
        write_json(path, payload)
    except OSError as error:
        diagnostic = f"Could not preserve required terminal evidence {path}: {error}"
        payload["evidence_write_error"] = diagnostic
        try:
            print(f"focused-selection-evidence: {diagnostic}", file=sys.stderr)
        except (OSError, ValueError):
            pass  # An unavailable diagnostic sink cannot replace the terminal status either.
        if failure is None:
            raise EvidenceError(diagnostic, status or 1) from error


def preserve_build_metadata(build: Path, destination: Path) -> list[dict]:
    """Copy bounded compiler metadata only, without evaluating a manifest or a build."""
    destination.mkdir(exist_ok=False)
    excluded = {"package", "checkouts", "repositories", "artifacts", "module-cache", "ModuleCache",
                "ModuleCache.noindex", "SwiftExplicitPrecompiledModules", "SDKExplicitPrecompiledModules",
                "SDKModuleCaches", "index", "index.noindex", "SDKStatCaches.noindex", ".git"}
    names = {"description.json", "debug.yaml", "release.yaml", "output-file-map.json"}
    packets, total = [], 0
    complete = False
    try:
        for directory, children, files in os.walk(build, followlinks=False):
            children[:] = sorted(name for name in children if name not in excluded and
                                 not (Path(directory) / name).is_symlink() and
                                 (Path(directory) / name).resolve() != destination.resolve())
            for name in sorted(files):
                source = Path(directory) / name
                if source.is_symlink() or not (name in names or source.suffix == ".dia" or
                        name.endswith("-OutputFileMap.json") or
                        (source.parent.suffix == ".xcbuilddata" and name in {"manifest.json", "task-store.msgpack", "description.msgpack"})):
                    continue
                size = source.stat().st_size
                if size > 32 * 1024 * 1024 or total + size > 64 * 1024 * 1024 or len(packets) >= 2048:
                    raise EvidenceError("Compiler metadata preservation exceeded its bounded packet budget")
                relative = source.relative_to(build)
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                data = source.read_bytes()
                target.write_bytes(data)
                total += len(data)
                packets.append({"source": str(source), "preserved": str(target), "bytes": len(data),
                                "sha256": hashlib.sha256(data).hexdigest()})
        complete = True
    finally:
        write_json(destination / "inventory.json", {"build": str(build), "files": packets,
                                                   "total_bytes": total, "complete": complete})
    return packets


def contributor(target: str | None, selector: str, *extra: str) -> list[str]:
    return [sys.executable, "Scripts/verify.py", "test", *(["--target", target] if target else []),
            "--filter", selector, *extra]


def selected_build(root: Path, target: str) -> Path:
    return runpy.run_path(str(root / "Scripts/verification_package.py"))["workspace"](root, f"test-target:{target}")


def invalid_override(destination: Path) -> dict[str, str]:
    path = destination / "never-created.xcframework"
    if path.exists() or path.is_symlink():
        raise EvidenceError("Invalid artifact override unexpectedly exists")
    return {"SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK": str(path)}


def build_observations(description: dict) -> dict:
    """Observe actual compilation tasks, rather than inferring modules from product names."""
    compilations, link_sdks = {}, set()
    commands = description.get("commands", {})
    if not isinstance(commands, dict):
        raise EvidenceError("Malformed actual build commands")
    for command in commands.values():
        if not isinstance(command, dict):
            raise EvidenceError("Malformed actual build command")
        if command.get("tool") == "swift-driver-compilation":
            match = re.fullmatch(r"SwiftDriver Compilation (\S+) normal \S+ com\.apple\.xcode\.tools\.swift\.compiler", command.get("description", ""))
            if match is None:
                raise EvidenceError("Unrecognized actual Swift compilation task")
            inputs = command.get("inputs")
            if not isinstance(inputs, list) or any(not isinstance(item, str) for item in inputs):
                raise EvidenceError("Malformed actual Swift compilation inputs")
            module = match[1]
            sources = [item for item in inputs if item.endswith(".swift")]
            caches = [item for item in inputs if item.startswith("<ClangStatCache ")]
            if not sources or not caches:
                raise EvidenceError(f"Actual compilation {module} has no source/SDK cache inputs")
            sdks = []
            for cache in caches:
                match = re.search(r"/macosx([0-9.]+)-([A-Za-z0-9]+)-[a-f0-9]+\.sdkstatcache>$", cache)
                if match is None:
                    raise EvidenceError("Unrecognized compiler-consumed SDK cache")
                sdks.append({"version": match[1], "build": match[2], "input": cache})
            compilations[module] = {"source_inputs": sources, "compiler_sdk_stat_caches": sdks}
        if command.get("description", "").startswith("Ld "):
            arguments = command.get("args", [])
            if not isinstance(arguments, list):
                raise EvidenceError("Malformed actual linker arguments")
            for index, token in enumerate(arguments[:-1]):
                if token == "-sdk":
                    link_sdks.add(arguments[index + 1])
    # SwiftPM's native build description on other supported backends has explicit
    # moduleName/source/otherArguments fields. No target-product-name assumptions.
    for command in description.get("swiftCommands", {}).values():
        module = command.get("moduleName")
        sources = command.get("sources")
        arguments = command.get("otherArguments", [])
        if not isinstance(module, str) or not isinstance(sources, list) or not sources:
            raise EvidenceError("Malformed SwiftPM compilation description")
        sdk_paths = [arguments[index + 1] for index, token in enumerate(arguments[:-1]) if token == "-sdk"]
        if not sdk_paths:
            raise EvidenceError("SwiftPM compilation lacks its actual SDK operand")
        compilations[module] = {"source_inputs": sources, "compiler_sdk_paths": sdk_paths,
                                "compiler_arguments": arguments}
    return {"compilations": compilations, "link_sdk_paths": sorted(link_sdks)}


def decode_msgpack(data: bytes) -> list:
    """Bounded decoder for actual SwiftBuild task metadata; unsupported data fails."""
    if len(data) > 32 * 1024 * 1024:
        raise EvidenceError("Oversize SwiftBuild MessagePack metadata")
    offset = nodes = 0

    def take(count):
        nonlocal offset
        end = offset + count
        if end > len(data):
            raise EvidenceError("Truncated SwiftBuild MessagePack metadata")
        result, offset = data[offset:end], end
        return result

    def unsigned(width):
        return int.from_bytes(take(width), "big")

    def hashable(value):
        if isinstance(value, list):
            return tuple(hashable(item) for item in value)
        if isinstance(value, dict):
            return tuple((hashable(key), hashable(item)) for key, item in value.items())
        return value

    def mapping(length, depth):
        result = {}
        for _ in range(length):
            key, item = hashable(read(depth + 1)), read(depth + 1)
            if key in result:
                raise EvidenceError("Duplicate SwiftBuild MessagePack map key")
            result[key] = item
        return result

    def read(depth=0):
        nonlocal nodes
        nodes += 1
        if nodes > 500000 or depth > 256:
            raise EvidenceError("SwiftBuild MessagePack complexity limit")
        code = unsigned(1)
        if code <= 0x7f:
            return code
        if code >= 0xe0:
            return code - 256
        if 0xa0 <= code <= 0xbf:
            return take(code & 31).decode("utf-8")
        if 0x90 <= code <= 0x9f:
            return [read(depth + 1) for _ in range(code & 15)]
        if 0x80 <= code <= 0x8f:
            return mapping(code & 15, depth)
        if code == 0xc0:
            return None
        if code in (0xc2, 0xc3):
            return code == 0xc3
        if code in (0xc4, 0xc5, 0xc6):
            return take(unsigned((1, 2, 4)[code - 0xc4]))
        if code in (0xca, 0xcb):
            return struct.unpack(">f" if code == 0xca else ">d", take(4 if code == 0xca else 8))[0]
        if 0xcc <= code <= 0xcf:
            return unsigned((1, 2, 4, 8)[code - 0xcc])
        if 0xd0 <= code <= 0xd3:
            return int.from_bytes(take((1, 2, 4, 8)[code - 0xd0]), "big", signed=True)
        if code in (0xd9, 0xda, 0xdb):
            return take(unsigned((1, 2, 4)[code - 0xd9])).decode("utf-8")
        if code in (0xdc, 0xdd):
            return [read(depth + 1) for _ in range(unsigned(2 if code == 0xdc else 4))]
        if code in (0xde, 0xdf):
            return mapping(unsigned(2 if code == 0xde else 4), depth)
        if code in (0xc7, 0xc8, 0xc9):
            length, tag = unsigned((1, 2, 4)[code - 0xc7]), unsigned(1)
            return ("extension", tag, take(length))
        if 0xd4 <= code <= 0xd8:
            return ("extension", unsigned(1), take((1, 2, 4, 8, 16)[code - 0xd4]))
        raise EvidenceError(f"Unsupported SwiftBuild MessagePack tag {code:#x}")

    values = []
    while offset < len(data):
        values.append(read())
    return values


def compiler_arguments(value) -> list[list[str]]:
    result = []
    if isinstance(value, list):
        if all(isinstance(item, str) for item in value) and "-module-name" in value:
            if not value or not (value[0] == "builtin-SwiftDriver" or Path(value[0]).name in {"swiftc", "swift-frontend"}):
                raise EvidenceError("Module operand in an unrecognized compiler invocation")
            for flag in ("-module-name", "-sdk"):
                if value.count(flag) != 1 or value.index(flag) == len(value) - 1:
                    raise EvidenceError(f"Missing/ambiguous actual compiler operand: {flag}")
            result.append(value)
        else:
            for child in value:
                result.extend(compiler_arguments(child))
    elif isinstance(value, dict):
        for child in value.values():
            result.extend(compiler_arguments(child))
    return result


def verify_compile_scope(compilations: dict, targets: dict, scratch: Path, *, package_name: str) -> list[str]:
    required = {name for name, declaration in targets.items() if declaration["type"] != "binary"}
    if not required <= compilations.keys():
        raise EvidenceError(f"Actual compilation missing manifest targets: {sorted(required - compilations.keys())}")
    if not isinstance(package_name, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", package_name):
        raise EvidenceError("Unsupported manifest package name for generated runner proof")
    allowed = {package_name + "PackageDiscoveredTests", package_name + "PackageTests"}
    generated = []
    for module in compilations.keys() - required:
        sources = compilations[module]["source_inputs"]
        # Aggregate backends may compile generated discovery/runner modules. Require
        # nonempty actual inputs in that named module's own derived directory.
        if (module not in allowed or not isinstance(sources, list) or not sources or
                not all(isinstance(source, str) and Path(source).suffix == ".swift" and
                        Path(source).resolve().is_relative_to(scratch.resolve()) and
                        module + ".derived" in Path(source).parts for source in sources)):
            raise EvidenceError(f"Actual compilation escaped manifest closure: {module}")
        generated.append(module)
    return sorted(generated)


def verify_optimized_compilations(compilations: dict, *, release: bool = False) -> dict:
    """Check the effective compiler configuration, not just the contributor argv."""
    result = {}
    for module, compilation in compilations.items():
        commands = compilation.get("compiler_argv") or [compilation.get("compiler_arguments", [])]
        for arguments in commands:
            if not isinstance(arguments, list) or any(not isinstance(flag, str) for flag in arguments):
                raise EvidenceError(f"Malformed actual optimized compiler arguments: {module}")
            # Clang/linker operands are not Swift configuration flags. An explicit
            # frontend override would need separate proof rather than an assumption.
            swift_flags = []
            operands = iter(arguments)
            controls = {"-Onone", "-O", "-Osize", "-Ounchecked", "-whole-module-optimization", "-wmo",
                        "-no-whole-module-optimization", "-enable-testing", "-disable-testing"}
            for flag in operands:
                if flag in {"-Xcc", "-Xlinker", "-Xfrontend"}:
                    value = next(operands, None)
                    if flag == "-Xfrontend" and value in controls:
                        raise EvidenceError(f"Ambiguous optimized frontend override: {module}")
                    continue
                swift_flags.append(flag)
            optimization = [flag for flag in swift_flags if flag in {"-Onone", "-O", "-Osize", "-Ounchecked"}]
            wmo = [flag for flag in swift_flags if flag in {"-whole-module-optimization", "-wmo", "-no-whole-module-optimization"}]
            debug = any(flag == "-DDEBUG" or (flag == "-D" and index + 1 < len(swift_flags)
                        and swift_flags[index + 1] == "DEBUG") for index, flag in enumerate(swift_flags))
            testability = [flag for flag in swift_flags if flag in {"-enable-testing", "-disable-testing"}]
            if (not optimization or optimization[-1] != "-O" or not wmo or
                    (wmo[-1] in {"-whole-module-optimization", "-wmo"}) != release or debug == release or
                    not testability or testability[-1] != "-enable-testing"):
                raise EvidenceError(f"Actual compiler configuration is not the declared optimized probe: {module}")
        result[module] = {"optimization": "-O", "whole_module_optimization": release, "testable": True,
                          "debug_hooks_compiled": not release}
    if not result:
        raise EvidenceError("Optimized probe lacks actual compiler configuration evidence")
    return result


def graph_proof(root: Path, target: str | None, destination: Path, *, scratch: Path | None = None,
                environment: dict[str, str] | None = None, optimized: bool = False,
                optimized_release: bool = False) -> dict:
    destination.mkdir(exist_ok=False)
    owner = runpy.run_path(str(root / "Scripts/check-package-graphs.py"))
    package_owner = runpy.run_path(str(root / "Scripts/verification_package.py"))
    graph = f"test-target:{target}" if target else "full"
    # Inspect the wrapper-created package after timing. Re-preparing would seed a
    # lockfile again and destroy the engine-free post-invocation observation.
    package = package_owner["workspace"](root, graph) / "package" if target else root
    if not (package / "Package.swift").exists():
        raise EvidenceError("Contributor invocation did not produce its owned selected package")
    env = clean_environment()
    env.update(environment or {})
    env.update(SPOTTY_PACKAGE_GRAPH=graph, SPOTTY_BUILD_BROWSING_HARNESS="0" if target else "1")
    focused = strict_json(owner["succeeded"](owner["swift"](package, graph, "dump-package", **env)))
    write_json(destination / "manifest.json", focused)
    full_env = dict(env)
    full_env.pop("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK", None)
    full_env.update(SPOTTY_PACKAGE_GRAPH="full", SPOTTY_BUILD_BROWSING_HARNESS="1")
    full = strict_json(owner["succeeded"](owner["swift"](root, "full", "dump-package", **full_env))) if target else focused
    write_json(destination / "full-manifest.json", full)
    # The immutable before revision predates this API. Use the evidence owner's
    # shared validator for both references without modifying either clone's source.
    validator_path = Path(__file__).with_name("check-package-graphs.py")
    reference_owner = runpy.run_path(str(validator_path))
    reference = {"validator": {"source": str(validator_path),
                               "sha256": hashlib.sha256(validator_path.read_bytes()).hexdigest()},
                 "probe_owner": {"source": str(root / "Scripts/check-package-graphs.py"),
                                 "sha256": hashlib.sha256((root / "Scripts/check-package-graphs.py").read_bytes()).hexdigest(),
                                 "has_full_manifest_validator": "verify_full_manifest" in owner},
                 "full_reference_validated": False}
    write_json(destination / "reference-assessment.json", reference)
    reference_owner["verify_full_manifest"](full)
    reference["full_reference_validated"] = True
    write_json(destination / "reference-assessment.json", reference)
    if target:
        owner["verify_selection"](full, focused, target, full_package=root, focused_package=package)
    targets = {item["name"]: item for item in focused["targets"]}
    build = scratch or (package_owner["workspace"](root, graph) if target else root / ".build")
    binaries = [name for name, value in targets.items() if value["type"] == "binary"]
    inventory = sorted(str(path.relative_to(build)) for path in build.rglob("*")
                       if path.is_file() and (path.suffix in {".o", ".swiftmodule"} or ".xctest/" in str(path)))
    descriptions = sorted(path for path in build.rglob("*") if path.is_file() and
                          (path.name == "description.json" or (path.name == "manifest.json" and path.parent.suffix == ".xcbuilddata")))
    if not descriptions or not inventory:
        raise EvidenceError("Missing actual build description or produced module/object/test inventory")
    sdks, compilations, actual_argv, metadata = set(), {}, {}, []
    for index, path in enumerate(descriptions):
        raw = path.read_bytes()
        (destination / f"build-description-{index}.json").write_bytes(raw)
        parsed = strict_json(raw.decode())
        observation = build_observations(parsed)
        compilations.update(observation["compilations"])
        for compilation in observation["compilations"].values():
            sdks.update(compilation.get("compiler_sdk_paths", []))
        metadata.append({"source": str(path), "sha256": hashlib.sha256(raw).hexdigest()})
        if path.parent.suffix == ".xcbuilddata":
            for name in ("task-store.msgpack", "description.msgpack"):
                binary = path.with_name(name)
                data = binary.read_bytes()
                (destination / f"build-description-{index}-{name}").write_bytes(data)
                metadata.append({"source": str(binary), "sha256": hashlib.sha256(data).hexdigest()})
                for arguments in compiler_arguments(decode_msgpack(data)):
                    module = arguments[arguments.index("-module-name") + 1]
                    sdk = arguments[arguments.index("-sdk") + 1]
                    sdks.add(sdk)
                    if arguments not in actual_argv.setdefault(module, []):
                        actual_argv[module].append(arguments)
    if actual_argv:
        if actual_argv.keys() != compilations.keys():
            raise EvidenceError("Actual compiler argv modules differ from declared compilation tasks")
        for module, arguments in actual_argv.items():
            compilations[module]["compiler_argv"] = arguments
    elif any("compiler_sdk_stat_caches" in compilation for compilation in compilations.values()):
        raise EvidenceError("SwiftBuild actual compiler argv missing from decoded metadata")
    if not sdks or not compilations:
        raise EvidenceError("Actual compilation/SDK evidence missing from preserved build descriptions")
    if optimized and (actual_argv or any("compiler_arguments" not in item for item in compilations.values())):
        raise EvidenceError("Optimized probe did not produce native-backend compiler metadata")
    optimized_configuration = verify_optimized_compilations(compilations, release=optimized_release) if optimized else None
    generated = verify_compile_scope(compilations, targets, build, package_name=focused["name"]) if target else []
    engine_free = not binaries and not focused["dependencies"]
    if engine_free and (package / "Package.resolved").exists():
        raise EvidenceError("Engine-free selected package retained a resolution lockfile")
    sdk_receipts = {sdk: {"settings": strict_json((Path(sdk) / "SDKSettings.json").read_text()),
                         "system_version": plistlib.loads((Path(sdk) / "System/Library/CoreServices/SystemVersion.plist").read_bytes())}
                    for sdk in sdks}
    proof = {"graph": graph, "package": str(package), "scratch": str(build),
             "full_reference": reference,
             "local_targets": sorted(targets), "external_dependencies": focused["dependencies"],
             "binary_targets": binaries, "engine_free": engine_free,
             "actual_compiled_modules": compilations, "generated_runner_modules": generated,
             "optimized_configuration": optimized_configuration,
             "actual_compiler_sdk_settings": sdk_receipts, "preserved_build_metadata": metadata,
             "produced_inventory": inventory, "isolated_lock_sha256": hashlib.sha256((package / "Package.resolved").read_bytes()).hexdigest() if (package / "Package.resolved").exists() else None}
    if binaries:
        inherited_override = os.environ.pop("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK", None)
        try:
            proof["playback_artifact"] = engine_identity(root, build)
        finally:
            if inherited_override is not None:
                os.environ["SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"] = inherited_override
    write_json(destination / "proof.json", proof)
    return proof


def workload_report(path: Path, kind: str) -> dict:
    report = strict_json(path.read_text())
    measurements = report.get("measurements")
    if not isinstance(measurements, list) or any(not isinstance(row, dict) for row in measurements):
        raise EvidenceError("Malformed optimized workload report")
    if kind == "gateway":
        expected = {(name, sample) for name in ("search-30", "playlist-300", "graphql-error") for sample in range(3)}
        actual = {(row.get("workload"), row.get("sample")) for row in measurements}
        valid = report.get("version") == 1 and report.get("iterations") == 500 and len(measurements) == 9 and actual == expected
    else:
        valid = (report.get("version") == 2 and report.get("iterations") == 100 and len(measurements) == 3
                 and [row.get("requestedURIs") for row in measurements] == [500, 20000, 40000])
    if not valid:
        raise EvidenceError("Optimized workload report changed its bounded inputs")
    for row in measurements:
        for key in ("cpuSeconds", "wallSeconds"):
            value = row.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise EvidenceError("Invalid workload timing observation")
    return report


def run_smoke(root: Path, destination: Path, compiler: str) -> dict:
    provenance = toolchain(root, compiler)
    write_json(destination / "toolchain.json", provenance)
    before = snapshot(root)
    environment = invalid_override(destination)
    rows = [record_invocation(root, destination / label, contributor("SpottyTestSupportTests", SMOKE),
                              expected=native_expected("SpottyTestSupportTests", SMOKE), environment=environment,
                              build=selected_build(root, "SpottyTestSupportTests"))
            for label in ("first", "repeat")]
    graph = graph_proof(root, "SpottyTestSupportTests", destination / "graph", environment=environment)
    if not graph["engine_free"] or any(row["fetch_lines"] for row in rows) or snapshot(root)["files"] != before["files"]:
        raise EvidenceError("TestSupport smoke acquired an artifact, dependency fetch, or lockfile mutation")
    return {"toolchain": provenance, "invocations": rows, "graph": graph,
            "cache_context": "Primary lane shared caches may be restored/warm; first and repeat costs are observed, not machine-wide cold."}


def immutable_clone(source: str, revision: str, root: Path) -> None:
    root.mkdir()
    with (root.parent / f"{root.name}-clone.log").open("wb") as log:
        subprocess.run(["git", "clone", "--no-checkout", "--no-local", "--", source, str(root)], check=True, stdout=log, stderr=subprocess.STDOUT)
        # Fetch only missing immutable objects, never a moving main fallback.
        if subprocess.run(["git", "cat-file", "-e", revision + "^{commit}"], cwd=root, stdout=log, stderr=log).returncode:
            origin = output(["git", "remote", "get-url", "origin"], root)
            if Path(origin).exists():
                origin = output(["git", "remote", "get-url", "origin"], Path(source))
            subprocess.run(["git", "fetch", "--no-tags", origin, revision], cwd=root, check=True, stdout=log, stderr=log)
        subprocess.run(["git", "checkout", "--detach", revision], cwd=root, check=True, stdout=log, stderr=log)
    if output(["git", "rev-parse", "HEAD"], root) != revision or (root / ".build").exists():
        raise EvidenceError("Clone is not exact or already contains build products")


def verify_comparison_inputs(identities: dict) -> None:
    before, after = identities["before"], identities["after"]
    if before["files"]["Package.resolved"] != after["files"]["Package.resolved"]:
        raise EvidenceError("Shipping Package.resolved bytes differ; selection-only comparison invalid")
    if before["native_swift_sha256"] != after["native_swift_sha256"] or before["playback_pin"] != after["playback_pin"]:
        raise EvidenceError("Native Swift inputs or playback pins differ; selection-only comparison invalid")


def compatibility_probes(after: Path, destination: Path, invalid: dict[str, str], full: dict) -> dict:
    """One build per explicit configuration; skip-build and negative cases never retry failures."""
    probes = []
    # Engine independence derives from the manifest owner's closure, not this function list.
    owner = runpy.run_path(str(after / "Scripts/check-package-graphs.py"))
    targets = {item["name"]: item for item in full["targets"]}
    for target, selector in PROBES:
        local, external = owner["dependency_closure"](targets, target)
        engine_free = not external and not any(targets[name]["type"] == "binary" for name in local)
        env = invalid if engine_free else {}
        scratch = after / ".build" / "owned TestSupport scratch" if target == "SpottyTestSupportTests" else None
        extra = ["--scratch-path", str(scratch)] if scratch else []
        row = record_invocation(after, destination / target, contributor(target, selector, *extra), expected=native_expected(target, selector),
                                environment=env, build=scratch or selected_build(after, target))
        proof = graph_proof(after, target, destination / f"{target}-graph", scratch=scratch, environment=env)
        if engine_free and row["fetch_lines"]:
            raise EvidenceError(f"Engine-free {target} fetched dependencies")
        probes.append({"invocation": row, "graph": proof})
    optimized = []
    gateway_selector = "PathfinderDecodingMeasurementTests/measureResponseDecoding"
    gateway_scratch = after / ".build" / "owned gateway optimized scratch"
    gateway_flags = [*OPTIMIZED_PROBE_FLAGS, "--scratch-path", str(gateway_scratch)]
    for label, extra in (("optimized-debug-native", []), ("optimized-debug-native-skip-build", ["--skip-build"])):
        report = destination / f"gateway-{label}-workload.json"
        row = record_invocation(after, destination / f"gateway-{label}", contributor("SpottyGatewayTests", gateway_selector, *gateway_flags, *extra),
                                expected=native_expected("SpottyGatewayTests", gateway_selector), build=gateway_scratch,
                                environment={**invalid, "SPOTTY_PATHFINDER_DECODING_REPORT": str(report)})
        if row["fetch_lines"]:
            raise EvidenceError("Optimized engine-free Gateway probe fetched dependencies")
        optimized.append({"invocation": row, "workload": workload_report(report, "gateway")})
    optimized.append({"graph": graph_proof(after, "SpottyGatewayTests", destination / "gateway-optimized-debug-native-graph",
                                          scratch=gateway_scratch, environment=invalid, optimized=True)})
    boundary_selector = "CatalogMetadataMeasurementTests/measureUnchangedEntitySubscriptions"
    boundary_scratch = after / ".build" / "owned boundary optimized scratch"
    for label, extra in (("optimized-debug-native", []), ("optimized-debug-native-skip-build", ["--skip-build"])):
        boundary_report = destination / f"boundary-{label}-workload.json"
        row = record_invocation(after, destination / f"boundary-{label}", contributor("SpottyBoundaryTests", boundary_selector, *OPTIMIZED_PROBE_FLAGS,
                                "--scratch-path", str(boundary_scratch), "-Xswiftc", "-DSPOTTY_BROWSING_OPTIMIZED", *extra),
                                expected=native_expected("SpottyBoundaryTests", boundary_selector), build=boundary_scratch,
                                environment={"SPOTTY_ENTITY_OBSERVATION_REPORT": str(boundary_report)})
        optimized.append({"invocation": row, "workload": workload_report(boundary_report, "boundary")})
    optimized.append({"graph": graph_proof(after, "SpottyBoundaryTests", destination / "boundary-optimized-debug-native-graph", scratch=boundary_scratch, optimized=True)})
    domain_selector = PROBES[0][1]
    domain_scratch = after / ".build" / "owned domain release scratch"
    for label, extra in (("release-native", []), ("release-native-skip-build", ["--skip-build"])):
        row = record_invocation(after, destination / f"domain-{label}", contributor("SpottyDomainTests", domain_selector,
                                *DOMAIN_RELEASE_PROBE_FLAGS, "--scratch-path", str(domain_scratch), *extra),
                                expected=native_expected("SpottyDomainTests", domain_selector),
                                build=domain_scratch, environment=invalid)
        if row["fetch_lines"]:
            raise EvidenceError("Optimized engine-free Domain probe fetched dependencies")
        optimized.append({"invocation": row})
    optimized.append({"graph": graph_proof(after, "SpottyDomainTests", destination / "domain-release-native-graph",
                                          scratch=domain_scratch, environment=invalid,
                                          optimized=True, optimized_release=True)})
    hook = "QueueAdmissionTests/suspendedResetCannotReplaceANewerAccount"
    hook_row = record_invocation(after, destination / "runtime-debug-hook", contributor("SpottySessionRuntimeTests", hook, "--skip-build"),
                                 expected=native_expected("SpottySessionRuntimeTests", hook), build=selected_build(after, "SpottySessionRuntimeTests"))
    negatives = []
    cases = (
        ("zero-match", contributor("SpottyGatewayTests", "SpottyDoesNotExist589", "--skip-build"), None, invalid),
        ("skipped", contributor("SpottyGatewayTests", gateway_selector, *gateway_flags, "--skip-build"), native_expected("SpottyGatewayTests", gateway_selector), invalid),
        ("inspection", [sys.executable, "Scripts/verify.py", "list", "--target", "SpottyGatewayTests"], None, invalid),
        ("unknown", contributor("SpottyUnknown589Tests", GATEWAY), None, invalid),
        ("conflict", contributor("SpottyGatewayTests", GATEWAY, "--package-path", str(after)), None, invalid),
        ("compiler", contributor("SpottyGatewayTests", GATEWAY, "-Xswiftc", "-spotty-deliberately-invalid-589"), None, invalid),
    )
    for case, argv, expected, env in cases:
        row = record_invocation(after, destination / f"negative-{case}", argv, expected=expected, case=case, environment=env,
                                build=gateway_scratch if case == "skipped" else selected_build(after, "SpottyGatewayTests"))
        if case == "inspection":
            text = (destination / f"negative-{case}/command.log").read_text()
            listed = re.findall(r"^(Spotty\w+Tests)\.", text, re.MULTILINE)
            if not listed or set(listed) != {"SpottyGatewayTests"}:
                raise EvidenceError("Selected listing escaped its module or listed no functions")
        negatives.append(row)
    return {"module_probes": probes, "optimized_probes": optimized,
            "debug_hook": hook_row, "negative_cases": negatives}


def run_compatibility(primary: Path, destination: Path, source: str, head: str, compiler: str) -> dict:
    """Source-bound compatibility acceptance without another cost-comparison experiment."""
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise EvidenceError("Compatibility proof requires an immutable full head SHA")
    original = snapshot(primary)
    provenance = toolchain(primary, compiler)
    driver_digest = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    write_json(destination / "toolchain.json", provenance)
    write_json(destination / "inputs.json", {"head": head, "primary": original, "cloning_source": source,
                                            "driver_sha256": driver_digest})
    clones = destination / "clones"
    clones.mkdir()
    selected = clones / "selected"
    immutable_clone(source, head, selected)
    identity = snapshot(selected)
    if hashlib.sha256((selected / "Scripts/focused_selection_evidence.py").read_bytes()).hexdigest() != driver_digest:
        raise EvidenceError("Compatibility driver differs from the requested immutable head")
    if (identity["source"]["revision"] != head or identity["source"]["diffSHA256"] != hashlib.sha256(b"").hexdigest() or
            identity["source"]["untrackedFileCount"]):
        raise EvidenceError("Compatibility clone does not match the clean requested head")
    write_json(destination / "clone-identity.json", identity)
    # Validate the genuine current full inventory before making any selected cut.
    owner = runpy.run_path(str(selected / "Scripts/check-package-graphs.py"))
    full = strict_json(owner["succeeded"](owner["swift"](selected, "full", "dump-package",
                                                      SPOTTY_BUILD_BROWSING_HARNESS="1", **clean_environment())))
    write_json(destination / "full-manifest.json", full)
    owner["verify_full_manifest"](full)
    reference = {"source": identity["source"], "validator": str(selected / "Scripts/check-package-graphs.py"),
                 "validator_sha256": hashlib.sha256((selected / "Scripts/check-package-graphs.py").read_bytes()).hexdigest(),
                 "full_reference_validated": True}
    write_json(destination / "full-reference.json", reference)
    invalid = invalid_override(destination)
    gateway = record_invocation(selected, destination / "SpottyGatewayTests", contributor("SpottyGatewayTests", GATEWAY),
                                expected=native_expected("SpottyGatewayTests", GATEWAY), environment=invalid,
                                build=selected_build(selected, "SpottyGatewayTests"))
    gateway_graph = graph_proof(selected, "SpottyGatewayTests", destination / "Gateway-debug-graph", environment=invalid)
    if not gateway_graph["engine_free"] or gateway["fetch_lines"]:
        raise EvidenceError("Focused Gateway graph acquired engine/external fetch")
    acceptance = compatibility_probes(selected, destination, invalid, full)
    acceptance["module_probes"].insert(0, {"invocation": gateway, "graph": gateway_graph})
    final = snapshot(selected)
    if final["source"] != identity["source"] or final["files"] != identity["files"]:
        raise EvidenceError("Compatibility probes changed their source or shipping lockfile")
    current = snapshot(primary)
    if current["source"] != original["source"] or current["files"] != original["files"]:
        raise EvidenceError("Compatibility proof changed the primary checkout or shipping lockfile")
    return {"head": head, "primary_sha": original["source"]["revision"], "toolchain": provenance,
            "identity": identity, "after": final, "full_reference": reference, **acceptance,
            "driver_sha256": driver_digest,
            "optimized_probe_flags": list(OPTIMIZED_PROBE_FLAGS),
            "domain_release_probe_flags": list(DOMAIN_RELEASE_PROBE_FLAGS),
            "cache_context": "One Debug build per cut; native optimized Debug/non-WMO Gateway/Boundary and native WMO Domain Release. No before/after loop or CI speed credit."}


def run_experiment(primary: Path, destination: Path, source: str, before_sha: str, after_sha: str, compiler: str) -> dict:
    if os.environ.get("CI") != "true" or compiler != "6.3.3":
        raise EvidenceError("The bounded one-time experiment requires CI and actual Swift 6.3.3")
    if any(not re.fullmatch(r"[0-9a-f]{40}", revision) for revision in (before_sha, after_sha)):
        raise EvidenceError("Before and after require immutable full commit SHAs")
    if before_sha == after_sha:
        raise EvidenceError("Before and after revisions must differ")
    original = snapshot(primary)
    provenance = toolchain(primary, compiler)
    write_json(destination / "toolchain.json", provenance)
    write_json(destination / "inputs.json", {"before_sha": before_sha, "after_sha": after_sha,
               "primary": original, "cloning_source": source})
    clones = destination / "clones"
    clones.mkdir()
    before, after = clones / "before", clones / "after"
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(immutable_clone, source, revision, root)
                   for root, revision in ((before, before_sha), (after, after_sha))]
        for future in futures:
            future.result()
    # A shallow source checkout can lack baseline history. Resolve it before ancestry assertion.
    if output(["git", "rev-parse", "--is-shallow-repository"], after) == "true":
        origin = output(["git", "remote", "get-url", "origin"], primary)
        subprocess.run(["git", "fetch", "--unshallow", "--no-tags", origin], cwd=after, check=True, stdout=subprocess.DEVNULL)
    if subprocess.run(["git", "merge-base", "--is-ancestor", before_sha, after_sha], cwd=after).returncode:
        raise EvidenceError("Immutable before revision is not an available ancestor of after")
    identities = {name: snapshot(root) for name, root in (("before", before), ("after", after))}
    write_json(destination / "clone-identities.json", identities)
    verify_comparison_inputs(identities)
    rows, graphs = {}, {}
    invalid = invalid_override(destination)
    for side, root, target, selector, environment in (("before", before, None, "SpottyGatewayTests." + GATEWAY, {}),
                                                      ("after", after, "SpottyGatewayTests", GATEWAY, invalid)):
        rows[side] = []
        for label in ("cold", "warm-1", "warm-2", "skip-build"):
            row = record_invocation(root, destination / f"{side}-{label}", contributor(target, selector, *(["--skip-build"] if label == "skip-build" else [])),
                                    expected=native_expected("SpottyGatewayTests", GATEWAY), environment=environment,
                                    build=selected_build(root, target) if target else root / ".build")
            rows[side].append(row)
        graphs[side] = graph_proof(root, target, destination / f"{side}-graph", environment=environment)
        if side == "after" and (not graphs[side]["engine_free"] or any(row["fetch_lines"] for row in rows[side])):
            raise EvidenceError("Focused Gateway graph acquired engine/external fetch")
    acceptance = compatibility_probes(after, destination, invalid,
                                      strict_json((destination / "after-graph/full-manifest.json").read_text()))
    current = snapshot(primary)
    if current["source"] != original["source"] or current["files"] != original["files"]:
        raise EvidenceError("Experiment mutated the primary checkout or shipping lockfile")
    costs = {}
    for side, samples in rows.items():
        warm = [row["wall_seconds"] for row in samples[1:3]]
        costs[side] = {"cold_seconds": samples[0]["wall_seconds"], "warm_seconds": warm,
                       "warm_median_seconds": statistics.median(warm), "warm_range_seconds": [min(warm), max(warm)],
                       "skip_build_seconds": samples[3]["wall_seconds"]}
    return {"before_sha": before_sha, "after_sha": after_sha, "primary_sha": original["source"]["revision"],
            "event_base_sha": os.environ.get("SPOTTY_EVIDENCE_EVENT_BASE_SHA"), "toolchain": provenance,
            "identities": identities, "timing_samples": rows, "costs": costs, "graphs": graphs,
            **acceptance,
            "cache_context": "Owned clones began without products/module caches; shared dependency/manifest/system caches are warm after full lane. One cold sample is descriptive; no #587 credit or speed threshold."}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    validate = actions.add_parser("validate")
    validate.add_argument("--native-events", type=Path, required=True)
    validate.add_argument("--expected-function", required=True)
    record = actions.add_parser("record")
    record.add_argument("--expected-function")
    record.add_argument("--build-path", type=Path, help="Actual scratch directory whose bounded compiler metadata is preserved on success or failure")
    record.add_argument("--case", choices=("success", "inspection", "zero-match", "skipped", "unknown", "conflict", "compiler"), default="success")
    record.add_argument("argv", nargs=argparse.REMAINDER)
    smoke = actions.add_parser("smoke")
    compatibility = actions.add_parser("compatibility", help="One source-bound compatibility proof; no before/after timing experiment")
    experiment = actions.add_parser("experiment")
    for action in (record, smoke, compatibility, experiment):
        action.add_argument("--root", type=Path, default=Path.cwd())
        action.add_argument("--output", type=Path, required=True)
    for action in (smoke, compatibility, experiment):
        action.add_argument("--swift-version", required=True, choices=("6.3.3", "6.4"))
    experiment.add_argument("--source", required=True)
    experiment.add_argument("--before", required=True)
    experiment.add_argument("--after", required=True)
    compatibility.add_argument("--source", required=True)
    compatibility.add_argument("--head", required=True)
    args = parser.parse_args()
    try:
        if args.action == "validate":
            print(json.dumps(validate_native(args.native_events, args.expected_function)))
            return 0
        if args.action == "record":
            argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            if not argv:
                raise EvidenceError("record requires a contributor argv after --")
            record_invocation(args.root.resolve(), args.output.resolve(), argv, expected=args.expected_function, case=args.case,
                              build=args.build_path.resolve() if args.build_path else None)
            return 0
        destination = args.output.resolve()
        destination.mkdir(parents=True, exist_ok=False)
        summary = {"schema_version": 1, "action": args.action, "success": False, "started_at_unix_seconds": time.time(),
                   "ci": {key: os.environ.get(key) for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB", "GITHUB_SHA")}}
        start = time.monotonic()
        write_json(destination / "summary.json", summary)
        failure = None
        try:
            if args.action == "smoke":
                result = run_smoke(args.root.resolve(), destination, args.swift_version)
            elif args.action == "compatibility":
                result = run_compatibility(args.root.resolve(), destination, args.source, args.head, args.swift_version)
            else:
                result = run_experiment(args.root.resolve(), destination, args.source, args.before, args.after, args.swift_version)
            summary.update(result, success=True)
        except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            summary["error"] = str(error)
            failure = error
            raise
        finally:
            summary["driver_wall_seconds"] = round(time.monotonic() - start, 6)
            write_final_json(destination / "summary.json", summary, failure=failure)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        try:
            print(f"focused-selection-evidence: {error}", file=sys.stderr)
        except (OSError, ValueError):
            pass  # Broken pipes and closed streams cannot replace the original failure.
        return error.status if isinstance(error, EvidenceError) else 130 if isinstance(error, KeyboardInterrupt) else 1


if __name__ == "__main__":
    raise SystemExit(main())
