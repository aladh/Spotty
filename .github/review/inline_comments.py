"""Idempotent, source-bound publication of OpenCode pull-request comments.

This module deliberately has no dependency on ``review.py``.  The caller passes
the already validated report and its API/current-revision callbacks so the
overview publisher can keep ownership of its existing issue comment.
"""

import html
import re
from urllib.parse import quote

from contract import MAX_RESOLUTION, bounded_text, safe_path, validate_finding


BOT = "github-actions[bot]"
GRAPHQL_BOT_LOGIN = "github-actions"
GRAPHQL_BOT_TYPE = "Bot"
INLINE_MARKER_PREFIX = "<!-- spotty-opencode-inline:v1"
INLINE_MARKER = INLINE_MARKER_PREFIX
INLINE_MARKER_RE = re.compile(r"^<!-- spotty-opencode-inline:v1 id=(F[0-9a-f]{12}) -->$")
SUPERSEDE_MARKER_RE = re.compile(
    r"^<!-- spotty-opencode-inline-superseded:v1 id=(F[0-9a-f]{12}) head=([0-9a-f]{40}) -->$"
)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
MAX_THREAD_PAGES = 10
MAX_THREAD_PAGE_SIZE = 100
MAX_THREAD_COMMENTS = 100
MAX_COMMENT_BYTES = 60_000


THREADS_QUERY = """
query($owner:String!, $name:String!, $number:Int!, $after:String) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:100, after:$after) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          diffSide
          comments(first:100) {
            nodes {
              id
              databaseId
              fullDatabaseId
              body
              author { __typename login }
              replyTo { id }
              path
              line
              outdated
              commit { oid }
              url
            }
            pageInfo { hasNextPage endCursor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"""


RESOLVE_MUTATION = """
mutation($threadId:ID!) {
  resolveReviewThread(input:{threadId:$threadId}) {
    thread { id isResolved }
  }
}
"""


UNRESOLVE_MUTATION = """
mutation($threadId:ID!) {
  unresolveReviewThread(input:{threadId:$threadId}) {
    thread { id isResolved }
  }
}
"""


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _escaped(value):
    """Escape untrusted model prose for the HTML-ish GitHub comment body."""
    return html.escape(value, quote=True).replace("@", "&#64;")


def _graphql_bot(author):
    return (isinstance(author, dict) and author.get("__typename") == GRAPHQL_BOT_TYPE
            and author.get("login") == GRAPHQL_BOT_LOGIN)


def _marker(identity):
    return f"{INLINE_MARKER_PREFIX} id={identity} -->"


def _first_line(body):
    if not isinstance(body, str) or not body:
        return ""
    return body.splitlines()[0]


def marker_id(body):
    """Return an owned marker ID only when it is the exact first line."""
    match = INLINE_MARKER_RE.fullmatch(_first_line(body))
    return match.group(1) if match else None


def _superseded(body, identity, head):
    match = SUPERSEDE_MARKER_RE.fullmatch(_first_line(body))
    return bool(match and match.group(1) == identity and match.group(2) == head)


def _source_url(meta, path, line):
    return f"https://github.com/{meta['repo']}/blob/{meta['head']}/{quote(path, safe='/')}#L{line}"


def _finding_body(meta, finding):
    identity = finding["id"]
    source = _source_url(meta, finding["path"], finding["line"])
    lines = [
        _marker(identity),
        f"**OpenCode advisory · {_escaped(identity)} · {_escaped(finding['severity'])}**",
        "",
        "<pre>" + _escaped(finding["title"] + "\n" + finding["body"]) + "</pre>",
        "",
        f"[Source at head `{meta['head']}`]({source})",
        "Advisory feedback only; no approval was issued.",
    ]
    body = "\n\n".join(lines)
    _require(len(body.encode()) <= MAX_COMMENT_BYTES, "Rendered inline comment exceeds comment budget")
    return body


def _resolution_body(meta, thread, resolution):
    identity = resolution["id"]
    path, line = thread.get("path"), thread.get("line")
    location = ""
    if isinstance(path, str) and type(line) is int and line > 0:
        location = f"\n\n[Source at head `{meta['head']}`]({_source_url(meta, path, line)})"
    lines = [
        _marker(identity),
        f"**OpenCode advisory · {_escaped(identity)} · resolved**",
        "",
        "<pre>" + _escaped("Resolved against the source at head " + meta["head"] + ":\n"
                             + resolution["reason"]) + "</pre>" + location,
        "Advisory feedback only; no approval was issued.",
    ]
    body = "\n\n".join(lines)
    _require(len(body.encode()) <= MAX_COMMENT_BYTES, "Rendered inline resolution exceeds comment budget")
    return body


