"""Exercise file routing as well as syntax: ast-grep's rule tests have no filename."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
AST_GREP = shutil.which(os.environ.get("SPOTTY_AST_GREP", "ast-grep"))


class SourcePolicyRoutingTests(unittest.TestCase):
    def scan(self, path, source):
        self.assertIsNotNone(AST_GREP, "ast-grep must be installed")
        with tempfile.TemporaryDirectory(prefix="spotty-source-policy-") as directory:
            root = Path(directory)
            shutil.copy(ROOT / "sgconfig.yml", root)
            shutil.copytree(ROOT / "Scripts/ast-grep/rules", root / "Scripts/ast-grep/rules")
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source)
            result = subprocess.run(
                [AST_GREP, "scan", "--config", "sgconfig.yml", "--json=compact", "."],
                cwd=root, capture_output=True, text=True, check=False,
            )
            self.assertIn(result.returncode, (0, 1), result.stderr)
            findings = json.loads(result.stdout)
            self.assertEqual(result.returncode, 1 if findings else 0, result.stderr)
            return {finding["ruleId"] for finding in findings}

    def test_import_and_adapter_owner_exceptions(self):
        cases = [
            ("Sources/Spotty/Spotify/PlaybackCore.swift", "import SpottyPlaybackCore", set()),
            ("Sources/Spotty/Spotify/Other.swift", "import SpottyPlaybackCore", {"ffi-import-owner"}),
            ("Sources/Spotty/Spotify/RustPlaybackEngine.swift", "PlaybackCore.start()", set()),
            ("Sources/Spotty/Spotify/Other.swift", "PlaybackCore.start()", {"playback-core-owner"}),
            ("Sources/Spotty/Spotify/Other.swift", "func f(_ r: PlaybackCore.Result) {}", {"playback-core-owner"}),
            ("Sources/Spotty/Spotify/RustPlaybackEngine.swift", "typealias R = PlaybackCore.Result", set()),
            ("Sources/Spotty/Spotify/SearchStore.swift", "Module.PlaybackCore.start()", {"playback-core-owner", "injected-dependencies"}),
            ("Tests/Example.swift", "import SpottyPlaybackCore\nPlaybackCore.start()", set()),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path, source=source):
                self.assertEqual(self.scan(path, source), expected)

    def test_presence_policies_cannot_be_satisfied_by_comments(self):
        cases = [
            ("Sources/Spotty/Spotify/PlaybackCore.swift", "// import SpottyPlaybackCore", "ffi-import-required"),
            ("Sources/Spotty/Spotify/RustPlaybackEngine.swift", "// PlaybackCore.start()", "playback-core-required"),
            ("Sources/Spotty/SpottyApp.swift", "// NSApplication.shared.appearance = NSAppearance(named: .darkAqua)", "dark-appearance-required"),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path):
                self.assertEqual(self.scan(path, source), {expected})

    def test_scoped_policies_do_not_leak_to_other_owners(self):
        cases = [
            ("Sources/SpottyDomain/Example.swift", "import AppKit", {"domain-imports"}),
            ("Sources/Spotty/Views/Example.swift", "import AppKit", set()),
            ("Sources/Spotty/Spotify/SearchStore.swift", "PartnerAPI()", {"injected-dependencies"}),
            ("Sources/Spotty/Spotify/PlaybackStore+Queue.swift", "PartnerAPI()", {"injected-dependencies"}),
            ("Sources/Spotty/Views/Nested/Example.swift", "PartnerAPI()", {"injected-dependencies"}),
            ("Sources/Spotty/Spotify/PlaybackEnvironment.swift", "PartnerAPI()", set()),
            ("Sources/Spotty/Spotify/KeychainManager.swift", "let key = kSecAttrAccessGroup", {"legacy-keychain"}),
            ("Sources/Spotty/Spotify/Other.swift", "let key = kSecAttrAccessGroup", set()),
            ("Sources/Spotty/Views/Example.swift", "view.draggable(item)", {"unsupported-drag-ui"}),
            ("Tests/Example.swift", "view.draggable(item)", set()),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path, source=source):
                self.assertEqual(self.scan(path, source), expected)

    def test_wrapper_rejects_missing_or_empty_owners(self):
        self.assertIsNotNone(AST_GREP, "ast-grep must be installed")
        owners = [
            "Sources/Spotty/SpottyApp.swift",
            "Sources/Spotty/Spotify/KeychainManager.swift",
            "Sources/Spotty/Spotify/PlaybackCore.swift",
            "Sources/Spotty/Spotify/RustPlaybackEngine.swift",
        ]
        for absent in owners:
            for empty in (False, True):
                with self.subTest(owner=absent, empty=empty), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / "Scripts/ast-grep").mkdir(parents=True)
                    shutil.copy(ROOT / "Scripts/check-source-policy.sh", root / "Scripts")
                    shutil.copy(ROOT / "Scripts/ast-grep/version", root / "Scripts/ast-grep")
                    for owner in owners:
                        path = root / owner
                        path.parent.mkdir(parents=True, exist_ok=True)
                        if owner != absent:
                            path.write_text("// owner\n")
                        elif empty:
                            path.touch()
                    result = subprocess.run(
                        ["bash", str(root / "Scripts/check-source-policy.sh"), "--test-only"],
                        env={**os.environ, "SPOTTY_AST_GREP": AST_GREP},
                        capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(f"Missing or empty policy owner: {absent}", result.stderr)

    def test_policy_still_matches_beside_recovered_swift_syntax(self):
        # The pinned tree-sitter grammar recovers some valid Swift expressions as ERROR nodes.
        # Source policy matching is lexical evidence, never a substitute for swiftc.
        source = '''
        func parse(_ json: [String: Any]) {
            let expires = json["expires_in"] as? Double ?? 0
            let api = PartnerAPI()
        }
        '''
        self.assertEqual(
            self.scan("Sources/Spotty/Spotify/SearchStore.swift", source),
            {"injected-dependencies"},
        )


if __name__ == "__main__":
    unittest.main()
