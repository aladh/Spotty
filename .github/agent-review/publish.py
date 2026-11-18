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


def paginated_nodes(page, fetch_next, key):
    nodes = []
    seen_keys = set()
    seen_cursors = set()
    while True:
        for node in page["nodes"]:
            identity = node.get(key)
            if not identity or identity in seen_keys:
                return nodes, False
            seen_keys.add(identity)
            nodes.append(node)
        info = page["pageInfo"]
        if info["hasNextPage"] is False:
            return nodes, True
        cursor = info.get("endCursor")
        if info["hasNextPage"] is not True or not page["nodes"] or not cursor or cursor in seen_cursors:
            return nodes, False
        seen_cursors.add(cursor)
        page = fetch_next(cursor)


def review_threads(env, request):
    owner, name = env["GITHUB_REPOSITORY"].split("/")
    query = '''query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        reviewThreads(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes {
          id isResolved isOutdated path line originalLine diffSide
          comments(first: 50) { pageInfo { hasNextPage endCursor } nodes {
            author { login } body url pullRequestReview { id state } } } } } } } }'''

    def page(after):
        data = graphql(query, {"owner": owner, "name": name, "number": int(env["PR_NUMBER"]),
                               "after": after}, request)
        return data["repository"]["pullRequest"]["reviewThreads"]

    return paginated_nodes(page(None), page, "id")


def thread_history(thread, request, exclude_review=None):
    query = '''query($id: ID!, $after: String!) {
      node(id: $id) { ... on PullRequestReviewThread {
        comments(first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes {
          author { login } body url pullRequestReview { id state } } } } } }'''

    def page(after):
        return graphql(query, {"id": thread["id"], "after": after}, request)["node"]["comments"]

    comments, complete = paginated_nodes(thread["comments"], page, "url")
    history = [{"author": (comment["author"] or {}).get("login"),
                "body": comment["body"], "url": comment["url"]}
               for comment in comments
               if exclude_review is None or (comment.get("pullRequestReview") or {}).get("id") != exclude_review]
    return history, complete


def collect_threads(env, request=github):
    threads, complete = review_threads(env, request)
    owned = []
    for thread in threads:
        if thread["isResolved"]:
            continue
        if not thread["comments"]["nodes"]:
            complete = False
        if owns(thread, env):
            comments, ready = thread_history(thread, request)
            complete = complete and ready
            owned.append({"id": thread["id"], "path": thread["path"],
                          "line": thread["line"] if thread["line"] is not None else thread["originalLine"],
                          "originalLine": thread["originalLine"], "diffSide": thread["diffSide"],
                          "isOutdated": thread["isOutdated"], "comments": comments})
    if not complete:
        raise RuntimeError("Could not read the complete PR review thread history")
    (Path(env["REVIEW_IN"]) / "threads.json").write_text(json.dumps(owned) + "\n")


def thread_state(env, pending_review, snapshots, request):
    threads, complete = review_threads(env, request)
    unresolved = [thread for thread in threads if not thread["isResolved"]]
    owned = [thread for thread in unresolved if owns(thread, env)
             and (thread["comments"]["nodes"][0].get("pullRequestReview") or {}).get("state") != "PENDING"
             and (thread["comments"]["nodes"][0].get("pullRequestReview") or {}).get("id") != pending_review]
    complete = complete and all(thread["comments"]["nodes"] for thread in unresolved)
    complete = complete and snapshots.keys() <= {thread["id"] for thread in threads}
    # Compare identity, author and body; ignore only replies this publication itself staged.
    # Check every snapshot thread, including changed ownership markers or external resolutions.
    for thread in threads:
        if thread["id"] not in snapshots and thread not in owned:
            continue
        history, ready = thread_history(thread, request, pending_review)
        complete = complete and ready and history == snapshots.get(thread["id"])
    return owned, complete


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
    snapshots = {thread["id"]: thread["comments"]
                 for thread in json.loads((Path(env["REVIEW_IN"]) / "threads.json").read_text())}
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

    # Re-read complete thread histories and head after staging, before deciding approval.
    owned, complete = thread_state(env, pending["node_id"], snapshots, request)
    pr = request("GET", root)
    current = pr["head"]["sha"] == head and pr["state"] == "open" and not pr["draft"]
    resolving = {action["id"] for action in actions if action["resolve"]} if current else set()
    resolving &= {thread["id"] for thread in owned}
    remaining = sum(thread["id"] not in resolving for thread in owned)
    event = "APPROVE" if env["CAN_APPROVE"] == "true" and not findings and remaining == 0 and current and complete else "COMMENT"
    header = f"**{env['REVIEWER_NAME']}** of `{head[:7]}` ({env['REVIEW_REASON']}): {len(findings)} new finding(s)."
    if not complete:
        header += " Thread state is incomplete or changed since review; approval and resolution withheld."
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
        owned, complete = thread_state(env, pending["node_id"], snapshots, request)
        latest = request("GET", root)
        if complete and latest["head"]["sha"] == head and latest["state"] == "open" and not latest["draft"]:
            for thread_id in sorted(resolving & {thread["id"] for thread in owned}):
                graphql('''mutation($id: ID!) {
                  resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }''',
                        {"id": thread_id}, request)
        else:
            print("Thread state or PR eligibility changed after submission; resolution withheld")
    print(f"Published one {event} review of {head} with {len(findings)} finding(s) ({placement})")


if __name__ == "__main__":
    if sys.argv[1:] == ["--cleanup"]:
        cleanup(os.environ)
    elif sys.argv[1:] == ["--collect-threads"]:
        collect_threads(os.environ)
    else:
        publish(os.environ)
