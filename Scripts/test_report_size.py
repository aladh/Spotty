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
        (scripts / "playback-xcframework.sh").write_text("""
spotty_playback_resolve_xcframework() { printf '%s\\n' "$SIZE_TEST_FRAMEWORK"; }
spotty_playback_validate_xcframework() { test -d "$1"; }
spotty_playback_slice_path() { printf '%s\\n' "$1/macos-arm64"; }
spotty_playback_archive_path() { printf '%s\\n' "$1/libtest.a"; }
""")
        self.framework = self.root / "selected.xcframework"
        self.archive = self.framework / "macos-arm64/libtest.a"
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b"archive" * 5)
        self.binary = self.root / "Spotty"
        self.binary.write_bytes(b"binary" * 7)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for name in ("dirname", "basename", "mkdir", "awk", "grep", "cat"):
            (self.tools / name).symlink_to(shutil.which(name))
        (self.tools / "python3").symlink_to(sys.executable)
        self.tool("stat", "from pathlib import Path\nprint(Path(sys.argv[-1]).stat().st_size)")
        self.tool("size", "print('Segment __TEXT: 12\\nSegment __DATA: 34\\nSegment __LINKEDIT: 56')")
        self.tool("nm", "print('00000001 T _one\\n00000002 T _two')")
        self.output = self.root / "reports"
        self.summary = self.root / "summary.md"
        self.environment = {
            **os.environ, "PATH": str(self.tools), "SIZE_TEST_FRAMEWORK": str(self.framework),
            "GITHUB_STEP_SUMMARY": str(self.summary),
        }
        self.environment.pop("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK", None)

    def tool(self, name, body):
        path = self.tools / name
        path.write_text(f"#!{sys.executable}\nimport sys\n{body}\n")
        path.chmod(0o755)

    def report(self):
        result = subprocess.run(
            ["/bin/bash", str(self.command), "--binary", str(self.binary), "--out-dir", str(self.output)],
            env=self.environment, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.output / "size-report.json").read_text()), result

    def test_json_preserves_paths_and_numeric_measurements(self):
        self.prepare('quoted " checkout\\name\nwith unicode é')
        report, result = self.report()
        self.assertEqual(report["binary_path"], str(self.binary))
        self.assertEqual(report["xcframework_path"], str(self.framework))
        self.assertEqual(report["archive_path"], str(self.archive))
        self.assertEqual(report["binary_bytes"], 42)
        self.assertEqual(report["archive_bytes"], 35)
        self.assertEqual(report["binary_segments"], {
            "available": True, "text_bytes": 12, "data_bytes": 34, "linkedit_bytes": 56,
        })
        self.assertEqual(report["archive_exported_symbols"], {"available": True, "count": 2})
        self.assertIn("| App binary | 42 bytes", result.stdout)
        self.assertIn("| Binary __TEXT | 12 bytes", self.summary.read_text())

    def test_missing_optional_tools_leave_valid_unavailable_measurements(self):
        self.prepare()
        (self.tools / "size").unlink()
        (self.tools / "nm").unlink()
        report, result = self.report()
        self.assertEqual(report["binary_segments"], {
            "available": False, "text_bytes": None, "data_bytes": None, "linkedit_bytes": None,
        })
        self.assertEqual(report["archive_exported_symbols"], {"available": False, "count": None})
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
