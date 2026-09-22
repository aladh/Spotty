"""Collect bounded, read-only evidence; unavailable evidence never means lack of gh access."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote
import zipfile
import zlib


SCENARIO_MANIFEST = "Tests/BrowsingHarness/Scenarios/manifest.json"
MAX_ARTIFACT_BYTES = 20 * 1024 * 1024
MAX_SUMMARY_BYTES = 512 * 1024


class EvidenceUnavailable(ValueError):
    def __init__(self, endpoint, error):
        self.endpoint = endpoint
        super().__init__(error)


def github(endpoint):
    result = subprocess.run(["gh", "api", endpoint], capture_output=True, text=True, timeout=40)
    if result.returncode:
        # Do not copy response bodies, headers, URLs or credentials into agent inputs.
        status = re.search(r"HTTP (\d{3})", result.stderr)
        error = f"HTTP {status[1]}" if status else f"gh exited {result.returncode}"
        raise EvidenceUnavailable(endpoint, error)
    return json.loads(result.stdout)


def artifact_summary(endpoint):
    """Read one bounded JSON member without extracting or executing artifact contents."""
    with tempfile.TemporaryFile() as archive:
        result = subprocess.run(["gh", "api", endpoint], stdout=archive, stderr=subprocess.PIPE,
                                timeout=40)
        if result.returncode:
            status = re.search(rb"HTTP (\d{3})", result.stderr)
            error = f"HTTP {status[1].decode()}" if status else f"gh exited {result.returncode}"
            raise EvidenceUnavailable(endpoint, error)
        if archive.tell() > MAX_ARTIFACT_BYTES:
            raise ValueError("artifact exceeds bounded input size")
        archive.seek(0)
        try:
            with zipfile.ZipFile(archive) as bundle:
                summaries = [entry for entry in bundle.infolist() if entry.filename == "summary.json"]
                if len(summaries) != 1 or summaries[0].file_size > MAX_SUMMARY_BYTES:
                    raise ValueError("missing, duplicate, or oversized summary")
                return json.loads(bundle.read(summaries[0]))
        except (zipfile.BadZipFile, RuntimeError, NotImplementedError, EOFError, zlib.error) as error:
            raise ValueError("invalid artifact archive") from error


def acceptance_summary(response, run, head, manifest, manifest_digest, root, download):
    """Bind the untrusted summary to this CI attempt, PR head and scenario manifest."""
    if response["total_count"] > len(response["artifacts"]):
        raise ValueError("truncated artifacts")
    expected_name = f"acceptance-evidence-{run['id']}-{run['run_attempt']}"
    artifacts = [artifact for artifact in response["artifacts"] if artifact["name"] == expected_name]
    if not artifacts:
        return {"status": "not_supplied", "reason": "The latest CI attempt has no acceptance artifact."}
    if len(artifacts) != 1:
        raise ValueError("ambiguous artifact")
    artifact = artifacts[0]
    if (artifact["expired"] or not 0 < artifact["size_in_bytes"] <= MAX_ARTIFACT_BYTES
            or artifact["workflow_run"]["id"] != run["id"]
            or artifact["workflow_run"]["head_sha"] != head
            or not isinstance(artifact["id"], int) or artifact["id"] <= 0):
        raise ValueError("unavailable or mismatched artifact")
    summary = download(f"{root}/actions/artifacts/{artifact['id']}/zip")
    source = summary["source"]
    if (summary["schemaVersion"] != 1 or summary["manifestDigest"] != manifest_digest
            or source["prHeadRevision"] != head or source["dirty"] is not False
            or summary["sourceUnchanged"] is not True
            or not re.fullmatch(r"[0-9a-f]{40}", source["revision"])
            or not re.fullmatch(r"[0-9a-f]{64}", source["trackedDiffDigest"])
            or summary["outcome"] not in ("passed", "failed")):
        raise ValueError("summary identity mismatch")
    expected = {scenario["id"]: scenario for scenario in manifest["scenarios"]}
    observed = summary["scenarios"]
    if len(observed) != len(expected) or {scenario["id"] for scenario in observed} != set(expected):
        raise ValueError("incomplete acceptance corpus")
    for scenario in observed:
        contract = expected[scenario["id"]]
        if (scenario["version"] != contract["version"] or scenario["corpus"] != contract["corpus"]
                or scenario["outcome"] not in ("passed", "failed")):
            raise ValueError("scenario identity mismatch")
    if summary["outcome"] == "passed" and any(scenario["outcome"] != "passed" for scenario in observed):
        raise ValueError("inconsistent passing summary")
    return {"status": "present", "run": fields(run, "id run_attempt head_sha status conclusion html_url"),
            "artifact": fields(artifact, "id name size_in_bytes expired"), "summary": summary,
            "limits": "Untrusted state-boundary evidence. Does not establish signed Demo network isolation, visual fidelity, live playback, or merge readiness."}


def fields(value, names):
    if not isinstance(value, dict):
        raise ValueError("expected an object")
    return {key: value.get(key) for key in names.split()}


def rules_snapshot(response):
    allowed = {
        "pull_request": "required_approving_review_count dismiss_stale_reviews_on_push require_code_owner_review require_last_push_approval required_review_thread_resolution allowed_merge_methods",
        "required_status_checks": "strict_required_status_checks_policy do_not_enforce_on_create",
    }
    rules = []
    for rule in response:
        kind = rule["type"]
        entry = {"type": kind}
        parameters = rule.get("parameters") or {}
        if kind in allowed:
            entry["parameters"] = fields(parameters, allowed[kind])
        if kind == "required_status_checks":
            entry["parameters"]["required_status_checks"] = [
                fields(check, "context integration_id") for check in parameters["required_status_checks"]
            ]
        rules.append(entry)
    return rules


def collect(context, directory, fetch=github, download=artifact_summary):
    directory = Path(directory)
    repo = context["repository"]
    head = context["head"]
    root = f"repos/{repo}"
    preflight = {"repository": repo, "head": head,
                 "collected_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "inputs": []}

    def record(name, endpoint, transform, filename):
        item = {"name": name, "endpoint": endpoint}
        try:
            data = transform(fetch(endpoint))
            path = directory / filename
            path.write_text(json.dumps({"repository": repo, "head": head, "endpoint": endpoint,
                                        "data": data}, indent=2) + "\n")
            item.update(status="present", path=str(path))
        except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
            # Collector errors are fixed messages, never raw remote text.
            message = str(error) if isinstance(error, EvidenceUnavailable) and re.fullmatch(r"HTTP \d{3}|gh exited \d+", str(error)) else "response unavailable, invalid, or timed out"
            item.update(status="unavailable", error=message)
            if isinstance(error, EvidenceUnavailable):
                item["endpoint"] = error.endpoint
        preflight["inputs"].append(item)
        return item

    for key in ("pr_description", "pr_diff", "changes_diff", "threads"):
        path = Path(context[key])
        preflight["inputs"].append({"name": key, "path": str(path),
                                    "status": "present" if path.is_file() else "missing"})
    actual_head = None
    try:
        actual_head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True,
                                              stderr=subprocess.DEVNULL, timeout=10).strip()
        revisions = [context["base"], head]
        if context.get("mode") == "incremental":
            revisions.append(context.get("previous_head"))
        history_present = actual_head == head and all(
            revision and subprocess.run(["git", "cat-file", "-e", f"{revision}^{{commit}}"],
                                        capture_output=True, timeout=10).returncode == 0
            for revision in revisions
        )
    except (OSError, subprocess.SubprocessError):
        history_present = False
    preflight["inputs"].append({"name": "source_and_history", "head": actual_head,
                                "status": "present" if history_present else "missing"})

    manifest = None
    manifest_digest = None
    manifest_input = {"name": "acceptance_manifest", "source_path": SCENARIO_MANIFEST}
    try:
        raw = subprocess.check_output(["git", "show", f"{head}:{SCENARIO_MANIFEST}"],
                                      stderr=subprocess.DEVNULL, timeout=10)
        manifest = json.loads(raw)
        if manifest["schemaVersion"] != 1 or not isinstance(manifest["scenarios"], list):
            raise ValueError("invalid manifest")
        manifest_digest = hashlib.sha256(raw).hexdigest()
        path = directory / "acceptance-manifest.json"
        path.write_bytes(raw)
        manifest_input.update(status="present", path=str(path), digest=manifest_digest, head=head)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        manifest = None
        manifest_input.update(status="missing", reason="No readable versioned scenario manifest at the reviewed head.")
    preflight["inputs"].append(manifest_input)

    record("branch_rules", f"{root}/rules/branches/{quote(context['base_branch'], safe='')}",
           rules_snapshot, "branch-rules.json")

    def checks(response):
        if response["total_count"] > len(response["check_runs"]):
            raise ValueError("truncated")
        return [fields(check, "name head_sha status conclusion started_at completed_at html_url")
                for check in response["check_runs"] if check["head_sha"] == head]
    record("check_runs", f"{root}/commits/{head}/check-runs?per_page=100", checks, "check-runs.json")

    latest_ci_run = None

    def runtime(response):
        nonlocal latest_ci_run
        if response["total_count"] > len(response["workflow_runs"]):
            raise ValueError("truncated")
        runs = [run for run in response["workflow_runs"] if run["head_sha"] == head]
        if not runs:
            return {"status": "not_started", "runs": []}
        run = max(runs, key=lambda item: item["id"])
        latest_ci_run = run
        endpoint = f"{root}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100"
        jobs = fetch(endpoint)
        if jobs["total_count"] > len(jobs["jobs"]):
            raise ValueError("truncated")
        return {"run": fields(run, "id run_attempt head_sha event status conclusion html_url"),
                "jobs_endpoint": endpoint,
                "jobs": [dict(fields(job, "name head_sha status conclusion html_url"),
                              steps=[fields(step, "name status conclusion started_at completed_at")
                                     for step in job["steps"]]) for job in jobs["jobs"]],
                "limits": "Step results establish execution and exit status only, not visual parity, live playback, or performance."}
    record("ci_runtime", f"{root}/actions/workflows/ci.yml/runs?head_sha={head}&per_page=10",
           runtime, "ci-runtime.json")
    if latest_ci_run is not None and latest_ci_run.get("status") == "completed" and manifest is not None:
        record("acceptance_scenarios", f"{root}/actions/runs/{latest_ci_run['id']}/artifacts?per_page=100",
               lambda response: acceptance_summary(response, latest_ci_run, head, manifest,
                                                   manifest_digest, root, download),
               "acceptance-scenarios.json")
    else:
        preflight["inputs"].append({"name": "acceptance_scenarios", "status": "not_supplied",
                                    "reason": "No completed head-matched CI run and readable scenario manifest. Pending checks never establish passing scenarios."})
    preflight["inputs"].extend([
        {"name": "ui_runtime_report", "status": "not_supplied",
         "reason": "No head-matched UI report, trace or screenshot manifest is supplied by this workflow. Inspect explicitly linked evidence before claiming UI or playback verification."},
        {"name": "app_installation_permissions", "status": "not_collected",
         "reason": "The agent has no installation credential or settings access. Workflow permissions and a successful publication do not enumerate the App installation permissions."},
    ])
    path = directory / "evidence.json"
    path.write_text(json.dumps(preflight, indent=2) + "\n")
    context["evidence"] = str(path)
    (directory / "context.json").write_text(json.dumps(context, indent=2) + "\n")
    for item in preflight["inputs"]:
        print(f"Evidence {item['name']}: {item['status']}" + (f" ({item['endpoint']}: {item['error']})" if "error" in item else ""))
    return preflight


if __name__ == "__main__":
    inputs = Path(os.environ["REVIEW_IN"])
    collect(json.loads((inputs / "context.json").read_text()), inputs)
