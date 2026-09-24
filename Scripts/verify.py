#!/usr/bin/env python3
"""Discover tools and delegate focused verification to the repository's existing owners."""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
GATES = {
    "check": ("check.sh", "full"),
    "swift": ("check.sh", "swift"),
    "rust": ("check.sh", "rust"),
    "source": ("check-source-policy.sh", None),
    "clean": ("check-clean.sh", "full"),
}


def preflight() -> int:
    """Discover executable paths without running tools, installing tools, or opening apps."""
    groups = {
        "Shared gate tools": ("python3", "zsh", "xcrun", "clang", "git", "rg"),
        "Swift gate": ("swift", "ruby"),
        "Source policies": ("bash", "node", "npm", "jq", "ast-grep"),
        "Rust gate": ("cargo", "cbindgen"),
    }
    overrides = {
        "cargo": "SPOTTY_CARGO", "cbindgen": "SPOTTY_CBINDGEN", "ast-grep": "SPOTTY_AST_GREP",
    }
    # Delegated gates run at ROOT, including relative override paths and PATH entries.
    search_path = os.pathsep.join(str(ROOT / entry) for entry in os.get_exec_path())
    missing = False
    for group, names in groups.items():
        print(f"{group}:")
        for name in names:
            override = os.environ.get(overrides.get(name, ""))
            requested = override or name
            # Cargo/cbindgen gates require executable paths, while ast-grep also accepts a PATH name.
            if (override and name in ("cargo", "cbindgen")) or os.path.dirname(requested):
                requested = str(ROOT / requested)
            executable = shutil.which(requested, path=search_path)
            if name == "cargo" and not executable and requested == "cargo":
                executable = shutil.which(
                    "/private/tmp/spotty-rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo"
                )
            print(f"  {name}: {executable or 'missing'}")
            missing |= executable is None
    print("Discovery only; gates validate versions, the selected SDK, and dependencies.")
    print("Setup: docs/development/setup.md; gate requirements: docs/development/verification.md")
    return 1 if missing else 0


def run(command: list[str], environment: dict[str, str], artifacts: Path | None = None) -> int:
    settings = [
        f"{name}={environment[name]}"
        for name in ("SPOTTY_CHECK_SCOPE", "SPOTTY_BUILD_BROWSING_HARNESS")
        if name in environment
    ]
    displayed = shlex.join([*(["env", *settings] if settings else []), *command])
    print(f"Running: {displayed}", flush=True)
    try:
        result = subprocess.run(command, cwd=ROOT, env=environment)
        status = result.returncode if result.returncode >= 0 else 128 - result.returncode
    except OSError as error:
        print(f"Could not launch command: {error}", file=sys.stderr)
        status = 127
    except KeyboardInterrupt:
        status = 130
    if status:
        print(f"Failed delegated command (exit {status}): {displayed}", file=sys.stderr)
    if artifacts is not None:
        print(f"Swift test diagnostics (when produced): {artifacts}", flush=True)
    return status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Commands:
  preflight  Read-only discovery of local gate tools; no installation or launch
  list       swift test list, including the synthetic browsing harness
  test       Watchdog-backed swift test; pass standard SwiftPM filters/options
  swift      Existing Swift gate against the selected playback artifact
  rust       Existing Python playback/harness and compiled Rust/header checks
  harness    Existing synthetic browsing, measurement, and trace helper checks
  source     Existing source, topology, documentation, and script policy checks
  check      Complete normal gate (never narrowed by SPOTTY_CHECK_SCOPE)
  clean      Existing clean Debug-and-Release gate; use only for a needed rebuild

Examples:
  python3 Scripts/verify.py list
  python3 Scripts/verify.py test --filter ProtobufTests/testProtobuf
  python3 Scripts/verify.py test --skip-build --filter AuthFlowTests/testAuthFlow
  python3 Scripts/verify.py rust

list/test forward remaining arguments to SwiftPM. Focused checks optimize local
iteration; Scripts/check.sh remains the complete gate. These commands do not launch
apps, sign in, or start playback. Setup: docs/development/verification.md
""",
    )
    parser.add_argument("command", choices=("preflight", "list", "test", "harness", *GATES), nargs="?")
    parser.add_argument("arguments", nargs=argparse.REMAINDER, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0
    if args.arguments[:1] == ["--"]:
        args.arguments = args.arguments[1:]
    if args.command not in ("list", "test") and args.arguments:
        parser.error(f"{args.command} takes no arguments")
    if args.command == "preflight":
        return preflight()

    environment = os.environ.copy()
    artifacts = None
    if args.command in ("test", "check", "swift", "clean"):
        configured = environment.get("SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR")
        artifacts = Path(configured).resolve() if configured else Path(tempfile.mkdtemp(prefix="spotty-verification-"))
        environment["SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR"] = str(artifacts)
    if args.command in ("list", "test"):
        environment["SPOTTY_BUILD_BROWSING_HARNESS"] = "1"
        command = ["swift", "test"]
        if args.command == "list":
            command.append("list")
        else:
            command.append("--no-parallel")
        command += ["--disable-sandbox", "--package-path", str(ROOT), *args.arguments]
        if args.command == "test":
            command = [
                sys.executable, str(ROOT / "Scripts/swift_test_watchdog.py"),
                "--lane", "focused", "--repetition", "1",
                "--timeout-seconds", environment.get("SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS")
                or ("300" if environment.get("CI") else "1200"),
                "--log-dir", str(artifacts),
                "--event-stream-path", str(artifacts / "focused-repeat-1-events.jsonl"),
                "--", *command,
            ]
    elif args.command == "harness":
        command = [sys.executable, "-B", str(ROOT / "Scripts/script_tests.py"), "harness"]
    else:
        script, scope = GATES[args.command]
        command = [str(ROOT / "Scripts" / script)]
        if scope is not None:
            environment["SPOTTY_CHECK_SCOPE"] = scope
    return run(command, environment, artifacts)


if __name__ == "__main__":
    raise SystemExit(main())
