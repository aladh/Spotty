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
    "gui-shell": ("home.default", "home.minimum", "shell.inactive", "shell.resized", "inspector.resized",
                  "inspector.minimum", "inspector.default", "inspector.closed", "search.all",
                  "search.albums", "detail.playlist", "search.returned"),
    "gui-signed-out": ("signed-out.default", "signed-out.minimum", "shell.inactive", "shell.resized",
                       "inspector.resized", "inspector.minimum", "inspector.default", "inspector.closed"),
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
    names.update(("toolbar.history-controls-disjoint", "toolbar.group-centered", "toolbar.home-size",
                  "toolbar.search-width", "toolbar.control-alignment", "toolbar.history-alignment",
                  "toolbar.row-height", "toolbar.control-margins",
                  "toolbar.shortcut-search", "toolbar.hit-target-search", "toolbar.hit-target-home", "toolbar.hit-target-back", "toolbar.hit-target-forward",
                  "toolbar.shortcut-search-already-focused",
                  "shell.home.glyph.aligned", "shell.search.glyph.aligned", "toolbar.search-field-inset",
                  "inspector.presentation"))
    if name.startswith("inspector.") and name != "inspector.closed":
        names.add("inspector.excludes-catalog")
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


def rectangle(value, label, *, allow_empty=False):
    require(isinstance(value, dict) and all(type(value.get(axis)) in (int, float)
            and math.isfinite(value[axis]) for axis in ("x", "y", "width", "height"))
            and (value["width"] > 0 and value["height"] > 0
                 or allow_empty and value["width"] == 0 and value["height"] == 0), label)
    return value


def contains(outer, inner, tolerance=2):
    return (inner["x"] >= outer["x"] - tolerance and inner["y"] >= outer["y"] - tolerance
            and inner["x"] + inner["width"] <= outer["x"] + outer["width"] + tolerance
            and inner["y"] + inner["height"] <= outer["y"] + outer["height"] + tolerance)


def intersects(first, second):
    return (first["x"] < second["x"] + second["width"]
            and second["x"] < first["x"] + first["width"]
            and first["y"] < second["y"] + second["height"]
            and second["y"] < first["y"] + first["height"])


