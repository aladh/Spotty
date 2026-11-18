"""Run the real shell gate with controlled tools to check execution and failure propagation."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GATES = {
    "python3 -B Scripts/documentation_policy.py": "documentation",
    "ruby Scripts/check-ci-workflow.rb .github/workflows/ci.yml": "workflow",
    "ast-grep test --filter <rules> --skip-snapshot-tests": "source-fixtures",
    "python3 -B Scripts/test_source_policy.py": "routing",
    "python3 -B Scripts/test_rune_workflow_policy.py": "workflow-fixtures",
    "python3 -B -m unittest discover -s Scripts -p test_source_gate_policy.py": "gate",
    "python3 -B Scripts/test_notices_policy.py": "notices",
    "python3 -B Scripts/test_verify.py": "acceptance",
    "python3 -B Scripts/test_harness_ui_smoke.py": "smoke",
    "python3 -B Scripts/test_report_size.py": "size",
    "python3 -B Scripts/test_ci_timings.py": "timing",
    "npm test --prefix Scripts/agent-review-tests": "review",
    "ast-grep scan --filter <rules> .github/workflows Scripts script Rune": "scan",
}


class SourceGateExecutionTests(unittest.TestCase):
    def run_gate(self, *, ci, failing=None, source=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "Scripts"
            (scripts / "ast-grep").mkdir(parents=True)
            gate = scripts / "check-source-policy.sh"
            gate.write_text(source if source is not None else (ROOT / "Scripts/check-source-policy.sh").read_text())
            shutil.copy2(ROOT / "Scripts/ast-grep/version", scripts / "ast-grep/version")
            (scripts / "ast-grep/required-files.txt").write_text("README.md\n")
            for name in ("README.md", "SECURITY.md", "CONTRIBUTING.md"):
                (root / name).write_text("Fixture document.\n")
            tools = root / "tools"
            tools.mkdir()
            log = root / "gates.log"
            stub = f"""#!{sys.executable}
import os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
if name == "ast-grep" and sys.argv[1:] == ["--version"]:
    print("ast-grep " + Path("Scripts/ast-grep/version").read_text().strip())
    raise SystemExit(0)
args = sys.argv[1:]
if name == "ast-grep" and len(args) >= 3 and args[1] == "--filter":
    args[2] = "<rules>"
gate = {GATES!r}.get(" ".join([name, *args]))
if gate is None:
    raise SystemExit("Unexpected gate invocation")
with Path(os.environ["SPOTTY_GATE_LOG"]).open("a") as output:
    output.write(gate + "\\n")
raise SystemExit(17 if gate == os.environ["SPOTTY_FAILING_GATE"] else 0)
"""
            for name in ("python3", "npm", "ast-grep", "ruby"):
                path = tools / name
                path.write_text(stub)
                path.chmod(0o755)
            environment = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                           "SPOTTY_AST_GREP": str(tools / "ast-grep"), "SPOTTY_GATE_LOG": str(log),
                           "SPOTTY_FAILING_GATE": failing or ""}
            if ci:
                environment["CI"] = "true"
            else:
                environment.pop("CI", None)
            result = subprocess.run(["bash", str(gate), *(["--test-only"] if ci else [])],
                                    cwd=root, env=environment, capture_output=True, text=True, timeout=10)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_success_runs_every_gate_in_order(self):
        for ci in (False, True):
            with self.subTest(ci=ci):
                result, ran = self.run_gate(ci=ci)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(ran, list(GATES.values())[:(-1 if ci else None)])

    def test_each_failure_stops_local_and_ci_execution(self):
        for ci in (False, True):
            gates = list(GATES.values())[:(-1 if ci else None)]
            for index, failing in enumerate(gates):
                with self.subTest(ci=ci, failing=failing):
                    result, ran = self.run_gate(ci=ci, failing=failing)
                    self.assertEqual(result.returncode, 17, result.stderr)
                    self.assertEqual(ran, gates[:index + 1])
