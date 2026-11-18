"""Run the Rune build or record revision-bound synthetic evidence for review."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess

from browsing_provenance import source_identity

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "Scripts"
MANIFEST = ROOT / "Rune" / "acceptance.json"
SCENARIOS = {"rune.integrated": "check.sh", "playback.transport": "check-transport-traces.sh",
             "rune.reference": "browse-synthetic.sh"}
REFERENCE_FILES = ("reference.json", "reference.png")
SCENARIO_TIMEOUTS = {"rune.integrated": 35 * 60, "playback.transport": 5 * 60, "rune.reference": 5 * 60}


def run_scenario(key, output):
    with (output / f"{key}.log").open("w+") as log:
        try:
            with subprocess.Popen([SCRIPTS / SCENARIOS[key]], cwd=ROOT, start_new_session=True,
                                  stdout=log, stderr=subprocess.STDOUT) as process:
                try:
                    if process.wait(timeout=SCENARIO_TIMEOUTS[key]):
                        return False
                except subprocess.TimeoutExpired as error:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    raise ValueError(f"Scenario exceeded {error.timeout} seconds.") from error
            if key == "rune.reference":
                log.seek(0)
                lines = log.read().rstrip().splitlines()
                if not lines:
                    raise ValueError("The renderer did not report its output directory.")
                capture = Path(lines[-1])
                if any((capture / name).stat().st_size == 0 for name in REFERENCE_FILES):
                    raise ValueError("The renderer produced an empty reference file.")
                for name in REFERENCE_FILES:
                    shutil.copyfile(capture / name, output / name)
        except (OSError, ValueError) as error:
            if key == "rune.reference":
                for name in REFERENCE_FILES:
                    (output / name).unlink(missing_ok=True)
            log.write(f"\nCould not record {key}: {error}\n")
            return False
    return True


def acceptance(output):
    output.mkdir(parents=True, exist_ok=True)
    for name in ("summary.json", *REFERENCE_FILES):
        (output / name).unlink(missing_ok=True)
    before = source_identity(ROOT)
    status_command = ["git", "status", "--porcelain"]
    before_status = subprocess.check_output(status_command, cwd=ROOT)
    dirty = bool(before_status)
    manifest = b""
    manifest_error = None
    try:
        manifest = MANIFEST.read_bytes()
        document = json.loads(manifest)
        entries = document["scenarios"]
        if (type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1
                or not isinstance(entries, list)
                or len(entries) != len(SCENARIOS)
                or {row["id"] for row in entries} != SCENARIOS.keys()
                or any(type(row["version"]) is not int or row["version"] < 1
                       or not isinstance(row["corpus"], str) or not row["corpus"] for row in entries)):
            raise ValueError("Acceptance manifest and its runnable scenarios disagree")
    except (OSError, ValueError, KeyError, TypeError) as error:
        manifest_error = f"Invalid acceptance manifest: {error}"
        entries = []
        print(manifest_error, flush=True)
    results = []
    for row in entries:
        key = row["id"]
        passed = run_scenario(key, output)
        print(f"{key} {'passed' if passed else 'failed'}", flush=True)
        results.append({k: row[k] for k in ("id", "version", "corpus")} |
                       {"outcome": "passed" if passed else "failed"})
    unchanged = (before == source_identity(ROOT)
                 and before_status == subprocess.check_output(status_command, cwd=ROOT))
    passed = manifest_error is None and unchanged and not dirty and all(row["outcome"] == "passed" for row in results)
    summary = {"schemaVersion": 1, "manifestDigest": hashlib.sha256(manifest).hexdigest(),
               "source": {"revision": before["revision"], "trackedDiffDigest": before["diffSHA256"],
                          "dirty": dirty,
                          "prHeadRevision": os.environ.get("SPOTTY_ACCEPTANCE_HEAD_SHA", before["revision"])},
               "sourceUnchanged": unchanged, "outcome": "passed" if passed else "failed", "scenarios": results}
    if manifest_error is not None:
        summary["error"] = manifest_error
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if passed else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("gate", nargs="?", choices=["check", "clean", "traces", "acceptance"], default="check")
    parser.add_argument("--output", default=ROOT / ".build" / "rune-evidence", type=Path)
    args = parser.parse_args()
    if args.gate == "acceptance":
        raise SystemExit(acceptance(args.output.resolve()))
    script = {"check": "check.sh", "clean": "check-clean.sh", "traces": "check-transport-traces.sh"}[args.gate]
    os.execv(SCRIPTS / script, [str(SCRIPTS / script)])