def validate_product_geometry(point):
    """Recompute geometry from rendered markers, independently of native assertion flags."""
    content = rectangle(point.get("contentBounds"), "actual content rectangle")
    layout = rectangle(point.get("contentLayoutRect"), "actual content layout rectangle")
    markers = point.get("markers")
    required = {"shell." + name for name in
                ("sidebar", "catalog", "player", "navigation", "home", "search", "home.glyph", "search.glyph",
                 "search.field", "history.back", "history.forward")}
    if point["name"].startswith("search."):
        required.add("search.filters")
    if point["name"] == "detail.playlist":
        required.add("detail.native-scroll")
    expects_inspector = point["name"].startswith("inspector.") and point["name"] != "inspector.closed"
    if expects_inspector:
        required.add("shell.inspector")
    require(isinstance(markers, dict) and required.issubset(markers), "complete product geometry markers")
    for name, value in markers.items():
        require(isinstance(name, str), "product marker identity")
        rect = rectangle(value, "product marker rectangle: " + name,
                         allow_empty=name == "shell.inspector" and not expects_inspector)
        require(contains(content, rect), "product marker contained by content: " + name)
    inspector = markers.get("shell.inspector")
    require(expects_inspector == (inspector is not None and inspector["width"] > 0),
            "independent inspector presentation")
    sidebar, catalog, player, navigation, home, search, back, forward = (
        markers["shell." + name] for name in
        ("sidebar", "catalog", "player", "navigation", "home", "search", "history.back", "history.forward"))
    require(178 <= sidebar["width"] <= 262, "independent sidebar width")
    require(sidebar["x"] + sidebar["width"] <= catalog["x"] + 2, "independent catalog excludes sidebar")
    require(player["y"] + player["height"] <= catalog["y"] + 2, "independent player excludes catalog")
    require(catalog["y"] + catalog["height"] <= navigation["y"] + 2, "independent toolbar excludes catalog")
    require(player["height"] >= 70, "independent player height")
    require(all(abs(home[axis] - 48) <= 2 for axis in ("width", "height")), "independent Home size")
    row_height = content["y"] + content["height"] - layout["y"] - layout["height"]
    require(abs(row_height - 64) <= 2, "independent toolbar row height")
    require(all(abs(content["y"] + content["height"] - control["y"] - control["height"] - 8) <= 2
                and abs(control["y"] - layout["y"] - layout["height"] - 8) <= 2
                for control in (home, search)), "independent toolbar vertical control margins")
    expected_search_width = min(474, max(0, content["width"] / 2 - 72))
    require(abs(search["width"] - expected_search_width) <= 2 and abs(search["height"] - 48) <= 2,
            "independent Search size")
    require(not intersects(home, search), "independent Home/Search disjointness")
    require(abs(search["x"] - home["x"] - home["width"] - 8) <= 2
            and abs(home["y"] + home["height"] / 2 - search["y"] - search["height"] / 2) <= 2,
            "independent Home/Search alignment and gap")
    group_min = min(home["x"], search["x"])
    group_max = max(home["x"] + home["width"], search["x"] + search["width"])
    content_center = content["x"] + content["width"] / 2
    require(abs((group_min + group_max) / 2 - content_center) <= 2,
            "independent Home/Search group centered across full content")
    require(contains(navigation, home) and contains(navigation, search)
            and abs(navigation["x"] + navigation["width"] / 2 - content_center) <= 2,
            "independent navigation contains centered controls")
    for name, control in (("shell.home.glyph", home), ("shell.search.glyph", search)):
        glyph = markers[name]
        require(all(abs(glyph[axis] - 24) <= 2 for axis in ("width", "height"))
                and contains(control, glyph, tolerance=0)
                and abs(glyph["y"] + glyph["height"] / 2 - control["y"] - control["height"] / 2) <= 2,
                "independent glyph size and vertical alignment: " + name)
        require(abs(glyph["x"] + glyph["width"] / 2 - home["x"] - home["width"] / 2) <= 2
                if name == "shell.home.glyph" else abs(glyph["x"] - search["x"] - 12) <= 2,
                "independent glyph horizontal alignment: " + name)
    field = markers["shell.search.field"]
    require(contains(search, field, tolerance=0) and abs(field["x"] - search["x"] - 48) <= 2,
            "independent search field containment and inset")
    require(all(abs(rect[axis] - 32) <= 2 for rect in (back, forward) for axis in ("width", "height")),
            "independent history hitbox size")
    require(abs(forward["x"] + forward["width"] / 2 - back["x"] - back["width"] / 2 - 34) <= 2
            and abs(back["y"] + back["height"] / 2 - forward["y"] - forward["height"] / 2) <= 2
            and abs(back["y"] + back["height"] / 2 - home["y"] - home["height"] / 2) <= 2,
            "independent history control alignment")
    require(not intersects(back, forward) and not intersects(back, navigation) and not intersects(forward, navigation),
            "independent history controls disjointness")
    if expects_inspector:
        # RootView marks SidePanel before its 8pt outer padding; accept either measured extent.
        require(250 <= inspector["width"] <= 362, "independent inspector width")
        require(catalog["x"] + catalog["width"] <= inspector["x"] + 2,
                "independent inspector excludes catalog")
    for name in ("search.filters", "detail.native-scroll"):
        if name in required:
            require(contains(catalog, markers[name]), "independent catalog contains " + name)


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



def hosted_display_environment():
    require(all(os.environ.get(key) == value for key, value in
                (("GITHUB_ACTIONS", "true"), ("CI", "true"), ("RUNNER_ENVIRONMENT", "github-hosted"),
                 ("RUNNER_OS", "macOS"))), "Display qualification requires GitHub-hosted macOS CI")


def compile_display_guardian(root, output, deadline):
    executable = root / ".build/gui-display-guardian"
    bounded_command(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
                     "-sdk", os.environ["SDKROOT"], str(root / "Scripts/gui_display_guardian.swift"),
                     "-o", str(executable)], root, output / "hosted-display.log", deadline)
    return executable


