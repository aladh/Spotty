"""Preserve unchanged Swift inputs across CI checkouts without hiding source edits."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


MANIFEST = Path(".build/ci-source-mtimes.json")


def inputs(root):
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    for name in paths:
        if name in {"Package.swift", "Package.resolved"} or name.startswith(("Sources/", "Tests/")):
            path = root / name
            # Never follow symlinks, including a symlinked parent directory.
            if path.is_file() and not any(part.is_symlink() for part in [path, *path.parents]):
                yield name, path


def snapshot(root):
    return {
        name: {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mtime_ns": path.stat().st_mtime_ns}
        for name, path in inputs(root)
    }


def restore(root, saved):
    restored = 0
    for name, path in inputs(root):
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
    args = parser.parse_args()
    root = Path.cwd().resolve()
    manifest = root / MANIFEST
    if args.operation == "save":
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps(snapshot(root), sort_keys=True) + "\n")
    else:
        try:
            saved = json.loads(manifest.read_text())
            if not isinstance(saved, dict):
                raise ValueError("invalid manifest")
        except (OSError, ValueError):
            print("No usable Swift timestamp manifest; compiling with checkout timestamps")
            return
        print(f"Restored timestamps for {restore(root, saved)} content-matched Swift inputs")


if __name__ == "__main__":
    main()
