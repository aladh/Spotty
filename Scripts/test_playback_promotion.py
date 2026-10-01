import copy
import hashlib
import io
import json
import unittest
from pathlib import Path
import zipfile

from playback_promotion import (
    PRODUCER_STEPS, promote, release_tag, validate_artifact, validate_checkout, validate_payload, validate_run,
)


HEAD = "a" * 40
BASE = "b" * 40
DIGEST = "d" * 64
WORKFLOW = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_bytes()


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
        self.jobs = [
            {"name": "Source policies", "conclusion": "success"},
            {"name": "Playback script checks", "conclusion": "success"},
            {"name": "macOS verification", "conclusion": "failure", "steps": [
                {"name": name, "conclusion": "success", "started_at": "2026-09-05T12:00:00Z",
                 "completed_at": "2026-09-05T12:10:00Z"} for name in PRODUCER_STEPS
            ] + [{"name": "Run checks", "conclusion": "failure"}],
        }]
        self.upload_step = next(step for step in self.jobs[2]["steps"]
                                if step["name"] == "Upload candidate playback artifact")
        self.upload_step["started_at"] = "2026-09-05T12:08:00Z"
        self.artifact = {"expired": False, "created_at": "2026-09-05T12:09:00Z"}

    def test_engine_promotion_survives_later_swift_failure(self):
        validate_run(self.run, self.jobs, "owner/repo", HEAD)
        validate_checkout(self.run, HEAD)
        validate_artifact(self.artifact, self.jobs)
        self.assertEqual(validate_payload(payload(), HEAD), (HEAD, DIGEST))

    def test_engine_promotion_survives_later_cache_export_failure(self):
        self.jobs[2]["steps"] = [step for step in self.jobs[2]["steps"] if step["name"] in PRODUCER_STEPS]
        self.jobs[2]["steps"].append({"name": "Export rust-debug cache products", "conclusion": "failure"})
        source, digest, _ = promote(**self.promotion_inputs())
        self.assertEqual((source, digest), (HEAD, DIGEST))

    def promotion_inputs(self):
        bundle = zip_bytes(payload())
        return dict(
            run=self.run, jobs=self.jobs,
            artifacts=[{**self.artifact, "name": f"playback-candidate-{HEAD}",
                        "digest": "sha256:" + hashlib.sha256(bundle).hexdigest()}],
            bundle=bundle,
            comparison="ahead", workflow_bytes=WORKFLOW, trusted_ci=WORKFLOW,
            source_ref=HEAD, repo="owner/repo")

    def test_complete_promotion_returns_exact_publication_bytes(self):
        args = self.promotion_inputs()
        source, digest, assets = promote(**args)
        self.assertEqual((source, digest), (HEAD, DIGEST))
        # Compare to the actual bundle contents, including unchanged archive bytes.
        with zipfile.ZipFile(io.BytesIO(args["bundle"])) as archive:
            self.assertEqual(assets, {name: archive.read(name) for name in archive.namelist()})

    def test_promotion_rejects_legacy_or_ambiguous_producer_jobs(self):
        for jobs in ([{**self.jobs[2], "name": "macOS checks"}] + self.jobs[:2],
                     [{**self.jobs[2], "name": "macOS engine"}] + self.jobs[:2],
                     self.jobs + [copy.deepcopy(self.jobs[2])]):
            with self.subTest(jobs=jobs), self.assertRaisesRegex(ValueError, "one macOS verification"):
                validate_run(self.run, jobs, "owner/repo", HEAD)

    def test_legacy_producer_definition_requires_a_fresh_candidate(self):
        args = self.promotion_inputs()
        legacy = WORKFLOW.replace(b"  macos_verify:\n", b"  macos_engine:\n")
        with self.assertRaisesRegex(ValueError, "Unrecognized CI producer boundary"):
            promote(**{**args, "workflow_bytes": legacy})

    def test_post_quality_cache_publication_does_not_change_tested_producer(self):
        args = self.promotion_inputs()
        self.assertIn(b"name: Validated main caches", WORKFLOW)
        promote(**{**args, "trusted_ci": WORKFLOW.replace(
            b"name: Validated main caches", b"name: Validated main caches # unrelated publisher")})

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

    def test_consumer_or_linux_image_changes_do_not_invalidate_candidate(self):
        args = self.promotion_inputs()
        self.assertIn(b"ubuntu-latest", WORKFLOW)
        self.assertIn(b"id: debug", WORKFLOW)
        args["trusted_ci"] = WORKFLOW.replace(b"ubuntu-latest", b"ubuntu-24.04").replace(
            b"id: debug", b"id: debug # consumer change")
        promote(**args)

    def test_consumer_output_binding_does_not_change_tested_producer(self):
        for binding in (b"contracts_result", b"swift_result", b"release_result",
                        b"contracts_key", b"tests_key", b"release_key"):
            with self.subTest(binding=binding):
                lines = WORKFLOW.splitlines(keepends=True)
                original = next(line for line in lines if line.startswith(b"      " + binding + b":"))
                changed = WORKFLOW.replace(original, original.replace(b"${{", b"${{ # consumer change "))
                promote(**{**self.promotion_inputs(), "trusted_ci": changed})

    def test_missing_duplicated_or_reindented_consumer_outputs_fail_closed(self):
        for binding in (b"contracts_result", b"swift_result", b"release_result",
                        b"contracts_key", b"tests_key", b"release_key"):
            original = next(line for line in WORKFLOW.splitlines(keepends=True)
                            if line.startswith(b"      " + binding + b":"))
            for replacement in (b"", original * 2, b"  " + original):
                with self.subTest(binding=binding, replacement=replacement), self.assertRaisesRegex(
                        ValueError, "Unrecognized CI consumer output"):
                    promote(**{**self.promotion_inputs(), "trusted_ci": WORKFLOW.replace(original, replacement)})

    def test_producer_checkout_identity_or_classification_invalidates_candidate(self):
        for old, new in ((b"id: engine_checkout", b"id: engine_checkout # changed"),
                         (b"name: macOS verification", b"name: untrusted native job"),
                         (b"needs.policy.outputs.macos_needed == 'true'", b"needs.policy.outputs.macos_needed != 'false'")):
            with self.subTest(old=old), self.assertRaises(ValueError):
                promote(**{**self.promotion_inputs(), "trusted_ci": WORKFLOW.replace(old, new)})

    def test_changed_producer_or_source_policy_invalidates_candidate(self):
        for old, new in ((b"--for-publish", b"--for-publish --changed"),
                         (b"contents: read", b"contents: write"),
                         (b"--test-only", b"--skip-tests"),
                         (b"Scripts/ci_cache_bundle.py preflight", b"Scripts/ci_cache_bundle.py changed-preflight"),
                         (b"Scripts/script_tests.py playback", b"Scripts/script_tests.py policy")):
            with self.subTest(old=old):
                self.assertIn(old, WORKFLOW)
                with self.assertRaises(ValueError):
                    promote(**{**self.promotion_inputs(), "trusted_ci": WORKFLOW.replace(old, new)})

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

    def test_every_required_job_must_pass(self):
        for index in range(2):
            for conclusion in ("failure", "skipped", "cancelled", None):
                jobs = copy.deepcopy(self.jobs)
                jobs[index]["conclusion"] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(ValueError):
                    validate_run(self.run, jobs, "owner/repo", HEAD)
        for index in range(len(self.jobs)):
            with self.subTest(missing=index), self.assertRaises(ValueError):
                validate_run(self.run, self.jobs[:index] + self.jobs[index + 1:], "owner/repo", HEAD)
            with self.subTest(duplicate=index), self.assertRaises(ValueError):
                validate_run(self.run, [*self.jobs, self.jobs[index]], "owner/repo", HEAD)

    def test_every_producer_step_must_pass_even_when_job_succeeds(self):
        for index in range(len(PRODUCER_STEPS)):
            for conclusion in ("failure", "skipped", "cancelled", None):
                jobs = copy.deepcopy(self.jobs)
                jobs[2]["conclusion"] = "success"
                jobs[2]["steps"][index]["conclusion"] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(ValueError):
                    validate_run(self.run, jobs, "owner/repo", HEAD)
            for duplicate in (False, True):
                jobs = copy.deepcopy(self.jobs)
                step = jobs[2]["steps"].pop(index)
                if duplicate:
                    jobs[2]["steps"].extend([step, step])
                with self.subTest(index=index, duplicate=duplicate), self.assertRaises(ValueError):
                    validate_run(self.run, jobs, "owner/repo", HEAD)

    def test_public_cargo_source_proof_requires_one_successful_record(self):
        name = "Preflight public Cargo source proof"
        for conclusion in ("failure", "skipped", "cancelled", None, "missing", "duplicate"):
            args = self.promotion_inputs()
            args["jobs"] = copy.deepcopy(args["jobs"])
            engine = args["jobs"][2]
            engine["conclusion"] = "success"
            engine["steps"] = [step for step in engine["steps"] if step["name"] != name]
            if conclusion != "missing":
                engine["steps"].append({"name": name, "conclusion": "success" if conclusion == "duplicate" else conclusion})
            if conclusion == "duplicate":
                engine["steps"].append({"name": name, "conclusion": "success"})
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(ValueError, "Missing successful " + name):
                promote(**args)

    def test_artifact_finalization_timestamp_skew_is_bounded(self):
        validate_artifact({**self.artifact, "created_at": "2026-09-05T12:10:01Z"}, self.jobs)
        for created in ("2026-09-05T12:07:59Z", "2026-09-05T12:10:02Z"):
            with self.subTest(created=created), self.assertRaises(ValueError):
                validate_artifact({**self.artifact, "created_at": created}, self.jobs)

    def test_artifact_timestamp_tolerance_crosses_midnight(self):
        self.upload_step["completed_at"] = "2026-09-05T23:59:59Z"
        validate_artifact({**self.artifact, "created_at": "2026-09-06T00:00:00Z"}, self.jobs)
        with self.assertRaises(ValueError):
            validate_artifact({**self.artifact, "created_at": "2026-09-06T00:00:01Z"}, self.jobs)

    def test_stale_artifact_cannot_borrow_a_rerun_success(self):
        with self.assertRaises(ValueError):
            validate_artifact({**self.artifact, "created_at": "2026-09-04T12:09:00Z"}, self.jobs)
        with self.assertRaises(ValueError):
            validate_artifact({**self.artifact, "created_at": "2026-09-05T12:07:00Z"}, self.jobs)
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