def _supersede_reply(meta, finding, old_thread):
    old_path, old_line = old_thread.get("path"), old_thread.get("line")
    old_location = ""
    if isinstance(old_path, str) and type(old_line) is int and old_line > 0:
        old_location = f" from <code>{_escaped(old_path)}:{old_line}</code>"
    source = _source_url(meta, finding["path"], finding["line"])
    marker = f"<!-- spotty-opencode-inline-superseded:v1 id={finding['id']} head={meta['head']} -->"
    body = (f"{marker}\n\nOpenCode advisory `{_escaped(finding['id'])}` was re-anchored{old_location} "
            f"to [current source]({source}) at <code>{_escaped(finding['path'])}:{finding['line']}</code> "
            f"on head `{meta['head']}`. "
            "This older owned thread is superseded.")
    _require(len(body.encode()) <= MAX_COMMENT_BYTES, "Rendered inline supersession exceeds comment budget")
    return body


def _validate_inputs(meta, result, token, api, check_current):
    _require(isinstance(meta, dict), "Invalid inline publication metadata")
    _require(isinstance(result, dict) and set(result) == {"summary", "findings", "resolved"},
             "Invalid inline publication result")
    _require(isinstance(token, str) and token, "Missing GitHub token for inline publication")
    _require(callable(api) and callable(check_current), "Invalid inline publication callbacks")
    repo = meta.get("repo")
    _require(isinstance(repo, str) and REPO_RE.fullmatch(repo), "Invalid repository identity")
    _require(type(meta.get("pr")) is int and meta["pr"] > 0, "Invalid pull request number")
    for key in ("head", "base"):
        _require(isinstance(meta.get(key), str) and SHA_RE.fullmatch(meta[key]), f"Invalid {key} SHA")
    changed = meta.get("changed")
    files = meta.get("files")
    diff_lines = meta.get("diff_lines")
    _require(isinstance(changed, (list, tuple)) and isinstance(files, dict)
             and isinstance(diff_lines, dict), "Missing inline source metadata")
    _require(all(isinstance(path, str) and safe_path(path) for path in changed),
             "Invalid changed path metadata")
    for path, count in files.items():
        _require(isinstance(path, str) and safe_path(path) and type(count) is int and count >= 0,
                 "Invalid source line metadata")
    for path, anchors in diff_lines.items():
        _require(isinstance(path, str) and safe_path(path) and isinstance(anchors, (list, tuple, set)),
                 "Invalid diff anchor metadata")
        _require(all(type(line) is int and line > 0 for line in anchors), "Invalid diff anchor line")

    findings = result["findings"]
    resolved = result["resolved"]
    _require(isinstance(findings, list) and isinstance(resolved, list), "Invalid inline result lists")
    _require(isinstance(result["summary"], str) and 0 < len(result["summary"].strip()) <= 2_000,
             "Invalid inline summary")
    seen = set()
    for finding in findings:
        normalized = validate_finding(finding, meta)
        identity = normalized["id"]
        _require(identity not in seen, "Invalid or duplicate inline finding ID")
        seen.add(identity)
    for item in resolved:
        _require(isinstance(item, dict) and set(item) == {"id", "reason"},
                 "Invalid inline resolution schema")
        identity = item["id"]
        _require(isinstance(identity, str) and re.fullmatch(r"F[0-9a-f]{12}", identity)
                 and identity not in seen, "Invalid or duplicate inline resolution ID")
        bounded_text(item["reason"], MAX_RESOLUTION, "inline resolution reason")
        seen.add(identity)


def _graphql(api, token, query, variables):
    response = api("graphql", token, "POST", {"query": query, "variables": variables})
    _require(isinstance(response, dict) and not response.get("errors"),
             "GitHub GraphQL request failed")
    data = response.get("data")
    _require(isinstance(data, dict), "Invalid GitHub GraphQL response")
    return data


