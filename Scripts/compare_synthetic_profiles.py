#!/usr/bin/env python3
"""Validate two completed Demo recordings before comparing their measurements."""
import argparse
import json
import math
from pathlib import Path
import re
import uuid


CADENCE_RELATIVE_TOLERANCE = 0.01
VARIANT_FIELDS = ("layout.forceSynchronousLayout",)
BUILD_FIELDS = (
    "configuration", "optimization", "testabilityEnabled", "compilerVersion",
    "requestedSDKVersion", "requestedSDKName", "linkedSDKVersion", "buildProductSHA256",
)
ENGINE_FIELDS = (
    "selection", "pinURL", "pinChecksum", "librarySHA256", "canonicalHeadersSHA256",
    "sourceRevision", "engineInputDigest", "librespotRevision", "usedForPlayback",
)
WINDOW_FIELDS = ("visible", "miniaturized", "key", "width", "height", "inspector")
DISPLAY_FIELDS = ("scale", "maximumFramesPerSecond", "reducedMotion")


class InvalidEvidence(ValueError):
    pass


def field(value, path):
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            raise InvalidEvidence(path)
        value = value[component]
    return value


def require(condition, path):
    if not condition:
        raise InvalidEvidence(path)


def number(value, positive=False, integer=False):
    try:
        return (type(value) in ((int,) if integer else (int, float))
                and math.isfinite(value) and (value > 0 if positive else value >= 0))
    except OverflowError:
        return False


def digest(value):
    return isinstance(value, str) and re.fullmatch(r"[a-fA-F0-9]{64}", value) is not None


def validate_manifest(manifest):
    require(type(field(manifest, "schemaVersion")) is int and manifest["schemaVersion"] == 1, "schemaVersion")
    try:
        uuid.UUID(field(manifest, "runID"))
    except (ValueError, AttributeError, TypeError):
        raise InvalidEvidence("runID") from None
    require(isinstance(field(manifest, "source.revision"), str) and bool(manifest["source"]["revision"]), "source.revision")
    for path in ("source.sourceSHA256", "source.diffSHA256", "fixture.sha256", "fixture.workloadSHA256"):
        require(digest(field(manifest, path)), path)
    require(field(manifest, "source.includesUntrackedNonignoredFiles") is True, "source.includesUntrackedNonignoredFiles")
    for name in BUILD_FIELDS:
        value = field(manifest, f"build.{name}")
        valid = (type(value) is bool if name == "testabilityEnabled" else
                 digest(value) if name == "buildProductSHA256" else isinstance(value, str) and bool(value))
        require(valid, f"build.{name}")
    for name in ENGINE_FIELDS:
        value = field(manifest, f"engine.{name}")
        valid = (value is False if name == "usedForPlayback" else
                 digest(value) if name.endswith(("SHA256", "Checksum", "Digest")) else
                 isinstance(value, str) and bool(value))
        require(valid, f"engine.{name}")
    require(type(field(manifest, "layout.forceSynchronousLayout")) is bool, "layout.forceSynchronousLayout")


def validate_environment(evidence):
    for name in WINDOW_FIELDS:
        value = field(evidence, f"window.{name}")
        valid = (number(value, positive=True) if name in ("width", "height") else
                 value in ("queue", "history", "connect", "closed", "unobserved") if name == "inspector" else type(value) is bool)
        require(valid, f"window.{name}")
    for name in DISPLAY_FIELDS:
        value = field(evidence, f"display.{name}")
        require(type(value) is bool if name == "reducedMotion" else number(value, positive=True), f"display.{name}")
    require(evidence["window"]["visible"] is True, "window.visible")
    require(evidence["window"]["miniaturized"] is False, "window.miniaturized")
    require(evidence["window"]["key"] is True, "window.key")


def validate_status(status, expected_state):
    require(type(field(status, "schemaVersion")) is int and status["schemaVersion"] == 1, "schemaVersion")
    require(field(status, "state") == expected_state, "state")
    # Swift omits nil optionals; Python recorder status encodes an explicit null.
    require(status.get("failureCode") is None, "failureCode")
    require(number(field(status, "pid"), positive=True, integer=True), "pid")
    require(isinstance(field(status, "runID"), str) and bool(status["runID"]), "runID")
    validate_environment(status["evidence"] if expected_state == "complete" else status)


