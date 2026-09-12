#!/bin/zsh
set -euo pipefail

# One non-shipping entry point for the existing deterministic behavior corpus and real XPC tests.
# Like check.sh, owner tests use Debug because they import their implementation with @testable.
project_root="${0:A:h:h}"
if (( $# != 0 )); then
    print -u2 "Usage: $0 (optional SPOTTY_CHECK_REPEATS=1..25)"
    exit 2
fi
source "$project_root/Scripts/swiftpm-env.sh"

# Python handles structured evidence and xUnit parsing, never source rewriting or test selection.
python3 -B - "$project_root" "${spotty_swiftc_warnings_as_errors[@]}" <<'PY'
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
repeats_text = os.environ.get("SPOTTY_CHECK_REPEATS", "1")
if not re.fullmatch(r"[1-9][0-9]*", repeats_text) or int(repeats_text) > 25:
    sys.exit("SPOTTY_CHECK_REPEATS must be between 1 and 25")
repeats = int(repeats_text)
targets = ["SpottyDomainTests", "SpottyBoundaryTests", "SpottySessionRuntimeTests",
           "SpottyGatewayTests", "SpottyCatalogStorageTests", "SpottySessionTransportTests"]
test_filter = "^(" + "|".join(targets) + ")[./]"


def output(*arguments):
    return subprocess.check_output(arguments, cwd=root, text=True).strip()


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def source_identity():
    # Only repository source inputs: no app containers, ignored build products, environment dumps,
    # or file contents enter evidence. Include untracked implementation and deleted tracked files.
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).split(b"\0")
    roots = {"Sources", "Tests", "Scripts", "script", "Backend", "Packaging", ".github"}
    suffixes = {".swift", ".rs", ".toml", ".lock", ".json", ".yml", ".yaml", ".sh",
                ".py", ".rb", ".h", ".c", ".modulemap", ".plist", ".entitlements", ".sql"}
    digest = hashlib.sha256()
    count = 0
    for raw_name in sorted(set(names)):
        if not raw_name:
            continue
        name = os.fsdecode(raw_name)
        relative = Path(name)
        if name not in {"Package.swift", "Package.resolved"} and not (
            relative.parts[0] in roots and relative.suffix in suffixes
        ):
            continue
        path = root / relative
        # Never follow a symlink out of a source tree, including a replaced ancestor directory.
        for index in range(1, len(relative.parts) + 1):
            component = root.joinpath(*relative.parts[:index])
            if component.is_symlink():
                raise ValueError("Source identity cannot attest symlinked source inputs")
        if not path.exists():
            content = b"deleted"
        elif not stat.S_ISREG(path.stat().st_mode):
            raise ValueError("Source identity cannot attest nonregular source inputs")
        else:
            content = b"file\0" + hashlib.sha256(path.read_bytes()).digest()
        digest.update(raw_name + b"\0" + content + b"\0")
        count += 1
    return {"head": output("git", "rev-parse", "HEAD"), "contentSHA256": digest.hexdigest(),
            "fileCount": count, "scope": "tracked and unignored untracked source/configuration inputs"}


def engine_identity():
    manifest = (root / "Package.swift").read_text()
    pin = {}
    for label, variable in [("url", "generatedPlaybackArtifactURL"),
                            ("checksum", "generatedPlaybackArtifactChecksum")]:
        matches = re.findall(r"private\s+let\s+" + variable + r'\s*=\s*"([^"]+)"', manifest)
        if len(matches) != 1:
            raise ValueError("Expected one playback " + label + " pin")
        pin[label] = matches[0]
    result = {"packagePin": pin, "selection": "pinned-remote"}
    override = os.environ.get("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK")
    if override:
        path = Path(override)
        if not path.is_absolute():
            path = root / path
        provenance = (path / "spotty_playback_provenance.json").read_bytes()
        parsed = json.loads(provenance)
        result = {"packagePin": pin, "selection": "explicit-local-override",
                  "provenanceSHA256": hashlib.sha256(provenance).hexdigest()}
        for label, value in [("engineInputDigest", parsed.get("source", {}).get("engineInputDigest")),
                             ("librarySHA256", parsed.get("librarySHA256"))]:
            if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", value):
                raise ValueError("Missing valid engine provenance " + label)
            result[label] = value
        info = plistlib.loads((path / "Info.plist").read_bytes())
        libraries = [item for item in info["AvailableLibraries"] if item["LibraryIdentifier"] == "macos-arm64"]
        if (len(libraries) != 1 or libraries[0]["LibraryPath"] in {"", ".", ".."}
                or Path(libraries[0]["LibraryPath"]).name != libraries[0]["LibraryPath"]):
            raise ValueError("Expected one bounded macos-arm64 playback archive path")
        archive_digest = hashlib.sha256()
        with (path / "macos-arm64" / libraries[0]["LibraryPath"]).open("rb") as archive:
            for block in iter(lambda: archive.read(1024 * 1024), b""):
                archive_digest.update(block)
        result["actualLibrarySHA256"] = archive_digest.hexdigest()
        result["provenanceMatchesArchive"] = result["actualLibrarySHA256"] == result["librarySHA256"].lower()
    return result


def suite_names():
    # xUnit may use either Swift type names or @Suite display names across toolchain versions.
    result = {}
    for target in targets:
        names = set()
        for path in sorted((root / "Tests" / target).rglob("*.swift")):
            source = path.read_text()
            declarations = list(re.finditer(
                r"^(?:(?:final|private|fileprivate|internal|public|package)\s+)*(?:struct|class)\s+(\w+)",
                source, re.M))
            for index, declaration in enumerate(declarations):
                end = declarations[index + 1].start() if index + 1 < len(declarations) else len(source)
                if re.search(r"^\s*@Test\b", source[declaration.end():end], re.M):
                    names.add(declaration.group(1))
            names.update(re.findall(r'@Suite\(\s*"([^"\n]+)"', source))
        result[target] = sorted(names)
    return result


def generated_traces():
    source = "Tests/SpottyDomainTests/PlaybackReducerModelChecks.swift"
    matches = re.findall(
        r"for seed in UInt64\(([\d_]+)\)\.\.\.UInt64\(([\d_]+)\)\s*\{\s*"
        r"if let violation = runModelTrace\(seed: seed, steps: (\d+), commandHeavy: (true|false)\)",
        (root / source).read_text())
    return [{"source": source, "seedRangeInclusive": [int(first.replace("_", "")),
                                                       int(last.replace("_", ""))],
             "stepsPerSeed": int(steps), "commandHeavy": heavy == "true"}
            for first, last, steps, heavy in matches]


def test_results(paths, names):
    def owners(case):
        suite, name = case.get("classname", ""), case.get("name", "")
        qualified = [target for target in targets if any(
            value == target or value.startswith((target + ".", target + "/"))
            for value in [suite, name])]
        return qualified or [target for target, aliases in names.items() if suite in aliases]

    documents = [(path.name, ET.parse(path)) for path in paths]
    summary_issues = set()
    for _, document in documents:
        for suite in [*document.iter("testsuite"), *document.iter("testsuites")]:
            for field in ["failures", "errors", "skipped"]:
                value = suite.get(field)
                if value is not None:
                    if not re.fullmatch(r"[0-9]+", value):
                        raise ValueError("Invalid xUnit suite summary " + field)
                    if int(value) > 0:
                        summary_issues.add(field)
    cases = []
    xml_cases = [(filename, case) for filename, document in documents for case in document.iter("testcase")]
    for filename, case in xml_cases:
        status = "passed"
        if case.find("failure") is not None or case.find("error") is not None:
            status = "failed"
        elif case.find("skipped") is not None:
            status = "skipped"
        matches = owners(case)
        cases.append({"suite": case.get("classname", ""), "name": case.get("name", ""),
                      "outcome": status, "durationSeconds": case.get("time"), "xunit": filename,
                      "targets": matches if len(matches) == 1 else [],
                      "ambiguousTargets": matches if len(matches) > 1 else []})
    observed = {target for case in cases for target in case["targets"]}
    return {"counts": {status: sum(case["outcome"] == status for case in cases)
                       for status in ["passed", "failed", "skipped"]},
            "missingTargets": sorted(set(targets) - observed),
            "suiteSummaryIssues": sorted(summary_issues),
            "ambiguousTests": sum(bool(case["ambiguousTargets"]) for case in cases), "tests": cases}


def lifecycle_results(path):
    report = json.loads(path.read_text())

    def nonnegative_number(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0

    if (not isinstance(report, dict) or type(report.get("version")) is not int
            or report["version"] != 1 or not nonnegative_number(report.get("deadlineMilliseconds"))
            or report["deadlineMilliseconds"] == 0):
        raise ValueError("Invalid lifecycle report version or deadline")
    samples = report.get("samples")
    if not isinstance(samples, list) or not samples or any(
        not isinstance(sample, dict) or any(not nonnegative_number(sample.get(field)) for field in
            ["cooperativeMilliseconds", "fencedNoncancelableMilliseconds"])
        for sample in samples
    ):
        raise ValueError("Lifecycle report requires complete finite drain samples")
    return {"version": report["version"], "sampleCount": len(samples),
            "deadlineMilliseconds": report["deadlineMilliseconds"]}


run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
directory = root / ".build" / "session-scenarios" / run_id
directory.mkdir(parents=True)
evidence_path = directory / "evidence.json"
evidence = {"schemaVersion": 1, "runID": run_id, "startedAt": now(), "finishedAt": None,
            "environment": {"os": platform.system(), "osVersion": platform.mac_ver()[0],
                            "architecture": platform.machine(),
                            # SwiftPM may use a different SDK even with an explicit --sdk request.
                            "requestedSDK": Path(os.environ["SDKROOT"]).name,
                            "sdkSelection": "explicit-swiftpm-request", "compilerSDK": "unverified",
                            "configuration": "debug",
                            "parallel": False, "warningsAsErrors": True},
            "expected": {"targets": targets, "filter": test_filter, "repetitions": repeats,
                         "outcome": "Every selected test passes; no missing targets or skipped tests",
                         "generatedTraces": []},
            "isolation": ["Non-shipping test targets with synthetic dependencies and temporary test storage.",
                          "Real NSXPC transport uses anonymous test endpoints, never a named live service.",
                          "No app launch or live account mutation is requested by this runner.",
                          "This is not packaged-helper, live playback, audio, or UI performance evidence."],
            "runs": [], "outcome": "running"}


def save():
    evidence_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")


save()
exit_code = 0
try:
    evidence["sourceBefore"] = source_identity()
    evidence["engine"] = engine_identity()
    evidence["environment"]["swift"] = output("swift", "--version")
    evidence["expected"]["generatedTraces"] = generated_traces()
    names = suite_names()
    save()
    for number in range(1, repeats + 1):
        xml = directory / ("tests-" + str(number) + ".xml")
        log = directory / ("tests-" + str(number) + ".log")
        lifecycle = directory / ("lifecycle-" + str(number) + ".json")
        test_environment = dict(os.environ, SPOTTY_SWIFT_LIFECYCLE_REPORT=str(lifecycle))
        command = ["swift", "test", "--disable-sandbox", "--no-parallel", "--package-path", str(root),
                   "--sdk", os.environ["SDKROOT"], "--configuration", "debug", "--filter", test_filter,
                   "--xunit-output", str(xml),
                   *sys.argv[2:]]
        record = {"repetition": number, "startedAt": now(), "xunit": xml.name, "log": log.name,
                  "lifecycleReport": lifecycle.name}
        evidence["runs"].append(record)
        save()
        with log.open("w") as transcript:
            process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, env=test_environment)
            try:
                for line in process.stdout:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    transcript.write(line)
                record["exitCode"] = process.wait()
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait()
        record["finishedAt"] = now()
        # SwiftPM preserves XCTest output at the requested path and uses a sibling for Swift
        # Testing. Older toolchains may put all results at the requested path. Inspect both so
        # neither framework's failures disappear and future XCTest additions remain covered.
        swift_testing_xml = xml.with_name(xml.stem + "-swift-testing" + xml.suffix)
        xml_paths = [path for path in [xml, swift_testing_xml] if path.is_file()]
        record["xunitFiles"] = [path.name for path in xml_paths]
        if xml_paths:
            record["observed"] = test_results(xml_paths, names)
        else:
            record["observed"] = {"error": "SwiftPM did not produce xUnit evidence"}
        observed = record["observed"]
        record["lifecycleReportPresent"] = lifecycle.is_file()
        if record["lifecycleReportPresent"]:
            record["lifecycle"] = lifecycle_results(lifecycle)
        passed = (record["exitCode"] == 0 and "counts" in observed
                  and observed["counts"]["passed"] > 0 and observed["counts"]["failed"] == 0
                  and observed["counts"]["skipped"] == 0 and not observed["missingTargets"]
                  and observed["ambiguousTests"] == 0
                  and not observed["suiteSummaryIssues"]
                  and record["lifecycleReportPresent"])
        record["outcome"] = "passed" if passed else "failed"
        if not passed:
            exit_code = 1
        save()
except (Exception, KeyboardInterrupt) as error:
    evidence["runnerError"] = type(error).__name__ + ": " + str(error)
    if evidence["runs"] and "outcome" not in evidence["runs"][-1]:
        evidence["runs"][-1]["outcome"] = "failed"
        evidence["runs"][-1]["finishedAt"] = now()
    exit_code = 1
finally:
    try:
        evidence["sourceAfter"] = source_identity()
        evidence["sourceUnchanged"] = evidence.get("sourceBefore") == evidence["sourceAfter"]
        evidence["engineAfter"] = engine_identity()
        evidence["engineUnchanged"] = evidence.get("engine") == evidence["engineAfter"]
        if (not evidence["sourceUnchanged"] or not evidence["engineUnchanged"]
                or evidence.get("engine", {}).get("provenanceMatchesArchive") is False):
            exit_code = 1
    except Exception as error:
        evidence["identityError"] = type(error).__name__ + ": " + str(error)
        exit_code = 1
    evidence["finishedAt"] = now()
    evidence["outcome"] = "passed" if exit_code == 0 else "failed"
    save()
    print("Session scenario evidence: " + str(evidence_path), flush=True)
sys.exit(exit_code)
PY