def _discover_threads(meta, token, api):
    owner, name = meta["repo"].split("/", 1)
    cursor = None
    threads = []
    for page in range(MAX_THREAD_PAGES):
        variables = {"owner": owner, "name": name, "number": meta["pr"], "after": cursor}
        data = _graphql(api, token, THREADS_QUERY, variables)
        repository = data.get("repository")
        pull_request = repository.get("pullRequest") if isinstance(repository, dict) else None
        connection = pull_request.get("reviewThreads") if isinstance(pull_request, dict) else None
        _require(isinstance(connection, dict), "Invalid GitHub review-thread response")
        nodes = connection.get("nodes")
        page_info = connection.get("pageInfo")
        _require(isinstance(nodes, list) and isinstance(page_info, dict),
                 "Invalid GitHub review-thread page")
        for node in nodes:
            if not isinstance(node, dict):
                continue
            comments = node.get("comments")
            comment_nodes = comments.get("nodes") if isinstance(comments, dict) else None
            _require(isinstance(comment_nodes, list), "Invalid GitHub review-thread comments")
            if not comment_nodes:
                continue
            first = comment_nodes[0]
            if not isinstance(first, dict):
                continue
            author = first.get("author")
            identity = marker_id(first.get("body"))
            # A marker in a later reply, a quoted marker, or a marker from any
            # other actor does not make a thread ours.
            if not _graphql_bot(author) or identity is None or first.get("replyTo") is not None:
                continue
            thread_id = node.get("id")
            _require(isinstance(thread_id, str) and thread_id, "Invalid owned review-thread ID")
            raw_comment_id = first.get("databaseId", first.get("fullDatabaseId"))
            if raw_comment_id is None:
                raw_comment_id = first.get("fullDatabaseId")
            comment_id = None
            if type(raw_comment_id) is int and raw_comment_id > 0:
                comment_id = raw_comment_id
            elif isinstance(raw_comment_id, str) and raw_comment_id.isdigit() and int(raw_comment_id) > 0:
                comment_id = int(raw_comment_id)
            elif type(first.get("id")) is int and first["id"] > 0:
                comment_id = first["id"]
            elif isinstance(first.get("id"), str) and first["id"].isdigit() and int(first["id"]) > 0:
                comment_id = int(first["id"])
            comment_page = comments.get("pageInfo") if isinstance(comments, dict) else None
            _require(isinstance(comment_page, dict), "Invalid GitHub review-thread comment page")
            _require(not comment_page.get("hasNextPage"),
                     "Owned review thread has more than the bounded comment page")
            reply_records = []
            for reply in comment_nodes[1:]:
                if isinstance(reply, dict) and isinstance(reply.get("body"), str):
                    reply_records.append({
                        "body": reply["body"],
                        "author": reply.get("author"),
                    })
            commit = first.get("commit")
            threads.append({
                "id": thread_id,
                "finding_id": identity,
                "comment_id": comment_id,
                "url": first.get("url"),
                "body": first.get("body") or "",
                "path": node.get("path", first.get("path")),
                "line": node.get("line", first.get("line")),
                "side": node.get("diffSide"),
                "outdated": bool(node.get("isOutdated") or first.get("outdated")),
                "resolved": bool(node.get("isResolved")),
                "replies": reply_records,
                "comment_nodes": comment_nodes,
                "commit": commit.get("oid") if isinstance(commit, dict) else None,
            })
        has_next = page_info.get("hasNextPage")
        _require(isinstance(has_next, bool), "Invalid GitHub review-thread pagination")
        if not has_next:
            return threads
        cursor = page_info.get("endCursor")
        _require(isinstance(cursor, str) and cursor, "Missing GitHub review-thread cursor")
    raise ValueError(f"Review-thread pagination exceeded {MAX_THREAD_PAGES} pages")


def _rest_result(response, fallback_url=None):
    _require(isinstance(response, dict), "Invalid GitHub review-comment response")
    url = response.get("html_url") or response.get("url") or fallback_url
    _require(isinstance(url, str) and url, "GitHub review-comment response omitted URL")
    return url


def _write(api, check_current, meta, token, path, method, data):
    check_current(meta, token)
    return api(path, token, method, data)


