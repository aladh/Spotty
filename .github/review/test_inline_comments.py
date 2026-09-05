import unittest

import inline_comments


REPO = "acme/spotty"
PATH = "Sources/Changed.swift"
OLD_PATH = "Sources/Old.swift"
BASE = "b" * 40
HEAD = "a" * 40
FINDING_ID = "F0123456789ab"


def meta(**overrides):
    value = {
        "repo": REPO,
        "pr": 268,
        "base": BASE,
        "head": HEAD,
        "changed": [PATH, OLD_PATH],
        "files": {PATH: 4, OLD_PATH: 4},
        "diff_lines": {PATH: [1, 2, 3], OLD_PATH: [1, 2]},
    }
    value.update(overrides)
    return value


def finding(identity=FINDING_ID, path=PATH, line=2, body="The changed code can fail."):
    return {
        "id": identity,
        "path": path,
        "line": line,
        "severity": "P2",
        "title": "A concrete bug",
        "body": body,
    }


def result(findings=(), resolved=()):
    return {"summary": "Advisory review", "findings": list(findings), "resolved": list(resolved)}


def marker(identity=FINDING_ID):
    return f"{inline_comments.INLINE_MARKER_PREFIX} id={identity} -->"


def thread(
    identity=FINDING_ID,
    path=PATH,
    line=2,
    *,
    resolved=False,
    outdated=False,
    author="github-actions",
    author_type="Bot",
    body=None,
    comment_id=41,
    url="https://github.example/pull/268#discussion_r41",
    side="RIGHT",
    replies=(),
    reply_author="github-actions",
    reply_author_type="Bot",
    commit=HEAD,
):
    comments = [
        {
            "id": str(comment_id),
            "databaseId": comment_id,
            "fullDatabaseId": str(comment_id),
            "body": body if body is not None else marker(identity) + "\n\nOld text",
            "author": {"login": author, "__typename": author_type},
            "replyTo": None,
            "path": path,
            "line": line,
            "outdated": outdated,
            "commit": {"oid": commit},
            "url": url,
        }
    ]
    for offset, reply in enumerate(replies, start=1):
        comments.append(
            {
                "id": str(comment_id + offset),
                "databaseId": comment_id + offset,
                "fullDatabaseId": str(comment_id + offset),
                "body": reply,
                "author": {"login": reply_author, "__typename": reply_author_type},
                "replyTo": {"id": str(comment_id)},
                "path": path,
                "line": line,
                "outdated": outdated,
                "commit": {"oid": HEAD},
                "url": url + f"/reply{offset}",
            }
        )
    return {
        "id": f"thread-{comment_id}",
        "isResolved": resolved,
        "isOutdated": outdated,
        "path": path,
        "line": line,
        "diffSide": side,
        "comments": {"nodes": comments, "pageInfo": {"hasNextPage": False, "endCursor": None}},
    }


class FakeGitHub:
    def __init__(self, threads=()):
        self.threads = list(threads)
        self.calls = []
        self.created = []
        self.patched = []
        self.replies = []
        self.resolutions = []
        self.unresolutions = []

    def api(self, path, token, method="GET", data=None):
        self.calls.append((path, method, data))
        if path == "graphql" and method == "POST":
            query = data["query"]
            if "reviewThreads" in query:
                return {
                    "data": {
                        "repository": {
                            "pullRequest": {
                                "reviewThreads": {
                                    "nodes": self.threads,
                                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                                }
                            }
                        }
                    }
                }
            if "unresolveReviewThread" in query:
                self.unresolutions.append(data["variables"]["threadId"])
                return {"data": {"unresolveReviewThread": {"thread": {"isResolved": False}}}}
            if "resolveReviewThread" in query:
                self.resolutions.append(data["variables"]["threadId"])
                return {"data": {"resolveReviewThread": {"thread": {"isResolved": True}}}}
            raise AssertionError("unexpected GraphQL query")
        if method == "POST" and path.endswith("/comments"):
            self.created.append(data)
            return {"id": 99, "html_url": "https://github.example/pull/268#discussion_r99"}
        if method == "PATCH" and "/pulls/comments/" in path:
            self.patched.append((path, data))
            return {"html_url": "https://github.example/pull/268#discussion_r41"}
        if method == "POST" and path.endswith("/replies"):
            self.replies.append((path, data))
            return {"html_url": "https://github.example/pull/268#discussion_r42"}
        raise AssertionError(f"unexpected API call: {path} {method}")


