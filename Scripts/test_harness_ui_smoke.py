"""Exercise the Rune UI smoke wrapper through its two executable entry points."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class UISmokeWrapperChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="spotty smoke ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / "Scripts"
        tools = self.root / "bin"
        for directory in (scripts, tools, self.root / "Rune"):
            directory.mkdir()
        self.command = scripts / "smoke-synthetic-ui.sh"
        shutil.copy2(Path(__file__).with_name(self.command.name), self.command)
        self.trace = self.root / "trace.jsonl"
        for name, path in (("cargo", tools / "cargo"), ("browse", scripts / "browse-synthetic.sh")):
            path.write_text(f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
with open(os.environ['SPOTTY_SMOKE_TRACE'], 'a') as out:
    out.write(json.dumps([{name!r}, Path.cwd().name, *sys.argv[1:]]) + '\\n')
sys.exit(int(os.environ.get('SPOTTY_SMOKE_{name.upper()}_STATUS', '0')))
""")
            path.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
                    "SPOTTY_SMOKE_TRACE": str(self.trace)}

    def run_wrapper(self, cargo=0, browse=0):
        process = subprocess.run([str(self.command), "--size", "960x640"], capture_output=True,
                                 env={**self.env, "SPOTTY_SMOKE_CARGO_STATUS": str(cargo),
                                      "SPOTTY_SMOKE_BROWSE_STATUS": str(browse)}, timeout=10)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        return process.returncode, calls

    def test_runs_the_locked_suite_then_forwards_render_arguments_once(self):
        status, calls = self.run_wrapper()
        self.assertEqual(status, 0)
        self.assertEqual(calls, [["cargo", "Rune", "test", "--locked", "--bin", "spotty-rune", "tests::"],
                                 ["browse", "Rune", "--size", "960x640"]])

    def test_failed_tests_prevent_rendering(self):
        status, calls = self.run_wrapper(cargo=37)
        self.assertEqual(status, 37)
        self.assertEqual([call[0] for call in calls], ["cargo"])

    def test_failed_renderer_returns_its_status_without_a_retry(self):
        status, calls = self.run_wrapper(browse=41)
        self.assertEqual(status, 41)
        self.assertEqual([call[0] for call in calls], ["cargo", "browse"])


if __name__ == "__main__":
    unittest.main()
