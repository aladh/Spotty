"""Promote a CI candidate without executing code from its source or archive."""

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


ASSETS = (
    "SpottyPlaybackCore.xcframework.zip",
    "SpottyPlaybackCore.xcframework.zip.sha256",
    "source-provenance.txt",
    "spotty_playback_provenance.json",
    "SpottyPlaybackCore-notices.zip",
    "LICENSE",
    "NOTICE",
    "THIRD_PARTY_NOTICES.md",
)
REQUIRED_JOBS = ("Rust checks", "Candidate Swift debug", "Candidate Swift release")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def release_tag(version):
    require(re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version),
            "Engine version must be MAJOR.MINOR.PATCH without a prefix or leading zeroes")
    return f"playback-v{version}"


def validate_run(run, jobs, repo, source_ref):
    require(re.fullmatch(r"[0-9a-f]{40}", source_ref), "Expected a full reviewed source SHA")
    require(run["repository"]["full_name"] == repo, "Wrong repository")
    require(run["head_repository"]["full_name"] == repo, "Fork candidates cannot be published")
    require(run["path"] == ".github/workflows/ci.yml", "Candidate must come from CI")
    require(run["event"] == "push" and run["head_branch"] == "main",
            "Candidate must come from a main-branch push CI run")
    require(run["head_sha"] == source_ref, "CI run does not cover the reviewed source")
    require(run["status"] == "completed", "CI run is still running")
    # Published-pin jobs can fail before an ABI-changing candidate has been published.
    for name in REQUIRED_JOBS:
        matches = [job for job in jobs if job["name"] == name]
        require(len(matches) == 1 and matches[0]["conclusion"] == "success",
                f"Missing successful {name} in this run attempt")


def validate_checkout(run, source_sha):
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha), "Invalid candidate checkout SHA")
    require(source_sha == run["head_sha"], "Candidate checkout differs from main CI SHA")


def validate_artifact(artifact, jobs):
    require(not artifact["expired"], "Candidate artifact expired; run CI again")
    rust = next(job for job in jobs if job["name"] == "Rust checks")
    created = artifact["created_at"]
    require(rust["started_at"] <= created <= rust["completed_at"],
            "Artifact was not uploaded by the successful Rust job in this attempt")
    for job in jobs:
        if job["name"] in REQUIRED_JOBS[1:]:
            require(created <= job["started_at"], "Candidate was uploaded after Swift checks started")


def read_payload(data):
    # Read only known files; never extract paths or execute candidate content.
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        require(len(archive.namelist()) == len(set(archive.namelist())), "Duplicate artifact entries")
        return {name: archive.read(name) for name in ASSETS}


