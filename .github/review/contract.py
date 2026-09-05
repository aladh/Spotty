"""Pure validation primitives shared by the review and inline publishers."""

import hashlib
import re
from pathlib import PurePosixPath


FINDING_KEYS = frozenset(("id", "path", "line", "severity", "title", "body"))
FINDING_ID_RE = re.compile(r"F[0-9a-f]{12}")
SEVERITIES = ("P1", "P2", "P3")
MAX_TITLE = 160
MAX_BODY = 1_500
MAX_RESOLUTION = 1_000


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(name):
    """Return whether *name* is a safe repository-relative POSIX path."""
    if not isinstance(name, str):
        return False
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts \
        and "\\" not in name and all(ord(char) >= 32 for char in name) and ".git" not in path.parts


def bounded_text(value, limit, label):
    """Validate and trim bounded model prose."""
    _require(isinstance(value, str) and 0 < len(value.strip()) <= limit, "Invalid " + label)
    return value.strip()


def canonical_finding_id(path, line, title):
    """Derive the stable ID used when a new model finding omits its ID."""
    return "F" + hashlib.sha256((path + "\0" + str(line) + "\0" + title.casefold()).encode()).hexdigest()[:12]


def validate_finding(item, meta, *, allow_empty_id=False):
    """Validate one source-bound finding and return its normalized fields.

    ``allow_empty_id`` is used by the model-response validator before it
    assigns a canonical ID.  Inline publication always requires an assigned
    stable ID at its own boundary.
    """
    _require(isinstance(item, dict) and set(item) == FINDING_KEYS, "Invalid finding schema")
    _require(isinstance(meta, dict), "Missing finding source metadata")
    changed = meta.get("changed")
    files = meta.get("files")
    diff_lines = meta.get("diff_lines")
    _require(isinstance(changed, (list, tuple)) and isinstance(files, dict)
             and isinstance(diff_lines, dict), "Missing finding source metadata")

    path = item["path"]
    line = item["line"]
    _require(isinstance(path, str) and safe_path(path) and path in changed and path in files,
             "Finding outside reviewed source")
    _require(type(files[path]) is int and files[path] >= 0,
             "Invalid source line metadata")
    _require(type(line) is int and 1 <= line <= files[path], "Invalid finding line")
    anchors = diff_lines.get(path)
    _require(isinstance(anchors, (list, tuple, set)) and line in anchors,
             "Finding line is not in a changed diff hunk")

    identity = item["id"]
    valid_id = isinstance(identity, str) and FINDING_ID_RE.fullmatch(identity)
    _require(valid_id or (allow_empty_id and identity == ""), "Invalid finding ID")
    severity = item["severity"]
    _require(severity in SEVERITIES, "Invalid severity")
    title = bounded_text(item["title"], MAX_TITLE, "title")
    body = bounded_text(item["body"], MAX_BODY, "finding body")
    return {"id": identity, "path": path, "line": line, "severity": severity,
            "title": title, "body": body}


def _diff_right_lines(diff):
    """Right-side ranges from a single file's diff, independent of quoted Git path headers."""
    anchors = set()
    for match in re.finditer(rb'^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@', diff, re.MULTILINE):
        start = int(match[1])
        count = int(match[2]) if match[2] is not None else 1
        anchors.update(range(start, start + count))
    return sorted(anchors)
