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

from verification_package import prepare as prepare_package


ROOT = Path(__file__).resolve().parents[1]
GATES = {
    "check": ("check.sh", "full"),
    "swift": ("check.sh", "swift"),
    "rust": ("check.sh", "rust"),
    "source": ("check-source-policy.sh", None),
    "clean": ("check-clean.sh", "full"),
}
COMPILER_ARGUMENT_OPTIONS = frozenset(("-Xswiftc", "-Xcc", "-Xcxx", "-Xlinker", "-Xbuild-tools-swiftc"))


def inspects_tests(arguments: list[str]) -> bool:
    """Recognize inspection at SwiftPM's level, not inside forwarded option values."""
    if arguments[:1] in (["list"], ["last"]):
        return True
    inspection_options = {
        "--help", "--help-hidden", "-h", "-help", "--version", "--list-tests", "-l",
        "--show-codecov-path", "--show-code-coverage-path", "--show-coverage-path",
    }
    value_options = COMPILER_ARGUMENT_OPTIONS | {
        "--filter", "--skip", "--test-product", "--package-path", "--scratch-path",
    }
    values = iter(arguments)
    for argument in values:
        if argument == "--":
            break
        if argument in value_options:
            next(values, None)
        elif argument in inspection_options:
            return True
    return False


def focused_graph(arguments: list[str]) -> str:
    """Select only unambiguous, repository-owned products using the default workspace."""
    products = []
    values = iter(arguments)
    for argument in values:
        if argument == "--" or argument.split("=", 1)[0] in ("--package-path", "--scratch-path"):
            return "full"
        if argument in COMPILER_ARGUMENT_OPTIONS:
            if next(values, None) is None:  # A compiler option is not a SwiftPM graph selector.
                return "full"
        elif argument in ("--filter", "--skip"):
            next(values, None)
        elif argument == "--test-product":
            products.append(next(values, None))
        elif argument.startswith("--test-product="):
            products.append(argument.partition("=")[2])
    if len(products) != 1:
        return "full"
    return {
        "SpottyDomainTests": "domain",
        "SpottyGatewayTests": "engine-free",
        "SpottyCatalogStorageTests": "engine-free",
        "SpottyTestSupportTests": "engine-free",
    }.get(products[0], "full")


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
        for name in ("SPOTTY_CHECK_SCOPE", "SPOTTY_BUILD_BROWSING_HARNESS", "SPOTTY_PACKAGE_GRAPH")
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
  test       Watchdog-backed swift test; use --filter for portable test selection
  domain     Isolated portable domain tests; no app or engine dependencies
  swift      Existing Swift gate against the selected playback artifact
  rust       Existing Python playback/harness and compiled Rust/header checks
  harness    Existing synthetic browsing, measurement, and trace helper checks
  source     Existing source, topology, documentation, and script policy checks
  check      Complete normal gate (never narrowed by SPOTTY_CHECK_SCOPE)
  clean      Existing clean Debug-and-Release gate; use only for a needed rebuild

Examples:
  python3 Scripts/verify.py list
  python3 Scripts/verify.py domain --filter PlaybackReducer
  python3 Scripts/verify.py test --filter SpottyBoundaryTests.PlaybackPositionSliderChecks
  python3 Scripts/verify.py rust

list/test/domain forward remaining arguments to SwiftPM. Target-named --test-product needs
Swift 6.4; Swift 6.3 combines test targets into one product. Explicit package/scratch paths
retain the caller's graph; default named products use isolated caches. Focused checks optimize local
iteration; Scripts/check.sh remains the complete gate. These commands do not launch
apps, sign in, or start playback. Setup: docs/development/verification.md
""",
    )
    parser.add_argument("command", choices=("preflight", "list", "test", "domain", "harness", *GATES), nargs="?")
    parser.add_argument("arguments", nargs=argparse.REMAINDER, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0
    # argparse already consumes this CLI's separator. A remaining "--" belongs to SwiftPM.
    if args.command not in ("list", "test", "domain") and args.arguments:
        parser.error(f"{args.command} takes no arguments")
    if args.command == "preflight":
        return preflight()

    environment = os.environ.copy()
    environment["SPOTTY_CHECK_PHASE"] = "all"
    environment["SPOTTY_PACKAGE_GRAPH"] = "full"
    artifacts = None
    if args.command in ("test", "domain", "check", "swift", "clean"):
        configured = environment.get("SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR")
        artifacts = Path(configured).resolve() if configured else Path(tempfile.mkdtemp(prefix="spotty-verification-"))
        environment["SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR"] = str(artifacts)
    if args.command in ("list", "test", "domain"):
        inspection = inspects_tests(args.arguments)
        graph = "domain" if args.command == "domain" else "full"
        if args.command == "test" and not inspection and sys.platform == "darwin":
            graph = focused_graph(args.arguments)
        environment["SPOTTY_BUILD_BROWSING_HARNESS"] = "1" if graph == "full" else "0"
        command = ["swift", "test"]
        if args.command == "list":
            command.append("list")
        else:
            command.append("--no-parallel")
        package = prepare_package(ROOT, graph) if graph != "full" else ROOT
        command += ["--disable-sandbox", "--package-path", str(package), *args.arguments]
        if graph != "full" and not any(arg.split("=", 1)[0] == "--scratch-path" for arg in args.arguments):
            command += ["--scratch-path", str(ROOT / ".build" / graph)]
        if args.command != "list":
            command = [
                sys.executable, str(ROOT / "Scripts/swift_test_watchdog.py"),
                "--lane", "focused", "--repetition", "1",
                "--timeout-seconds", environment.get("SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS")
                or ("300" if environment.get("CI") else "1200"),
                "--log-dir", str(artifacts),
                "--event-stream-path", str(artifacts / "focused-repeat-1-events.jsonl"),
                *([] if inspection else ["--require-tests"]),
                "--", *command,
            ]
    elif args.command == "harness":
        command = [sys.executable, "-B", str(ROOT / "Scripts/script_tests.py"), "harness"]
    else:
        script, scope = GATES[args.command]
        command = [str(ROOT / "Scripts" / script)]
        if scope is not None:
            environment["SPOTTY_CHECK_SCOPE"] = scope
    if args.command in ("list", "test", "domain"):
        if graph != "full":
            # Override only after swiftpm-env.sh has reset ambient graph selectors. The
            # watchdog still launches Swift directly and receives its original argument list.
            command = ["env", f"SPOTTY_PACKAGE_GRAPH={graph}", *command]
        if sys.platform == "darwin":
            # Use the gate's SDK, module caches, and warning policy. Pass argv separately so
            # filters and paths remain literal; the watchdog still sees a direct Swift command.
            command = ["zsh", "-eu", "-c",
                       'project_root="$PWD"; source Scripts/swiftpm-env.sh; '
                       'exec "$@" "${spotty_swiftc_warnings_as_errors[@]}"',
                       "verify", *command]
        else:
            command += ["-Xswiftc", "-warnings-as-errors"]
    return run(command, environment, artifacts)


if __name__ == "__main__":
    raise SystemExit(main())
