#!/usr/bin/env python3
"""Generate the notices bundled with the Rune app.

The graph is deliberately fixed to the Rune manifest and lockfile in this
repository. The only inputs that vary for an artifact are the Cargo target
and the output directory. Python 3.11 is required for its standard-library
TOML parser.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

try:
    import tomllib
except ModuleNotFoundError:
    raise SystemExit("generate-rune-notices.py requires Python 3.11 or newer") from None


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Rune/Cargo.toml"
LOCKFILE = ROOT / "Rune/Cargo.lock"
OVERRIDES = ROOT / "Scripts/playback-license-overrides.json"
OVERRIDE_DIR = ROOT / "Scripts/playback-license-overrides"
PREAMBLE = ROOT / "THIRD_PARTY_NOTICES.md"
RETAINED_LIBRESPOT = ROOT / "Backend/spotty-playback/vendor/librespot"
REQUIRED_INPUTS = (MANIFEST, LOCKFILE, OVERRIDES, PREAMBLE, Path(__file__).resolve())
INVENTORY_NAME = "ThirdPartyNotices.json"
RUNE_REPOSITORY = "https://github.com/anomalyco/rune"
RUNE_ASSET_LICENSES = {
    "crates/rune/assets/IBMPlexMono-LICENSE.txt": "OFL-1.1",
    "crates/rune/assets/Inter-LICENSE.txt": "OFL-1.1",
    "crates/rune-highlights/vendor/LICENSE.md": "Apache-2.0",
}
EDGE_SET = "normal,build"
DEFAULT_TARGET = "aarch64-apple-darwin"
LEGAL_FILE_PREFIXES = (
    "license",
    "licence",
    "notice",
    "copying",
    "unlicense",
    "lgpl",
    "gpl",
    "mpl",
    "apache",
    "mit",
    "bsd",
    "zlib",
    "copyright",
    "patent",
)
LEGAL_TEXT_SUFFIXES = {"", ".txt", ".md", ".markdown", ".rst", ".html"}
LEGAL_LICENSE_SUFFIXES = {".apache", ".mit", ".chromium"}
REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
TREE_PACKAGE_RE = re.compile(
    r"^(?P<name>[^\s]+) v(?P<version>[^\s]+)(?: \((?P<origin>.*)\))?$"
)


class GenerationError(RuntimeError):
    """An input was incomplete or failed an integrity check."""


def fail(message: str) -> None:
    raise GenerationError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def run(command: list[str], *, cwd: Path = ROOT) -> str:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            check=True,
            text=True,
            capture_output=True,
            env={**os.environ, "CARGO_TERM_COLOR": "never"},
        )
    except FileNotFoundError:
        fail(f"required command is unavailable: {command[0]}")
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() or exc.stdout.strip() or "no command output"
        fail(f"{' '.join(command)} failed: {detail}")
    return completed.stdout


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot read JSON input {path}: {exc}")


def package_key(package: dict[str, Any]) -> str:
    return f"{package['name']}@{package['version']}"


def source_kind(source: str | None) -> str:
    if source is None:
        return "path"
    if source.startswith("registry+"):
        return "registry"
    if source.startswith("git+"):
        return "git"
    return "other"


def source_url(package: dict[str, Any], kind: str) -> str:
    source = package.get("source")
    if kind == "registry":
        return f"https://crates.io/crates/{package['name']}/{package['version']}"
    if kind == "git" and isinstance(source, str):
        return source.removeprefix("git+")
    repository = package.get("repository")
    return repository if isinstance(repository, str) else ""


def source_revision_from_source(source: str | None) -> str | None:
    if not source or not source.startswith("git+"):
        return None
    revision = source.rsplit("#", 1)[-1]
    if REVISION_RE.fullmatch(revision):
        return revision
    fail(f"git package source has no full 40-character revision: {source}")


def load_lockfile() -> dict[tuple[str, str, str], dict[str, Any]]:
    try:
        with LOCKFILE.open("rb") as lockfile:
            lock = tomllib.load(lockfile)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        fail(f"cannot read {LOCKFILE}: {exc}")
    records: dict[tuple[str, str, str], dict[str, Any]] = {}
    for package in lock.get("package", []):
        key = (
            package["name"],
            package["version"],
            package.get("source", ""),
        )
        records[key] = package
    return records


def parse_tree(tree: str) -> set[tuple[str, str, str]]:
    selected: set[tuple[str, str, str]] = set()
    for raw_line in tree.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.endswith(" (*)"):
            line = line[:-4].rstrip()
        if line.endswith(" (proc-macro)"):
            line = line[: -len(" (proc-macro)")].rstrip()
        match = TREE_PACKAGE_RE.fullmatch(line)
        if not match:
            fail(f"unrecognized cargo tree package line: {raw_line!r}")
        selected.add((match["name"], match["version"], match["origin"] or ""))
    if not selected:
        fail("cargo tree returned an empty dependency graph")
    return selected


def tree_key(package: dict[str, Any]) -> tuple[str, str, str]:
    source = package.get("source")
    kind = source_kind(source)
    origin = ""
    if kind == "path":
        origin = str(Path(package["manifest_path"]).parent)
    elif kind == "git":
        base, revision = source.removeprefix("git+").rsplit("#", 1)
        origin = f"{base}#{revision[:8]}"
    return package["name"], package["version"], origin


def archive_vcs_details(package_dir: Path) -> dict[str, str]:
    vcs_file = package_dir / ".cargo_vcs_info.json"
    if vcs_file.is_file():
        info = load_json(vcs_file)
        git_info = info.get("git", {}) if isinstance(info, dict) else {}
        revision = git_info.get("sha1") if isinstance(git_info, dict) else None
        if revision is not None and (
            not isinstance(revision, str) or not REVISION_RE.fullmatch(revision)
        ):
            fail(f"invalid git revision in {vcs_file}: {revision!r}")
        details: dict[str, str] = {}
        if revision:
            details["revision"] = revision
        path_in_vcs = info.get("path_in_vcs") if isinstance(info, dict) else None
        if isinstance(path_in_vcs, str) and path_in_vcs:
            details["path_in_vcs"] = path_in_vcs
        return details
    return {}


def git_checkout(package_dir: Path) -> tuple[Path, str]:
    for ancestor in (package_dir, *package_dir.parents):
        if (ancestor / ".git").exists():
            revision = run(["git", "-C", str(ancestor), "rev-parse", "HEAD"]).strip()
            if not REVISION_RE.fullmatch(revision):
                fail(f"git returned an invalid revision for {package_dir}: {revision!r}")
            return ancestor, revision
    fail(f"cannot verify the pinned git revision for {package_dir}")


def find_override(
    overrides: dict[str, Any], package: dict[str, Any]
) -> tuple[str, dict[str, Any]] | None:
    exact = package_key(package)
    if exact in overrides:
        return exact, overrides[exact]
    for key in sorted(overrides):
        override = overrides[key]
        revisions = override.get("source_revisions", {}) if isinstance(override, dict) else {}
        if isinstance(revisions, dict) and exact in revisions:
            return key, override
        if key.endswith("*"):
            prefix = key[:-1]
            if package["name"].startswith(prefix) or (
                prefix.endswith("-") and package["name"] == prefix[:-1]
            ):
                return key, override
    return None


def expected_override_revision(
    override: dict[str, Any], package: dict[str, Any]
) -> str | None:
    revisions = override.get("source_revisions", {})
    if isinstance(revisions, dict):
        package_revision = revisions.get(package_key(package))
        if package_revision is not None:
            return package_revision
    return override.get("source_revision")


def safe_override_file(path_value: str) -> Path:
    if not path_value or Path(path_value).is_absolute():
        fail(f"override file path must be relative: {path_value!r}")
    path = (OVERRIDE_DIR / path_value).resolve()
    try:
        path.relative_to(OVERRIDE_DIR.resolve())
    except ValueError:
        fail(f"override file escapes {OVERRIDE_DIR}: {path_value!r}")
    if not path.is_file():
        fail(f"declared license override file does not exist: {path}")
    return path


def license_ids(expression: str) -> set[str]:
    tokens = re.findall(r"[A-Za-z][A-Za-z0-9.+-]*", expression)
    return {token for token in tokens if token.upper() not in {"OR", "AND", "WITH"}}


def validate_override(
    override_key: str,
    override: dict[str, Any],
    package: dict[str, Any],
    vcs_details: dict[str, str],
) -> tuple[str, list[dict[str, Any]]]:
    def repository_path(url: str) -> str:
        parsed = urlsplit(url)
        path = parsed.path.split("/tree/", 1)[0].rstrip("/").removesuffix(".git")
        return f"{parsed.netloc}{path}".lower()

    repository = override.get("source_repository")
    if not repository or repository_path(repository) != repository_path(package.get("repository") or ""):
        fail(f"override {override_key} does not match the repository for {package_key(package)}")
    expected = expected_override_revision(override, package)
    if not isinstance(expected, str) or not REVISION_RE.fullmatch(expected):
        fail(f"override {override_key} has no valid source revision for {package_key(package)}")
    actual = vcs_details.get("embedded_revision", vcs_details.get("revision"))
    if not actual:
        fail(f"cannot verify source revision for overridden package {package_key(package)}")
    if actual != expected:
        fail(
            f"source revision mismatch for {package_key(package)}: "
            f"expected {expected}, found {actual}"
        )

    files = override.get("files")
    if not isinstance(files, list) or not files:
        fail(f"override {override_key} has no license files")
    explicit_ids: set[str] = set()
    validated: list[dict[str, Any]] = []
    for descriptor in files:
        if not isinstance(descriptor, dict):
            fail(f"override {override_key} contains a non-object license file")
        path_value = descriptor.get("path")
        license_name = descriptor.get("license")
        source_path = descriptor.get("source_path")
        source = descriptor.get("source_url")
        if not all(
            isinstance(value, str) and value
            for value in (path_value, license_name, source_path, source)
        ):
            fail(f"override {override_key} contains an incomplete license file descriptor")
        path = safe_override_file(path_value)
        if "source_revision" not in descriptor and expected not in source:
            fail(
                f"override {override_key} source URL is not tied to {expected}: "
                f"{source}"
            )
        file_revision = descriptor.get("source_revision", expected)
        if not isinstance(file_revision, str) or not REVISION_RE.fullmatch(file_revision):
            fail(f"override {override_key} has an invalid license source revision")
        if file_revision not in source:
            fail(
                f"override {override_key} license source URL is not tied to "
                f"{file_revision}: {source}"
            )
        explicit_ids.update(license_ids(license_name))
        validated.append(
            {
                "path": path,
                "license": license_name,
                "source_path": source_path,
                "source_url": source,
                "source_revision": file_revision,
                "origin": descriptor.get("origin", "checked-in upstream override"),
            }
        )

    required_ids = license_ids(package["license"])
    missing_ids = sorted(required_ids - explicit_ids)
    if missing_ids:
        fail(
            f"override {override_key} does not provide declared license IDs for "
            f"{package_key(package)}: {', '.join(missing_ids)}"
        )
    return expected, validated


def package_license_candidates(package: dict[str, Any]) -> list[Path]:
    package_dir = Path(package["manifest_path"]).resolve().parent
    if not package_dir.is_dir():
        fail(f"Cargo metadata package directory is missing: {package_dir}")
    candidates: set[Path] = set()
    for path in package_dir.rglob("*"):
        suffix = path.suffix.lower()
        stem = path.stem.lower()
        legal_name = stem.endswith("-license") or path.name.lower().startswith(LEGAL_FILE_PREFIXES)
        legal_text = legal_name and suffix in LEGAL_TEXT_SUFFIXES
        named_license = stem == "license" and suffix in LEGAL_LICENSE_SUFFIXES
        if (legal_text or named_license) and path.is_file():
            resolved = path.resolve()
            try:
                resolved.relative_to(package_dir)
            except ValueError:
                fail(
                    f"license candidate escapes package source directory: "
                    f"{path} -> {resolved}"
                )
            candidates.add(resolved)

    declared = package.get("license_file")
    if declared:
        declared_path = (package_dir / declared).resolve()
        try:
            declared_path.relative_to(package_dir)
        except ValueError:
            fail(f"package license_file escapes its source directory: {declared!r}")
        if not declared_path.is_file():
            fail(f"package license_file is missing: {declared_path}")
        candidates.add(declared_path)
    return sorted(candidates)


def document_reference(
    content: bytes,
    *,
    package: str,
    license_name: str,
    origin: str,
    source_path: str,
    source_url: str,
    source_revision: str | None,
    documents: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    try:
        content.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"license text for {package} is not valid UTF-8: {exc}")
    digest = sha256_bytes(content)
    bundle_path = f"licenses/sha256-{digest}.txt"
    source = {
        "package": package,
        "license": license_name,
        "origin": origin,
        "source_path": source_path,
        "source_url": source_url,
    }
    if source_revision:
        source["source_revision"] = source_revision
    document = documents.setdefault(
        digest,
        {
            "content": content,
            "bundle_path": bundle_path,
            "sha256": digest,
            "bytes": len(content),
            "sources": [],
        },
    )
    if document["content"] != content:
        fail(f"SHA-256 collision while collecting license text {digest}")
    if source not in document["sources"]:
        document["sources"].append(source)
    reference = {
        "bundle_path": bundle_path,
        "sha256": digest,
        "bytes": len(content),
        "origin": origin,
        "license": license_name,
        "source_path": source_path,
        "source_url": source_url,
    }
    if source_revision:
        reference["source_revision"] = source_revision
    return reference


def collect_package(
    package: dict[str, Any],
    lock_records: dict[tuple[str, str, str], dict[str, Any]],
    overrides: dict[str, Any],
    documents: dict[str, dict[str, Any]],
    override_inputs: set[Path],
) -> dict[str, Any]:
    key = package_key(package)
    source = package.get("source")
    kind = source_kind(source)
    rune_checkout = kind == "git" and source.split("?", 1)[0] == f"git+{RUNE_REPOSITORY}"
    lock_key = (package["name"], package["version"], source or "")
    lock_record = lock_records.get(lock_key)
    if lock_record is None:
        fail(f"{key} is in the target graph but absent from Cargo.lock")
    record: dict[str, Any] = {
        "name": package["name"],
        "version": package["version"],
        "license_expression": package["license"],
        "source": source,
        "source_kind": kind,
        "source_url": source_url(package, kind),
        "authors": sorted(package.get("authors") or []),
        "license_files": [],
    }
    if not package["license"] and not package.get("license_file"):
        fail(f"Cargo package {key} has no declared license metadata")
    if package.get("repository"):
        record["repository"] = package["repository"]

    if kind == "registry":
        checksum = lock_record.get("checksum")
        if not isinstance(checksum, str) or not checksum:
            fail(f"registry package {key} has no checksum in Cargo.lock")
        record["checksum"] = checksum
    elif kind == "git":
        revision = source_revision_from_source(source)
        record["git_revision"] = revision
    elif kind == "path":
        retained = {"librespot-core": "core", "librespot-connect": "connect", "librespot-playback": "playback"}
        directory = retained.get(package["name"])
        expected = RETAINED_LIBRESPOT / (directory or "") / "Cargo.toml"
        if directory is None or Path(package["manifest_path"]).resolve() != expected.resolve():
            fail(f"unsupported local dependency for {key}")
        record["source_path"] = expected.parent.relative_to(ROOT).as_posix()
    else:
        fail(f"unsupported non-workspace package source for {key}: {source!r}")

    package_dir = Path(package["manifest_path"]).resolve().parent
    vcs = archive_vcs_details(package_dir)
    checkout = None
    if kind == "git":
        checkout, revision = git_checkout(package_dir)
        relative = package_dir.relative_to(checkout).as_posix()
        embedded = vcs
        vcs = {"revision": revision, "path_in_vcs": relative}
        if rune_checkout and relative.startswith("vendor/"):
            vcs.update({f"embedded_{name}": value for name, value in embedded.items()})
    if kind == "path":
        upstream_file = expected.parent.parent / "UPSTREAM"
        try:
            upstream = upstream_file.read_text().splitlines()[0]
            retained_manifest = tomllib.loads(MANIFEST.read_text())
            pinned = retained_manifest["dependencies"][package["name"]]["rev"]
        except (OSError, UnicodeError, IndexError, KeyError, TypeError, tomllib.TOMLDecodeError) as error:
            fail(f"cannot read retained upstream metadata for {key}: {error}")
        if not REVISION_RE.fullmatch(upstream) or upstream != pinned:
            fail(f"retained upstream revision mismatch for {key}")
        vcs = {"revision": upstream, "path_in_vcs": directory}
        override_inputs.add(upstream_file)
    if vcs.get("revision"):
        record["source_revision"] = vcs["revision"]
    if vcs.get("path_in_vcs"):
        record["source_path_in_vcs"] = vcs["path_in_vcs"]
    if vcs.get("embedded_revision"):
        record["embedded_source_revision"] = vcs["embedded_revision"]
        record["embedded_source_path_in_vcs"] = vcs.get("embedded_path_in_vcs", "")
    if kind == "git" and vcs.get("revision") != record["git_revision"]:
        fail(
            f"git revision mismatch for {key}: expected {record['git_revision']}, "
            f"found {vcs.get('revision', 'none')}"
        )

    override_match = find_override(overrides, package)
    override_key: str | None = None
    override_files: list[dict[str, Any]] = []
    expected_override: str | None = None
    if override_match and kind != "path":
        override_key, override = override_match
        expected_override, override_files = validate_override(
            override_key, override, package, vcs
        )

    archive_files = package_license_candidates(package)
    archive_license_records: list[dict[str, Any]] = []
    package_url = source_url(package, kind)
    origin = {"git": "Cargo git checkout", "path": "retained workspace source"}.get(
        kind, "package source archive"
    )
    for path in archive_files:
        resolved = path.resolve()
        try:
            source_path = resolved.relative_to(package_dir).as_posix()
        except ValueError:
            fail(f"license file escaped package source directory: {path}")
        if checkout and vcs["path_in_vcs"] != ".":
            source_path = f"{vcs['path_in_vcs']}/{source_path}"
        license_name = "package-supplied license or notice"
        if rune_checkout:
            license_name = RUNE_ASSET_LICENSES.get(source_path, license_name)
        if path.name.lower() in {"license.mit", "license-mit"}:
            license_name = "MIT"
        archive_license_records.append(
            document_reference(
                resolved.read_bytes(),
                package=key,
                license_name=license_name,
                origin=origin,
                source_path=source_path,
                source_url=package_url,
                source_revision=vcs.get("revision"),
                documents=documents,
            )
        )

    if (
        checkout
        and rune_checkout
        and vcs["path_in_vcs"].startswith("crates/rune")
        and package["license"] in {"MIT", "MIT AND Apache-2.0"}
    ):
        archive_license_records.append(
            document_reference(
                (checkout / "LICENSE").read_bytes(),
                package=key,
                license_name="MIT",
                origin="checkout workspace license",
                source_path="LICENSE",
                source_url=f"{RUNE_REPOSITORY}/blob/{vcs['revision']}/LICENSE",
                source_revision=vcs["revision"],
                documents=documents,
            )
        )

    override_license_records: list[dict[str, Any]] = []
    for descriptor in override_files:
        override_inputs.add(descriptor["path"])
        override_license_records.append(
            document_reference(
                descriptor["path"].read_bytes(),
                package=key,
                license_name=descriptor["license"],
                origin=descriptor["origin"],
                source_path=descriptor["source_path"],
                source_url=descriptor["source_url"],
                source_revision=descriptor["source_revision"],
                documents=documents,
            )
        )

    license_records = archive_license_records + override_license_records
    if not license_records:
        fail(
            f"{key} has no license or notice file in its source archive and no "
            "declared checked-in override"
        )
    record["license_files"] = sorted(
        license_records,
        key=lambda item: (item["bundle_path"], item["source_path"]),
    )
    origins = {item["origin"] for item in license_records}
    record["license_origin"] = " + ".join(sorted(origins))
    if override_key:
        record["license_override"] = override_key
        record["license_override_note"] = (
            f"Override selected for upstream commit {expected_override}. "
            "Each text has its own source URL and revision."
        )
    return record


def markdown_cell(value: Any) -> str:
    return str(value).replace("|", r"\|").replace("\r", " ").replace("\n", " ")


def render_markdown(
    *,
    preamble: str,
    target: str,
    root_package: dict[str, Any],
    package_records: list[dict[str, Any]],
    documents: dict[str, dict[str, Any]],
    input_hashes: dict[str, str],
) -> str:
    tick = chr(96)
    lines = [preamble.rstrip(), ""]
    lines.extend(
        [
            "## Generated Rune dependency inventory",
            "",
            f"- Target: {tick}{target}{tick}",
            f"- Cargo graph edges: {tick}{EDGE_SET}{tick}",
            (
                f"- Root package: {tick}{root_package['name']} "
                f"v{root_package['version']}{tick}"
            ),
            f"- Third-party packages: {len(package_records)}",
            f"- Unique license and notice files: {len(documents)}",
            f"- Machine-readable inventory: [{INVENTORY_NAME}]({INVENTORY_NAME})",
            "",
            (
                "The licenses directory contains the collected license and notice texts. "
                "The inventory records each file's digest, source location, and package association. "
                "It labels canonical license references and package declarations where "
                "the upstream archive omits the license text."
            ),
            "",
            (
                "Scripts/generate-rune-notices.py regenerates the inventory from the "
                "locked graph and fails when a package has neither a discoverable license "
                "text nor an explicit override."
            ),
            "",
            "Input SHA-256:",
            "",
            "| Input | SHA-256 |",
            "| --- | --- |",
        ]
    )
    for name, digest in input_hashes.items():
        lines.append(f"| {tick}{markdown_cell(name)}{tick} | {tick}{digest}{tick} |")
    lines.extend(
        [
            "",
            "### Package inventory",
            "",
            "| Package | Version | License expression | Source | Bundled license texts |",
            "| --- | --- | --- | --- | --- |",
        ]
    )
    for package in package_records:
        source = package["source_url"]
        source_cell = (
            f"[{markdown_cell(source)}]({source})" if source else "(workspace)"
        )
        text_cell = "<br>".join(
            f"[{tick}{item['bundle_path']}{tick}]({item['bundle_path']})"
            for item in package["license_files"]
        )
        lines.append(
            "| "
            + " | ".join(
                (
                    tick + markdown_cell(package["name"]) + tick,
                    tick + markdown_cell(package["version"]) + tick,
                    tick + markdown_cell(package["license_expression"]) + tick,
                    source_cell,
                    text_cell,
                )
            )
            + " |"
        )
    lines.extend(
        [
            "",
            "### License and notice files",
            "",
            "| Bundle path | SHA-256 | Bytes | Packages |",
            "| --- | --- | --- | --- |",
        ]
    )
    for digest in sorted(documents):
        document = documents[digest]
        packages = sorted({source["package"] for source in document["sources"]})
        lines.append(
            "| "
            + " | ".join(
                (
                    tick + document["bundle_path"] + tick,
                    tick + digest + tick,
                    tick + str(document["bytes"]) + tick,
                    tick + markdown_cell(", ".join(packages)) + tick,
                )
            )
            + " |"
        )
    lines.append("")
    return "\n".join(lines)


def write_output(
    output: Path,
    *,
    target: str,
    root_package: dict[str, Any],
    package_records: list[dict[str, Any]],
    documents: dict[str, dict[str, Any]],
    override_inputs: set[Path],
) -> None:
    output.mkdir(parents=True, exist_ok=True)
    license_dir = output / "licenses"
    license_dir.mkdir(parents=True, exist_ok=True)
    for stale in license_dir.glob("sha256-*.txt"):
        stale.unlink()
    for digest in sorted(documents):
        document = documents[digest]
        (output / document["bundle_path"]).write_bytes(document["content"])

    input_hashes = {
        path.relative_to(ROOT).as_posix(): sha256_file(path)
        for path in REQUIRED_INPUTS
    }
    for path in sorted(override_inputs):
        try:
            relative = path.relative_to(ROOT).as_posix()
        except ValueError:
            fail(f"override input escaped repository root: {path}")
        input_hashes[relative] = sha256_file(path)
    notices_name = "ThirdPartyNotices.md"
    notices = render_markdown(
        preamble=PREAMBLE.read_text(encoding="utf-8"),
        target=target,
        root_package=root_package,
        package_records=package_records,
        documents=documents,
        input_hashes=input_hashes,
    ).encode("utf-8")
    (output / notices_name).write_bytes(notices)
    inventory = {
        "schema_version": 1,
        "target": target,
        "cargo_tree_edges": EDGE_SET,
        "root_package": root_package,
        "package_count": len(package_records),
        "license_text_count": len(documents),
        "license_text_bytes": sum(document["bytes"] for document in documents.values()),
        "inputs": [
            {"path": name, "sha256": digest}
            for name, digest in input_hashes.items()
        ],
        "outputs": {
            "notices": notices_name,
            "notices_sha256": sha256_bytes(notices),
            "manifest": INVENTORY_NAME,
            "license_directory": "licenses",
        },
        "packages": package_records,
        "license_texts": [
            {
                key: value
                for key, value in document.items()
                if key != "content"
            }
            | {
                "sources": sorted(
                    document["sources"],
                    key=lambda source: json.dumps(source, sort_keys=True),
                )
            }
            for digest, document in sorted(documents.items())
        ],
    }
    (output / INVENTORY_NAME).write_text(
        json.dumps(inventory, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def generate(target: str, output: Path) -> tuple[int, int]:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", target):
        fail(f"invalid Cargo target: {target!r}")
    for path in REQUIRED_INPUTS:
        if not path.is_file():
            fail(f"required input is missing: {path}")

    metadata = cargo_metadata(target)
    tree = run(
        [
            "cargo",
            "tree",
            "--manifest-path",
            str(MANIFEST),
            "--locked",
            "--target",
            target,
            "--edges",
            EDGE_SET,
            "--prefix",
            "none",
            "--format",
            "{p}",
        ],
        cwd=MANIFEST.parent,
    )
    graph_keys = parse_tree(tree)
    packages = {package["id"]: package for package in metadata["packages"]}
    if graph_keys - {tree_key(package) for package in packages.values()}:
        # Cargo tree includes the host's build dependencies even when targeting another platform.
        cargo_version = run(["cargo", "-vV"], cwd=MANIFEST.parent)
        host = re.search(r"^host: (\S+)$", cargo_version, re.MULTILINE)
        if host and host[1] != target:
            packages.update({package["id"]: package for package in cargo_metadata(host[1])["packages"]})
    by_origin: dict[tuple[str, str, str], dict[str, Any]] = {}
    for package in packages.values():
        key = tree_key(package)
        if key in graph_keys:
            if key in by_origin:
                fail(f"ambiguous package identity in cargo tree: {key}")
            by_origin[key] = package
    if missing := graph_keys - by_origin.keys():
        fail(f"cargo tree packages are missing from cargo metadata: {sorted(missing)}")
    selected = list(by_origin.values())

    workspace_members = set(metadata.get("workspace_members") or [])
    roots = [package for package in selected if package["id"] in workspace_members]
    if len(roots) != 1:
        fail(f"expected one workspace root in target graph, found {len(roots)}")
    root = roots[0]
    root_package = {
        "name": root["name"],
        "version": root["version"],
        "license_expression": root["license"],
        "source": "workspace",
        "source_kind": "workspace",
    }
    lock_records = load_lockfile()
    overrides = load_json(OVERRIDES)
    if not isinstance(overrides, dict):
        fail(f"license override manifest is not an object: {OVERRIDES}")
    documents: dict[str, dict[str, Any]] = {}
    override_inputs: set[Path] = set()
    package_records = [
        collect_package(package, lock_records, overrides, documents, override_inputs)
        for package in selected
        if package["id"] not in workspace_members
    ]
    package_records.sort(
        key=lambda package: (
            package["name"],
            package["version"],
            package["source"] or "",
        )
    )
    write_output(
        output,
        target=target,
        root_package=root_package,
        package_records=package_records,
        documents=documents,
        override_inputs=override_inputs,
    )
    return len(package_records), len(documents)


def cargo_metadata(target: str) -> dict[str, Any]:
    text = run(
        [
            "cargo", "metadata", "--manifest-path", str(MANIFEST), "--locked",
            "--format-version", "1", "--filter-platform", target,
        ],
        cwd=MANIFEST.parent,
    )
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        fail(f"cargo metadata returned invalid JSON: {exc}")
    if not isinstance(value, dict) or not isinstance(value.get("packages"), list):
        fail("cargo metadata did not return a package list")
    return value


def verify_output(output: Path, target: str) -> tuple[int, int]:
    inventory = load_json(output / INVENTORY_NAME)
    try:
        packages = inventory["packages"]
        texts = inventory["license_texts"]
        if (
            inventory["target"] != target
            or inventory["root_package"]["name"] != "spotty-rune"
            or inventory["package_count"] != len(packages)
            or inventory["license_text_count"] != len(texts)
            or not packages
            or not texts
        ):
            fail("bundle notice inventory has an unexpected target, root package, or count")
        required = set(REQUIRED_INPUTS)
        checked_inputs = set()
        for item in inventory["inputs"]:
            name = item["path"]
            path = (ROOT / name).resolve()
            known = path in required or path == RETAINED_LIBRESPOT / "UPSTREAM"
            if (
                not path.is_relative_to(ROOT)
                or path.relative_to(ROOT).as_posix() != name
                or not (known or path.is_relative_to(OVERRIDE_DIR))
                or path in checked_inputs
            ):
                fail(f"bundle notice inventory contains an invalid input path: {name!r}")
            if sha256_file(path) != item["sha256"]:
                fail(f"bundle notice inventory does not match the current input: {name}")
            checked_inputs.add(path)
        if missing := required - checked_inputs:
            missing_names = ", ".join(sorted(path.relative_to(ROOT).as_posix() for path in missing))
            fail(f"bundle notice inventory is missing required inputs: {missing_names}")
        if sha256_file(output / "ThirdPartyNotices.md") != inventory["outputs"]["notices_sha256"]:
            fail("bundle notice Markdown does not match the inventory")
        checked = set()
        for text in texts:
            digest = text["sha256"]
            path = f"licenses/sha256-{digest}.txt"
            if not re.fullmatch(r"[0-9a-f]{64}", digest) or text["bundle_path"] != path:
                fail("bundle notice inventory contains an invalid license path")
            content = (output / path).read_bytes()
            if len(content) != text["bytes"] or sha256_bytes(content) != digest:
                fail(f"bundle license text does not match the inventory: {path}")
            checked.add(path)
        references = set()
        for package in packages:
            paths = {text["bundle_path"] for text in package["license_files"]}
            if not paths:
                fail(f"bundle notice inventory lacks a license for {package_key(package)}")
            references.update(paths)
        if references != checked or len(checked) != len(texts):
            fail("bundle notice inventory contains inconsistent license references")
    except (KeyError, TypeError, OSError) as exc:
        fail(f"cannot verify bundle notice inventory: {exc}")
    return len(packages), len(texts)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate the locked Rune dependency notices."
    )
    parser.add_argument("--target", default=DEFAULT_TARGET)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output", type=Path, help="generate notices in this directory")
    action.add_argument("--verify", type=Path, help="verify notices in this directory")
    args = parser.parse_args()
    try:
        if args.verify:
            package_count, document_count = verify_output(args.verify, args.target)
            verb = "verified"
        else:
            package_count, document_count = generate(args.target, args.output.resolve())
            verb = "generated"
    except GenerationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(
        f"{verb} {package_count} package notices and "
        f"{document_count} unique license and notice files"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