def validate_display_qualification(report, pid):
    require(report.get("schemaVersion") == 1 and report.get("ownerPID") == pid and report.get("phase") == "ready",
            "owned display guardian readiness")
    require(type(report.get("displayID")) is int and report["displayID"] > 0, "qualified display identity")
    modes = report.get("availableModes")
    require(isinstance(modes, list) and bool(modes), "advertised display modes")
    for mode in [report.get("originalMode"), report.get("selectedMode"), report.get("observedMode"), *modes]:
        require(isinstance(mode, dict) and type(mode.get("id")) is int
                and all(number(mode.get(key), positive=True, integer=True)
                        for key in ("width", "height", "pixelWidth", "pixelHeight"))
                and type(mode.get("desktopUsable")) is bool and number(mode.get("refreshRate")),
                "display mode shape")
    selected = report["selectedMode"]
    require(selected in modes and selected["desktopUsable"] is True
            and selected["width"] >= 1280 and selected["height"] >= 900, "advertised eligible logical display mode")
    require(report["observedMode"] == selected, "observed selected display mode")
    for key in ("beforeScreens", "afterScreens"):
        screens = report.get(key)
        require(isinstance(screens, list) and bool(screens), "display screen geometry")
        for screen in screens:
            require(isinstance(screen, dict) and type(screen.get("displayID")) is int
                    and number(screen.get("backingScale"), positive=True), "screen identity/scale")
            rectangle(screen.get("frame"), "screen frame")
            rectangle(screen.get("visibleFrame"), "visible screen frame")
    screen = next((item for item in report["afterScreens"] if item["displayID"] == report["displayID"]), None)
    require(screen is not None and abs(screen["frame"]["width"] - selected["width"]) <= 1
            and abs(screen["frame"]["height"] - selected["height"]) <= 1
            and screen["visibleFrame"]["width"] >= 1080 and screen["visibleFrame"]["height"] >= 752,
            "qualified mode/AppKit visible capacity")
    return {"passed": True, "guardianPID": pid, "artifact": "hosted-display.json"}


def ensure_display_guardian(process):
    if process is not None and process.poll() is not None:
        raise RuntimeError("The owned display guardian exited before fixture completion")



def inspect_original_display(root, output, executable, report):
    require(isinstance(report.get("originalMode"), dict) and bool(report["originalMode"])
            and isinstance(report.get("beforeScreens"), list) and bool(report["beforeScreens"]),
            "original display state available for restoration attestation")
    # App-lifetime mode selection reverts to the permanent configuration on owner exit.
    # Reinspect afterward: a previously volatile initial mode must not claim exact restoration.
    post_path = output / "hosted-display-restored.json"
    bounded_command([str(executable), "--inspect", str(post_path)], root, output / "hosted-display.log",
                    time.monotonic() + 5)
    post = read_json(post_path)
    require(post.get("phase") == "inspected" and post.get("displayID") == report.get("displayID")
            and post.get("originalMode") == report.get("originalMode"), "post-exit original display restoration")

    def screen_state(screens):
        require(isinstance(screens, list) and bool(screens), "post-exit screen geometry")
        identities, work_areas = {}, {}
        for screen in screens:
            require(isinstance(screen, dict) and type(screen.get("displayID")) is int and screen["displayID"] > 0
                    and screen["displayID"] not in identities and number(screen.get("backingScale"), positive=True),
                    "post-exit screen identity/scale")
            frame = rectangle(screen.get("frame"), "post-exit screen frame")
            visible = rectangle(screen.get("visibleFrame"), "post-exit visible screen frame")
            require(visible["x"] >= frame["x"] - 1 and visible["y"] >= frame["y"] - 1
                    and visible["x"] + visible["width"] <= frame["x"] + frame["width"] + 1
                    and visible["y"] + visible["height"] <= frame["y"] + frame["height"] + 1,
                    "post-exit visible area contained by screen")
            identities[screen["displayID"]] = {"frame": frame, "backingScale": screen["backingScale"]}
            work_areas[screen["displayID"]] = visible
        return identities, [{"displayID": identifier, "visibleFrame": work_areas[identifier]}
                            for identifier in sorted(work_areas)]

    before_identity, before_work_areas = screen_state(report["beforeScreens"])
    after_identity, after_work_areas = screen_state(post.get("beforeScreens"))
    require(after_identity == before_identity, "post-exit original screen identity/frame/scale")
    # Dock/menu-bar reservations may change after launching an app. Report that observation;
    # display restoration attests the mode, screen frame and scale, without changing preferences.
    return {"verified": True, "artifact": "hosted-display.json", "postExitArtifact": post_path.name,
            "workAreaChanged": before_work_areas != after_work_areas,
            "workAreasBefore": before_work_areas, "workAreasAfter": after_work_areas}


