#!/usr/bin/env python3
"""One bounded, synthetic-only GUI regression attempt using an isolated CI test host."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import signal
import struct
import zlib
import subprocess
import sys
import time
import uuid

import browsing_process
import browsing_provenance
from compare_synthetic_profiles import field, number, require, validate_manifest


EVIDENCE_ERRORS = (OSError, ValueError, RuntimeError, KeyError, TypeError, AttributeError, subprocess.SubprocessError)


TOTAL_TIMEOUT_SECONDS = 300
RUN_TIMEOUT_SECONDS = 90
HOST_ID = "dev.spotty.gui-test-host"
FIXTURES = {
    "gui-shell": ("home.default", "home.minimum", "shell.inactive", "shell.resized", "search.all",
                  "search.albums", "detail.playlist", "search.returned"),
    "gui-signed-out": ("signed-out.default", "signed-out.minimum", "shell.inactive", "shell.resized"),
}
LIMIT = "Unsandboxed synthetic GUI test host; no App Sandbox, live Spotify, audio, or visual-parity attestation."



def required_assertions(name, signed_out):
    names = {"window.requested-body-size", "sidebar.width", "catalog.excludes-sidebar", "player.excludes-catalog",
             "toolbar.excludes-catalog", "player.height", "toolbar.controls-disjoint", "toolbar.search-height",
             "window.display-stable", "window.fits-display", "window.key-state", "window.application-active-state", "safety.no-playing", "safety.no-commands", "capture.window-dimensions"}
    names.update("shell." + item + ".visible" for item in ("sidebar", "catalog", "player", "navigation", "home", "search"))
    names.update("shell." + item + suffix for item in ("home", "search")
                 for suffix in (".chrome-sample-region", ".native-background-does-not-cover-padding"))
    names.update("shell.history." + item + suffix for item in ("back", "forward")
                 for suffix in (".visible", ".hitbox-size", ".chrome-sample-region", ".native-background-does-not-cover-edge"))
    names.add("toolbar.history-controls-disjoint")
    names.update(item + ".chrome-opaque" for item in
                 ("shell.home", "shell.search", "shell.history.back", "shell.history.forward"))
    names.add("signed-out.no-engine" if signed_out else "restore.current-track-artwork")
    if name.startswith("search."):
        names.add("search.filters-contained")
    if name == "shell.resized":
        names.add("window.distinct-resize")
    if name == "search.returned":
        names.update(("history.shortcut-back", "history.shortcut-forward", "history.shortcut-returned"))
    if name == "detail.playlist":
        names.add("detail.native-scroll-contained")
    return names


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def read_json(path):
    value = json.loads(path.read_text())
    require(isinstance(value, dict), path.name)
    return value


def remaining(deadline):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise TimeoutError("GUI regression exceeded its five-minute total deadline")
    return seconds



def retire_command(process):
    # The session/group remains owned when the leader exits before its descendants.
    failures = []
    for action in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, action)
        except ProcessLookupError:
            pass
        except OSError as error:
            failures.append(str(error))
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired as error:
            if action == signal.SIGKILL:
                failures.append(str(error))
        except (OSError, subprocess.SubprocessError) as error:
            failures.append(str(error))
    return {"pid": process.pid, "verified": not failures, "failures": failures}


def preserve_cleanup_failure(primary, process):
    retirement = retire_command(process)
    if not retirement["verified"]:
        primary.cleanupFailure = retirement
    return retirement


def desired_body_size(name):
    if name.endswith(".default"):
        return {"width": 1220, "height": 780}
    if name.endswith(".minimum") or name == "shell.inactive":
        return {"width": 960, "height": 640}
    return {"width": 1080, "height": 700}


def rectangle(value, label):
    require(isinstance(value, dict) and all(type(value.get(axis)) in (int, float)
            and math.isfinite(value[axis]) for axis in ("x", "y", "width", "height"))
            and value["width"] > 0 and value["height"] > 0, label)
    return value


def validate_display_size(point):
    desired = rectangle(point.get("desiredBodySize"), "desired body rectangle")
    screen = rectangle(point.get("screenVisibleFrame"), "screen visible rectangle")
    requested = rectangle(point.get("requestedBodySize"), "requested body rectangle")
    layout = rectangle(point.get("contentLayoutRect"), "actual layout rectangle")
    content = rectangle(point.get("contentBounds"), "actual content rectangle")
    actual = {"width": content["width"], "height": layout["height"]}
    overhead = point.get("frameToBodyOverhead")
    require(isinstance(overhead, dict) and overhead.get("x") == 0 and overhead.get("y") == 0
            and all(number(overhead.get(axis)) for axis in ("width", "height")),
            "nonnegative frame-to-body overhead")
    fixed = desired_body_size(point["name"])
    require(desired["x"] == 0 and desired["y"] == 0 and requested["x"] == 0 and requested["y"] == 0
            and all(desired[axis] == fixed[axis] for axis in ("width", "height")), "fixed desired fixture size")
    chosen = {axis: min(fixed[axis], math.floor(screen[axis] - overhead[axis])) for axis in ("width", "height")}
    require(chosen["width"] >= 960 and chosen["height"] >= 640, "display supports minimum fixture body")
    require(all(abs(requested[axis] - chosen[axis]) <= 0.01 for axis in ("width", "height")),
            "independent display-aware target size")
    require(all(abs(actual[axis] - chosen[axis]) <= 2 for axis in ("width", "height")), "actual body matches target size")
    frame = rectangle(point.get("windowFrame"), "window frame rectangle")
    require(all(abs(frame[axis] - chosen[axis] - overhead[axis]) <= 2 for axis in ("width", "height")),
            "window frame/body overhead")
    require(frame["x"] >= screen["x"] - 2 and frame["y"] >= screen["y"] - 2
            and frame["x"] + frame["width"] <= screen["x"] + screen["width"] + 2
            and frame["y"] + frame["height"] <= screen["y"] + screen["height"] + 2, "window fits visible display")
    return chosen


def png_dimensions(path):
    with path.open("rb") as stream:
        header = stream.read(33)
    require(len(header) == 33 and header[:8] == b"\x89PNG\r\n\x1a\n"
            and header[8:16] == b"\x00\x00\x00\x0dIHDR", "PNG signature/IHDR")
    require(struct.unpack(">I", header[29:33])[0] == zlib.crc32(header[12:29]), "PNG IHDR checksum")
    width, height = struct.unpack(">II", header[16:24])
    require(width > 0 and height > 0, "PNG nonempty dimensions")
    return width, height


def metadata(root, deadline, operation, *paths):
    """Keep the existing provenance owner, with a deadline on its complete process group."""
    program = """import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'Scripts'))
