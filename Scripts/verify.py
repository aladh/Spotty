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

from verification_package import TEST_TARGETS, prepare as prepare_package, workspace


ROOT = Path(__file__).resolve().parents[1]
GATES = {
    "check": ("check.sh", "full"),
    "swift": ("check.sh", "swift"),
    "rust": ("check.sh", "rust"),
    "source": ("check-source-policy.sh", None),
    "clean": ("check-clean.sh", "full"),
}
COMPILER_ARGUMENT_OPTIONS = frozenset(("-Xswiftc", "-Xcc", "-Xcxx", "-Xlinker", "-Xbuild-tools-swiftc"))


SWIFTPM_VALUE_OPTIONS = COMPILER_ARGUMENT_OPTIONS | frozenset((
    "--filter", "--skip", "--test-product", "--package-path", "--scratch-path",
    "--configuration", "-c", "--jobs", "-j", "--num-workers", "--triple", "--sdk",
    "--toolchain", "--swift-sdk", "--experimental-swift-sdk", "--arch", "--sanitize",
    "--build-system", "--cache-path", "--config-path", "--security-path",
    "--multiroot-data-file", "--netrc-file", "--resolver-fingerprint-checking",
    "--resolver-signing-entity-checking", "--default-registry-url", "--traits",
    "--xunit-output", "--event-stream-output-path",
))


def swiftpm_options(arguments: list[str]):
    """Walk top-level options once; compiler/filter/path operands stay opaque."""
    values = iter(arguments)
    for argument in values:
        if argument == "--":
            yield "--", None
            break
        key, separator, value = argument.partition("=")
        if not separator and key in SWIFTPM_VALUE_OPTIONS:
            value = next(values, None)
        yield key, value


def target_selection(arguments: list[str]) -> tuple[str | None, list[str]]:
    """Consume only the leading repository selector; never reinterpret SwiftPM operands."""
    target = None
    remaining = arguments
    if arguments[:1] == ["--target"]:
        if len(arguments) < 2 or not arguments[1] or arguments[1].startswith("-"):
            raise ValueError("--target requires one test module name")
        target, remaining = arguments[1], arguments[2:]
    elif arguments and arguments[0].startswith("--target="):
        target, remaining = arguments[0].partition("=")[2], arguments[1:]
        if not target:
            raise ValueError("--target requires one test module name")
    if target is not None:
        if target not in TEST_TARGETS:
            raise ValueError(f"Unknown --target {target!r}; choose one of: {', '.join(TEST_TARGETS)}")
        for key, _ in swiftpm_options(remaining):
            if key == "--target":
                raise ValueError("--target must be specified exactly once, immediately after test or list")
            if key == "--package-path":
                raise ValueError("--target owns its package root and cannot be combined with --package-path; "
                                 "use test --package-path PATH --filter MODULE.SUITE instead")
            if key == "--test-product":
                raise ValueError("--target cannot be combined with --test-product; it selects one test module directly")
    return target, remaining


def inspects_tests(arguments: list[str]) -> bool:
    """Recognize inspection at SwiftPM's level, not inside forwarded option values."""
    if arguments[:1] in (["list"], ["last"]):
        return True
    inspection_options = {
        "--help", "--help-hidden", "-h", "-help", "--version", "--list-tests", "-l",
        "--show-codecov-path", "--show-code-coverage-path", "--show-coverage-path",
    }
    return any(key in inspection_options for key, _ in swiftpm_options(arguments))


def focused_graph(arguments: list[str]) -> str:
    """Select only unambiguous, repository-owned products using the default workspace."""
    products = []
    for key, value in swiftpm_options(arguments):
        if key in ("--", "--package-path", "--scratch-path"):
            return "full"
        if key in COMPILER_ARGUMENT_OPTIONS and value is None:
            return "full"
        if key == "--test-product":
            products.append(value)
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
  test       Watchdog-backed swift test; --target MODULE selects its dependency closure
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
  python3 Scripts/verify.py test --target SpottyGatewayTests --filter KeymasterPersistence
  python3 Scripts/verify.py rust

Place --target NAME or --target=NAME immediately after test/list. It selects exactly one
existing test module plus its declared dependencies, using ordinary swift test on Swift 6.3.3/6.4.
Remaining arguments pass literally to SwiftPM; repeated filters retain SwiftPM union semantics.
Selected listing/help retains that graph. --target owns an isolated package and cannot be combined
with --package-path or --test-product. A selected --scratch-path is forwarded without broadening.
Without --target, explicit paths retain the caller's graph; legacy target-named --test-product
needs Swift 6.4. Complete gates and shipping builds keep the full graph. These commands do not launch
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

    selected = None
    if args.command in ("test", "list"):
        try:
            selected, args.arguments = target_selection(args.arguments)
        except ValueError as error:
            parser.error(str(error))
        if selected is not None and sys.platform != "darwin" and selected != "SpottyDomainTests":
            parser.error(f"--target {selected} requires macOS; SpottyDomainTests is portable")

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
        if selected is not None:
            graph = f"test-target:{selected}"
            # The manifest's package root changes; a local artifact still belongs to the
            # repository from which the wrapper delegates, including relative overrides.
            override = environment.get("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK")
            if override is not None:
                environment["SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"] = str(ROOT / override)
        elif args.command == "test" and not inspection and sys.platform == "darwin":
            graph = focused_graph(args.arguments)
        environment["SPOTTY_BUILD_BROWSING_HARNESS"] = "1" if graph == "full" else "0"
        command = ["swift", "test"]
        if args.command == "list":
            command.append("list")
        else:
            command.append("--no-parallel")
        try:
            package = prepare_package(ROOT, graph) if graph != "full" else ROOT
        except (ValueError, OSError) as error:
            parser.error(str(error))
        command += ["--disable-sandbox", "--package-path", str(package), *args.arguments]
        if graph != "full" and not any(key == "--scratch-path" for key, _ in swiftpm_options(args.arguments)):
            command += ["--scratch-path", str(workspace(ROOT, graph))]
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