class InlineCommentTests(unittest.TestCase):
    def setUp(self):
        self.checks = []

    def check_current(self, current=True):
        def check(meta_value, token):
            self.checks.append((meta_value["head"], token))
            if not current:
                raise ValueError("PR moved or closed; refusing stale review publication")

        return check

    def test_initial_create_uses_current_head_right_anchor(self):
        github = FakeGitHub()
        urls = inline_comments.sync(meta(), result([finding()]), "token", github.api,
                                    self.check_current())

        self.assertEqual(urls, ["https://github.example/pull/268#discussion_r99"])
        self.assertEqual(len(github.created), 1)
        payload = github.created[0]
        self.assertEqual(payload["commit_id"], HEAD)
        self.assertEqual(payload["path"], PATH)
        self.assertEqual(payload["line"], 2)
        self.assertEqual(payload["side"], "RIGHT")
        self.assertEqual(inline_comments.marker_id(payload["body"]), FINDING_ID)
        self.assertEqual(len(self.checks), 2)  # before the write and after the batch

    def test_same_finding_updates_owned_current_thread_without_duplicate(self):
        existing = thread(body=marker() + "\n\nOld text")
        github = FakeGitHub([existing])
        value = finding(body="The updated explanation.")
        urls = inline_comments.sync(meta(), result([value]), "token", github.api,
                                    self.check_current())

        self.assertEqual(urls, [existing["comments"]["nodes"][0]["url"]])
        self.assertEqual(github.created, [])
        self.assertEqual(len(github.patched), 1)
        self.assertEqual(github.patched[0][0], "repos/acme/spotty/pulls/comments/41")
        self.assertIn(HEAD, github.patched[0][1]["body"])
        self.assertEqual(github.replies, [])
        self.assertEqual(github.resolutions, [])

    def test_same_anchor_on_old_commit_creates_current_comment(self):
        existing = thread(commit=BASE, body=marker() + "\n\nOld text")
        github = FakeGitHub([existing])
        urls = inline_comments.sync(meta(), result([finding()]), "token", github.api,
                                    self.check_current())

        self.assertEqual(urls, ["https://github.example/pull/268#discussion_r99"])
        self.assertEqual(len(github.created), 1)
        self.assertEqual(github.created[0]["commit_id"], HEAD)
        self.assertEqual(github.patched, [])
        self.assertEqual(len(github.replies), 1)
        self.assertEqual(github.resolutions, ["thread-41"])

    def test_reopened_resolved_finding_unresolves_and_updates_owned_thread(self):
        existing = thread(resolved=True, body=marker() + "\n\nOld text")
        github = FakeGitHub([existing])
        value = finding(body="The reopened explanation.")
        urls = inline_comments.sync(meta(), result([value]), "token", github.api,
                                    self.check_current())

        self.assertEqual(urls, [existing["comments"]["nodes"][0]["url"]])
        self.assertEqual(github.created, [])
        self.assertEqual(github.unresolutions, ["thread-41"])
        self.assertEqual(github.resolutions, [])
        self.assertEqual(len(github.patched), 1)
        self.assertIn("reopened explanation", github.patched[0][1]["body"])

    def test_moved_finding_creates_new_anchor_then_supersedes_old_owned_thread(self):
        old = thread(path=OLD_PATH, line=1, outdated=True)
        github = FakeGitHub([old])
        urls = inline_comments.sync(meta(), result([finding(path=PATH, line=2)]), "token", github.api,
                                    self.check_current())

        self.assertEqual(urls, ["https://github.example/pull/268#discussion_r99"])
        self.assertEqual(len(github.created), 1)
        self.assertEqual(github.created[0]["commit_id"], HEAD)
        self.assertEqual(len(github.replies), 1)
        self.assertIn("superseded", github.replies[0][1]["body"])
        self.assertEqual(github.replies[0][0], "repos/acme/spotty/pulls/268/comments/41/replies")
        self.assertEqual(github.resolutions, ["thread-41"])

    def test_graphql_ownership_requires_bot_type_and_exact_login(self):
        lookalikes = [
            thread(author=inline_comments.GRAPHQL_BOT_LOGIN, author_type="User"),
            thread(author=inline_comments.BOT, author_type=inline_comments.GRAPHQL_BOT_TYPE,
                   comment_id=42),
            thread(author="coderabbitai", author_type=inline_comments.GRAPHQL_BOT_TYPE,
                   comment_id=43),
        ]
        github = FakeGitHub(lookalikes)
        inline_comments.sync(meta(), result([finding()]), "token", github.api, self.check_current())

        self.assertEqual(len(github.created), 1)
        self.assertEqual(github.patched, [])
        self.assertEqual(github.replies, [])
        self.assertEqual(github.resolutions, [])

    def test_supersession_reply_ownership_requires_graphql_bot_identity(self):
        superseded = f"<!-- spotty-opencode-inline-superseded:v1 id={FINDING_ID} head={HEAD} -->"
        owned = thread(path=OLD_PATH, line=1, outdated=True, replies=(superseded,))
        github = FakeGitHub([owned])
        inline_comments.sync(meta(), result([finding()]), "token", github.api, self.check_current())
        self.assertEqual(github.replies, [])

        lookalike = thread(path=OLD_PATH, line=1, outdated=True, replies=(superseded,),
                           reply_author_type="User")
        github = FakeGitHub([lookalike])
        inline_comments.sync(meta(), result([finding()]), "token", github.api, self.check_current())
        self.assertEqual(len(github.replies), 1)

    def test_explicit_resolution_updates_and_resolves_only_owned_thread(self):
        existing = thread()
        github = FakeGitHub([existing])
        urls = inline_comments.sync(
            meta(), result(resolved=[{"id": FINDING_ID, "reason": "The source removed the failing branch."}]),
            "token", github.api, self.check_current()
        )

        self.assertEqual(urls, [existing["comments"]["nodes"][0]["url"]])
        self.assertEqual(len(github.patched), 1)
        self.assertIn("resolved", github.patched[0][1]["body"])
        self.assertIn("removed the failing branch", github.patched[0][1]["body"])
        self.assertEqual(github.resolutions, ["thread-41"])
        self.assertEqual(github.created, [])

    def test_explicit_resolution_reconciles_all_owned_copies(self):
        old = thread(comment_id=41, path=OLD_PATH, line=1, outdated=True)
        current = thread(comment_id=42, path=PATH, line=2, resolved=False,
                         url="https://github.example/pull/268#discussion_r42")
        github = FakeGitHub([old, current])
        urls = inline_comments.sync(
            meta(), result(resolved=[{"id": FINDING_ID, "reason": "The source removed the failing branch."}]),
            "token", github.api, self.check_current()
        )

        self.assertEqual(len(urls), 2)
        self.assertEqual(len(github.patched), 2)
        self.assertEqual(github.resolutions, ["thread-41", "thread-42"])

    def test_human_and_other_bot_threads_are_never_mutated(self):
        other_bot = thread(author="coderabbitai[bot]")
        quoted = thread(author=inline_comments.GRAPHQL_BOT_LOGIN,
                        body="quoted text\n" + marker() + "\nquoted marker")
        github = FakeGitHub([other_bot, quoted])
        inline_comments.sync(meta(), result([finding()]), "token", github.api, self.check_current())

        self.assertEqual(len(github.created), 1)
        self.assertEqual(github.patched, [])
        self.assertEqual(github.replies, [])
        self.assertEqual(github.resolutions, [])

    def test_stale_revision_refuses_before_first_write(self):
        github = FakeGitHub()
        with self.assertRaises(ValueError):
            inline_comments.sync(meta(), result([finding()]), "token", github.api,
                                 self.check_current(current=False))
        self.assertEqual(github.created, [])
        self.assertEqual(github.patched, [])
        self.assertEqual(github.replies, [])
        self.assertEqual(github.resolutions, [])

    def test_finding_must_use_right_side_diff_anchor(self):
        github = FakeGitHub()
        invalid = finding(line=4)
        with self.assertRaises(ValueError):
            inline_comments.sync(meta(), result([invalid]), "token", github.api, self.check_current())
        self.assertEqual(github.calls, [])
        self.assertEqual(self.checks, [])


if __name__ == "__main__":
    unittest.main()
