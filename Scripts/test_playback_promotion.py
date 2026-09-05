import copy
import hashlib
import io
import json
import unittest
import zipfile

from playback_promotion import (
    promote, release_tag, validate_artifact, validate_checkout, validate_payload, validate_run,
)


HEAD = "a" * 40
BASE = "b" * 40
DIGEST = "d" * 64


def zip_bytes(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return buffer.getvalue()


def payload():
    provenance = json.dumps({"source": {
        "sourceDirty": False, "sourceRevision": HEAD, "engineInputDigest": DIGEST,
    }}).encode()
    notices = {"Notices/source/" + name: name.encode()
               for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md")}
    notices["Notices/ThirdPartyNotices.md"] = b"Dependency licenses"
    notices["Notices/manifest.json"] = b"{}"
    framework = {"SpottyPlaybackCore.xcframework/" + name: content
                 for name, content in notices.items()}
    framework["SpottyPlaybackCore.xcframework/spotty_playback_provenance.json"] = provenance
    archive = zip_bytes(framework)
    return {
        "SpottyPlaybackCore.xcframework.zip": archive,
        "SpottyPlaybackCore.xcframework.zip.sha256":
            (hashlib.sha256(archive).hexdigest() + "  SpottyPlaybackCore.xcframework.zip\n").encode(),
        "SpottyPlaybackCore-notices.zip": zip_bytes(notices),
        "spotty_playback_provenance.json": provenance,
        "source-provenance.txt":
            f"source_sha={HEAD}\nsource_ref={HEAD}\nsource_input_digest={DIGEST}\n".encode(),
        **{name: name.encode() for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md")},
    }


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.run = {
            "repository": {"full_name": "owner/repo"},
            "head_repository": {"full_name": "owner/repo"},
            "path": ".github/workflows/ci.yml", "event": "push", "head_branch": "main",
            "head_sha": HEAD, "status": "completed", "conclusion": "failure",
        }
        self.jobs = [{"name": name, "conclusion": "success", "started_at": "2026-09-05T12:00:00Z",
                      "completed_at": "2026-09-05T12:10:00Z"} for name in ("Rust checks", "Candidate Swift debug", "Candidate Swift release")]
        for job in self.jobs[1:]:
            job["started_at"] = "2026-09-05T12:11:00Z"
        self.artifact = {"expired": False, "created_at": "2026-09-05T12:09:00Z"}

    def test_failed_published_pin_does_not_block_successful_candidate(self):
        validate_run(self.run, self.jobs, "owner/repo", HEAD)
        validate_checkout(self.run, HEAD)
        validate_artifact(self.artifact, self.jobs)
        self.assertEqual(validate_payload(payload(), HEAD), (HEAD, DIGEST))

    def promotion_inputs(self):
        bundle = zip_bytes(payload())
        return dict(
            run=self.run, jobs=self.jobs,
            artifacts=[{**self.artifact, "name": f"playback-candidate-{HEAD}",
                        "digest": "sha256:" + hashlib.sha256(bundle).hexdigest()}],
            bundle=bundle,
            comparison="ahead", workflow_bytes=b"trusted CI", trusted_ci=b"trusted CI",
            source_ref=HEAD, repo="owner/repo")

    def test_complete_promotion_returns_exact_publication_bytes(self):
        args = self.promotion_inputs()
        source, digest, assets = promote(**args)
        self.assertEqual((source, digest), (HEAD, DIGEST))
        # Compare to the actual bundle contents, including unchanged archive bytes.
        with zipfile.ZipFile(io.BytesIO(args["bundle"])) as archive:
            self.assertEqual(assets, {name: archive.read(name) for name in archive.namelist()})

    def test_promotion_rejects_missing_or_ambiguous_candidates(self):
        args = self.promotion_inputs()
        for artifacts in ([], args["artifacts"] * 2, [{"name": "size-report"}]):
            with self.subTest(artifacts=artifacts), self.assertRaises(ValueError):
                promote(**{**args, "artifacts": artifacts})

    def test_promotion_rejects_untrusted_bytes_workflow_or_base(self):
        for change in ({"bundle": b"tampered"}, {"workflow_bytes": b"modified CI"},
                       {"comparison": "diverged"}, {"comparison": "behind"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                promote(**{**self.promotion_inputs(), **change})

    def test_promotion_rejects_missing_asset(self):
        args = self.promotion_inputs()
        files = payload()
        del files["LICENSE"]
        args["bundle"] = zip_bytes(files)
        args["artifacts"][0]["digest"] = "sha256:" + hashlib.sha256(args["bundle"]).hexdigest()
        with self.assertRaises(KeyError):
            promote(**args)

    def test_release_versions_use_a_separate_tag_namespace(self):
        self.assertEqual(release_tag("0.1.0"), "playback-v0.1.0")
        self.assertEqual(release_tag("1.20.3"), "playback-v1.20.3")
        for version in ("v0.1.0", "01.0.0", "0.1", "0.1.0-beta", "0.1.0\n", "../v0.1.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release_tag(version)

    def test_wrong_origin_or_source_is_rejected(self):
        for key, value in (("head_sha", BASE), ("event", "workflow_dispatch"),
                           ("event", "pull_request"), ("head_branch", "feature"),
                           ("path", ".github/workflows/fake.yml"), ("status", "in_progress"),
                           ("head_repository", {"full_name": "fork/repo"})):
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_run({**self.run, key: value}, self.jobs, "owner/repo", HEAD)

    def test_every_candidate_job_must_pass(self):
        for index in range(len(self.jobs)):
            for conclusion in ("failure", "skipped", "cancelled", None):
                jobs = copy.deepcopy(self.jobs)
                jobs[index]["conclusion"] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(ValueError):
                    validate_run(self.run, jobs, "owner/repo", HEAD)
        with self.assertRaises(ValueError):
            validate_run(self.run, self.jobs[:-1], "owner/repo", HEAD)

    def test_stale_artifact_cannot_borrow_a_rerun_success(self):
        with self.assertRaises(ValueError):
            validate_artifact({**self.artifact, "created_at": "2026-09-04T12:09:00Z"}, self.jobs)
        with self.assertRaises(ValueError):
            validate_artifact({**self.artifact, "expired": True}, self.jobs)

    def test_different_checkout_is_rejected(self):
        with self.assertRaises(ValueError):
            validate_checkout(self.run, BASE)
        validate_checkout(self.run, HEAD)

    def test_tampering_is_rejected(self):
        for asset in ("SpottyPlaybackCore.xcframework.zip", "LICENSE", "NOTICE"):
            assets = payload()
            assets[asset] += b"modified"
            with self.subTest(asset=asset), self.assertRaises(ValueError):
                validate_payload(assets, HEAD)
        assets = payload()
        assets["SpottyPlaybackCore-notices.zip"] = zip_bytes({"Notices/fake": b"fake"})
        with self.assertRaises(ValueError):
            validate_payload(assets, HEAD)

    def test_provenance_must_match_embedded_archive(self):
        for key, value in (("sourceDirty", True), ("sourceRevision", BASE),
                           ("engineInputDigest", "e" * 64)):
            assets = payload()
            provenance = json.loads(assets["spotty_playback_provenance.json"])
            provenance["source"][key] = value
            assets["spotty_playback_provenance.json"] = json.dumps(provenance).encode()
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_payload(assets, HEAD)
        assets = payload()
        assets["source-provenance.txt"] += f"source_ref={HEAD}\n".encode()
        with self.assertRaises(ValueError):
            validate_payload(assets, HEAD)


if __name__ == "__main__":
    unittest.main()