def validate_payload(assets, source_ref):
    checksum = assets[ASSETS[1]].decode().split()
    require(len(checksum) == 2 and checksum[1] == ASSETS[0], "Invalid archive checksum file")
    require(hashlib.sha256(assets[ASSETS[0]]).hexdigest() == checksum[0], "Archive checksum mismatch")
    lines = assets["source-provenance.txt"].decode().splitlines()
    pairs = [line.split("=", 1) for line in lines]
    require(all(len(pair) == 2 for pair in pairs), "Malformed source provenance")
    sidecar = dict(pairs)
    require(len(sidecar) == len(pairs) == 3, "Duplicate or unexpected source provenance fields")
    require(sidecar["source_ref"] == source_ref, "Candidate does not name the reviewed source")
    provenance_bytes = assets["spotty_playback_provenance.json"]
    provenance = json.loads(provenance_bytes)
    source = provenance["source"]
    require(source["sourceDirty"] is False, "Dirty candidate source")
    require(source["sourceRevision"] == sidecar["source_sha"], "Source provenance mismatch")
    digest = source["engineInputDigest"]
    require(re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid engine input digest")
    require(digest == sidecar["source_input_digest"], "Engine input digest mismatch")
    prefix = "SpottyPlaybackCore.xcframework/"
    with zipfile.ZipFile(io.BytesIO(assets[ASSETS[0]])) as archive:
        require(len(archive.namelist()) == len(set(archive.namelist())), "Duplicate framework entries")
        require(archive.read(prefix + "spotty_playback_provenance.json") == provenance_bytes,
                "Embedded provenance differs from publication provenance")
        with zipfile.ZipFile(io.BytesIO(assets["SpottyPlaybackCore-notices.zip"])) as notices:
            expected = {name[len(prefix):] for name in archive.namelist()
                        if name.startswith(prefix + "Notices/") and not name.endswith("/")}
            actual = [name for name in notices.namelist() if not name.endswith("/")]
            require(len(actual) == len(set(actual)) and set(actual) == expected,
                    "Publication notices differ from tested archive")
            for name in actual:
                require(notices.read(name) == archive.read(prefix + name), "Notice content mismatch")
        for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
            require(assets[name] == archive.read(prefix + "Notices/source/" + name),
                    "Publication license differs from tested archive")
    return sidecar["source_sha"], digest


def candidate_artifact(artifacts):
    candidates = [a for a in artifacts if a["name"].startswith("playback-candidate-")]
    require(len(candidates) == 1, "Expected one immutable playback candidate")
    return candidates[0]


def promote(run, jobs, artifacts, bundle, comparison, workflow_bytes,
            trusted_ci, source_ref, repo):
    validate_run(run, jobs, repo, source_ref)
    artifact = candidate_artifact(artifacts)
    validate_artifact(artifact, jobs)
    require(artifact.get("digest") == "sha256:" + hashlib.sha256(bundle).hexdigest(),
            "Downloaded artifact does not match GitHub's immutable digest")
    assets = read_payload(bundle)
    source_sha, digest = validate_payload(assets, source_ref)
    require(artifact["name"] == f"playback-candidate-{source_sha}", "Artifact name/checkout mismatch")
    validate_checkout(run, source_sha)
    require(comparison in ("ahead", "identical"), "Candidate source is not on publisher main history")
    require(workflow_bytes == trusted_ci,
            "Candidate CI definition differs from the trusted publisher checkout; run current CI")
    return source_sha, digest, assets


def api(path, raw=False):
    result = subprocess.check_output(["gh", "api", "--allow-escape-sequences", path])
    return result if raw else json.loads(result)


def pages(path, key):
    result = []
    page = 1
    while True:
        batch = api(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")[key]
        result.extend(batch)
        if len(batch) < 100:
            return result
        page += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    tag = release_tag(args.version)
    repo = os.environ["GITHUB_REPOSITORY"]
    root = f"repos/{repo}"
    run_path = f"{root}/actions/runs/{args.run_id}"
    run = api(run_path)
    jobs = pages(f"{run_path}/attempts/{run['run_attempt']}/jobs", "jobs")
    validate_run(run, jobs, repo, args.source_ref)
    artifacts = pages(f"{run_path}/artifacts", "artifacts")
    artifact = candidate_artifact(artifacts)
    data = api(f"{root}/actions/artifacts/{artifact['id']}/zip", raw=True)
    # Parse the checkout only to fetch its GitHub metadata; promote validates before any writes.
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        source_sha = json.loads(archive.read("spotty_playback_provenance.json"))["source"]["sourceRevision"]
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha), "Invalid candidate checkout SHA")
    validate_checkout(run, source_sha)
    comparison = api(f"{root}/compare/{source_sha}...{os.environ['GITHUB_SHA']}")["status"]
    workflow = api(f"{root}/contents/.github/workflows/ci.yml?ref={source_sha}")
    source_sha, digest, assets = promote(
        run, jobs, artifacts, data, comparison, base64.b64decode(workflow["content"]),
        Path(".github/workflows/ci.yml").read_bytes(), args.source_ref, repo)
    args.output.mkdir(parents=True, exist_ok=False)
    for name, content in assets.items():
        (args.output / name).write_bytes(content)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"source_sha={source_sha}\nengine_digest={digest}\nversion={args.version}\nrelease_tag={tag}\n")
    print(f"Validated candidate {artifact['id']} from CI run {args.run_id}, checkout {source_sha}")


if __name__ == "__main__":
    main()
