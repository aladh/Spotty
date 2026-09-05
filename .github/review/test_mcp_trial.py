import importlib.util
import sys
import unittest
sys.path.insert(0, str(__import__("pathlib").Path(__file__).parent))
import json
from pathlib import Path
import tempfile
from unittest import TestCase, mock


SPEC = importlib.util.spec_from_file_location("mcp_trial", Path(__file__).with_name("mcp_trial.py"))
mcp_trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mcp_trial)


HEAD = "a" * 40
META = {"owner": "aladh", "name": "Spotty", "repo": "aladh/Spotty", "pr": 268,
        "base": "b" * 40, "head": HEAD, "run": 17, "attempt": 2,
        "title": "fixture", "body": "", "body_truncated": False}


def tool(name, value, output="ok"):
    return {"type": "tool_use", "part": {"tool": name,
            "state": {"status": "completed", "input": value, "output": output}}}


def direct_events(**changes):
    marker = f"<!-- spotty-opencode-mcp:v1 run={META['run']} attempt={META['attempt']} head={HEAD} -->"
    create = {"method": "create", "owner": META["owner"], "repo": META["name"],
              "pullNumber": META["pr"], "commitID": HEAD, "event": "COMMENT",
              "body": marker + "\nOpenCode GitHub MCP experiment (Actions, advisory)\n"
                     "Verdict: clean\nCorrectness: clean\nQuality: clean\nLimits: fixture\nHead: " + HEAD}
    tasks = [tool("task", {"subagent_type": role}, "<task_result>{}</task_result>".format(role))
             for role in mcp_trial.ROLES]
    events = [{"type": "step_start"}, *tasks, tool("github_pull_request_review_write", create),
              {"type": "text", "part": {"text": "published"}},
              {"type": "step_finish", "part": {"reason": "stop"}}]
    for event in events:
        if event.get("type") == "tool_use" and event["part"]["tool"] == "task":
            event["part"]["state"]["input"].update(changes.get("task", {}))
    return events


