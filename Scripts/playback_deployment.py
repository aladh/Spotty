"""Validate the deployment floor recorded in a playback archive's Mach-O objects."""

import argparse
import re
import sys


def version(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", value):
        raise ValueError(f"Invalid macOS deployment version: {value!r}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def validate(minimum: str, declared: str, check_source: bool, load_commands: str) -> None:
    current, artifact = version(minimum), version(declared)
    # Published dependencies may predate the producer's current floor. Local candidates and
    # publication must match it; metadata must never claim support below the actual binary.
    if artifact > current or (check_source and artifact != current):
        raise ValueError(f"Artifact minimum macOS {declared} does not match producer {minimum}")

    versions = []
    field = None
    for line in load_commands.splitlines():
        parts = line.split()
        if field is not None and parts and parts[0] == field and len(parts) != 2:
            raise ValueError("Malformed macOS deployment load command")
        if len(parts) != 2:
            continue
        if parts[0] == "cmd":
            if field is not None:
                raise ValueError("Incomplete macOS deployment load command")
            field = {"LC_BUILD_VERSION": "minos", "LC_VERSION_MIN_MACOSX": "version"}.get(parts[1])
        elif parts[0] == field:
            versions.append(version(parts[1]))
            field = None
    if not versions or field is not None:
        raise ValueError("Static archive has no macOS deployment load command")
    if max(versions) > artifact:
        raise ValueError(f"Static archive requires macOS newer than declared {declared}")
    # Rust's precompiled standard library can retain an older floor. At least one producer
    # object must demonstrate the requested target instead of merely relabeling old objects.
    if check_source and max(versions) != artifact:
        raise ValueError(f"Static archive has no object targeting declared macOS {declared}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minimum", required=True)
    parser.add_argument("--declared", required=True)
    parser.add_argument("--check-source", required=True, choices=("true", "false"))
    args = parser.parse_args()
    try:
        validate(args.minimum, args.declared, args.check_source == "true", sys.stdin.read())
    except ValueError as error:
        parser.exit(1, f"{error}\n")
