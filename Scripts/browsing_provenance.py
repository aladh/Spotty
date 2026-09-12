"""Build identity for the isolated Demo; no app launch or network access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(root: Path, *arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *arguments])


def source_identity(root: Path) -> dict:
    tracked = set(filter(None, git(root, "ls-files", "--cached", "-z").split(b"\0")))
    untracked = set(filter(None, git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")))
    inputs = []
    for name in sorted(tracked | untracked):
        path = root / os.fsdecode(name)
        if path.is_symlink():
            link_digest = hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()
            if path.is_file():
                kind, executable, digest = "symlink-file", bool(path.stat().st_mode & stat.S_IXUSR), [link_digest, sha256_file(path)]
            elif not path.exists():
                kind, executable, digest = "symlink-missing", False, link_digest
            else:
                raise ValueError("Source identity cannot bound inputs beneath a directory symlink")
        elif path.is_file():
            kind = "file"
            executable = bool(path.stat().st_mode & stat.S_IXUSR)
            digest = sha256_file(path)
        elif not path.exists():
            kind, executable, digest = "deleted", False, None
        else:
            raise ValueError("Source identity requires regular files or links, not submodule directories")
        # Only the aggregate digest leaves this helper. No untracked contents or filenames are reported.
        inputs.append([os.fsdecode(name), kind, executable, digest])
    encoded = json.dumps(inputs, ensure_ascii=True, separators=(",", ":")).encode()
    return {
        "revision": git(root, "rev-parse", "HEAD").decode().strip(),
        "diffSHA256": hashlib.sha256(git(root, "diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--")).hexdigest(),
        "sourceSHA256": hashlib.sha256(encoded).hexdigest(),
        "trackedFileCount": len(tracked),
        "untrackedFileCount": len(untracked),
        "includesUntrackedNonignoredFiles": True,
    }


def playback_pin(root: Path) -> tuple[str, str]:
    manifest = (root / "Package.swift").read_text()
    values = []
    for name in ("generatedPlaybackArtifactURL", "generatedPlaybackArtifactChecksum"):
        matches = re.findall(r"private\s+let\s+" + name + r'\s*=\s*"([^"]+)"', manifest)
        if len(matches) != 1:
            raise ValueError("Expected one generated playback artifact pin")
        values.append(matches[0])
    if not re.fullmatch(r"[a-fA-F0-9]{64}", values[1]):
        raise ValueError("Playback pin checksum is invalid")
    return values[0], values[1].lower()


def engine_identity(root: Path, scratch: Path | None = None) -> dict | None:
    pin_url, pin_checksum = playback_pin(root)
    override = os.environ.get("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK")
    if override:
        artifact = Path(override)
        if not artifact.is_absolute():
            artifact = root / artifact
    elif scratch is None:
        return None  # The pinned archive may not be downloaded before the build.
    else:
        state = json.loads((scratch / "workspace-state.json").read_text())
        matches = [entry for entry in state["object"]["artifacts"] if entry["targetName"] == "SpottyPlaybackCore"]
        if len(matches) != 1:
            raise ValueError("Expected one resolved playback artifact")
        selected = matches[0]
        source = selected["source"]
        if source.get("type") not in ("remote", "url") or source.get("url") != pin_url or source.get("checksum", "").lower() != pin_checksum:
            raise ValueError("Resolved engine differs from the declared pin")
        artifact = Path(selected["path"])
        if not artifact.is_absolute():
            artifact = root / artifact
    provenance = json.loads((artifact / "spotty_playback_provenance.json").read_text())
    info = plistlib.loads((artifact / "Info.plist").read_bytes())
    slices = [entry for entry in info["AvailableLibraries"] if entry["LibraryIdentifier"] == "macos-arm64"]
    if len(slices) != 1:
        raise ValueError("Expected the retained macOS arm64 engine slice")
    library_name = slices[0]["LibraryPath"]
    if Path(library_name).name != library_name or library_name != provenance["libraryName"]:
        raise ValueError("Engine library identity is inconsistent")
    library_sha = sha256_file(artifact / "macos-arm64" / library_name)
    if library_sha != provenance["librarySHA256"]:
        raise ValueError("Engine archive digest differs from its provenance")
    if slices[0].get("HeadersPath") != "Headers":
        raise ValueError("Engine canonical headers path is inconsistent")
    headers = artifact / "macos-arm64" / "Headers"
    canonical_headers = (
        "spotty_playback.h", "spotty_playback_generated.h", "spotty_playback_annotations.h", "module.modulemap",
    )
    if not headers.is_dir() or {entry.name for entry in headers.iterdir()} != set(canonical_headers):
        raise ValueError("Engine must contain exactly the four canonical header files")
    if any(not (headers / name).is_file() for name in canonical_headers):
        raise ValueError("Engine canonical headers must be files")
    # Match build-xcframework.sh and validate-xcframework.sh, including order and final newline.
    header_inputs = "".join(f"{name} {sha256_file(headers / name)}\n" for name in canonical_headers)
    headers_sha = hashlib.sha256(header_inputs.encode()).hexdigest()
    if headers_sha != provenance["source"]["canonicalHeadersSHA256"]:
        raise ValueError("Engine canonical headers digest differs from its provenance")
    return {
        "selection": "local-override" if override else "pinned",
        "pinURL": pin_url,
        "pinChecksum": pin_checksum,
        "librarySHA256": library_sha,
        "canonicalHeadersSHA256": headers_sha,
        "sourceRevision": provenance["source"]["sourceRevision"],
        "engineInputDigest": provenance["source"]["engineInputDigest"],
        "librespotRevision": provenance["source"]["librespotRevision"],
        "usedForPlayback": False,
    }


def build_snapshot(root: Path) -> dict:
    sdk = Path(os.environ["SDKROOT"])
    sdk_settings = json.loads((sdk / "SDKSettings.json").read_text())
    return {
        "source": source_identity(root),
        "compilerVersion": subprocess.check_output(["swift", "--version"], text=True).strip(),
        # The launcher passes this SDK explicitly to SwiftPM. The environment and SDK
        # settings alone cannot prove which SDK a compiler backend actually consumed.
        "requestedSDKVersion": sdk_settings["Version"],
        "requestedSDKName": sdk_settings["CanonicalName"],
        "localEngine": engine_identity(root),
    }


def linked_sdk_version(binary: Path) -> str:
    output = subprocess.check_output(["xcrun", "otool", "-l", str(binary)], text=True)
    versions = set()
    for command in re.split(r"(?m)^Load command \d+\s*$", output):
        if not re.search(r"(?m)^\s*cmd LC_(?:BUILD_VERSION|VERSION_MIN_MACOSX)\s*$", command):
            continue
        match = re.search(r"(?m)^\s*sdk (\d+\.\d+(?:\.\d+)?)\s*$", command)
        if match is None:
            raise ValueError("Executable is missing a valid linked SDK version")
        versions.add(match[1])
    if len(versions) != 1:
        raise ValueError("Executable must declare one consistent linked SDK version")
    return versions.pop()


def write_launch(root: Path, scratch: Path, run_root: Path, app: Path, configuration: str, automated: bool, profile: bool) -> None:
    before = json.loads((run_root / "build-start.json").read_text())
    after = build_snapshot(root)
    if before != after:
        raise ValueError("Source, compiler, SDK or local engine inputs changed during the build; rerun with stable inputs")
    engine = engine_identity(root, scratch)
    launch = {
        "runRoot": str(run_root), "automated": automated, "waitForProfiler": profile,
        "revision": after["source"]["revision"], "diffSHA256": after["source"]["diffSHA256"],
        "source": after["source"],
        "build": {
            "configuration": configuration,
            "optimization": "-O" if configuration == "release" else "-Onone",
            "testabilityEnabled": True,
            "compilerVersion": after["compilerVersion"],
            "requestedSDKVersion": after["requestedSDKVersion"],
            "requestedSDKName": after["requestedSDKName"],
            # This is the Mach-O linker stamp, not proof of the Swift compiler's SDK.
            "linkedSDKVersion": linked_sdk_version(app / "Contents/MacOS/SpottyDemo"),
            # Demo signing changes the executable signature after launch metadata is sealed.
            "buildProductSHA256": sha256_file(app / "Contents/MacOS/SpottyDemo"),
        },
        "engine": engine,
    }
    (app / "Contents/Resources/launch.json").write_text(json.dumps(launch, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["snapshot", "launch"])
    parser.add_argument("root", type=Path)
    parser.add_argument("run_root", type=Path)
    parser.add_argument("--scratch", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--configuration", choices=["debug", "release"])
    parser.add_argument("--automated", choices=["true", "false"])
    parser.add_argument("--profile", choices=["true", "false"])
    args = parser.parse_args()
    if args.operation == "snapshot":
        (args.run_root / "build-start.json").write_text(json.dumps(build_snapshot(args.root), sort_keys=True))
    else:
        if any(value is None for value in (args.scratch, args.app, args.configuration, args.automated, args.profile)):
            parser.error("launch requires build and app arguments")
        write_launch(args.root, args.scratch, args.run_root, args.app, args.configuration, args.automated == "true", args.profile == "true")


if __name__ == "__main__":
    main()
