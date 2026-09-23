"""Credential-free launch metadata shared by the Demo evidence helper tests."""


def launch_manifest(run_id="11111111-1111-4111-8111-111111111111"):
    return {
        "schemaVersion": 1, "runID": run_id,
        "source": {"revision": "a" * 40, "sourceSHA256": "b" * 64, "diffSHA256": "c" * 64,
                   "includesUntrackedNonignoredFiles": True},
        "build": {"configuration": "release", "optimization": "-O", "testabilityEnabled": True,
                  "compilerVersion": "Swift version 6.2", "requestedSDKVersion": "26.0",
                  "requestedSDKName": "macosx26.0", "linkedSDKVersion": "26.0", "buildProductSHA256": "d" * 64},
        "engine": {"selection": "pinned", "pinURL": "https://example.invalid/engine.zip",
                   "pinChecksum": "e" * 64, "librarySHA256": "f" * 64, "canonicalHeadersSHA256": "0" * 64,
                   "sourceRevision": "1" * 40, "engineInputDigest": "2" * 64,
                   "librespotRevision": "3" * 40, "usedForPlayback": False},
        "fixture": {"sha256": "4" * 64, "workloadSHA256": "5" * 64},
        "layout": {"forceSynchronousLayout": False},
    }