def validate_report(report):
    require(field(report, "passed") is True and report.get("failure") is None, "passed")
    require(isinstance(field(report, "samples"), list) and bool(report["samples"]), "samples")
    validate_manifest(field(report, "launch"))
    responsiveness = field(report, "responsiveness")
    for name in ("windowVisibleAtStart", "windowVisibleAtEnd"):
        require(field(responsiveness, name) is True, f"responsiveness.{name}")
    require(type(field(responsiveness, "reducedMotion")) is bool, "responsiveness.reducedMotion")
    require(number(field(responsiveness, "displayCallbackCount"), positive=True, integer=True), "responsiveness.displayCallbackCount")
    require(number(field(responsiveness, "nominalFramesPerSecond"), positive=True), "responsiveness.nominalFramesPerSecond")
    gaps = [field(responsiveness, name) for name in
            ("callbackGapP95Milliseconds", "callbackGapP99Milliseconds", "maximumCallbackGapMilliseconds")]
    require(all(number(value, positive=True) for value in gaps) and gaps == sorted(gaps), "responsiveness.callbackGaps")
    cadence = field(responsiveness, "observedTargetFramesPerSecond")
    rates = [field(cadence, name) for name in ("minimum", "p50", "maximum")]
    require(all(number(value, positive=True) for value in rates) and rates == sorted(rates),
            "responsiveness.observedTargetFramesPerSecond")


def validate_trace(trace):
    require(number(field(trace, "workloadSeconds"), positive=True), "workloadSeconds")
    frames = field(trace, "completeApplicationFrames")
    require(number(frames, positive=True, integer=True), "completeApplicationFrames")
    require(field(trace, "completeFrameLifetimesMilliseconds.count") == frames, "completeFrameLifetimesMilliseconds.count")
    lifetimes = [field(trace, f"completeFrameLifetimesMilliseconds.{name}")
                 for name in ("minimum", "p50", "p95", "p99", "maximum")]
    require(all(number(value, positive=True) for value in lifetimes) and lifetimes == sorted(lifetimes),
            "completeFrameLifetimesMilliseconds")
    hitches = field(trace, "framesWithHitches")
    require(number(hitches, integer=True) and hitches <= frames, "framesWithHitches")
    percent = field(trace, "hitchFreeFramePercent")
    require(number(percent) and math.isclose(percent, 100 * (frames - hitches) / frames), "hitchFreeFramePercent")


def load_run(root, side):
    documents = {}
    failures = []
    validators = {
        "manifest": validate_manifest,
        "profiler-state": lambda value: validate_status(value, "complete"),
        "run-status": lambda value: validate_status(value, "workload-finished"),
        "report": validate_report,
        "trace-summary": validate_trace,
    }
    for name, validate in validators.items():
        try:
            value = json.loads((root / f"{name}.json").read_text())
        except FileNotFoundError:
            failures.append({"code": f"{side}.{name}-missing"})
            continue
        except (OSError, UnicodeError, json.JSONDecodeError):
            failures.append({"code": f"{side}.{name}-unreadable"})
            continue
        try:
            validate(value)
            documents[name] = value
        except (InvalidEvidence, KeyError, TypeError) as error:
            failures.append({"code": f"{side}.{name}-invalid", "field": str(error)})
    if failures:
        return documents, failures
    manifest, profiler, status, report = (documents[name] for name in ("manifest", "profiler-state", "run-status", "report"))
    if any(value != manifest["runID"] for value in (profiler["runID"], status["runID"], report["launch"]["runID"])):
        failures.append({"code": f"{side}.run-identity-mismatch"})
    if any(manifest[name] != report["launch"][name] for name in ("source", "build", "engine", "fixture", "layout")):
        failures.append({"code": f"{side}.report-manifest-mismatch"})
    if profiler["pid"] != status["pid"]:
        failures.append({"code": f"{side}.process-identity-mismatch"})
    for group, names in (("window", WINDOW_FIELDS), ("display", DISPLAY_FIELDS)):
        if any(profiler["evidence"][group][name] != status[group][name] for name in names):
            failures.append({"code": f"{side}.{group}-changed-during-workload"})
    responsiveness = report["responsiveness"]
    if (responsiveness["nominalFramesPerSecond"] != status["display"]["maximumFramesPerSecond"]
            or responsiveness["reducedMotion"] != status["display"]["reducedMotion"]):
        failures.append({"code": f"{side}.report-display-mismatch"})
    return documents, failures