import browsing_provenance as provenance
root = Path(sys.argv[1])
operation = sys.argv[2]
if operation == 'source':
    result = provenance.source_identity(root)
elif operation == 'snapshot':
    result = provenance.build_snapshot(root)
elif operation == 'launch':
    run_root, app = map(Path, sys.argv[3:5])
    provenance.write_launch(root, root / '.build', run_root, app, 'debug', True, False)
    result = None
else:
    raise ValueError('Unsupported bounded provenance operation')
print(json.dumps(result))
"""
    timeout = remaining(deadline)
    command = [sys.executable, "-c", program, str(root), operation, *map(str, paths)]
    process = subprocess.Popen(command, cwd=root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException as primary:
        preserve_cleanup_failure(primary, process)
        raise
    if process.returncode:
        raise RuntimeError(f"Provenance {operation} failed: {stderr[-4000:].strip()}")
    return json.loads(stdout)


def stable_source(root, expected, expected_head=None, *, deadline=None):
    observed = (browsing_provenance.source_identity(root) if deadline is None else metadata(root, deadline, "source"))
    require(observed == expected, "source changed during GUI regression")
    if expected_head:
        require(observed["revision"] == expected_head, "checkout does not match expected head")
    return observed


def bounded_command(command, root, log, deadline):
    """Bound build/sign commands and retire only the process group this call creates."""
    with log.open("ab") as output:
        output.write(("Command: " + repr(command) + "\n").encode())
        output.flush()
        process = subprocess.Popen(command, cwd=root, stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            result = process.wait(timeout=remaining(deadline))
        except BaseException as primary:
            retirement = preserve_cleanup_failure(primary, process)
            if not retirement["verified"]:
                output.write(("Cleanup unverified: " + json.dumps(retirement) + "\n").encode())
                output.flush()
            raise
    if result:
        raise RuntimeError(f"Command exited {result}; see {log.name}")


def build(root, output, deadline):
    # Use the normal SDK, full graph, validated engine and module cache. Reuse the Swift gate's .build.
    program = '''set -euo pipefail
project_root="$1"
source "$project_root/Scripts/swiftpm-env.sh"
source "$project_root/Scripts/playback-xcframework.sh"
selected_xcframework="$(spotty_playback_resolve_xcframework)"
spotty_playback_validate_xcframework "$selected_xcframework"
playback_headers="$(spotty_playback_headers_path "$(spotty_playback_slice_path "$selected_xcframework")")"
python3 "$project_root/Scripts/playback_module_cache.py" "$project_root/.build" "$playback_headers" --configuration debug
SPOTTY_BUILD_BROWSING_HARNESS=1 swift build --disable-sandbox --sdk "$SDKROOT" --configuration debug --product SpottyBrowsingHarness "${spotty_swiftc_warnings_as_errors[@]}"
SPOTTY_BUILD_BROWSING_HARNESS=1 swift build --disable-sandbox --sdk "$SDKROOT" --configuration debug --show-bin-path > "$2/binary-path.txt"
'''
    bounded_command(["/bin/zsh", "-c", program, "gui-regression-build", str(root), str(output)],
                    root, output / "build.log", deadline)
    binary_dir = Path((output / "binary-path.txt").read_text().strip()).resolve()
    require(binary_dir.is_relative_to(root / ".build"), "build product outside shared scratch")
    return binary_dir


def assemble(root, run_root, binary_dir, fixture, snapshot, deadline):
    app = run_root / "Spotty GUI Test Host.app"
    resources = app / "Contents/Resources"
    executable = app / "Contents/MacOS/SpottyDemo"
    resources.mkdir(parents=True)
    executable.parent.mkdir()
    shutil.copy2(binary_dir / "SpottyBrowsingHarness", executable)
    shutil.copytree(binary_dir / "Spotty_SpottyBrowsingSupport.bundle", resources / "Spotty_SpottyBrowsingSupport.bundle")
    shutil.copy2(fixture, resources / "scenario.json")
    with (root / "Packaging/Info.plist").open("rb") as stream:
        minimum = plistlib.load(stream)["LSMinimumSystemVersion"]
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": HOST_ID, "CFBundleExecutable": "SpottyDemo", "CFBundlePackageType": "APPL",
        "CFBundleName": "Spotty GUI Test Host", "CFBundleDisplayName": "Spotty GUI Test Host",
        "LSMinimumSystemVersion": minimum, "NSPrincipalClass": "NSApplication",
    }))
    write_json(run_root / "build-start.json", snapshot)
    metadata(root, deadline, "launch", run_root, app)
    launch = read_json(run_root / "manifest.json")
    launch["guiTestHost"] = True
    write_json(run_root / "manifest.json", launch)
    write_json(resources / "launch.json", launch)
    # Ad-hoc signing is confined to this disposable synthetic fixture. No development identity is queried.
    program = '''set -euo pipefail
project_root="$1"
source "$project_root/Scripts/embed-sparkle.sh"
spotty_embed_sparkle "$2" - --scratch-path "$project_root/.build" --timestamp=none
/usr/bin/codesign --force --timestamp=none --sign - "$2"
/usr/bin/codesign --verify --strict "$2"
'''
    bounded_command(["/bin/zsh", "-c", program, "gui-regression-sign", str(root), str(app)],
                    root, run_root / "host.log", deadline)
    return executable, launch


def validate_reports(run_root, manifest, fixture, owned, expected_names):
    validate_manifest(manifest)
    require(manifest.get("guiTestHost") is True, "manifest.guiTestHost")
    require(manifest.get("runRoot") == str(run_root), "manifest.runRoot")
    require(manifest["build"]["configuration"] == "debug" and manifest["build"]["optimization"] == "-Onone",
            "manifest.Debug build")
    require(manifest["build"]["testabilityEnabled"] is True, "manifest.testabilityEnabled")
    require(manifest["fixture"]["sha256"] == browsing_provenance.sha256_file(fixture), "fixture digest")
    scenario = read_json(fixture)
    workload = {key: value for key, value in scenario.items() if key != "forceSynchronousLayout"}
    digest = hashlib.sha256(json.dumps(workload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    require(manifest["fixture"]["workloadSHA256"] == digest, "fixture workload digest")
    require(scenario.get("guiShellRegression") is True and scenario.get("mode") in ("browsing", "signed-out"),
            "synthetic nonplaying GUI fixture")
    report = read_json(run_root / "report.json")
    shell = read_json(run_root / "shell-regression.json")
    require(report.get("shellRegression") == shell, "report shell snapshot")
    for value in (report, shell):
        require(value.get("launch") == manifest, "report launch identity")
        require(value.get("passed") is True and value.get("failure") is None, "report passed")
        require(value.get("networkSandboxVerified") is False, "test host must not claim sandbox attestation")
    require(shell.get("host") == HOST_ID, "test host identity")
    require(all(report["scenario"].get(key) == value for key, value in scenario.items()), "report scenario")
    require(type(field(report, "world.mutationAttempts")) is int and report["world"]["mutationAttempts"] == 0,
            "no mutations")
    require(type(field(report, "playback.commandCount")) is int and report["playback"]["commandCount"] == 0,
            "no commands")
    require(field(report, "playback.playing") is False, "no playing")
    if scenario["mode"] == "signed-out":
        requests = field(report, "world.requests")
        require(isinstance(requests, dict) and requests.get("engine.synthetic-initialize", 0) == 0,
                "signed-out no engine initialization")
    checkpoints = shell.get("checkpoints")
    require(isinstance(checkpoints, list) and all(isinstance(point, dict) for point in checkpoints)
            and tuple(point.get("name") for point in checkpoints) == expected_names,
            "complete GUI checkpoints")
    sizes = {}
    for point in checkpoints:
        sizes[point["name"]] = validate_display_size(point)
        for key, value in (("runID", manifest["runID"]), ("host", HOST_ID),
                           ("sourceSHA256", manifest["source"]["sourceSHA256"]),
                           ("buildProductSHA256", manifest["build"]["buildProductSHA256"])):
            require(point.get(key) == value, "checkpoint." + key)
        require(point.get("playing") is False, "checkpoint.no-playing")
        for key in ("commandCount", "mutationAttempts"):
            require(type(point.get(key)) is int and point[key] == 0, "checkpoint." + key)
        assertions = point.get("assertions")
        require(isinstance(assertions, list) and bool(assertions)
                and all(isinstance(item, dict) and item.get("passed") is True for item in assertions),
                "checkpoint assertions")
        require(required_assertions(point["name"], scenario["mode"] == "signed-out")
                .issubset({item.get("name") for item in assertions}), "complete rendered/safety assertions")
        require(point.get("keyWindow") is (point["name"] != "shell.inactive"), "checkpoint key-window state")
        require(point.get("appActive") is True, "checkpoint application active state")
        require(type(point.get("windowNumber")) is int and point["windowNumber"] > 0, "checkpoint window identity")
        require(number(point.get("capturePointPixelScale"), positive=True), "capture point-pixel scale")
        for key in ("captureContentRect", "requestedBodySize"):
            rect = point.get(key)
            require(isinstance(rect, dict) and number(rect.get("width"), positive=True)
                    and number(rect.get("height"), positive=True), "checkpoint." + key)
        samples = point.get("pixelSamples")
        require(isinstance(samples, list) and len(samples) == 4
                and all(isinstance(sample, dict) for sample in samples)
                and {sample.get("name") for sample in samples} == {"shell.home", "shell.search", "shell.history.back", "shell.history.forward"}, "chrome pixel samples")
        for sample in samples:
            require(number(sample.get("pixelCount"), positive=True, integer=True)
                    and number(sample.get("maximumRGB"), integer=True) and sample["maximumRGB"] <= 12
                    and number(sample.get("meanRGB")) and sample["meanRGB"] <= 12, "dark chrome padding pixels")
            require(type(sample.get("minimumAlpha")) is int and 250 <= sample["minimumAlpha"] <= 255,
                    "opaque chrome padding pixels")
        require(point.get("visible") is True, "GUI checkpoint visibility")
        captures = point.get("captures")
        require(isinstance(captures, list) and bool(captures), "GUI checkpoint captures")
        require(any(isinstance(capture, dict) and capture.get("source") ==
                    f"ScreenCaptureKit.currentProcess.own-window.{point['windowNumber']}" for capture in captures),
                "required own-window compositor capture")
        composite_dimensions = None
        for capture in captures:
            require(isinstance(capture, dict) and isinstance(capture.get("file"), str), "capture identity")
            path = (run_root / capture["file"]).resolve()
            require(path.is_relative_to((run_root / "shell-captures").resolve()) and path.is_file(), "owned GUI capture")
            require(type(capture.get("byteCount")) is int and capture["byteCount"] == path.stat().st_size
                    and capture.get("sha256") == browsing_provenance.sha256_file(path), "capture bytes digest")
            require(type(capture.get("pixelWidth")) is int and capture["pixelWidth"] > 0
                    and type(capture.get("pixelHeight")) is int and capture["pixelHeight"] > 0, "capture dimensions")
            dimensions = png_dimensions(path)
            require(dimensions == (capture["pixelWidth"], capture["pixelHeight"]), "PNG declared dimensions")
            if capture.get("source") == f"ScreenCaptureKit.currentProcess.own-window.{point['windowNumber']}":
                composite_dimensions = dimensions
        frame = point.get("windowFrame")
        require(isinstance(frame, dict) and number(frame.get("width"), positive=True)
                and number(frame.get("height"), positive=True)
                and number(point.get("backingScale"), positive=True), "compositor window geometry")
        require(all(abs(observed - frame[axis] * point["backingScale"]) <= 1
                    for observed, axis in zip(composite_dimensions, ("width", "height"))),
                "compositor pixel/window dimensions")
        for sample in samples:
            rect = sample.get("pixelRect")
            require(isinstance(rect, dict) and all(number(rect.get(axis)) and float(rect[axis]).is_integer()
                    for axis in ("x", "y", "width", "height"))
                    and rect["width"] > 0 and rect["height"] > 0, "pixel sample integer region")
            require(rect["x"] + rect["width"] <= composite_dimensions[0]
                    and rect["y"] + rect["height"] <= composite_dimensions[1]
                    and sample["pixelCount"] == rect["width"] * rect["height"], "pixel sample bounds/count")
    minimum = next(sizes[name] for name in sizes if name.endswith(".minimum"))
    resized = sizes["shell.resized"]
    require(minimum == {"width": 960, "height": 640}, "exact minimum fixture size")
    require(any(resized[axis] - minimum[axis] > 2 for axis in ("width", "height")),
            "resized fixture exercises a distinct size change")
    actual_minimum = next(point for point in checkpoints if point["name"].endswith(".minimum"))
    actual_resized = next(point for point in checkpoints if point["name"] == "shell.resized")
    require(actual_resized["contentBounds"]["width"] - actual_minimum["contentBounds"]["width"] > 2
            or actual_resized["contentLayoutRect"]["height"] - actual_minimum["contentLayoutRect"]["height"] > 2,
            "observed body exercises a distinct size change")
    require(all(point["screenVisibleFrame"] == checkpoints[0]["screenVisibleFrame"] for point in checkpoints),
            "fixture display remains stable")
    status = read_json(run_root / "run-status.json")
    require(status.get("runID") == manifest["runID"] and status.get("pid") == owned["pid"], "status process identity")
    require(status.get("state") == "workload-finished" and status.get("failureCode") is None, "status completion")
    require(status.get("syntheticDependencies") is True and status.get("engineUsedForPlayback") is False
            and status.get("networkSandboxVerified") is False, "status synthetic isolation")
    require(type(status.get("commandCount")) is int and status["commandCount"] == 0
            and type(status.get("mutationAttempts")) is int and status["mutationAttempts"] == 0, "status safety")
    return {"runID": manifest["runID"], "host": HOST_ID, "checkpointCount": len(checkpoints), "passed": True}


def run_host(root, run_root, executable, manifest, fixture, expected_names, deadline):
    """Launch once with LaunchServices, discover exact app ownership, and retain every outcome."""
    require(not any((run_root / name).exists() for name in ("report.json", "shell-regression.json", "process.json")),
            "fresh GUI run directory")
    owned = None
    process = None
    outcome = {"passed": False, "runID": manifest["runID"], "limit": LIMIT}
    problem = None
    run_deadline = min(deadline, time.monotonic() + RUN_TIMEOUT_SECONDS)
    try:
        with (run_root / "host.log").open("ab") as log:
            app = executable.parent.parent.parent
            process = subprocess.Popen(["/usr/bin/open", "-W", "-n",
                                        "--stdout", str(run_root / "runtime.stdout.log"),
                                        "--stderr", str(run_root / "runtime.stderr.log"), str(app)],
                                       cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            outcome["openWrapperPID"] = process.pid
            owned = browsing_process.discover(executable, timeout=min(10, remaining(run_deadline)))
            outcome["ownedAppPID"] = owned["pid"]
            browsing_process.write_record(run_root, owned)
            while not (run_root / "report.json").exists():
                if not browsing_process.matches(owned):
                    raise RuntimeError("The owned GUI test host exited without a report")
                if time.monotonic() >= run_deadline:
                    raise TimeoutError("GUI test host did not finish within its 90-second deadline; GUI may be unavailable")
                time.sleep(min(0.1, max(0, run_deadline - time.monotonic())))
            completed = read_json(run_root / "report.json")
            if completed.get("passed") is not True or completed.get("failure") is not None:
                raise RuntimeError("GUI workload failed: " + str(completed.get("failure") or "report did not pass"))
            # report.json precedes the final status write by one atomic write.
            while True:
                status = read_json(run_root / "run-status.json")
                if status.get("state") == "workload-finished":
                    break
                if status.get("state") == "failed" or status.get("failureCode") is not None:
                    raise RuntimeError("GUI workload status failed: " + str(status.get("failureCode") or "failed"))
                if not browsing_process.matches(owned):
                    raise RuntimeError("The owned GUI test host exited before publishing final status")
                if time.monotonic() >= run_deadline:
                    raise TimeoutError("GUI test host did not publish final status before its deadline")
                time.sleep(0.05)
            outcome.update(validate_reports(run_root, manifest, fixture, owned, expected_names))
    except EVIDENCE_ERRORS as error:
        problem = error
        outcome["failure"] = str(error)
    finally:
        try:
            if owned is not None:
                browsing_process.terminate(owned)
                outcome["cleanup"] = "owned app retired"
            else:
                outcome["cleanup"] = "no verified app identity; no app process signaled"
                if process is not None:
                    outcome["appRetirementUnverified"] = True
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            outcome["passed"] = False
            outcome["cleanupFailure"] = str(error)
            problem = problem or error
        try:
            if process is not None:
                try:
                    outcome["openWrapperExitCode"] = process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    retirement = retire_command(process)
                    if not retirement["verified"]:
                        raise RuntimeError("Owned wrapper retirement unverified: " + json.dumps(retirement))
                outcome["openWrapperCleanup"] = "owned wrapper reaped"
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            outcome["passed"] = False
            outcome["openWrapperCleanupFailure"] = str(error)
            problem = problem or error
        outcome["artifacts"] = [name for name in ("report.json", "shell-regression.json", "run-status.json",
                                                  "manifest.json", "process.json", "host.log", "runtime.stdout.log",
                                                  "runtime.stderr.log", "shell-captures")
                                if (run_root / name).exists()]
        write_json(run_root / "gui-evidence.json", outcome)
    if problem:
        raise problem
    return outcome


def execute(root, output, expected_head=None):
    # Creating the output itself is the single-attempt lock; never reuse prior success.
    output.mkdir(parents=True, exist_ok=False)
    # Reserve fifteen seconds for bounded app/wrapper retirement and final evidence.
    deadline = time.monotonic() + TOTAL_TIMEOUT_SECONDS - 15
    summary = {"schemaVersion": 1, "passed": False, "runs": [], "limit": LIMIT}
    snapshot = None
    problem = None
    try:
        snapshot = metadata(root, deadline, "snapshot")
        summary["source"] = snapshot["source"]
        stable_source(root, snapshot["source"], expected_head, deadline=deadline)
        write_json(output / "build-start.json", snapshot)
        binary_dir = build(root, output, deadline)
        require(metadata(root, deadline, "snapshot") == snapshot, "source/compiler/SDK/engine changed during build")
        for name, expected_names in FIXTURES.items():
            remaining(deadline)
            stable_source(root, snapshot["source"], expected_head, deadline=deadline)
            run_root = output / (name + "-" + str(uuid.uuid4()))
            run_root.mkdir()
            summary["runs"].append({"fixture": name, "directory": run_root.name, "passed": False})
            fixture = root / "Tests/BrowsingHarness/Scenarios" / (name + ".json")
            executable, manifest = assemble(root, run_root, binary_dir, fixture, snapshot, deadline)
            outcome = run_host(root, run_root, executable, manifest, fixture, expected_names, deadline)
            summary["runs"][-1].update(outcome)
            stable_source(root, snapshot["source"], expected_head, deadline=deadline)
        remaining(deadline)
        summary["passed"] = True
    except EVIDENCE_ERRORS as error:
        problem = error
        summary["failure"] = str(error)
        if getattr(error, "cleanupFailure", None):
            summary["cleanupFailure"] = error.cleanupFailure
    finally:
        if snapshot is not None:
            try:
                summary["sourceAtEnd"] = stable_source(root, snapshot["source"], expected_head, deadline=deadline)
                summary["sourceStable"] = True
            except EVIDENCE_ERRORS as error:
                summary["sourceStable"] = False
                summary["passed"] = False
                summary["trailingFailure"] = str(error)
                if getattr(error, "cleanupFailure", None):
                    summary["trailingCleanupFailure"] = error.cleanupFailure
                problem = problem or error
        write_json(output / "summary.json", summary)
        if problem:
            (output / "failure.log").write_text(str(problem) + "\n")
    return 0 if summary["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new, unused evidence directory")
    parser.add_argument("--expected-head", help="exact checkout revision required by CI")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        code = execute(root, args.output.resolve(), args.expected_head)
    except (OSError, ValueError) as error:
        parser.exit(1, f"GUI regression: {error}\n")
    print(f"GUI regression {'passed' if code == 0 else 'failed'}: {args.output.resolve() / 'summary.json'}")
    return code


if __name__ == "__main__":
    sys.exit(main())
