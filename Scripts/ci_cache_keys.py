"""Bound CI restores to actual compiler and fixed build-contract compatibility.

The Rust result is a prefix only: callers append the complete playback input digest for
the exact cache. A compatible restore never proves final archive freshness; Cargo and
the hash-checked source timestamp policy still own recompilation.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess


SCHEMA = 1
SWIFT_LANES = ("contracts", "tests", "release")
SWIFT_BUILD_INPUTS = (
    "Package.swift", "Package.resolved", "Scripts/swiftpm-env.sh", "Scripts/check.sh",
    "Scripts/compile-release-spotty.sh", "Scripts/verification_package.py", "Scripts/ci_cache_keys.py",
    "Sources/SpottyPlaybackCore/include/module.modulemap",
    "Sources/SpottyPlaybackCore/include/spotty_playback.h",
    "Sources/SpottyPlaybackCore/include/spotty_playback_annotations.h",
    "Sources/SpottyPlaybackCore/include/spotty_playback_generated.h",
)
RUST_BUILD_INPUTS = (
    "rust-toolchain.toml", "Scripts/ci_cache_keys.py",
    "Backend/spotty-playback/Cargo.toml", "Backend/spotty-playback/Cargo.lock",
    "Backend/spotty-playback/build.sh", "Backend/spotty-playback/build-xcframework.sh",
    "Backend/spotty-playback/macos-deployment-target",
    "Sources/SpottyPlaybackCore/include/module.modulemap",
    "Sources/SpottyPlaybackCore/include/spotty_playback.h",
    "Sources/SpottyPlaybackCore/include/spotty_playback_annotations.h",
    "Sources/SpottyPlaybackCore/include/spotty_playback_generated.h",
)
RUST_OPTIONAL_INPUTS = (".cargo/config", ".cargo/config.toml")
RUST_FIXED_FLAGS = "-C target-cpu=apple-m1 --cfg aes_armv8"
RUST_TARGET = "aarch64-apple-darwin"
FORBIDDEN_RUST_ENV = (
    "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER",
    "RUSTC_BOOTSTRAP",
    "CARGO_BUILD_RUSTFLAGS", "CARGO_BUILD_TARGET", "CARGO_BUILD_RUSTC_WRAPPER",
    "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER", "CC", "CXX", "AR", "CFLAGS", "CXXFLAGS",
    "CPPFLAGS", "LDFLAGS", "CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER",
    "CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS",
)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def command(arguments, root):
    try:
        result = subprocess.run(arguments, cwd=root, check=True, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        # Tool diagnostics and environment contents are not a public identity surface.
        raise ValueError(f"Unable to read {Path(arguments[0]).name} toolchain identity") from error
    return result.stdout.strip()


def field(text, pattern, name):
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"Expected one canonical {name} toolchain field")
    return matches[0]


def sdk_path(scope, root, probe, environment):
    if scope == "swift":
        # Keep this selection aligned with swiftpm-env.sh, which overwrites SDKROOT.
        compatible = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
        if compatible.is_dir():
            return str(compatible)
    elif environment.get("SDKROOT"):
        return environment["SDKROOT"]
    return probe(["xcrun", "--show-sdk-path"], root)


def sdk_identity(path):
    root = Path(path)
    settings = (root / "SDKSettings.json").read_bytes()
    metadata = json.loads(settings)
    system = plistlib.loads((root / "System/Library/CoreServices/SystemVersion.plist").read_bytes())
    # Xcode's xcrun cannot inspect every standalone CLT SDK selected by swiftpm-env.sh.
    # Read the selected SDK's own version/build, rather than reporting Xcode's default SDK.
    return {
        "sdk": field(str(metadata.get("Version", "")), r"^([0-9]+(?:\.[0-9]+)*)$", "SDK version"),
        "sdk_build": field(str(system.get("ProductBuildVersion", "")), r"^([A-Za-z0-9.]+)$", "SDK build"),
        "sdk_settings": hashlib.sha256(settings).hexdigest(),
    }


def toolchain_identity(scope, root, *, probe=command, environment=None, machine=None, read_sdk=sdk_identity):
    environment = os.environ if environment is None else environment
    architecture = machine or platform.machine()
    if architecture not in ("arm64", "aarch64", "x86_64"):
        raise ValueError("Unsupported CI host architecture")
    xcode = probe(["xcodebuild", "-version"], root)
    selected_sdk = sdk_path(scope, root, probe, environment)
    clang = probe(["xcrun", "clang", "--version"], root)
    identity = {
        "architecture": architecture,
        "xcode": field(xcode, r"^Xcode ([0-9]+(?:\.[0-9]+)*)$", "Xcode version"),
        "xcode_build": field(xcode, r"^Build version ([A-Za-z0-9.]+)$", "Xcode build"),
        "clang": field(clang, r"^Apple clang version ([0-9]+(?:\.[0-9]+)*) ", "Clang version"),
        "clang_build": field(clang, r"\((clang-[A-Za-z0-9.+_-]+)\)", "Clang build"),
        "clang_target": field(clang, r"^Target: ([A-Za-z0-9._-]+)$", "Clang target"),
        **read_sdk(selected_sdk),
    }
    if scope == "swift":
        swift = probe(["swift", "--version"], root)
        identity.update({
            "swift": field(swift, r"(?:^| )Swift version ([0-9]+(?:\.[0-9]+)*) ", "Swift version"),
            "swift_build": field(swift, r"\((swift(?:lang)?-[A-Za-z0-9.+_-]+(?: clang-[A-Za-z0-9.+_-]+)?)\)",
                                 "Swift compiler build"),
            "swift_target": field(swift, r"^Target: ([A-Za-z0-9._-]+)$", "Swift target"),
        })
    else:
        rust = probe([environment.get("RUSTC") or "rustc", "-vV"], root)
        cargo_path = environment.get("SPOTTY_CARGO") or "cargo"
        cargo = probe([cargo_path, "-vV"], root)
        identity.update({
            "rust": field(rust, r"^release: ([0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9._-]+)?)$", "Rust version"),
            "rust_commit": field(rust, r"^commit-hash: ([0-9a-f]{40})$", "Rust compiler commit"),
            "rust_host": field(rust, r"^host: ([A-Za-z0-9._-]+)$", "Rust host"),
            "rust_llvm": field(rust, r"^LLVM version: ([0-9]+(?:\.[0-9]+)*)$", "Rust LLVM version"),
            "cargo": field(cargo, r"^cargo ([0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9._-]+)?) ", "Cargo version"),
            "cargo_commit": field(cargo, r"^commit-hash: ([0-9a-f]{40})$", "Cargo commit"),
            "cargo_host": field(cargo, r"^host: ([A-Za-z0-9._-]+)$", "Cargo host"),
        })
    return identity


def regular_input(root, name, *, optional=False):
    path = root / name
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError(f"Cache contract input must not be a symlink: {name}")
    if not path.is_file():
        if optional and not path.exists():
            return None
        raise ValueError(f"Cache contract input is missing: {name}")
    content = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(128 * 1024), b""):
            content.update(chunk)
    return content.hexdigest()


def input_identity(root, names, *, optional=()):
    return {name: regular_input(root, name, optional=name in optional) for name in sorted(set(names))}


def rust_compatible_inputs(root):
    """Exclude only root bridge Rust sources; keep every local dependency and build script."""
    backend = root / "Backend/spotty-playback"
    if not backend.is_dir() or backend.is_symlink():
        raise ValueError("Missing regular playback crate directory")
    paths = list(RUST_BUILD_INPUTS) + list(RUST_OPTIONAL_INPUTS)
    for directory, children, files in os.walk(backend, followlinks=False):
        children[:] = sorted(child for child in children if child != "target")
        for child in children:
            if (Path(directory) / child).is_symlink():
                raise ValueError("Playback cache inputs must not contain symlink directories")
        for name in files:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if relative.startswith("Backend/spotty-playback/src/") and path.suffix == ".rs":
                continue
            paths.append(relative)
    # Explicit absences matter when Cargo acquires a new root build script/configuration.
    optional = (*RUST_OPTIONAL_INPUTS, "Backend/spotty-playback/build.rs",
                "Backend/spotty-playback/.cargo/config", "Backend/spotty-playback/.cargo/config.toml")
    paths.extend(optional)
    return input_identity(root, paths, optional=optional)


def cargo_configuration(environment):
    cargo_home = Path(environment.get("CARGO_HOME") or Path.home() / ".cargo").resolve()
    result = {}
    for name in ("config", "config.toml"):
        path = cargo_home / name
        if any(part.is_symlink() for part in (path, *path.parents)):
            raise ValueError("Cargo user configuration must not be a symlink")
        if path.exists() and not path.is_file():
            raise ValueError("Cargo user configuration must be a regular file")
        result[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return result


def playback_pin(manifest):
    return {
        "url": field(manifest, r'generatedPlaybackArtifactURL\s*=\s*"(https://github\.com/aladh/Spotty/releases/download/playback-v[0-9]+\.[0-9]+\.[0-9]+/SpottyPlaybackCore\.xcframework\.zip)"',
                     "published playback URL"),
        "checksum": field(manifest, r'generatedPlaybackArtifactChecksum\s*=\s*"([0-9a-f]{64})"',
                          "published playback checksum"),
    }


def deployment_target(manifest):
    versions = set(re.findall(r"\.macOS\(\.v([0-9]+(?:_[0-9]+)*)\)", manifest))
    if len(versions) != 1:
        raise ValueError("Expected one fixed manifest macOS deployment target")
    return next(iter(versions)).replace("_", ".")


def cache_keys(scope, root, identity, *, lane=None, build_system="default", revision=None, environment=None):
    environment = os.environ if environment is None else environment
    toolchain_key = digest(identity)
    common = {"schema": SCHEMA, "toolchain": identity}
    if scope == "swift":
        if lane not in SWIFT_LANES or build_system not in ("default", "xcode", "native"):
            raise ValueError("Swift cache requires a supported lane and build system")
        if environment.get("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"):
            raise ValueError("CI Swift caches require the published playback pin")
        if environment.get("SPOTTY_SIGNING_IDENTITY"):
            raise ValueError("CI Swift caches require the compile-only unsigned contract")
        configuration = "release" if lane == "release" else environment.get("SPOTTY_BUILD_CONFIGURATION", "debug")
        if configuration not in ("debug", "release"):
            raise ValueError("Invalid Swift build configuration")
        inputs = input_identity(root, SWIFT_BUILD_INPUTS)
        manifest = (root / "Package.swift").read_text()
        common.update({"inputs": inputs, "lane": lane, "build_system": build_system,
                       "deployment": deployment_target(manifest), "playback": playback_pin(manifest),
                       "flags": ["--disable-sandbox", "-Xswiftc", "-warnings-as-errors"],
                       "configuration": configuration, "distribution": lane == "release", "graph": "full"})
        revision = revision or command(["git", "rev-parse", "HEAD"], root)
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("Swift exact cache requires a full Git revision")
        prefix = f"macos-swiftpm-v2-{lane}-{digest(common)}-"
        values = {"SWIFT_CACHE_KEY": f"{prefix}{revision}", "SWIFT_CACHE_PREFIX": prefix,
                  "SWIFT_TOOLCHAIN_KEY": toolchain_key}
    elif scope == "rust":
        for name in FORBIDDEN_RUST_ENV:
            if environment.get(name):
                raise ValueError(f"Unsupported reproducible release override: {name}")
        if any(name.startswith("CARGO_PROFILE_RELEASE_") for name in environment):
            raise ValueError("Release profile overrides must be declared in Cargo.toml")
        minimum = (root / "Backend/spotty-playback/macos-deployment-target").read_text().strip()
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", minimum):
            raise ValueError("Invalid playback macOS deployment target")
        if environment.get("MACOSX_DEPLOYMENT_TARGET", minimum) != minimum:
            raise ValueError("Playback deployment override disagrees with the producer")
        common.update({"inputs": rust_compatible_inputs(root), "target": RUST_TARGET,
                       "deployment": minimum, "profile": "release", "features": "manifest-default",
                       "flags": RUST_FIXED_FLAGS, "locked": True,
                       "incremental": environment.get("CARGO_INCREMENTAL", "manifest-default"),
                       "cargo_configuration": cargo_configuration(environment)})
        values = {"RUST_RELEASE_COMPATIBILITY_KEY": f"macos-rust-release-v3-{digest(common)}",
                  "RUST_TOOLCHAIN_KEY": toolchain_key}
    else:
        raise ValueError("Unsupported cache scope")
    return {**values, "toolchain_identity": identity}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scope", choices=("swift", "rust"))
    parser.add_argument("--lane", choices=SWIFT_LANES)
    parser.add_argument("--build-system", choices=("default", "xcode", "native"), default="default")
    parser.add_argument("--revision")
    parser.add_argument("--github-env", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    root = Path.cwd().resolve()
    try:
        identity = toolchain_identity(args.scope, root)
        result = cache_keys(args.scope, root, identity, lane=args.lane,
                            build_system=args.build_system, revision=args.revision)
        output = json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n"
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(output)
        if args.github_env:
            with args.github_env.open("a") as destination:
                for name, value in result.items():
                    if name != "toolchain_identity":
                        destination.write(f"{name}={value}\n")
        print(output, end="")
    except (OSError, ValueError) as error:
        parser.exit(1, f"CI cache keys: {error}\n")


if __name__ == "__main__":
    main()
