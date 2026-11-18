"""Run the size-report entry point with synthetic artifacts and portable tool fixtures."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SizeReportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve()

    def prepare(self, name="checkout"):
        self.root = self.parent / name
        scripts = self.root / "Scripts"
        scripts.mkdir(parents=True)
        self.command = scripts / "report-size.sh"
        shutil.copy2(ROOT / "Scripts/report-size.sh", self.command)
        self.binary = self.root / "Rune" / "target" / "release" / "spotty-rune"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"binary" * 7)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for name in ("dirname", "mkdir"):
            (self.tools / name).symlink_to(shutil.which(name))
        (self.tools / "python3").symlink_to(sys.executable)
        self.tool("size", "print('Segment __TEXT: 12\\nSegment __DATA: 34\\nSegment __LINKEDIT: 56')")
        self.output = self.root / "reports"
        self.summary = self.root / "summary.md"
        self.environment = {
            **os.environ, "PATH": str(self.tools),
            "GITHUB_STEP_SUMMARY": str(self.summary),
        }
        self.environment.pop("CARGO_TARGET_DIR", None)

    def tool(self, name, body):
        path = self.tools / name
        path.write_text(f"#!{sys.executable}\nimport sys\n{body}\n")
        path.chmod(0o755)

    def report(self, *, locate_binary=False):
        arguments = [] if locate_binary else ["--binary", str(self.binary)]
        result = subprocess.run(
            ["/bin/bash", str(self.command), *arguments, "--out-dir", str(self.output)],
            env=self.environment, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.output / "size-report.json").read_text()), result

    def test_default_binary_lookup_uses_the_rune_release_target(self):
        self.prepare()
        report, _ = self.report(locate_binary=True)
        self.assertEqual(report["binary_path"], str(self.binary))

    def test_json_preserves_paths_and_numeric_measurements(self):
        self.prepare('quoted " checkout\\name\nwith unicode é')
        report, result = self.report()
        self.assertEqual(report["binary_path"], str(self.binary))
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["binary_bytes"], 42)
        self.assertEqual(report["binary_segments"], {
            "available": True, "text_bytes": 12, "data_bytes": 34, "linkedit_bytes": 56,
        })
        self.assertIn("| App binary | 42 bytes", result.stdout)
        self.assertIn("| Binary __TEXT | 12 bytes", self.summary.read_text())

    def test_missing_optional_tools_leave_valid_unavailable_measurements(self):
        self.prepare()
        (self.tools / "size").unlink()
        report, result = self.report()
        self.assertEqual(report["binary_segments"], {
            "available": False, "text_bytes": None, "data_bytes": None, "linkedit_bytes": None,
        })
        self.assertIn("unavailable", result.stdout)

    def test_malformed_optional_size_output_is_unavailable(self):
        self.prepare()
        self.tool("size", "print('Segment __TEXT: unknown\\nSegment __DATA: 34\\nSegment __LINKEDIT: 56')")
        report, result = self.report()
        self.assertEqual(report["binary_segments"], {
            "available": False, "text_bytes": None, "data_bytes": None, "linkedit_bytes": None,
        })
        self.assertIn("Binary segments | unavailable", result.stdout)


if __name__ == "__main__":
    unittest.main()