def _resolve(api, check_current, meta, token, thread_id, resolved):
    query = RESOLVE_MUTATION if resolved else UNRESOLVE_MUTATION
    mutation_name = "resolveReviewThread" if resolved else "unresolveReviewThread"
    response = _write(api, check_current, meta, token, "graphql", "POST",
                      {"query": query, "variables": {"threadId": thread_id}})
    _require(isinstance(response, dict) and not response.get("errors"),
             "GitHub review-thread resolution failed")
    data = response.get("data")
    payload = data.get(mutation_name) if isinstance(data, dict) else None
    _require(isinstance(payload, dict) and isinstance(payload.get("thread"), dict),
             "Invalid GitHub review-thread resolution response")
    state = payload["thread"].get("isResolved")
    _require(type(state) is bool and state is resolved,
             "GitHub review-thread resolution did not reach the requested state")


def _comment_id(thread):
    _require(type(thread.get("comment_id")) is int and thread["comment_id"] > 0,
             "Owned review thread omitted its REST comment ID")
    return thread["comment_id"]


def _reply_once(api, check_current, meta, token, finding, old_thread):
    if any(_graphql_bot(record.get("author"))
           and _superseded(record.get("body"), finding["id"], meta["head"])
           for record in old_thread.get("replies", [])):
        return
    path = f"repos/{meta['repo']}/pulls/{meta['pr']}/comments/{_comment_id(old_thread)}/replies"
    _write(api, check_current, meta, token, path, "POST", {"body": _supersede_reply(meta, finding, old_thread)})


def _patch_if_needed(api, check_current, meta, token, thread, body):
    if thread.get("body") == body:
        return
    path = f"repos/{meta['repo']}/pulls/comments/{_comment_id(thread)}"
    _write(api, check_current, meta, token, path, "PATCH", {"body": body})


def _create(api, check_current, meta, token, finding, body):
    path = f"repos/{meta['repo']}/pulls/{meta['pr']}/comments"
    response = _write(api, check_current, meta, token, path, "POST", {
        "body": body,
        "commit_id": meta["head"],
        "path": finding["path"],
        "line": finding["line"],
        "side": "RIGHT",
    })
    return _rest_result(response)


def _current(thread, finding, head):
    side = thread.get("side")
    return (thread.get("commit") == head
            and not thread.get("outdated") and thread.get("path") == finding["path"]
            and thread.get("line") == finding["line"] and side == "RIGHT")


def _thread_url(thread):
    url = thread.get("url")
    return url if isinstance(url, str) and url else None


def sync(meta, result, token, api, check_current):
    """Reconcile validated findings with owned inline review threads.

    The return value contains the GitHub URLs of active/resolution threads that
    were found or written.  All mutations are revision-checked immediately
    beforehand and the final check is performed even when there were no writes.
    Any API or validation failure propagates so the caller cannot publish a
    successful overview for a partial inline publication.
    """
    _validate_inputs(meta, result, token, api, check_current)
    owned = {}
    for thread in _discover_threads(meta, token, api):
        owned.setdefault(thread["finding_id"], []).append(thread)
    urls = []

    for finding in result["findings"]:
        identity = finding["id"]
        matches = owned.get(identity, [])
        current = [thread for thread in matches if _current(thread, finding, meta["head"])]
        canonical = current[-1] if current else None
        if canonical is None:
            body = _finding_body(meta, finding)
            url = _create(api, check_current, meta, token, finding, body)
            urls.append(url)
        else:
            if canonical.get("resolved"):
                _resolve(api, check_current, meta, token, canonical["id"], False)
            _patch_if_needed(api, check_current, meta, token, canonical,
                             _finding_body(meta, finding))
            url = _thread_url(canonical)
            if url:
                urls.append(url)

        # Every other owned copy of this ID is stale or a duplicate.  Only
        # owned threads with the same stable ID are reconciled here.
        for old_thread in matches:
            if canonical is old_thread:
                continue
            if old_thread.get("resolved"):
                continue
            _reply_once(api, check_current, meta, token, finding, old_thread)
            _resolve(api, check_current, meta, token, old_thread["id"], True)

    for resolution in result["resolved"]:
        matches = owned.get(resolution["id"], [])
        if not matches:
            continue
        # A failed move can leave both the old and new owned threads open.
        # Reconcile every exact-ID copy, while continuing to ignore all other
        # reviewers' threads.
        for thread in matches:
            body = _resolution_body(meta, thread, resolution)
            _patch_if_needed(api, check_current, meta, token, thread, body)
            if not thread.get("resolved"):
                _resolve(api, check_current, meta, token, thread["id"], True)
            url = _thread_url(thread)
            if url:
                urls.append(url)

    check_current(meta, token)
    return list(dict.fromkeys(urls))