def start_display_guardian(root, output, executable, deadline):
    hosted_display_environment()  # Refuse local/self-hosted mutation before creating a process.
    report_path = output / "hosted-display.json"
    process = None
    try:
        with (output / "hosted-display.log").open("ab") as log:
            process = subprocess.Popen([str(executable), "--guard", str(report_path)], cwd=root,
                                       stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT,
                                       text=True, start_new_session=True)
        ready_deadline = min(deadline, time.monotonic() + 15)
        while True:
            if report_path.exists():
                report = read_json(report_path)
                if report.get("phase") == "failed":
                    raise RuntimeError("Display qualification failed: " + str(report.get("failure")))
                if report.get("phase") == "ready":
                    ensure_display_guardian(process)
                    validate_display_qualification(report, process.pid)
                    return process
            ensure_display_guardian(process)
            if time.monotonic() >= ready_deadline:
                raise TimeoutError("Hosted display qualification did not finish within its deadline")
            time.sleep(0.05)
    except BaseException as primary:
        if process is not None:
            retirement = preserve_cleanup_failure(primary, process)
            if process.stdin is not None:
                try:
                    process.stdin.close()
                except OSError:
                    pass
            try:
                require(retirement["verified"], "owned display guardian exit verified before restoration inspection")
                report = read_json(report_path)
                require(report.get("ownerPID") == process.pid, "failed qualification report owner")
                primary.displayRestoration = inspect_original_display(root, output, executable, report)
                primary.displayRestoration["ownedGuardianRetirement"] = retirement
            except EVIDENCE_ERRORS as cleanup_error:
                primary.displayRestoration = {"verified": False, "failure": str(cleanup_error),
                                              "ownedGuardianRetirement": retirement, "artifact": "hosted-display.json"}
                if getattr(cleanup_error, "cleanupFailure", None):
                    primary.displayRestoration["inspectionCleanupFailure"] = cleanup_error.cleanupFailure
        raise


def restore_display_guardian(process, root, output, executable):
    report_path = output / "hosted-display.json"
    try:
        ensure_display_guardian(process)
        process.stdin.write("restore\n")
        process.stdin.flush()
        process.stdin.close()
        process.wait(timeout=5)
        report = read_json(report_path)
        require(report.get("ownerPID") == process.pid and report.get("phase") == "restored"
                and report.get("restorationAttempted") is True and report.get("restorationVerified") is True
                and report.get("restoredMode") == report.get("originalMode"), "verified original display restoration")
        return inspect_original_display(root, output, executable, report)
    except EVIDENCE_ERRORS as primary:
        retirement = preserve_cleanup_failure(primary, process)
        return {"verified": False, "failure": str(primary), "ownedGuardianRetirement": retirement,
                "artifact": "hosted-display.json"}


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
        validate_product_geometry(point)
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


def run_host(root, run_root, executable, manifest, fixture, expected_names, deadline, guardian=None):
    """Launch once with LaunchServices, discover exact app ownership, and retain every outcome."""
    require(not any((run_root / name).exists() for name in ("report.json", "shell-regression.json", "process.json")),
            "fresh GUI run directory")
    owned = None
    process = None
    outcome = {"passed": False, "runID": manifest["runID"], "limit": LIMIT}
    problem = None
    run_deadline = min(deadline, time.monotonic() + RUN_TIMEOUT_SECONDS)
    try:
        ensure_display_guardian(guardian)
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
                ensure_display_guardian(guardian)
                if not browsing_process.matches(owned):
                    raise RuntimeError("The owned GUI test host exited without a report")
                if time.monotonic() >= run_deadline:
                    raise TimeoutError("GUI test host did not finish within its 90-second deadline; GUI may be unavailable")
                time.sleep(min(0.1, max(0, run_deadline - time.monotonic())))
            ensure_display_guardian(guardian)
            completed = read_json(run_root / "report.json")
            if completed.get("passed") is not True or completed.get("failure") is not None:
                raise RuntimeError("GUI workload failed: " + str(completed.get("failure") or "report did not pass"))
            # report.json precedes the final status write by one atomic write.
            while True:
                ensure_display_guardian(guardian)
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
            ensure_display_guardian(guardian)
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


