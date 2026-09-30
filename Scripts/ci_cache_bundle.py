#!/usr/bin/env python3
"""Move explicitly scoped CI cache products between isolated macOS jobs."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import resource
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unicodedata


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = 1
SCOPES = {
    "swift": [("build", "repo", ".build")],
    "rust-debug": [
        ("rust-debug", "repo", "Backend/spotty-playback/target/debug"),
        ("rust-info", "repo", "Backend/spotty-playback/target/.rustc_info.json"),
        ("cargo-git", "cargo", "git"),
        ("cargo-registry", "cargo", "registry"),
    ],
    "rust-release": [
        ("rust-release-target", "repo", "Backend/spotty-playback/target/aarch64-apple-darwin/release"),
        ("rust-release-host", "repo", "Backend/spotty-playback/target/release"),
    ],
    "cbindgen": [("cbindgen", "runner", "spotty-cbindgen")],
}
# These stores are never cache inputs. Do not enumerate the rest of CARGO_HOME, the
# runner temp directory, or the repository; those can hold account/signing material.
PRIVATE_NAMES = {"spotty-signing", ".git-credentials", ".netrc", ".npmrc", "credentials",
                 "credentials.toml", "credentials.json", "id_rsa", "id_ed25519"}


def path_key(value: str) -> str:
    # macOS cache destinations commonly use case-insensitive, canonically
    # normalized filesystems. Reject aliases even when tests run on Linux.
    return unicodedata.normalize("NFD", value).casefold()


def private_path(path: PurePosixPath, *, logical_name: str, kind: str | None = None) -> bool:
    parts = [path_key(component) for component in path.parts]
    # Cargo's approved dependency source roots can contain public schema/source
    # directories named credentials. Credential stores and secret file names still
    # stay private, including .cargo/.git stores inside those source trees. A bare
    # credentials file/link is never a public directory. Unknown kind is used only
    # for lexical path checks; validate_structure checks every manifest entry's kind.
    public_source = (logical_name == "cargo-git" and len(parts) >= 4 and parts[0] == "checkouts"
                     and re.fullmatch(r"[0-9a-f]{7}", path.parts[2]) is not None
                     and not any(part in {".cargo", ".git"} for part in parts[3:]))
    for index, component in enumerate(parts):
        if component not in PRIVATE_NAMES:
            continue
        if (component == "credentials" and public_source and index >= 3
                and (index < len(parts) - 1 or kind in {None, "directory"})):
            continue
        return True
    return False


def verify_credentials_proof(root: Path, logical_name: str, relative: PurePosixPath) -> str | None:
    """Return exact HEAD-proven bytes' SHA256 for relaxed Git files, otherwise None."""
    if logical_name != "cargo-git" or "credentials" not in {path_key(part) for part in relative.parts}:
        return None
    path = root / relative
    error_message = "public credentials source lacks exact tracked HEAD proof"
    stage = "input-metadata"
    try:
        mode = path.lstat().st_mode
        kind = "directory" if stat.S_ISDIR(mode) else "symlink" if stat.S_ISLNK(mode) else "file"
        if kind == "directory" or private_path(relative, logical_name=logical_name, kind=kind):
            return None
        stage = "input-kind"
        if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
            raise ValueError(error_message)
        stage = "checkout-path"
        checkout = root.joinpath(*relative.parts[:3])
        source_path = PurePosixPath(*relative.parts[3:])
        revision = relative.parts[2]
        if not re.fullmatch(r"[0-9a-f]{7}", revision):
            raise ValueError(error_message)
        check_ancestors(checkout, root)
        stage = "git-layout"
        git_dir = checkout / ".git"
        if git_dir.is_symlink() or not git_dir.is_dir():
            raise ValueError(error_message)
        # Git must consume only this checkout's transferred metadata. Linked
        # worktrees, alternate object stores and internal links can redirect reads.
        if any((git_dir / name).exists() for name in ("commondir", "objects/info/alternates", "config.worktree")):
            raise ValueError(error_message)
        for directory, dirs, files in os.walk(git_dir, followlinks=False):
            for name in dirs + files:
                metadata_mode = (Path(directory) / name).lstat().st_mode
                if not (stat.S_ISDIR(metadata_mode) or stat.S_ISREG(metadata_mode)):
                    raise ValueError(error_message)
        # Ignore ambient configuration and reject checkout-local include/path or
        # command configuration before Git can consume it. Ordinary Cargo clones
        # use core/remote settings; objectformat supports SHA1 and SHA256 fixtures.
        allowed_keys = {
            "core": {"repositoryformatversion", "filemode", "bare", "logallrefupdates", "ignorecase", "precomposeunicode", "autocrlf"},
            "remote": {"url", "fetch", "tagopt", "mirror"},
            "branch": {"remote", "merge"}, "extensions": {"objectformat"},
        }
        section = None
        stage = "git-config"
        for line in (git_dir / "config").read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith(("#", ";")):
                continue
            if line.startswith("["):
                header = re.fullmatch(r'\[([A-Za-z][A-Za-z0-9-]*)(?:\s+"(?:[^"\\]|\\.)*")?\]\s*(?:[#;].*)?', line)
                section = header.group(1).lower() if header else None
                if section not in allowed_keys:
                    raise ValueError(error_message)
            else:
                key = re.match(r"([A-Za-z][A-Za-z0-9-]*)(?:\s*=|\s*$)", line)
                if not key or key.group(1).lower() not in allowed_keys.get(section, set()):
                    raise ValueError(error_message)
        environment = {
            "PATH": os.defpath, "LANG": "C", "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_NO_LAZY_FETCH": "1", "GIT_PAGER": "cat",
        }
        command = ["git", "--no-optional-locks", "--literal-pathspecs",
                   f"--git-dir={git_dir}", f"--work-tree={checkout}",
                   "-c", "core.hooksPath=" + os.devnull, "-c", "core.fsmonitor=false",
                   "-c", "core.pager=cat", "-c", "protocol.allow=never"]

        def read_git(*arguments: str, input_data: bytes | None = None) -> bytes:
            # Identity/path/size output is bounded; never collect object contents.
            def limit_output() -> None:
                resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024, 64 * 1024))

            with tempfile.TemporaryFile() as output:
                subprocess.run(command + list(arguments), input=input_data,
                               stdout=output, stderr=subprocess.DEVNULL,
                               env=environment, timeout=5, check=True, preexec_fn=limit_output)
                output.seek(0)
                data = output.read(64 * 1024 + 1)
                if len(data) > 64 * 1024:
                    raise ValueError(error_message)
                return data

        stage = "git-head"
        head = read_git("rev-parse", "--verify", "HEAD^{commit}").strip()
        if not re.fullmatch(rb"[0-9a-f]{40}|[0-9a-f]{64}", head) or head[:7].decode() != revision:
            raise ValueError(error_message)
        stage = "git-tree"
        tree = read_git("ls-tree", "-z", "--full-tree", head.decode(), "--", str(source_path))
        if not tree.endswith(b"\0") or tree.count(b"\0") != 1:
            raise ValueError(error_message)
        attributes, tracked_path = tree[:-1].split(b"\t", 1)
        tracked_mode, tracked_kind, oid = attributes.split(b" ")
        if (tracked_path != os.fsencode(str(source_path)) or tracked_kind != b"blob"
                or len(oid) != len(head) or not re.fullmatch(rb"[0-9a-f]+", oid)
                or tracked_mode not in ({b"120000"} if kind == "symlink" else {b"100644", b"100755"})):
            raise ValueError(error_message)
        stage = "source-mode"
        if kind == "file" and (mode & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX)
                               or bool(mode & stat.S_IXUSR) != (tracked_mode == b"100755")):
            raise ValueError(error_message)
        # No blob contents pass through subprocess output, hooks or Git filters.
        stage = "git-blob-size"
        description = read_git("cat-file", "--batch-check", input_data=oid + b"\n").split()
        if len(description) != 3 or description[:2] != [oid, b"blob"]:
            raise ValueError(error_message)
        size = int(description[2])
        stage = "source-bytes"
        blob = hashlib.new("sha1" if len(oid) == 40 else "sha256")
        blob.update(f"blob {size}\0".encode())
        digest = hashlib.sha256()
        read_size = 0
        if kind == "symlink":
            data = os.fsencode(os.readlink(path))
            blob.update(data)
            digest.update(data)
            read_size = len(data)
        else:
            with path.open("rb") as source:
                while data := source.read(1024 * 1024):
                    blob.update(data)
                    digest.update(data)
                    read_size += len(data)
        if read_size != size or blob.hexdigest().encode() != oid:
            raise ValueError(error_message)
        return digest.hexdigest()
    except subprocess.TimeoutExpired:
        reason = "git-timeout"
    except subprocess.CalledProcessError as error:
        reason = f"git-exit-{error.returncode}"
    except OSError:
        reason = "io"
    except (ValueError, subprocess.SubprocessError):
        reason = "rejected"
    # Keep the category bounded and source-independent. Exception text, argv,
    # stderr, paths, config values and object contents are never diagnostics.
    raise ValueError(f"{error_message} ({stage}:{reason})") from None


