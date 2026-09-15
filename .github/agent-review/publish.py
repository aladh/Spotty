"""Publish one pending review, including earlier-thread replies, then resolve verified threads."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


class APIError(RuntimeError):
    def __init__(self, result):
        status = re.search(r"HTTP (\d{3})", result.stderr)
        self.status = int(status[1]) if status else None
        self.pending_conflict = self.status == 422 and "pending review" in result.stdout.lower()
        super().__init__(f"GitHub request failed (HTTP {self.status or 'unknown'}); no response or credentials logged")


def github(method, endpoint, payload=None):
    command = ["gh", "api", "--method", method, endpoint]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=None if payload is None else json.dumps(payload),
                            capture_output=True, text=True, timeout=40)
    if result.returncode:
        raise APIError(result)
    return json.loads(result.stdout) if result.stdout.strip() else None


def graphql(query, variables, request):
    response = request("POST", "graphql", {"query": query, "variables": variables})
    if response.get("errors"):
        raise RuntimeError("GitHub GraphQL rejected the review operation")
    return response["data"]


def review_body(env, header, summary):
    hint = f"Trusted repository collaborators can rerun this review by commenting `{env['RERUN_COMMAND']}`."
    return f"{env['REVIEW_MARKER']}\n{header}\n\n{summary.strip()}\n\n{hint}"


def owns(thread, env):
    comments = thread["comments"]["nodes"]
    if not comments:
        return False
    comment = comments[0]
    body = comment["body"]
    return comment["author"] is not None and comment["author"]["login"] == env["REVIEWER_LOGIN"] and (
        body.startswith(env["REVIEW_MARKER"]) or
        env["LEGACY_UNMARKED_THREADS"] == "true" and not body.startswith("<!-- spotty-"))


def cleanup(env, request=github):
    state = Path(env["REVIEW_PENDING"])
    if not state.exists():
        return
    saved = json.loads(state.read_text())
    if saved["id"] is None:
        # Creation can succeed remotely just before cancellation/timeout prevents saving its ID.
        connection = graphql('''query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) { pullRequest(number: $number) {
            reviews(first: 100, states: PENDING) { nodes { databaseId body } } } } }''',
            {"owner": env["GITHUB_REPOSITORY"].split('/')[0], "name": env["GITHUB_REPOSITORY"].split('/')[1],
             "number": int(env["PR_NUMBER"])}, request)["repository"]["pullRequest"]["reviews"]
        matches = [review for review in connection["nodes"] if review["body"].startswith(saved["marker"])]
        if not matches:
            state.unlink()
            return
        if len(matches) != 1:
            raise RuntimeError("Ambiguous pending-review cleanup; refusing to delete")
        saved["id"] = matches[0]["databaseId"]
    endpoint = f"repos/{env['GITHUB_REPOSITORY']}/pulls/{env['PR_NUMBER']}/reviews/{saved['id']}"
    review = request("GET", endpoint)
    if review["state"] == "PENDING":
        request("DELETE", endpoint)
        print("Removed this run's unsubmitted pending review")
    state.unlink()


def publish(env, request=github, sleep=time.sleep):
    out = Path(env["REVIEW_OUT"])
    findings = json.loads((out / "findings.json").read_text())
    actions = json.loads((out / "thread-actions.json").read_text())
    summary = (out / "summary.md").read_text()
    root = f"repos/{env['GITHUB_REPOSITORY']}/pulls/{env['PR_NUMBER']}"
    head = env["HEAD_SHA"]
    marker = env["REVIEW_MARKER"]
    comments = [dict(path=item["path"], line=item["line"], side="RIGHT", body=marker + "\n" + item["body"])
                for item in findings]
    run_marker = f"{marker}\n<!-- pending-run:{env['GITHUB_RUN_ID']}:{env['GITHUB_RUN_ATTEMPT']} -->"
    Path(env["REVIEW_PENDING"]).write_text(json.dumps({"id": None, "marker": run_marker}) + "\n")
    pending_body = review_body(env, f"**{env['REVIEWER_NAME']}** of `{head[:7]}`: publication pending.", summary)
    payload = {"commit_id": head, "body": pending_body.replace(marker, run_marker, 1), "comments": comments}
    placement = "inline"
    # The reviewers share an App identity and GitHub allows only one pending review per identity/PR.
    # Wait briefly for the other publisher; never reuse or delete its pending review.
    for attempt in range(11):
        try:
            pending = request("POST", root + "/reviews", payload)
            break
        except APIError as error:
            if error.pending_conflict and attempt < 10:
                sleep(3)
                continue
            if error.status == 422 and not error.pending_conflict and payload["comments"]:
                payload["comments"] = []
                placement = "body"
                continue
            raise
    else:
        raise RuntimeError("Pending review creation did not complete")
    Path(env["REVIEW_PENDING"]).write_text(json.dumps({"id": pending["id"]}) + "\n")
    for action in actions:
        if action["reply"]:
            graphql('''mutation($review: ID!, $thread: ID!, $body: String!) {
              addPullRequestReviewThreadReply(input: {pullRequestReviewId: $review,
                pullRequestReviewThreadId: $thread, body: $body}) { comment { id } } }''',
                    {"review": pending["node_id"], "thread": action["id"], "body": action["reply"]}, request)

    # Re-read head and owned threads after staging; calculate approval from intended resolutions.
    pr = request("GET", root)
    connection = graphql('''query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        reviewThreads(first: 100) { pageInfo { hasNextPage } nodes {
          id isResolved comments(first: 1) { nodes { author { login } body pullRequestReview { state } } } } } } } }''',
        {"owner": env["GITHUB_REPOSITORY"].split('/')[0], "name": env["GITHUB_REPOSITORY"].split('/')[1],
         "number": int(env["PR_NUMBER"])}, request)["repository"]["pullRequest"]["reviewThreads"]
    current = pr["head"]["sha"] == head and pr["state"] == "open" and not pr["draft"]
    resolving = {action["id"] for action in actions if action["resolve"]} if current else set()
    owned = [thread for thread in connection["nodes"] if not thread["isResolved"] and owns(thread, env)
             and (thread["comments"]["nodes"][0].get("pullRequestReview") or {}).get("state") != "PENDING"]
    resolving &= {thread["id"] for thread in owned}
    remaining = sum(thread["id"] not in resolving for thread in owned)
    complete = not connection["pageInfo"]["hasNextPage"] and all(
        thread["comments"]["nodes"] for thread in connection["nodes"] if not thread["isResolved"])
    event = "APPROVE" if env["CAN_APPROVE"] == "true" and not findings and remaining == 0 and current and complete else "COMMENT"
    header = f"**{env['REVIEWER_NAME']}** of `{head[:7]}` ({env['REVIEW_REASON']}): {len(findings)} new finding(s)."
    if not complete:
        header += " Thread state is incomplete; approval withheld."
        resolving.clear()
    elif remaining:
        header += f" {remaining} earlier thread(s) remain open."
    elif not findings:
        header += " No actionable findings remain in the reviewed scope."
    if not current:
        header += " The PR head or eligibility changed during review; approval and resolution withheld."
    body = review_body(env, header, summary)
    if placement == "body":
        body += "\n\nFindings (inline placement rejected):\n" + "\n".join(
            f"- `{item['path']}:{item['line']}` — {item['body']}" for item in findings)
    request("POST", root + f"/reviews/{pending['id']}/events", {"event": event, "body": body})
    # A failed submission leaves every thread open; resolution only follows a confirmed submission.
    if resolving:
        latest = request("GET", root)
        if latest["head"]["sha"] == head and latest["state"] == "open" and not latest["draft"]:
            for thread_id in sorted(resolving):
                graphql('''mutation($id: ID!) {
                  resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }''',
                        {"id": thread_id}, request)
    print(f"Published one {event} review of {head} with {len(findings)} finding(s) ({placement})")


if __name__ == "__main__":
    if sys.argv[1:] == ["--cleanup"]:
        cleanup(os.environ)
    else:
        publish(os.environ)
