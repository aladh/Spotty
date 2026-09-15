"""Collect bounded, read-only evidence; unavailable evidence never means lack of gh access."""

import datetime
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import quote


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


def collect(context, directory, fetch=github):
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

    record("branch_rules", f"{root}/rules/branches/{quote(context['base_branch'], safe='')}",
           rules_snapshot, "branch-rules.json")

    def checks(response):
        if response["total_count"] > len(response["check_runs"]):
            raise ValueError("truncated")
        return [fields(check, "name head_sha status conclusion started_at completed_at html_url")
                for check in response["check_runs"] if check["head_sha"] == head]
    record("check_runs", f"{root}/commits/{head}/check-runs?per_page=100", checks, "check-runs.json")

    def runtime(response):
        if response["total_count"] > len(response["workflow_runs"]):
            raise ValueError("truncated")
        runs = [run for run in response["workflow_runs"] if run["head_sha"] == head]
        if not runs:
            return {"status": "not_started", "runs": []}
        run = max(runs, key=lambda item: item["id"])
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
