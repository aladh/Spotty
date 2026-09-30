"""Batch read-only playback metadata checks; binary inspection remains in the shell gate."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
from xml.parsers.expat import ExpatError


METADATA_LIMIT = 4 * 1024 * 1024
HEADER_NAMES = (
    "spotty_playback.h", "spotty_playback_generated.h", "spotty_playback_annotations.h", "module.modulemap",
)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate metadata key: {key}")
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")


def _read(path, label, *, plist=False):
    if not path.is_file():
        raise ValueError(f"{label} is missing")
    with path.open("rb") as source:
        data = source.read(METADATA_LIMIT + 1)
    if len(data) > METADATA_LIMIT:
        raise ValueError(f"{label} is too large")
    try:
        # plutil also accepts JSON property lists. Retain that format alongside XML/binary.
        if plist and not data.lstrip().startswith(b"{"):
            value = plistlib.loads(data)
        else:
            value = json.loads(data, object_pairs_hook=_unique_object, parse_constant=_invalid_constant)
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError) as error:
        raise ValueError(f"{label} is invalid") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} is invalid")
    return value


def _equal(label, expected, actual):
    if type(expected) is not type(actual) or expected != actual:
        raise ValueError(f"{label} mismatch (expected {expected}, found {actual})")


def _text(value, label):
    if not isinstance(value, str) or not value or any(char in value for char in "\n\r\0"):
        raise ValueError(f"{label} is missing or invalid")
    return value


def metadata(artifact):
    info = _read(artifact / "Info.plist", "XCFramework Info.plist", plist=True)
    _equal("package type", "XFWK", info.get("CFBundlePackageType"))
    _equal("library type", "static", info.get("LibraryType"))
    _equal("module name", "SpottyPlaybackCore", info.get("ModuleName"))
    minimum = _text(info.get("MinimumOSVersion"), "artifact minimum OS version")
    libraries = info.get("AvailableLibraries")
    if not isinstance(libraries, list):
        raise ValueError("available library count mismatch (expected 1, found invalid array)")
    _equal("available library count", 1, len(libraries))
    library = libraries[0]
    if not isinstance(library, dict):
        raise ValueError("XCFramework library metadata is invalid")
    _equal("library identifier", "macos-arm64", library.get("LibraryIdentifier"))
    _equal("supported platform", "macos", library.get("SupportedPlatform"))
    architectures = library.get("SupportedArchitectures")
    if not isinstance(architectures, list):
        raise ValueError("architecture count mismatch (expected 1, found invalid array)")
    _equal("architecture count", 1, len(architectures))
    _equal("architecture", "arm64", architectures[0])
    name = _text(library.get("LibraryPath"), "static library path")
    _equal("binary path", name, library.get("BinaryPath"))
    if "/" in name or ".." in name:
        raise ValueError("static library path must be a safe file name")
    if not name.startswith("libSpottyPlaybackCore_") or not name.endswith(".a"):
        raise ValueError("static library name must carry the engine input digest")
    identity = name[len("libSpottyPlaybackCore_"):-2].split("_", 1)
    if not re.fullmatch(r"[0-9a-fA-F]{64}", identity[0]):
        raise ValueError("static library name has no valid engine input digest")
    if len(identity) != 2 or not re.fullmatch(r"[0-9a-fA-F]{64}", identity[1]):
        raise ValueError("static library name has no valid library digest")
    _equal("headers path", "Headers", library.get("HeadersPath"))
    return minimum, name, identity[0], identity[1]


def _digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(128 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(artifact, source_digest=None, *, for_publish=False, expected_minimum=None, expected_name=None):
    minimum, name, input_identity, library_identity = metadata(artifact)
    # Keep the hashes tied to the exact paths and deployment declaration already inspected by
    # the shell's Apple tools, even if metadata changed between the two helper invocations.
    if expected_minimum is not None:
        _equal("inspected minimum OS version", expected_minimum, minimum)
    if expected_name is not None:
        _equal("inspected library name", expected_name, name)
    provenance = _read(artifact / "spotty_playback_provenance.json", "embedded playback provenance", plist=True)
    source = provenance.get("source")
    if not isinstance(source, dict):
        raise ValueError("embedded provenance is missing source")
    recorded_digest = _text(source.get("engineInputDigest"), "embedded provenance source.engineInputDigest")
    source_digest = source_digest if source_digest is not None else recorded_digest
    _equal("provenance source input digest", source_digest, recorded_digest)
    _equal("provenance target", "aarch64-apple-darwin", provenance.get("target"))
    _equal("library filename input digest", source_digest, input_identity)
    for label, key, expected in (
        ("module", "module", "SpottyPlaybackCore"), ("library name", "libraryName", name),
        ("platform", "platform", "macOS"), ("minimum OS version", "minimumOSVersion", minimum),
        ("library type", "libraryType", "static"),
    ):
        _equal(f"provenance {label}", expected, provenance.get(key))
    headers = artifact / "macos-arm64/Headers"
    manifest = "".join(f"{header} {_digest(headers / header)}\n" for header in HEADER_NAMES)
    _equal("provenance canonical header digest", hashlib.sha256(manifest.encode()).hexdigest(),
           source.get("canonicalHeadersSHA256"))
    library_digest = _digest(artifact / "macos-arm64" / name)
    _equal("provenance library digest", library_digest, provenance.get("librarySHA256"))
    _equal("library filename digest", library_digest, library_identity)
    if for_publish:
        _equal("provenance source dirty flag", False, source.get("sourceDirty"))


def resolve(root, workspace, url, checksum):
    state = _read(workspace, "SwiftPM workspace state")
    container = state.get("object")
    artifacts = container.get("artifacts") if isinstance(container, dict) else None
    if not isinstance(artifacts, list) or len(artifacts) > 64:
        raise ValueError("SwiftPM workspace state must contain a bounded artifact array")
    matches = []
    for artifact in artifacts:
        if not isinstance(artifact, dict) or not isinstance(artifact.get("targetName"), str):
            raise ValueError("SwiftPM workspace state contains an invalid artifact entry")
        if artifact["targetName"] != "SpottyPlaybackCore":
            continue
        source = artifact.get("source")
        if not isinstance(source, dict) or source.get("type") not in ("remote", "url"):
            raise ValueError("SwiftPM SpottyPlaybackCore entry is not a remote artifact")
        path = _text(artifact.get("path"), "SwiftPM SpottyPlaybackCore artifact path")
        candidate = Path(path)
        if not candidate.is_absolute():
            candidate = root / candidate
        if not candidate.is_dir() or candidate.suffix != ".xcframework":
            raise ValueError(f"SwiftPM SpottyPlaybackCore artifact path is missing: {path}")
        state_url, state_checksum = source.get("url"), source.get("checksum")
        if not all(isinstance(value, str) and value for value in (url, checksum, state_url, state_checksum)):
            raise ValueError("SwiftPM SpottyPlaybackCore state or package pin is missing its remote URL/checksum")
        if state_url != url or state_checksum.lower() != checksum.lower():
            raise ValueError("SwiftPM SpottyPlaybackCore state does not match Package.swift")
        matches.append(candidate.resolve())
    if len(matches) != 1:
        raise ValueError(f"Expected one resolved remote SpottyPlaybackCore artifact in SwiftPM workspace state; found {len(matches)}")
    return matches[0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("metadata", "verify"):
        arguments = commands.add_parser(command)
        arguments.add_argument("artifact", type=Path)
        if command == "verify":
            arguments.add_argument("--source-digest")
            arguments.add_argument("--for-publish", action="store_true")
            arguments.add_argument("--expected-minimum", required=True)
            arguments.add_argument("--expected-name", required=True)
    arguments = commands.add_parser("resolve")
    arguments.add_argument("root", type=Path)
    arguments.add_argument("workspace", type=Path)
    arguments.add_argument("url")
    arguments.add_argument("checksum")
    args = parser.parse_args()
    try:
        if args.command == "metadata":
            minimum, name, _, _ = metadata(args.artifact)
            print(minimum)
            print(name)
        elif args.command == "verify":
            verify(args.artifact, args.source_digest, for_publish=args.for_publish,
                   expected_minimum=args.expected_minimum, expected_name=args.expected_name)
        else:
            print(resolve(args.root, args.workspace, args.url, args.checksum))
    except (OSError, ValueError, TypeError) as error:
        prefix = "" if args.command == "resolve" else "validate-xcframework.sh: "
        parser.exit(1, f"{prefix}{error}\n")
