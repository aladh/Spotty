#!/usr/bin/env python3
"""Keep one local Instruments recorder owned until the isolated Demo report settles."""
from pathlib import Path
import signal
import subprocess
import sys
import time


# Match the ordinary Demo report watchdog, including long validated scenarios.
WORKLOAD_TIMEOUT_SECONDS = 600
RECORDER_START_TIMEOUT_SECONDS = 50


def interruptible_child():
    # Noninteractive shells start background jobs with SIGINT ignored. xctrace needs
    # its default disposition when launched so it can save a trace on our interrupt.
    signal.signal(signal.SIGINT, signal.SIG_DFL)


def profile(root):
    deadline = time.monotonic() + 10
    while subprocess.run(["pgrep", "-x", "SpottyDemo"], stdout=subprocess.DEVNULL).returncode:
        if time.monotonic() >= deadline:
            raise RuntimeError("Demo did not launch")
        time.sleep(0.1)
    log_path = root / "profiler.log"
    with log_path.open("w") as log:
        recorder = subprocess.Popen(
            ["xcrun", "xctrace", "record", "--template", "Animation Hitches",
             "--attach", "SpottyDemo", "--time-limit",
             f"{WORKLOAD_TIMEOUT_SECONDS + RECORDER_START_TIMEOUT_SECONDS + 10}s",
             "--output", str(root / "animation.trace")],
            stdout=log, stderr=subprocess.STDOUT, preexec_fn=interruptible_child,
        )
        try:
            deadline = time.monotonic() + RECORDER_START_TIMEOUT_SECONDS
            while "Ctrl-C to stop the recording" not in log_path.read_text():
                if recorder.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Profiler did not start; inspect profiler.log")
                time.sleep(0.1)
            (root / "profiler-ready").touch()
            deadline = time.monotonic() + WORKLOAD_TIMEOUT_SECONDS
            while not (root / "report.json").exists():
                if recorder.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Profiler ended before the report; inspect profiler.log")
                time.sleep(0.1)
        finally:
            if recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                try:
                    recorder.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    recorder.terminate()
                    try:
                        recorder.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        recorder.kill()
                        recorder.wait()
                    raise RuntimeError("Profiler did not save after interrupt")
        if recorder.returncode != 0 or "[Error]" in log_path.read_text():
            raise RuntimeError("Profiler failed; inspect profiler.log")


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        profile(Path(sys.argv[1]))
    except (RuntimeError, OSError) as error:
        sys.exit(str(error))