def execute(root, output, expected_head=None, qualify_hosted_display=False):
    # Creating the output itself is the single-attempt lock; never reuse prior success.
    output.mkdir(parents=True, exist_ok=False)
    # Reserve twenty-five seconds for app/wrapper/display retirement and final evidence.
    deadline = time.monotonic() + TOTAL_TIMEOUT_SECONDS - 25
    summary = {"schemaVersion": 1, "passed": False, "runs": [], "limit": LIMIT}
    snapshot = None
    problem = None
    guardian = None
    display_executable = None
    if qualify_hosted_display:
        summary["displayQualification"] = {"requested": True, "passed": False, "artifact": "hosted-display.json"}
    try:
        if qualify_hosted_display:
            hosted_display_environment()
        snapshot = metadata(root, deadline, "snapshot")
        summary["source"] = snapshot["source"]
        stable_source(root, snapshot["source"], expected_head, deadline=deadline)
        write_json(output / "build-start.json", snapshot)
        binary_dir = build(root, output, deadline)
        require(metadata(root, deadline, "snapshot") == snapshot, "source/compiler/SDK/engine changed during build")
        if qualify_hosted_display:
            display_executable = compile_display_guardian(root, output, deadline)
            guardian = start_display_guardian(root, output, display_executable, deadline)
            summary["displayQualification"].update(validate_display_qualification(
                read_json(output / "hosted-display.json"), guardian.pid))
        for name, expected_names in FIXTURES.items():
            remaining(deadline)
            ensure_display_guardian(guardian)
            stable_source(root, snapshot["source"], expected_head, deadline=deadline)
            run_root = output / (name + "-" + str(uuid.uuid4()))
            run_root.mkdir()
            summary["runs"].append({"fixture": name, "directory": run_root.name, "passed": False})
            fixture = root / "Tests/BrowsingHarness/Scenarios" / (name + ".json")
            executable, manifest = assemble(root, run_root, binary_dir, fixture, snapshot, deadline)
            outcome = run_host(root, run_root, executable, manifest, fixture, expected_names, deadline, guardian=guardian)
            summary["runs"][-1].update(outcome)
            stable_source(root, snapshot["source"], expected_head, deadline=deadline)
        remaining(deadline)
        summary["passed"] = True
    except EVIDENCE_ERRORS as error:
        problem = error
        summary["failure"] = str(error)
        if getattr(error, "cleanupFailure", None):
            summary["cleanupFailure"] = error.cleanupFailure
        if getattr(error, "displayRestoration", None):
            summary["displayRestoration"] = error.displayRestoration
            if not error.displayRestoration["verified"]:
                summary["displayRestorationFailure"] = error.displayRestoration["failure"]
    finally:
        if guardian is not None:
            restoration = restore_display_guardian(guardian, root, output, display_executable)
            summary["displayRestoration"] = restoration
            if not restoration["verified"]:
                summary["passed"] = False
                summary["displayRestorationFailure"] = restoration["failure"]
                summary.setdefault("failure", restoration["failure"])
                problem = problem or RuntimeError(restoration["failure"])
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
    parser.add_argument("--qualify-hosted-display", action="store_true",
                        help="qualify a supported logical mode on an explicit GitHub-hosted macOS CI runner")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        code = execute(root, args.output.resolve(), args.expected_head, args.qualify_hosted_display)
    except (OSError, ValueError) as error:
        parser.exit(1, f"GUI regression: {error}\n")
    print(f"GUI regression {'passed' if code == 0 else 'failed'}: {args.output.resolve() / 'summary.json'}")
    return code


if __name__ == "__main__":
    sys.exit(main())
