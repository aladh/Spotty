"""Preserve unchanged compiler inputs across CI checkouts without hiding source edits."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


MANIFESTS = {
    "swift": Path(".build/ci-source-mtimes.json"),
    "rust": Path("Backend/spotty-playback/target/release/ci-source-mtimes.json"),
}


def inputs(root, scope="swift"):
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    for name in paths:
        selected = (
            name in {"Package.swift", "Package.resolved"} or name.startswith(("Sources/", "Tests/"))
            if scope == "swift"
            else name == "rust-toolchain.toml" or name.startswith("Backend/spotty-playback/")
        )
        if selected:
            path = root / name
            # Never follow symlinks, including a symlinked parent directory.
            if path.is_file() and not any(part.is_symlink() for part in [path, *path.parents]):
                yield name, path


def snapshot(root, scope="swift"):
    return {
        name: {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mtime_ns": path.stat().st_mtime_ns}
        for name, path in inputs(root, scope)
    }


def restore(root, saved, scope="swift"):
    restored = 0
    for name, path in inputs(root, scope):
        entry = saved.get(name)
        if not isinstance(entry, dict):
            continue
        timestamp = entry.get("mtime_ns")
        if type(timestamp) is not int or not 0 < timestamp <= path.stat().st_mtime_ns:
            continue
        if entry.get("sha256") != hashlib.sha256(path.read_bytes()).hexdigest():
            continue
        os.utime(path, ns=(path.stat().st_atime_ns, timestamp))
        restored += 1
    return restored


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("save", "restore"))
    parser.add_argument("--scope", choices=MANIFESTS, default="swift")
    args = parser.parse_args()
    root = Path.cwd().resolve()
    manifest = root / MANIFESTS[args.scope]
    if args.operation == "save":
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps(snapshot(root, args.scope), sort_keys=True) + "\n")
    else:
        try:
            saved = json.loads(manifest.read_text())
            if not isinstance(saved, dict):
                raise ValueError("invalid manifest")
        except (OSError, ValueError):
            print("No usable source timestamp manifest; compiling with checkout timestamps")
            return
        print(f"Restored timestamps for {restore(root, saved, args.scope)} content-matched {args.scope} inputs")


if __name__ == "__main__":
    main()