class MCPTrialTests(TestCase):
    def test_attach_diffs_keeps_distinct_inputs_and_deduplicates_equal(self):
        separate = mcp_trial.attach_diffs("audit", "FULL", "DELTA")
        self.assertEqual(separate.count("FULL"), 1)
        self.assertEqual(separate.count("DELTA"), 1)
        self.assertIn("UNTRUSTED", separate)
        same = mcp_trial.attach_diffs("audit", "FULL", "FULL")
        self.assertEqual(same.count("FULL"), 1)
        self.assertIn("byte-identical", same)

    def test_parse_events_rejects_non_object_json(self):
        with self.assertRaises(ValueError):
            mcp_trial.parse_events(b"[]\n")

    def test_validate_events_accepts_two_foreground_children_and_comment(self):
        mcp_trial.validate_events(direct_events(), META)

    def test_validate_events_rejects_background_child_or_stale_write(self):
        with self.assertRaises(ValueError):
            mcp_trial.validate_events(direct_events(task={"background": True}), META)
        events = direct_events()
        events[3]["part"]["state"]["input"]["commitID"] = "c" * 40
        with self.assertRaises(ValueError):
            mcp_trial.validate_events(events, META)

    def test_bounded_diff_refuses_oversized_output(self):
        with mock.patch.object(mcp_trial, "git", return_value=b"x" * (mcp_trial.MAX_DIFF + 1)):
            with self.assertRaises(ValueError):
                mcp_trial.bounded_diff(Path("/tmp/repo"), META["base"], META["head"])

    def test_export_failure_and_timeout_redact_token_from_artifact(self):
        token = "super-secret-token"
        payload = json.dumps({"token": token}, separators=(",", ":"))

        def write_payload(stdout):
            stdout.write(payload)
            stdout.flush()

        def failed_export(command, **kwargs):
            write_payload(kwargs["stdout"])
            return mcp_trial.subprocess.CompletedProcess(command, 1)

        def timed_out_export(command, **kwargs):
            write_payload(kwargs["stdout"])
            raise mcp_trial.subprocess.TimeoutExpired(command, 60)

        cases = (
            ("ses_failed", failed_export, ValueError),
            ("ses_timeout", timed_out_export, mcp_trial.subprocess.TimeoutExpired),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            (root / "runtime").mkdir()
            for session, side_effect, error in cases:
                with self.subTest(session=session), mock.patch.object(
                    mcp_trial.subprocess, "run", side_effect=side_effect
                ):
                    with self.assertRaises(error):
                        mcp_trial.export_session(Path("/tmp/opencode"), session, root, {}, output, token)
                artifact = (output / (session + ".json")).read_bytes()
                self.assertNotIn(token.encode(), artifact)
                self.assertIn(b"[REDACTED]", artifact)

    def test_oversized_export_writes_safe_placeholder(self):
        token = "super-secret-token"
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(mcp_trial, "MAX_EVENTS", 8):
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            (root / "runtime").mkdir()

            def oversized_export(command, **kwargs):
                kwargs["stdout"].write(token + "-overflow")
                kwargs["stdout"].flush()
                return mcp_trial.subprocess.CompletedProcess(command, 0)

            with mock.patch.object(mcp_trial.subprocess, "run", side_effect=oversized_export):
                with self.assertRaises(ValueError):
                    mcp_trial.export_session(Path("/tmp/opencode"), "ses_oversized", root, {}, output, token)

            artifact = (output / "ses_oversized.json").read_bytes()
            self.assertEqual(artifact, b'{"error":"export missing or oversized"}')
            self.assertNotIn(token.encode(), artifact)

    def test_config_exposes_only_parent_mcp_and_child_deny(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(mcp_trial.os.environ, {"MODEL": "opencode/muse", "VARIANT": "xhigh"}):
                path = mcp_trial.config(META, Path("/tmp/github-mcp"), "FULL", "FULL", Path(directory))
            data = json.loads(path.read_text())
            self.assertNotIn("environment", data["mcp"]["github"])
            self.assertEqual(data["mcp"]["github"]["command"][-1],
                             "--tools=add_comment_to_pending_review,get_file_contents,pull_request_read,pull_request_review_write")
            self.assertEqual(data["agent"]["thermos-parent"]["permission"]["github_pull_request_review_write"], "allow")
            for role in mcp_trial.ROLES:
                self.assertEqual(data["agent"][role]["permission"]["*"], "deny")
                self.assertNotIn("github_pull_request_review_write", data["agent"][role]["permission"])


    def test_export_completion_and_child_permissions_are_required(self):
        events = direct_events()
        for event in events: event["sessionID"] = "ses_root"
        exports = {}
        for session, role in [("ses_root", "thermos-parent"), ("ses_correct", mcp_trial.ROLES[0]), ("ses_quality", mcp_trial.ROLES[1])]:
            exports[session] = {"info": {"id": session, "agent": role, "parentID": "ses_root",
                "model": {"providerID": "opencode", "id": "muse", "variant": "xhigh"},
                "time": {"created": 1}}, "messages": [{"info": {"role": "assistant", "finish": "stop",
                "providerID": "opencode", "modelID": "muse", "variant": "xhigh", "time": {"completed": 3}},
                "parts": [{"type": "text", "text": json.dumps({"summary": "audited", "findings": [], "resolved": []})}]}]}
        for event, session in zip(events[1:3], ("ses_correct", "ses_quality")):
            event["part"]["state"]["metadata"] = {"sessionId": session}
        mcp_trial.validate_sessions(events, exports, "opencode/muse", "xhigh")
        exports["ses_quality"]["messages"][0]["parts"].append({"type": "tool", "tool": "bash"})
        with self.assertRaises(ValueError): mcp_trial.validate_sessions(events, exports, "opencode/muse", "xhigh")
        exports["ses_quality"]["messages"][0]["parts"].pop()
        exports["ses_root"]["messages"][0]["info"]["finish"] = "error"
        with self.assertRaises(ValueError): mcp_trial.validate_sessions(events, exports, "opencode/muse", "xhigh")

    def test_validate_sessions_gates_root_discussion_on_correctness_severity(self):
        def session_fixtures(findings):
            events = direct_events()
            for event in events:
                event["sessionID"] = "ses_root"
            exports = {}
            for session, role in [("ses_root", "thermos-parent"), ("ses_correct", mcp_trial.ROLES[0]),
                                  ("ses_quality", mcp_trial.ROLES[1])]:
                exports[session] = {"info": {"id": session, "agent": role, "parentID": "ses_root",
                    "model": {"providerID": "opencode", "id": "muse", "variant": "xhigh"},
                    "time": {"created": 1}}, "messages": [{"info": {"role": "assistant", "finish": "stop",
                    "providerID": "opencode", "modelID": "muse", "variant": "xhigh", "time": {"completed": 3}},
                    "parts": [{"type": "text", "text": json.dumps({"summary": "audited", "findings": findings if role == mcp_trial.ROLES[0] else [], "resolved": []})}]}]}
            for event, session in zip(events[1:3], ("ses_correct", "ses_quality")):
                event["part"]["state"]["metadata"] = {"sessionId": session}
            discussions = [tool("github_pull_request_read", {"owner": META["owner"], "repo": META["name"],
                "pullNumber": META["pr"], "method": method, "perPage": 20})
                for method in ("get_comments", "get_reviews", "get_review_comments")]
            events[3:3] = discussions
            return events, exports

        events, exports = session_fixtures([])
        mcp_trial.validate_events(events, META)
        with self.assertRaises(ValueError):
            mcp_trial.validate_sessions(events, exports, "opencode/muse", "xhigh")
        for severity in ("P1", "P2"):
            events, exports = session_fixtures([{"severity": severity}])
            mcp_trial.validate_sessions(events, exports, "opencode/muse", "xhigh")

    def test_file_reads_require_exact_head(self):
        events = direct_events()
        events.insert(1, tool("github_get_file_contents", {"owner": META["owner"], "repo": META["name"], "ref": "main"}))
        with self.assertRaises(ValueError): mcp_trial.validate_events(events, META)
        events[1]["part"]["state"]["input"]["sha"] = HEAD
        mcp_trial.validate_events(events, META)


    def test_untrusted_config_templates_are_literal(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(mcp_trial.os.environ, {"MODEL": "opencode/muse"}):
            payload = "{env:GH_TOKEN} {file:/tmp/private}"
            path = mcp_trial.config(META, Path("/tmp/github-mcp"), payload, payload, Path(directory))
            raw = path.read_text()
            self.assertNotIn("{env:", raw)
            self.assertNotIn("{file:", raw)
            decoded = json.loads(raw)
            self.assertIn(payload, decoded["agent"][mcp_trial.ROLES[0]]["prompt"])


if __name__ == "__main__":
    unittest.main()
