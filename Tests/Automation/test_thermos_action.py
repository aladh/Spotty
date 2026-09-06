"""Exercise the official-action adapter without GitHub or model requests."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ADAPTER = Path(__file__).resolve().parents[2] / ".github/thermos-review/action-entrypoint.sh"


class ThermosActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="thermos-action-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "source").mkdir()
        tools = self.root / "thermos-tools"
        tools.mkdir()
        shutil.copyfile(ADAPTER, tools / "opencode")
        (tools / "opencode").chmod(0o700)
        pinned = self.root / "thermos-cli/node_modules/.bin/opencode"
        pinned.parent.mkdir(parents=True)
        pinned.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['CAPTURE']).write_text(json.dumps({"
            "'args':sys.argv[1:], 'cwd':os.getcwd(),"
            "'gh_token':os.environ.get('GH_TOKEN'),"
            "'oidc':os.environ.get('ACTIONS_ID_TOKEN_REQUEST_TOKEN')}))\n"
            "print('1.18.29' if sys.argv[1:] == ['--version'] else 'private review output')\n"
            "print('private diagnostic', file=sys.stderr)\n"
            "sys.exit(int(os.environ.get('MOCK_EXIT', '0')))\n"
        )
        pinned.chmod(0o700)
        upstream = self.root / "upstream-bin"
        upstream.mkdir()
        (upstream / "opencode").write_text("#!/bin/sh\nexit 99\n")
        (upstream / "opencode").chmod(0o700)
        bash_env = self.root / "action-env.sh"
        bash_env.write_text(f'export PATH="{tools}:$PATH"\n')
        self.env = os.environ | {
            "BASH_ENV": str(bash_env),
            "PATH": str(upstream) + os.pathsep + os.environ["PATH"],
            "RUNNER_TEMP": str(self.root),
            "GITHUB_WORKSPACE": str(self.root),
            "GH_TOKEN": "synthetic-app-token",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "synthetic-oidc-request",
            "ACTIONS_ID_TOKEN_REQUEST_URL": "https://example.invalid/oidc",
            "CAPTURE": str(self.root / "capture.json"),
        }

    def run_action(self, arguments, exit_code=0):
        result = subprocess.run(
            ["bash", "-c", 'opencode "$@"', "action", *arguments],
            env=self.env | {"MOCK_EXIT": str(exit_code)},
            capture_output=True,
            text=True,
        )
        captured = json.loads((self.root / "capture.json").read_text())
        return result, captured

    def test_github_mode_uses_pinned_cli_and_hides_output(self):
        result, captured = self.run_action(["github", "run"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(captured["args"], ["--pure", "github", "run"])
        self.assertEqual(Path(captured["cwd"]).resolve(), (self.root / "source").resolve())
        self.assertEqual(captured["gh_token"], "synthetic-app-token")
        self.assertIsNone(captured["oidc"])
        self.assertEqual(result.stdout + result.stderr, "")
        self.assertIn("private diagnostic", (self.root / "thermos-review.log").read_text())

    def test_review_failure_is_preserved_without_exposing_diagnostics(self):
        result, _ = self.run_action(["github", "run"], exit_code=7)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout + result.stderr, "")

    def test_installer_version_probe_uses_pinned_cli(self):
        result, captured = self.run_action(["--version"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(captured["args"], ["--version"])
        self.assertEqual(result.stdout.strip(), "1.18.29")


if __name__ == "__main__":
    unittest.main()