def preflight_credentials(root: Path) -> dict:
    """Check the actual Cargo checkout admission without exporting any cache products."""
    if not root.is_dir() or root.is_symlink():
        raise ValueError("source preflight requires a regular Cargo Git root")
    examined = proven = 0
    try:
        for _, relative in paths_in(root, logical_name="cargo-git"):
            examined += 1
            if verify_credentials_proof(root, "cargo-git", relative) is not None:
                proven += 1
    except OSError:
        raise ValueError("source preflight traversal failed (io)") from None
    return {"examined_entries": examined, "proven_public_inputs": proven}


def excluded_path(name: str, relative: PurePosixPath, *, kind: str | None = None) -> bool:
    # verification_package.py regenerates these source links before compilation.
    # Their sibling scratch products remain cache inputs; source links leave .build.
    return private_path(relative, logical_name=name, kind=kind) or (
        name == "build" and len(relative.parts) >= 2
        and path_key(relative.parts[0]) in {"domain", "engine-free"}
        and path_key(relative.parts[1]) == "package"
    )


def relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (not value or "\0" in value or path.is_absolute() or value != path.as_posix()
            or any(part in {".", ".."} for part in path.parts) or path == PurePosixPath(".")):
        raise ValueError(f"unsafe cache path: {value!r}")
    return path


