"""Named synthetic acceptance, using the existing Swift Testing and Demo owners.

Representative runs are the default. Acceptance jobs explicitly request both corpora.
Every invocation has one attempt and a wall deadline; failure evidence survives a
missing report, failed test host, or timeout. This module never launches a live app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from browsing_provenance import source_identity

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = Path("Tests/BrowsingHarness/Scenarios/manifest.json")
SCHEMA_VERSION = 1
LIMITS = [
    "State assertions use injected synthetic services; no live Spotify or audible-output proof.",
    "The Swift test host does not establish Demo App Sandbox or visual/accessibility coverage.",
    "Holdouts are excluded from default runs, but their source is public, not secret.",
    "Timings are diagnostic samples, not performance budgets.",
]


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def repository_file(root, value):
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise ValueError("Manifest paths must be repository-relative files")
    path = (root / value.split("#", 1)[0]).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError("Manifest path escapes the repository or does not exist: " + value)
    return path


def manifest(root=ROOT):
    value = read_json(root / MANIFEST)
    if set(value) != {"schemaVersion", "scenarios"} or value["schemaVersion"] != SCHEMA_VERSION:
        raise ValueError("Unsupported acceptance manifest schema")
    if not isinstance(value["scenarios"], list) or not value["scenarios"]:
        raise ValueError("Manifest needs scenarios")
    seen = set()
    required = {"id", "version", "corpus", "workload", "contracts", "actions", "assertions", "safety",
                "timeoutSeconds", "terminalCondition", "evidence"}
    for item in value["scenarios"]:
        if not isinstance(item, dict) or not required <= item.keys() or item.keys() - required - {"variation"}:
            raise ValueError("Invalid scenario fields")
        identifier = item["id"]
        if not isinstance(identifier, str) or not re.fullmatch(r"[a-z][a-z0-9.-]{0,79}", identifier) or identifier in seen:
            raise ValueError("Scenario IDs must be unique stable names")
        seen.add(identifier)
        if type(item["version"]) is not int or item["version"] < 1:
            raise ValueError("Scenario version must be positive")
        if item["corpus"] not in ("representative", "holdout"):
            raise ValueError("Unknown scenario corpus")
        if type(item["timeoutSeconds"]) is not int or not 1 <= item["timeoutSeconds"] <= 600:
            raise ValueError("Scenario timeout must be bounded")
        if item["safety"] != {"dependencies": "synthetic", "liveMutations": False, "audioOutput": False}:
            raise ValueError("Acceptance requires synthetic services without live mutations or audio")
        for key in ("contracts", "actions", "assertions", "evidence"):
            if not isinstance(item[key], list) or not item[key] or not all(isinstance(x, str) and x.strip() for x in item[key]):
                raise ValueError("Scenario requires nonempty " + key)
        if set(item["evidence"]) != {"checkpoints", "timeline", "isolation"}:
            raise ValueError("Unsupported evidence requirements")
        if not isinstance(item["terminalCondition"], str) or not item["terminalCondition"].strip():
            raise ValueError("Scenario requires a terminal condition")
        for contract in item["contracts"]:
            repository_file(root, contract)
        workload = read_json(repository_file(root, item["workload"]))
        if not isinstance(workload, dict) or workload.get("mode") not in ("signed-out", "browsing", "playback"):
            raise ValueError("Scenario requires a supported workload")
        if "variation" in item and (item["corpus"] != "holdout" or item["variation"] != "stale-observation-reversed"):
            raise ValueError("Unsupported acceptance variation")
    return value


def selected_scenarios(value, corpus="representative", identifiers=None):
    items = [item for item in value["scenarios"] if corpus == "all" or item["corpus"] == corpus]
    if identifiers:
        wanted = set(identifiers)
        if wanted - {item["id"] for item in items}:
            raise ValueError("Unknown scenario ID or scenario outside the selected corpus")
        items = [item for item in items if item["id"] in wanted]
    return items


def scenario_input(item, root=ROOT):
    scenario = read_json(repository_file(root, item["workload"]))
    scenario.update(acceptanceScenarioID=item["id"], acceptanceScenarioVersion=item["version"],
                    acceptanceTimeoutSeconds=item["timeoutSeconds"])
    if item.get("variation"):
        scenario["acceptanceVariation"] = item["variation"]
    return {"id": item["id"], "version": item["version"], "corpus": item["corpus"],
            "timeoutSeconds": item["timeoutSeconds"], "scenario": scenario}


def source_record(root=ROOT):
    identity = source_identity(root)
    return {"revision": identity["revision"],
            "prHeadRevision": os.environ.get("SPOTTY_ACCEPTANCE_HEAD_SHA", identity["revision"]),
            "trackedDiffDigest": identity["diffSHA256"], "sourceDigest": identity["sourceSHA256"],
            "dirty": bool(subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=normal"]))}


def failure(code, checkpoint, expected, observed):
    return {"code": code, "checkpoint": checkpoint, "expected": expected, "observed": observed}


def normalize(item, raw, source, manifest_digest, fallback=None):
    problem = fallback
    if raw is None:
        problem = problem or failure("missing-report", "runtime.report", "A completed scenario report", "No report")
        raw = {}
    elif not isinstance(raw, dict):
        problem = problem or failure("invalid-report", "runtime.report", "A scenario report object", type(raw).__name__)
        raw = {}
    elif raw.get("schemaVersion") != SCHEMA_VERSION or raw.get("scenarioID") != item["id"] or raw.get("scenarioVersion") != item["version"]:
        problem = failure("invalid-report", "runtime.identity", "Matching scenario and schema versions", "Mismatched report")
    reported_failure = raw.get("failure")
    if reported_failure is not None and (not isinstance(reported_failure, dict)
            or not all(isinstance(reported_failure.get(key), str) and reported_failure[key] for key in ("code", "checkpoint"))
            or not {"expected", "observed"} <= reported_failure.keys()):
        reported_failure = failure("invalid-report", "runtime.failure", "A structured failed checkpoint", reported_failure)
    problem = problem or reported_failure
    checks = raw.get("checkpoints", [])
    timeline = raw.get("timeline", [])
    isolation = raw.get("isolation", {})
    if not problem and (not isinstance(checks, list) or not checks or any(
            not isinstance(check, dict) or not isinstance(check.get("name"), str) or not check["name"]
            or not isinstance(check.get("expected"), dict) or not isinstance(check.get("observed"), dict)
            or check.get("passed") is not True for check in checks)):
        problem = failure("checkpoint-failed", "runtime.checkpoints", "Completed passing checkpoints with expected and observed state", checks)
    if not problem and (not isinstance(timeline, list) or not timeline or any(
            not isinstance(event, dict) or not isinstance(event.get("name"), str) or not event["name"] for event in timeline)):
        problem = failure("invalid-report", "runtime.timeline", "A retained command/observation timeline", timeline)
    if not problem and (not isinstance(isolation, dict) or isolation.get("dependencyMode") != "synthetic"
                        or type(isolation.get("forbiddenMutationAttempts")) is not int
                        or isolation["forbiddenMutationAttempts"] != 0):
        problem = failure("isolation-failed", "runtime.isolation", "Synthetic services and zero forbidden mutations", isolation)
    if not problem and raw.get("passed") is not True:
        problem = failure("runtime-failed", "runtime.terminal", "Successful terminal state", raw.get("passed"))
    return {"schemaVersion": SCHEMA_VERSION, "scenarioID": item["id"], "scenarioVersion": item["version"],
            "corpus": item["corpus"], "source": source, "manifestDigest": manifest_digest,
            "outcome": "failed" if problem else "passed", "failure": problem,
            "checkpoints": checks, "timeline": timeline, "isolation": isolation,
            "environment": raw.get("environment", {}), "artifacts": ["runtime-" + item["id"] + ".json"],
            "limits": LIMITS}


def summarize(output):
    output = Path(output)
    request_path = output / "request.json"
    try:
        request = read_json(request_path)
        if (not isinstance(request, dict) or request.get("schemaVersion") != SCHEMA_VERSION
                or not isinstance(request.get("source"), dict) or not isinstance(request.get("manifestDigest"), str)
                or not isinstance(request.get("scenarios"), list) or not request["scenarios"]):
            raise ValueError("Invalid run request")
        identifiers = set()
        for item in request["scenarios"]:
            if (not isinstance(item, dict) or not isinstance(item.get("id"), str)
                    or not re.fullmatch(r"[a-z][a-z0-9.-]{0,79}", item["id"]) or item["id"] in identifiers
                    or type(item.get("version")) is not int or item["version"] < 1
                    or item.get("corpus") not in ("representative", "holdout")):
                raise ValueError("Invalid requested scenario")
            identifiers.add(item["id"])
    except (ValueError, OSError):
        request = None
    if request is None:
        missing = not request_path.exists()
        result = {"schemaVersion": SCHEMA_VERSION, "source": None, "manifestDigest": None, "outcome": "failed",
                  "scenarios": [], "sourceUnchanged": False,
                  "failure": failure("not-executed" if missing else "invalid-request", "corpus.start", "A valid executed corpus request", "No run request" if missing else "Malformed run request"),
                  "scope": "credential-free synthetic state scenarios", "limits": LIMITS}
    else:
        entries = []
        for item in request["scenarios"]:
            path = output / ("evidence-" + item["id"] + ".json")
            problem = None
            raw = None
            try:
                evidence = read_json(path)
                if (not isinstance(evidence, dict) or evidence.get("source") != request["source"]
                        or evidence.get("manifestDigest") != request["manifestDigest"]
                        or evidence.get("corpus") != item["corpus"]
                        or evidence.get("outcome") not in ("passed", "failed")):
                    raise ValueError("Evidence does not match the run request")
                raw = dict(evidence, passed=evidence["outcome"] == "passed")
            except (ValueError, OSError):
                if path.exists():
                    problem = failure("invalid-evidence", "runtime.evidence", "Readable evidence matching this request", "Malformed or mismatched evidence")
            if request.get("sourceUnchanged") is not True:
                problem = failure("source-unverified", "source.identity", "Stable source throughout execution", "Source stability was not verified")
            evidence = normalize(item, raw, request["source"], request["manifestDigest"], problem)
            write_json(path, evidence)
            entries.append({"id": item["id"], "version": item["version"], "corpus": item["corpus"],
                            "outcome": evidence["outcome"], "failedCheckpoint": evidence["failure"],
                            "evidence": path.name})
        result = {"schemaVersion": SCHEMA_VERSION, "source": request["source"], "manifestDigest": request["manifestDigest"],
                  "outcome": "passed" if entries and all(x["outcome"] == "passed" for x in entries) else "failed",
                  "scenarios": entries, "sourceUnchanged": request.get("sourceUnchanged") is True,
                  "scope": "credential-free synthetic state scenarios", "limits": LIMITS}
    write_json(output / "summary.json", result)
    return result


def run_corpus(args):
    value = manifest()
    items = selected_scenarios(value, args.corpus, args.scenario)
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use an empty output directory so previous evidence cannot satisfy this run")
    output.mkdir(parents=True, exist_ok=True)
    before = source_record()
    request = {"schemaVersion": SCHEMA_VERSION, "source": before, "manifestDigest": digest(ROOT / MANIFEST), "scenarios": items}
    write_json(output / "request.json", request)
    input_path = output / "input.json"
    write_json(input_path, [scenario_input(item) for item in items])
    environment = dict(os.environ, SPOTTY_BUILD_BROWSING_HARNESS="1", SPOTTY_ACCEPTANCE_INPUT=str(input_path),
                       SPOTTY_ACCEPTANCE_OUTPUT=str(output))
    # Reuse the normal test watchdog, SDK setup and Swift Testing discovery. No retry loop.
    command = ["zsh", "-c", 'project_root="$PWD"; source Scripts/swiftpm-env.sh; '
               'exec python3 Scripts/swift_test_watchdog.py --lane acceptance --repetition 1 '
               '--timeout-seconds "$1" --log-dir "$2" -- swift test --disable-sandbox --no-parallel '
               '--filter AcceptanceCorpusTests', "acceptance", str(args.timeout_seconds), str(output / "diagnostics")]
    result = subprocess.run(command, cwd=ROOT, env=environment, check=False)
    after = source_record()
    request["sourceUnchanged"] = before == after
    write_json(output / "request.json", request)
    fallback = None
    if before != after:
        fallback = failure("source-changed", "source.identity", "Stable source throughout execution", "Source changed during run")
    elif result.returncode:
        fallback = failure("test-host-failed", "runtime.host", "Swift test host exits successfully", result.returncode)
    for item in items:
        raw_path = output / ("runtime-" + item["id"] + ".json")
        try:
            raw = read_json(raw_path) if raw_path.exists() else None
        except (ValueError, OSError):
            raw = None
        # Prefer the scenario's precise failure packet to the aggregate host failure.
        problem = fallback
        if isinstance(raw, dict) and raw.get("passed") is False and isinstance(raw.get("failure"), dict) and before == after:
            problem = None  # normalize validates and retains the scenario's structured failure.
        write_json(output / ("evidence-" + item["id"] + ".json"), normalize(item, raw, before, request["manifestDigest"], problem))
    summary = summarize(output)
    print_summary(summary)
    return 0 if summary["outcome"] == "passed" else 1


def print_summary(value):
    print("Synthetic acceptance: " + value["outcome"])
    for item in value["scenarios"]:
        detail = item.get("failedCheckpoint") or {}
        print(f"- `{item['id']}` v{item['version']} ({item['corpus']}): {item['outcome']}"
              + (" — " + str(detail.get("checkpoint", "unknown") if isinstance(detail, dict) else "invalid failure packet") if detail else ""))
    print("\nEvidence covers synthetic state assertions; visual parity, live Spotify, audible output, and performance budgets remain unverified.")


def demo_evidence(args):
    root = args.output
    report_path = root / "report.json"
    report = read_json(report_path) if report_path.exists() else {}
    launch = report.get("launch", {})
    if not launch and (root / "manifest.json").exists():
        launch = read_json(root / "manifest.json")
    scenario = report.get("scenario", {})
    if not scenario and args.workload and args.workload.exists():
        scenario = read_json(args.workload)
    source = launch.get("source", {})
    checkpoints = [{"name": sample["checkpoint"], "passed": True, "observed": sample} for sample in report.get("samples", [])]
    isolation = {"dependencyMode": "synthetic", "networkSandboxVerified": report.get("networkSandboxVerified"),
                 "forbiddenMutationAttempts": report.get("world", {}).get("mutationAttempts")}
    runtime = report.get("acceptanceRuntime") or {}
    passed = report.get("passed") is True and args.exit_code == 0 and isolation["networkSandboxVerified"] is True and isolation["forbiddenMutationAttempts"] == 0
    if scenario.get("acceptanceScenarioID"):
        passed = passed and runtime.get("passed") is True
    problem = None if passed else runtime.get("failure") or failure("demo-failed", "demo.workload", "Completed workload with verified sandbox and no forbidden mutations", report.get("failure") or "Launch or workload did not finish")
    bundle = {"schemaVersion": SCHEMA_VERSION, "scenarioID": scenario.get("acceptanceScenarioID", "legacy." + scenario.get("mode", "unknown")),
              "scenarioVersion": scenario.get("acceptanceScenarioVersion", scenario.get("version")), "outcome": "passed" if passed else "failed",
              "source": source, "failure": problem, "checkpoints": runtime.get("checkpoints", []) + checkpoints,
              "timeline": runtime.get("timeline", report.get("playbackCheckpoints", [])), "isolation": isolation,
              "environment": {key: report.get(key) for key in ("os", "processorCount", "windowWidth", "windowHeight", "displayScale")},
              "artifacts": [name for name in ("report.json", "manifest.json", "process.json", "run-status.json", "profiler-state.json", "trace-summary.json") if (root / name).exists()],
              "limits": ["Demo state and layout checkpoints do not establish live Spotify or audible output.",
                         "No comparable performance configuration is declared; timings remain in report.json."]}
    write_json(root / "evidence.json", bundle)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate")
    listing = commands.add_parser("list")
    listing.add_argument("--corpus", choices=["representative", "holdout", "all"], default="representative")
    runner = commands.add_parser("run")
    runner.add_argument("--corpus", choices=["representative", "holdout", "all"], default="representative")
    runner.add_argument("--scenario", action="append")
    runner.add_argument("--output", type=Path, required=True)
    runner.add_argument("--timeout-seconds", type=int, choices=range(1, 1201), default=540, metavar="1..1200")
    summary = commands.add_parser("summary")
    summary.add_argument("--output", type=Path, required=True)
    prepare = commands.add_parser("prepare-demo")
    prepare.add_argument("scenario")
    prepare.add_argument("--output", type=Path, required=True)
    demo = commands.add_parser("demo-evidence")
    demo.add_argument("--output", type=Path, required=True)
    demo.add_argument("--workload", type=Path)
    demo.add_argument("--exit-code", type=int, required=True)
    args = parser.parse_args()
    try:
        if args.command == "run":
            return run_corpus(args)
        if args.command == "summary":
            value = summarize(args.output)
            print_summary(value)
            return 0  # Always publish the summary; the run step owns the CI verdict.
        if args.command == "demo-evidence":
            return demo_evidence(args)
        value = manifest()
        if args.command == "validate":
            print(f"Validated {len(value['scenarios'])} acceptance scenarios")
        elif args.command == "list":
            for item in selected_scenarios(value, args.corpus):
                print(f"{item['id']}\tv{item['version']}\t{item['corpus']}\t{item['workload']}")
        else:
            selected = selected_scenarios(value, "all", [args.scenario])
            write_json(args.output, scenario_input(selected[0])["scenario"])
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("Acceptance error: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