def compare(left_root, right_root, variant_field=None):
    if variant_field not in (None, *VARIANT_FIELDS):
        raise ValueError("Unsupported variant field")
    left, left_errors = load_run(Path(left_root), "left")
    right, right_errors = load_run(Path(right_root), "right")
    errors = left_errors + right_errors
    result = {"schemaVersion": 1, "classification": "invalid" if errors else "comparable",
              "reasonCodes": [error["code"] for error in errors]}
    if errors:
        result["invalidEvidence"] = errors
        return result
    a, b = left["manifest"], right["manifest"]
    if a["runID"] == b["runID"]:
        return {"schemaVersion": 1, "classification": "invalid", "reasonCodes": ["duplicate-run-identity"]}
    result["runIDs"] = {"left": a["runID"], "right": b["runID"]}
    differences = []
    for path in ("source.revision", "source.sourceSHA256", "source.diffSHA256",
                 *(f"build.{name}" for name in BUILD_FIELDS), *(f"engine.{name}" for name in ENGINE_FIELDS),
                 "fixture.workloadSHA256", "layout.forceSynchronousLayout"):
        if field(a, path) != field(b, path) and path != variant_field:
            differences.append(path)
    variant_changed = variant_field is not None and field(a, variant_field) != field(b, variant_field)
    if a["fixture"]["sha256"] != b["fixture"]["sha256"] and not variant_changed:
        differences.append("fixture.sha256")
    for group, names in (("window", WINDOW_FIELDS), ("display", DISPLAY_FIELDS)):
        for name in names:
            if left["profiler-state"]["evidence"][group][name] != right["profiler-state"]["evidence"][group][name]:
                differences.append(f"{group}.{name}")
    cadence = {side: run["report"]["responsiveness"]["observedTargetFramesPerSecond"]
               for side, run in (("left", left), ("right", right))}
    if any(not math.isclose(cadence["left"][name], cadence["right"][name], rel_tol=CADENCE_RELATIVE_TOLERANCE)
           for name in ("minimum", "p50", "maximum")):
        differences.append("responsiveness.observedTargetFramesPerSecond")
    result["observedTargetFramesPerSecond"] = cadence
    result["cadenceRelativeTolerance"] = CADENCE_RELATIVE_TOLERANCE
    if variant_field:
        result["declaredVariant"] = {"field": variant_field, "left": field(a, variant_field), "right": field(b, variant_field)}
    if differences:
        result["classification"] = "descriptive-only"
        result["reasonCodes"] = ["comparison-conditions-differ"]
        if "responsiveness.observedTargetFramesPerSecond" in differences:
            result["reasonCodes"].append("observed-target-cadence-differs")
        result["conditionDifferences"] = differences
    if any(run["profiler-state"]["evidence"]["window"]["inspector"] == "unobserved" for run in (left, right)):
        result["classification"] = "descriptive-only"
        result["reasonCodes"].append("inspector-unobserved")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("left", type=Path, help="First completed run directory")
    parser.add_argument("right", type=Path, help="Second completed run directory")
    parser.add_argument("--variant-field", choices=VARIANT_FIELDS, help="Explicit condition intentionally varied between exact-source runs")
    parser.add_argument("--allow-descriptive", action="store_true", help="Accept reporting incompatible runs as descriptive only; never accepts invalid evidence")
    arguments = parser.parse_args(argv)
    result = compare(arguments.left, arguments.right, arguments.variant_field)
    print(json.dumps(result, indent=2, sort_keys=True))
    return (2 if result["classification"] == "invalid" else
            1 if result["classification"] == "descriptive-only" and not arguments.allow_descriptive else 0)


if __name__ == "__main__":
    raise SystemExit(main())
