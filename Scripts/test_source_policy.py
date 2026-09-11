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


def read_yaml(paths):
    return json.loads(subprocess.check_output([
        "ruby", "-ryaml", "-rjson", "-e",
        "puts JSON.generate(ARGV.map { |p| YAML.safe_load(File.read(p)) })",
        *map(str, paths),
    ], text=True))


class SourcePolicyRoutingTests(unittest.TestCase):
    def test_every_rule_has_both_kinds_of_fixture(self):
        rules = {path.stem for path in (ROOT / "Scripts/ast-grep/rules").rglob("*.yml")}
        fixtures = list((ROOT / "Tests/SourcePolicy").rglob("*-test.yml"))
        self.assertEqual(rules, {path.stem.removesuffix("-test") for path in fixtures})
        for path, fixture in zip(fixtures, read_yaml(fixtures)):
            with self.subTest(rule=fixture["id"]):
                self.assertEqual(fixture["id"], path.stem.removesuffix("-test"))
                self.assertTrue(fixture.get("valid"))
                self.assertTrue(fixture.get("invalid"))

    def test_rule_routing_has_no_duplicate_patterns(self):
        paths = list((ROOT / "Scripts/ast-grep/rules").rglob("*.yml"))
        for rule in read_yaml(paths):
            for field in ("files", "ignores"):
                with self.subTest(rule=rule["id"], field=field):
                    patterns = rule.get(field, [])
                    self.assertEqual(len(patterns), len(set(patterns)), patterns)

    def scan(self, path, source):
        self.assertIsNotNone(AST_GREP, "ast-grep must be installed")
        with tempfile.TemporaryDirectory(prefix="spotty-source-policy-") as directory:
            root = Path(directory)
            shutil.copy(ROOT / "sgconfig.yml", root)
            shutil.copytree(ROOT / "Scripts/ast-grep/rules", root / "Scripts/ast-grep/rules")
            shutil.copytree(ROOT / "Scripts/ast-grep/utils", root / "Scripts/ast-grep/utils")
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source)
            result = subprocess.run(
                [AST_GREP, "scan", "--config", "sgconfig.yml", "--json=compact",
                 ".github/workflows" if path.startswith(".github/workflows/") else "."],
                cwd=root, capture_output=True, text=True, check=False,
            )
            self.assertIn(result.returncode, (0, 1), result.stderr)
            findings = json.loads(result.stdout)
            self.assertEqual(result.returncode, 1 if findings else 0, result.stderr)
            return {finding["ruleId"] for finding in findings}

    def test_engine_boundary_is_owned_by_the_package_graph(self):
        # The package graph owns imports between targets. The adapter source rules only
        # narrow C access within that target; Linux compilation owns unavailable domain imports.
        cases = [
            ("Sources/SpottyEngineAdapter/PlaybackCore.swift", "import SpottyPlaybackCore", set()),
            ("Sources/Spotty/Spotify/Other.swift", "import SpottyPlaybackCore", set()),
            ("Sources/Spotty/Spotify/Other.swift", "PlaybackCore.start()", set()),
            ("Sources/SpottyDomain/Example.swift", "import AppKit", set()),
            ("Sources/Spotty/Spotify/SearchStore.swift", "Module.PlaybackCore.start()", set()),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path, source=source):
                self.assertEqual(self.scan(path, source), expected)

    def test_presence_policies_cannot_be_satisfied_by_comments(self):
        cases = [
            ("Sources/Spotty/SpottyApp.swift", "// NSApplication.shared.appearance = NSAppearance(named: .darkAqua)", "dark-appearance-required"),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path):
                self.assertEqual(self.scan(path, source), {expected})

    def test_scoped_policies_do_not_leak_to_other_owners(self):
        cases = [
            ("Sources/Spotty/Views/Example.swift", "import AppKit", set()),
            ("Sources/Spotty/Spotify/SearchStore.swift", "PartnerAPI()", {"injected-dependencies"}),
            ("Sources/Spotty/Spotify/PlaybackStore+Queue.swift", "PartnerAPI()", {"injected-dependencies"}),
            # A store added after this rule was written is in scope without editing the rule.
            ("Sources/Spotty/Spotify/BrandNewStore.swift", "PartnerAPI()", {"injected-dependencies"}),
            ("Sources/Spotty/Spotify/PlaylistMutationController.swift", "PartnerAPI()", {"injected-dependencies"}),
            ("Sources/Spotty/Views/Nested/Example.swift", "PartnerAPI()", {"injected-dependencies"}),
            ("Sources/Spotty/Spotify/PlaybackEnvironment.swift", "PartnerAPI()", set()),
            ("Sources/Spotty/Views/Example.swift", "view.draggable(item)", {"unsupported-drag-ui"}),
            ("Tests/Example.swift", "view.draggable(item)", set()),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path, source=source):
                self.assertEqual(self.scan(path, source), expected)

    def test_rust_owner_and_test_file_routing(self):
        # Playing-flag write ownership is no longer a syntax policy: the flag is a private
        # field of EngineGeneration whose only "set true" path is note_playing_event, so the
        # compiler enforces what rust-playing-store-owner/-required used to assert.
        runtime_call = "fn f() { RUNTIME.block_on(future); }"
        cases = [
            ("runtime.rs", runtime_call, set()),
            ("player_control.rs", runtime_call, {"rust-runtime-owner"}),
            ("nested/module.rs", runtime_call, {"rust-runtime-owner"}),
            ("tests.rs", runtime_call, set()),
            ("lifecycle_tests.rs", runtime_call, set()),
            ("nested/other_tests.rs", runtime_call, set()),
            ("tests.rs", 'pub extern "C" fn export() { work(); }', {"rust-ffi-panic-barrier"}),
        ]
        for file, source, expected in cases:
            with self.subTest(file=file, source=source):
                self.assertEqual(self.scan(f"Backend/spotty-playback/src/{file}", source), expected)

    def test_workflow_and_script_policy_routing(self):
        cases = [
            (".github/workflows/ci.yml", "uses: actions/checkout@main", {"workflow-action-pins", "workflow-checkout-credentials"}),
            (".github/workflows/other.yml", "uses: actions/cache@main", {"workflow-action-pins"}),
            ("docs/example.yml", "uses: actions/checkout@main", set()),
            (".github/workflows/ci.yml", "env: {SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK: /tmp/local}", {"ci-published-engine"}),
            ("Scripts/compile-release-spotty.sh", "cargo build", {"app-script-rust-free"}),
            ("Scripts/package-app.sh", "tool='cbindgen'", {"app-script-rust-free", "development-signing-input"}),
            ("Backend/spotty-playback/build-xcframework.sh", "cargo build", set()),
            ("Sources/Spotty/Example.swift", "let catalog = MockCatalog()", {"retired-mock-symbols"}),
            ("Tests/Example.swift", "let catalog = MockCatalog()", set()),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path):
                self.assertEqual(self.scan(path, source), expected)

    def test_new_boundaries_and_owner_exceptions(self):
        cases = [
            ("Sources/Spotty/RootView.swift", "PartnerAPI.init()", {"injected-dependencies"}),
            ("Sources/Spotty/Spotify/Nested/NewStore.swift", "Module.KeymasterSession.shared", {"injected-dependencies"}),
            ("Sources/Spotty/RootView.swift", "view.onDrop(of: types, perform: drop)", {"unsupported-drag-ui"}),
            ("Sources/Spotty/RootView.swift", "let state: PlaybackState", {"view-projection-boundary"}),
            ("Sources/Spotty/Views/Example.swift", "PathfinderAddVariables()", {"view-projection-boundary"}),
            ("Sources/Spotty/Spotify/PathfinderPlaylist.swift", "PathfinderAddVariables()", set()),
            ("Sources/Spotty/Views/Nested/Example.swift", "NSCache<NSString, NSImage>()", {"artwork-framework-cache"}),
            ("Sources/Spotty/RootView.swift", '@AppStorage("panel") var panel = 0', {"view-scene-storage"}),
            ("Sources/Spotty/Models/NewModel.swift", "let catalog: any CatalogProviding", {"model-dependencies"}),
            ("Sources/Spotty/Spotify/CatalogStore.swift", "let catalog: any CatalogProviding", set()),
            ("Sources/SpottyDomain/NewPolicy.swift", "UserDefaults.standard", {"domain-no-io"}),
            ("Sources/SpottyDomain/NewPolicy.swift", "Task { await work() }", {"domain-no-io"}),
            ("Sources/Spotty/Spotify/SpotifyRetryTiming.swift", "try await Task.sleep(for: .seconds(1))", set()),
            ("Sources/Spotty/Spotify/KeymasterFileStore.swift", "SecItemDelete(query)", {"retired-keychain-api"}),
            ("Tests/SpottyBoundaryTests/NewChecks.swift", "Security.SecItemDelete(query)", {"retired-keychain-api"}),
            ("Sources/Spotty/New.swift", "Swift.print(token)", {"logging-owner"}),
            ("Sources/Spotty/New.swift", "FileHandle.standardError.write(Data())", {"logging-owner"}),
            ("Sources/SpottyEngineAdapter/DebugLog.swift", "Logger(subsystem: name, category: name)", set()),
            ("Sources/SpottyEngineAdapter/DebugLog.swift", "FileHandle.standardError.write(Data())", set()),
            ("Tests/SpottyBoundaryTests/NewChecks.swift", "print(result)", set()),
            ("Sources/Spotty/New.swift", "import Testing", {"production-test-code"}),
            ("Tests/SpottyDomainTests/NewChecks.swift", "import Testing", set()),
            ("Sources/SpottyDomain/New.swift", "struct Effect<Action> {}", {"no-generic-effects"}),
            ("Package.swift", '.package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.0.0")', {"no-generic-effects"}),
            ("Sources/Spotty/New.swift", "import WebKit", {"native-ui-scope"}),
            ("Sources/Spotty/New.swift", "Settings { Preferences() }", {"native-ui-scope"}),
            ("Sources/SpottyEngineAdapter/New.swift", "import SpottyPlaybackCore", {"adapter-c-import"}),
            ("Sources/SpottyEngineAdapter/New.swift", "PlaybackCore.resume()", {"adapter-core-caller"}),
            ("Sources/SpottyEngineAdapter/RustPlaybackEngine.swift", "PlaybackCore.resume()", set()),
            ("Sources/SpottyEngineAdapter/PlaybackCore.swift", "spotty_playback_resume()", set()),
            ("Sources/SpottyEngineAdapter/RustPlaybackEngine.swift", "spotty_playback_resume()", {"adapter-c-import"}),
            ("Tests/SpottyBoundaryTests/Harness/New.swift", "try await Task.sleep(for: .seconds(1))", {"test-no-wall-sleep"}),
            ("Tests/SpottyDomainTests/NewChecks.swift", "Thread.sleep(forTimeInterval: 1)", {"test-no-wall-sleep"}),
            ("Tests/BrowsingHarness/Checks/New.swift", "try await Task.sleep(for: .seconds(1))", {"test-no-wall-sleep"}),
            ("Tests/BrowsingHarness/Support/Measurement.swift", "try await Task.sleep(for: .seconds(1))", set()),
            ("Tests/BrowsingHarness/Support/New.swift", "RustPlaybackEngine.shared", {"test-live-dependencies"}),
            ("Tests/SpottyBoundaryTests/NewChecks.swift", "Foundation.UserDefaults.standard", {"test-live-dependencies"}),
            ("Backend/spotty-playback/src/new.rs", "fn f() { Runtime::new(); }", {"rust-runtime-creation"}),
            ("Backend/spotty-playback/src/runtime.rs", "fn f() { Runtime::new(); }", set()),
            ("Backend/spotty-playback/src/nested/new_tests.rs", "fn f() { Runtime::new(); }", set()),
            ("Backend/spotty-playback/src/lifecycle_measurements.rs", "fn f() { Runtime::new(); }", set()),
            ("Backend/spotty-playback/src/runtime.rs", "fn f() { std::panic::set_hook(hook); }", {"rust-process-globals"}),
            ("Backend/spotty-playback/src/new.rs", "fn f() { ::std::process::exit(1); }", {"rust-process-globals"}),
            ("Backend/spotty-playback/src/new.rs", "use std::process::*;", {"rust-process-globals"}),
            ("Backend/spotty-playback/src/new.rs", 'pub extern "C-unwind" fn f() {}', {"rust-no-unwind-abi"}),
            ("Backend/spotty-playback/vendor/librespot/lib.rs", "fn f() { std::panic::set_hook(hook); }", set()),
            ("Scripts/new.sh", "#!/bin/bash\nwork", {"script-fail-fast"}),
            ("Scripts/new.sh", "#!/bin/sh\nset -eu\nwork", {"script-fail-fast"}),
            ("Scripts/helper.sh", "helper() { work; }", set()),
            ("Backend/spotty-playback/new.sh", "set -x", {"script-no-xtrace"}),
            ("script/new.sh", "cargo build", {"app-script-rust-free"}),
            (".github/workflows/other.yaml", "uses: actions/cache@main", {"workflow-action-pins"}),
            (".github/workflows/other.yaml", 'run: echo "${{ inputs.title }}"', {"workflow-shell-interpolation"}),
            (".github/workflows/other.yml", "permissions: write-all", {"workflow-explicit-permissions"}),
            (".github/workflows/ci.yaml", "env: {SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK: /tmp/local}", {"ci-published-engine"}),
            (".github/workflows/other.yaml", "run: brew install swift-format", {"workflow-swift-tools"}),
            (".github/workflows/other.yaml", "run: FOO=1 brew reinstall swift-format", {"workflow-swift-tools"}),
            ("Scripts/tools.sh", "brew install swiftlint", {"xcode-swift-tools"}),
            ("Scripts/tools.sh", "brew reinstall swiftlint", {"xcode-swift-tools"}),
            (".github/workflows/ci.yaml", "continue-on-error: true", {"ci-fail-closed"}),
            (".github/workflows/other.yml", "continue-on-error: true", set()),
            (".github/workflows/ci.yml", "permissions: {contents: write}\njobs: {}", {"ci-read-permissions"}),
            (".github/workflows/ci.yaml", "permissions: {contents: read}\njobs:\n  check:\n    permissions: {contents: write}", {"ci-read-permissions"}),
            ("docs/example.yml", 'run: echo "${{ inputs.title }}"', set()),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path, source=source):
                self.assertEqual(self.scan(path, source), expected)

    def test_signing_statements_cannot_be_replaced_with_comments(self):
        cases = [
            ("script/build_and_run.sh", 'SPOTTY_APP_PATH="$staged_app_bundle" "$root_dir/Scripts/package-app.sh" "$package_mode"', "development-launch-staging"),
            ("script/build_and_run.sh", '"$root_dir/Scripts/validate-app.sh" --development-signed "$staged_app_bundle"', "development-launch-staging"),
            ("script/build_and_run.sh", 'mv "$staged_app_bundle" "$app_bundle"', "development-launch-staging"),
            ("script/build_and_run.sh", 'mv "$rollback_app_bundle" "$app_bundle"', "development-launch-staging"),
            ("Scripts/validate-app.sh", "codesign --verify --strict -R '=anchor apple generic'", "development-signing-validation"),
            ("Scripts/validate-app.sh", "awk -F= '/^TeamIdentifier=/{print $2; exit}'", "development-signing-validation"),
        ]
        for path, statement, rule in cases:
            with self.subTest(path=path, statement=statement):
                source = (ROOT / path).read_text()
                self.assertEqual(self.scan(path, source), set())
                self.assertIn(statement, source)
                # Keep the literal mention, but replace its executable occurrence.
                mutated = source.replace(statement, "true") + "\n# " + statement
                self.assertIn(rule, self.scan(path, mutated))

    def test_wrapper_rejects_missing_or_empty_owners(self):
        self.assertIsNotNone(AST_GREP, "ast-grep must be installed")
        owners = (ROOT / "Scripts/ast-grep/required-files.txt").read_text().splitlines()
        for absent in owners:
            for empty in (False, True):
                with self.subTest(owner=absent, empty=empty), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / "Scripts/ast-grep").mkdir(parents=True)
                    shutil.copy(ROOT / "Scripts/check-source-policy.sh", root / "Scripts")
                    shutil.copy(ROOT / "Scripts/ast-grep/version", root / "Scripts/ast-grep")
                    shutil.copy(ROOT / "Scripts/ast-grep/required-files.txt", root / "Scripts/ast-grep")
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