def check_revision(revision: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a complete lowercase source SHA")


def mappings(scope: str) -> list[dict]:
    return [{"name": name, "base": base, "path": path} for name, base, path in SCOPES[scope]]


def roots_for(scope: str, *, root: Path, cargo_home: Path | None,
              runner_temp: Path | None) -> dict[str, Path]:
    bases = {"repo": root, "cargo": cargo_home, "runner": runner_temp}
    roots = {}
    for name, base_name, relative in SCOPES[scope]:
        base = bases[base_name]
        if base is None:
            raise ValueError(f"{scope} requires --{'cargo-home' if base_name == 'cargo' else 'runner-temp'}")
        # An explicitly supplied base may use the macOS /tmp alias. Cache subpaths may
        # not introduce another symlink or redirect writes outside that chosen base.
        base = base.resolve(strict=True)
        if not base.is_dir():
            raise ValueError(f"cache base is not a directory: {base}")
        destination = base / relative
        check_ancestors(destination, base)
        roots[name] = destination
    return roots


def check_ancestors(path: Path, base: Path) -> None:
    cursor = base
    for part in path.relative_to(base).parts:
        cursor /= part
        if cursor.is_symlink():
            raise ValueError(f"cache destination contains a symlink: {cursor}")


def paths_in(root: Path, relative: PurePosixPath = PurePosixPath("."), *, logical_name: str):
    path = root if relative == PurePosixPath(".") else root / relative
    kind = "directory" if path.is_dir() and not path.is_symlink() else "file"
    if relative != PurePosixPath(".") and excluded_path(logical_name, relative, kind=kind):
        return
    yield path, relative
    if path.is_dir() and not path.is_symlink():
        for child in sorted(path.iterdir(), key=lambda item: os.fsencode(item.name)):
            yield from paths_in(root, relative / child.name, logical_name=logical_name)


def archive_path(name: str, relative: PurePosixPath) -> str:
    prefix = PurePosixPath("payload") / name
    return str(prefix if relative == PurePosixPath(".") else prefix / relative)


def logical_path(value: str, roots: dict[str, Path]) -> tuple[str, PurePosixPath]:
    path = relative_path(value)
    if len(path.parts) < 2 or path.parts[0] != "payload" or path.parts[1] not in roots:
        raise ValueError(f"entry does not belong to the selected scope: {value}")
    relative = PurePosixPath(*path.parts[2:])
    if excluded_path(path.parts[1], relative):
        raise ValueError(f"private store or regenerated package is not a cache entry: {value}")
    return path.parts[1], relative


def safe_symlink(path: str, target: str, roots: dict[str, Path]) -> None:
    name, _ = logical_path(path, roots)
    if not target or "\0" in target or PurePosixPath(target).is_absolute():
        raise ValueError(f"absolute or empty symlink in cache: {path}")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
    target_name, _ = logical_path(resolved, roots)
    if target_name != name:
        raise ValueError(f"symlink leaves its logical cache root: {path}")


def member_record(info: tarfile.TarInfo, digest: str | None = None) -> dict:
    if info.isfile():
        kind = "file"
    elif info.isdir():
        kind = "directory"
    elif info.issym():
        kind = "symlink"
    elif info.islnk():
        kind = "hardlink"
    else:
        raise ValueError(f"unsupported cache entry type: {info.name}")
    record = {"path": info.name.rstrip("/") if info.isdir() else info.name,
              "type": kind, "mode": info.mode, "mtime": info.mtime, "size": info.size}
    if kind in {"symlink", "hardlink"}:
        record["linkname"] = info.linkname
    if kind in {"file", "hardlink"}:
        record["sha256"] = digest
    return record


class HashingReader:
    def __init__(self, source):
        self.source = source
        self.digest = hashlib.sha256()

    def read(self, size):
        data = self.source.read(size)
        self.digest.update(data)
        return data


def export_bundle(archive: Path, *, scope: str, revision: str, roots: dict[str, Path]) -> dict:
    check_revision(revision)
    archive = archive.resolve()
    if archive.exists():
        raise ValueError("cache export archive already exists")
    if any(archive.is_relative_to(root) for root in roots.values()):
        raise ValueError("cache archive cannot be inside an exported root")
    archive.parent.mkdir(parents=True, exist_ok=True)
    entries = {}
    temporary = tempfile.NamedTemporaryFile(prefix=".spotty-cache-", dir=archive.parent, delete=False)
    temporary_path = Path(temporary.name)
    temporary.close()
    try:
        with tarfile.open(temporary_path, "w:gz", format=tarfile.PAX_FORMAT, compresslevel=3) as output:
            for name, root in roots.items():
                if not root.exists():
                    continue
                for path, relative in paths_in(root, logical_name=name):
                    arcname = archive_path(name, relative)
                    before = path.lstat()
                    info = output.gettarinfo(str(path), arcname=arcname)
                    if info.issym():
                        safe_symlink(arcname, info.linkname, roots)
                    elif info.islnk():
                        logical_path(info.linkname, roots)
                        if info.linkname not in entries or entries[info.linkname]["type"] != "file":
                            raise ValueError(f"hardlink target is not a regular cache entry: {arcname}")
                    elif not (info.isfile() or info.isdir()):
                        raise ValueError(f"unsupported cache entry type: {arcname}")
                    proof = verify_credentials_proof(root, name, relative)
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mode &= 0o7777
                    digest = None
                    if info.isfile():
                        with path.open("rb") as source:
                            reader = HashingReader(source)
                            output.addfile(info, reader)
                            digest = reader.digest.hexdigest()
                    else:
                        output.addfile(info)
                        if info.islnk():
                            digest = entries[info.linkname]["sha256"]
                    if proof is not None:
                        archived_digest = hashlib.sha256(os.fsencode(info.linkname)).hexdigest() if info.issym() else digest
                        if archived_digest != proof:
                            raise ValueError("public credentials source changed after HEAD proof")
                    after = path.lstat()
                    if (before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) != (
                            after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode):
                        raise ValueError(f"cache input changed during export: {arcname}")
                    entries[arcname] = member_record(info, digest)
            validate_structure(entries, roots)
            manifest = {"schema_version": SCHEMA_VERSION, "revision": revision, "scope": scope,
                        "roots": mappings(scope), "entries": list(entries.values())}
            data = json.dumps(manifest, separators=(",", ":"), allow_nan=False).encode()
            info = tarfile.TarInfo("manifest.json")
            info.size = len(data)
            info.mode = 0o600
            output.addfile(info, io.BytesIO(data))
        # Refuse overwriting a concurrent exporter too.
        os.link(temporary_path, archive)
        return bundle_stats(entries, archive)
    finally:
        temporary_path.unlink(missing_ok=True)


def validate_structure(entries: dict[str, dict], roots: dict[str, Path]) -> None:
    folded = {}
    for path, entry in entries.items():
        key = path_key(path)
        if key in folded:
            raise ValueError(f"cache paths alias on macOS: {path}")
        folded[key] = entry
    for path, entry in entries.items():
        name, relative = logical_path(path, roots)
        if excluded_path(name, relative, kind=entry["type"]):
            raise ValueError(f"private store is not a cache entry: {path}")
        if (name == "cargo-git" and entry["type"] in {"file", "hardlink", "symlink"}
                and "credentials" in {path_key(part) for part in relative.parts}
                and entry["mode"] & 0o7000):
            raise ValueError("public credentials source has unsupported special permission bits")
        parent = PurePosixPath(path).parent
        prefix = PurePosixPath("payload") / name
        while parent != prefix.parent:
            if parent != PurePosixPath(path):
                owner = entries.get(str(parent))
                if owner is None or owner["type"] != "directory":
                    raise ValueError(f"cache entry has a missing or non-directory ancestor: {path}")
            if parent == prefix:
                break
            parent = parent.parent
        if entry["type"] == "symlink":
            safe_symlink(path, entry["linkname"], roots)
            resolve_symlink(path, entries, roots, folded)
        elif entry["type"] == "hardlink":
            logical_path(entry["linkname"], roots)
            target = entries.get(entry["linkname"])
            if (target is None or target["type"] != "file" or target["sha256"] != entry["sha256"]
                    or target["mode"] != entry["mode"] or target["mtime"] != entry["mtime"]):
                raise ValueError(f"hardlink does not name a regular cache file: {path}")
        if relative == PurePosixPath("."):
            required_type = "file" if roots[name].name == ".rustc_info.json" else "directory"
            if entry["type"] != required_type:
                raise ValueError(f"logical cache root must be a {required_type}: {path}")


def resolve_symlink(path: str, entries: dict[str, dict], roots: dict[str, Path],
                    folded: dict[str, dict]) -> tuple[str, PurePosixPath]:
    # Lexical normalization alone is insufficient: `alias/..` follows alias before
    # applying '..'. Resolve archive-owned links component by component too.
    name, _ = logical_path(path, roots)
    prefix = PurePosixPath("payload") / name
    stack = list(PurePosixPath(path).parts[2:-1])
    pending = list(PurePosixPath(entries[path]["linkname"]).parts)
    links = 0
    while pending:
        part = pending.pop(0)
        if part == ".":
            continue
        if part == "..":
            if not stack:
                raise ValueError(f"symlink chain escapes its cache root: {path}")
            stack.pop()
            continue
        stack.append(part)
        relative = PurePosixPath(*stack)
        candidate = folded.get(path_key(str(prefix / relative)))
        # A lexical public-directory exception cannot expose a retained private
        # file/link or a dangling target. The manifest must own that directory.
        if excluded_path(name, relative, kind=candidate["type"] if candidate else "missing"):
            raise ValueError(f"symlink chain reaches an excluded cache input: {path}")
        if candidate is not None and candidate["type"] == "symlink":
            links += 1
            if links > 40:
                raise ValueError(f"cyclic or excessive symlink chain: {path}")
            stack.pop()
            pending = list(PurePosixPath(candidate["linkname"]).parts) + pending
    return name, PurePosixPath(*stack)


def existing_parent(path: Path) -> Path:
    parent = path.parent
    while not parent.exists():
        parent = parent.parent
    return parent


def bundle_stats(entries: dict[str, dict], archive: Path) -> dict:
    return {"entries": len(entries),
            "payload_bytes": sum(entry["size"] for entry in entries.values() if entry["type"] == "file"),
            "archive_bytes": archive.stat().st_size}


def load_bundle(source: tarfile.TarFile, *, scope: str, revision: str,
                roots: dict[str, Path]) -> tuple[dict[str, dict], dict[str, tarfile.TarInfo]]:
    members = {}
    for info in source.getmembers():
        name = info.name.rstrip("/") if info.isdir() else info.name
        relative_path(name)
        if name in members:
            raise ValueError(f"duplicate cache archive entry: {name}")
        members[name] = info
    manifest_info = members.pop("manifest.json", None)
    if manifest_info is None or not manifest_info.isfile() or manifest_info.size > 64 * 1024 * 1024:
        raise ValueError("cache archive requires one bounded regular manifest")
    with source.extractfile(manifest_info) as manifest_file:
        manifest = json.load(manifest_file)
    if (not isinstance(manifest, dict) or manifest.get("schema_version") != SCHEMA_VERSION
            or manifest.get("revision") != revision or manifest.get("scope") != scope
            or manifest.get("roots") != mappings(scope) or not isinstance(manifest.get("entries"), list)):
        raise ValueError("cache manifest schema, source, scope, or root mapping mismatch")
    entries = {}
    for record in manifest["entries"]:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise ValueError("invalid cache manifest entry")
        path = record["path"]
        logical_path(path, roots)
        if path in entries or path not in members:
            raise ValueError("duplicate or missing cache manifest entry")
        info = members[path]
        if (info.sparse is not None or not isinstance(info.mtime, (int, float)) or not math.isfinite(info.mtime)
                or info.mode < 0 or info.mode > 0o7777 or info.size < 0 or (not info.isfile() and info.size != 0)):
            raise ValueError(f"invalid cache metadata: {path}")
        digest = record.get("sha256")
        if info.isfile() or info.islnk():
            if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError(f"invalid cache file hash: {path}")
        if record != member_record(info, digest):
            raise ValueError(f"cache member metadata does not match manifest: {path}")
        entries[path] = record
    if set(entries) != set(members):
        raise ValueError("cache archive contains unlisted entries")
    validate_structure(entries, roots)
    return entries, members


def stage_bundle(source: tarfile.TarFile, stage: Path, entries: dict[str, dict],
                 members: dict[str, tarfile.TarInfo]) -> None:
    # Preserve tar order for data reads. Sorting compressed members by path/depth
    # would repeatedly rewind gzip and turn a large restore into quadratic work.
    for path in members:
        entry = entries[path]
        destination = stage / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        if entry["type"] == "directory":
            destination.mkdir(exist_ok=True)
        elif entry["type"] == "file":
            digest = hashlib.sha256()
            with source.extractfile(members[path]) as input_file, destination.open("xb") as output:
                while chunk := input_file.read(1024 * 1024):
                    digest.update(chunk)
                    output.write(chunk)
            if digest.hexdigest() != entry["sha256"] or destination.stat().st_size != entry["size"]:
                raise ValueError(f"cache content hash or size mismatch: {path}")
        # Links are created after all regular data is checked and staged.
    for path, entry in entries.items():
        destination = stage / path
        if entry["type"] == "symlink":
            destination.symlink_to(entry["linkname"])
        elif entry["type"] == "hardlink":
            os.link(stage / entry["linkname"], destination)
    # Preflight platform metadata before any reset. File metadata survives rename;
    # directories keep permissive staging modes until their children are moved.
    probe = stage / ".metadata-probe"
    probe.touch()
    for path, entry in entries.items():
        destination = stage / path
        try:
            if entry["type"] == "directory":
                probe.chmod(entry["mode"])
                os.utime(probe, (entry["mtime"], entry["mtime"]))
            elif entry["type"] == "symlink":
                if destination.lstat().st_mode & 0o7777 != entry["mode"]:
                    if not hasattr(os, "lchmod"):
                        raise ValueError("symlink permissions are unsupported on this platform")
                    os.lchmod(destination, entry["mode"])
                os.utime(destination, (entry["mtime"], entry["mtime"]), follow_symlinks=False)
            else:
                destination.chmod(entry["mode"])
                os.utime(destination, (entry["mtime"], entry["mtime"]))
        except (OSError, OverflowError) as error:
            raise ValueError(f"unsupported cache metadata: {path}") from error


def retained_private_inputs(path: Path, relative: PurePosixPath = PurePosixPath("."),
                            *, logical_name: str, source_root: Path | None = None) -> tuple[set[str], set[str]]:
    ancestors, exact = set(), set()
    if not path.exists() and not path.is_symlink():
        return ancestors, exact
    source_root = path if source_root is None else source_root
    kind = "directory" if path.is_dir() and not path.is_symlink() else "file"
    private = private_path(relative, logical_name=logical_name, kind=kind)
    if not private and kind != "directory":
        try:
            verify_credentials_proof(source_root, logical_name, relative)
        except (OSError, ValueError):
            private = True
    if private:
        exact.add(path_key(str(relative)))
        parent = relative.parent
        while True:
            ancestors.add(path_key(str(parent)))
            if parent == PurePosixPath("."):
                break
            parent = parent.parent
    elif path.is_dir() and not path.is_symlink():
        for child in path.iterdir():
            child_ancestors, child_exact = retained_private_inputs(child, relative / child.name,
                                                                 logical_name=logical_name, source_root=source_root)
            ancestors.update(child_ancestors)
            exact.update(child_exact)
    return ancestors, exact


def reset_owned_path(path: Path, relative: PurePosixPath = PurePosixPath("."), *, logical_name: str,
                     protected: set[str]) -> None:
    kind = "directory" if path.is_dir() and not path.is_symlink() else "file"
    if path_key(str(relative)) in protected or private_path(relative, logical_name=logical_name, kind=kind):
        return
    if path.is_symlink() or not path.is_dir():
        path.unlink(missing_ok=True)
    elif path.exists():
        for child in path.iterdir():
            reset_owned_path(child, relative / child.name, logical_name=logical_name, protected=protected)
        if not any(path.iterdir()):
            path.rmdir()


def restore_bundle(archive: Path, *, scope: str, revision: str, roots: dict[str, Path],
                   replace_owned_scope: bool = False) -> dict:
    check_revision(revision)
    if any(archive.resolve().is_relative_to(root) for root in roots.values()):
        raise ValueError("cache archive cannot be inside a restored root")
    with tarfile.open(archive, "r:*") as source:
        entries, members = load_bundle(source, scope=scope, revision=revision, roots=roots)
        # Default restoration requires fresh roots, so pre-existing unlisted links
        # cannot alter the meaning of otherwise safe incoming relative symlinks.
        if not replace_owned_scope:
            for root in roots.values():
                if root.exists() and (not root.is_dir() or any(root.iterdir())):
                    raise ValueError("cache restore would overwrite or merge an existing cache root")
        retained = {name: retained_private_inputs(root, logical_name=name)
                    for name, root in roots.items()} if replace_owned_scope else {}
        folded = {path_key(path): entry for path, entry in entries.items()}
        for path, entry in entries.items():
            name, relative = logical_path(path, roots)
            ancestors, exact = retained.get(name, (set(), set()))
            if (path_key(str(relative)) in exact
                    or (entry["type"] != "directory" and path_key(str(relative)) in ancestors)):
                raise ValueError(f"cache entry collides with a retained private directory: {path}")
            if entry["type"] == "symlink" and replace_owned_scope:
                target_name, target_relative = resolve_symlink(path, entries, roots, folded)
                target_ancestors, target_exact = retained.get(target_name, (set(), set()))
                if (path_key(str(target_relative)) in target_ancestors
                        or any(path_key(str(parent)) in target_exact
                               for parent in (target_relative, *target_relative.parents))):
                    raise ValueError("cache symlink reaches a retained private input")
        stage_parent = existing_parent(next(iter(roots.values())))
        if any(existing_parent(root).stat().st_dev != stage_parent.stat().st_dev for root in roots.values()):
            raise ValueError("cache scope destinations must share a filesystem to preserve hardlinks")
        with tempfile.TemporaryDirectory(prefix=".spotty-ci-cache-restore-", dir=stage_parent) as directory:
            stage = Path(directory)
            stage_bundle(source, stage, entries, members)
            for path in entries:
                name, relative = logical_path(path, roots)
                verify_credentials_proof(stage / "payload" / name, name, relative)
            if replace_owned_scope:
                for name, root in roots.items():
                    reset_owned_path(root, logical_name=name, protected=retained[name][1])
            for path, entry in sorted(entries.items(), key=lambda pair: (len(PurePosixPath(pair[0]).parts), pair[0])):
                name, relative = logical_path(path, roots)
                destination = roots[name] if relative == PurePosixPath(".") else roots[name] / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                if entry["type"] == "directory":
                    destination.mkdir(exist_ok=True)
                else:
                    os.replace(stage / path, destination)
            for path, entry in sorted(entries.items(), key=lambda pair: len(PurePosixPath(pair[0]).parts), reverse=True):
                if entry["type"] == "directory":
                    name, relative = logical_path(path, roots)
                    destination = roots[name] if relative == PurePosixPath(".") else roots[name] / relative
                    os.utime(destination, (entry["mtime"], entry["mtime"]))
                    destination.chmod(entry["mode"])
    return bundle_stats(entries, archive)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("export", "restore", "preflight"))
    parser.add_argument("--scope", choices=SCOPES, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--cargo-home", type=Path)
    parser.add_argument("--runner-temp", type=Path)
    parser.add_argument("--replace-owned-scope", action="store_true",
                        help="restore only: clear the listed cache roots in a fresh publisher workspace")
    args = parser.parse_args()
    started = time.monotonic()
    try:
        check_revision(args.revision)
        if args.action == "preflight":
            if args.scope != "rust-debug" or args.archive is not None or args.replace_owned_scope:
                raise ValueError("source preflight requires rust-debug without archive or replacement options")
        elif args.archive is None:
            raise ValueError("cache export and restore require --archive")
        try:
            roots = roots_for(args.scope, root=args.root, cargo_home=args.cargo_home,
                              runner_temp=args.runner_temp)
        except (OSError, ValueError):
            if args.action == "preflight":
                raise ValueError("source preflight root mapping rejected") from None
            raise
        if args.action == "preflight":
            result = preflight_credentials(roots["cargo-git"])
        elif args.action == "export":
            if args.replace_owned_scope:
                raise ValueError("--replace-owned-scope applies only to restore")
            result = export_bundle(args.archive, scope=args.scope, revision=args.revision, roots=roots)
        else:
            result = restore_bundle(args.archive, scope=args.scope, revision=args.revision, roots=roots,
                                    replace_owned_scope=args.replace_owned_scope)
    except (OSError, ValueError, tarfile.TarError) as error:
        if args.action == "preflight" and isinstance(error, OSError):
            parser.exit(1, "CI cache bundle: source preflight filesystem access failed (io)\n")
        parser.exit(1, f"CI cache bundle: {error}\n")
    result.update(action=args.action, scope=args.scope, revision=args.revision,
                  elapsed_seconds=round(time.monotonic() - started, 6))
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
