"""Run the Rune build or record revision-bound synthetic evidence for review."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from browsing_provenance import source_identity

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "Scripts"
MANIFEST = ROOT / "Rune" / "acceptance.json"
SCENARIOS = {"rune.integrated": "check.sh", "playback.transport": "check-transport-traces.sh",
             "rune.reference": "browse-synthetic.sh"}
REFERENCE_FILES = ("reference.json", "reference.png")


def run_scenario(key, output):
    with (output / f"{key}.log").open("w") as log:
        try:
            result = subprocess.run([SCRIPTS / SCENARIOS[key]], cwd=ROOT, text=True,
                                    stderr=log, stdout=subprocess.PIPE)
            log.write(result.stdout)
            if result.returncode:
                return False
            if key == "rune.reference":
                lines = result.stdout.rstrip().splitlines()
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
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))
    manifest = MANIFEST.read_bytes()
    entries = json.loads(manifest)["scenarios"]
    if {row["id"] for row in entries} != SCENARIOS.keys() or len(entries) != len(SCENARIOS):
        raise ValueError("Acceptance manifest and its runnable scenarios disagree")
    results = []
    for row in entries:
        key = row["id"]
        passed = run_scenario(key, output)
        print(f"{key} {'passed' if passed else 'failed'}", flush=True)
        results.append({k: row[k] for k in ("id", "version", "corpus")} |
                       {"outcome": "passed" if passed else "failed"})
    unchanged = before == source_identity(ROOT)
    passed = unchanged and all(row["outcome"] == "passed" for row in results)
    summary = {"schemaVersion": 1, "manifestDigest": hashlib.sha256(manifest).hexdigest(),
               "source": {"revision": before["revision"], "trackedDiffDigest": before["diffSHA256"],
                          "dirty": dirty,
                          "prHeadRevision": os.environ.get("SPOTTY_ACCEPTANCE_HEAD_SHA", before["revision"])},
               "sourceUnchanged": unchanged, "outcome": "passed" if passed else "failed", "scenarios": results}
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
