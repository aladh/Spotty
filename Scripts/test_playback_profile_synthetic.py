"""Recorder lifetime checks without Instruments, a display, or an app process."""
from pathlib import Path
import signal
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import profile_synthetic


class SyntheticProfileTests(unittest.TestCase):
    def test_long_workload_finishes_before_recorder_deadline(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            clock = {"now": 0.0}
            interrupts = []
            save_timeouts = []

            class Recorder:
                returncode = None

                def __init__(self, command, stdout, **kwargs):
                    self.deadline = float(command[command.index("--time-limit") + 1].removesuffix("s"))
                    stdout.write("Ctrl-C to stop the recording\n")
                    stdout.flush()

                def poll(self):
                    if clock["now"] >= self.deadline:
                        self.returncode = 0
                    return self.returncode

                def send_signal(self, value):
                    interrupts.append(value)
                    self.returncode = 0

                def wait(self, timeout):
                    save_timeouts.append(timeout)
                    if timeout < 90:
                        raise profile_synthetic.subprocess.TimeoutExpired("xctrace", timeout)
                    return self.returncode

            def sleep(seconds):
                clock["now"] += seconds
                # A supported long scenario outlasts the old 110/120-second limits.
                if clock["now"] >= 244:
                    (root / "report.json").write_text('{"passed": true}')

            with (
                patch.object(profile_synthetic.subprocess, "run", return_value=SimpleNamespace(returncode=0)),
                patch.object(profile_synthetic.subprocess, "Popen", Recorder),
                patch.object(profile_synthetic.time, "monotonic", side_effect=lambda: clock["now"]),
                patch.object(profile_synthetic.time, "sleep", side_effect=sleep),
            ):
                profile_synthetic.profile(root)

            self.assertTrue((root / "profiler-ready").exists())
            self.assertTrue((root / "report.json").exists())
            self.assertEqual(interrupts, [signal.SIGINT])
            self.assertEqual(save_timeouts, [profile_synthetic.RECORDER_SAVE_TIMEOUT_SECONDS])
