"""Compiler selection policy, independent of Git history and workflow execution."""

from pathlib import Path
import unittest
from unittest.mock import patch

from ci_rust_policy import verification_for_paths, verification_needed


class PathSelectionTests(unittest.TestCase):
    def test_app_pin_tests_assets_and_docs_skip_rust(self):
        for name in (
            'Sources/Spotty/View.swift',
            'Sources/SpottyApp/main.swift',
            'Sources/SpottyDomain/Model.swift',
            'Sources/SpottyEngineAdapter/Adapter.swift',
            'Sources/SpottyRuntimeContracts/Values.swift',
            'Sources/SpottySessionRuntime/Runtime.swift',
            'Sources/SpottyGateway/Gateway.swift',
            'Sources/SpottyCatalogStorage/Storage.swift',
            'Sources/SpottyDiagnostics/DebugLog.swift',
            'Tests/SpottyBoundaryTests/Example.swift',
            'Tests/SpottyTestSupport/Clock.swift',
            'Tests/SpottyRuntimeTestSupport/Environment.swift',
            'Tests/SpottyTestSupportTests/ClockChecks.swift',
            'Tests/SpottyEngineAdapterTests/Events.swift',
            'Tests/SpottyCatalogStorageTests/Example.swift',
            'Tests/SpottySessionRuntimeTests/Example.swift',
            'Tests/SpottyGatewayTests/Example.swift',
            'Tests/SpottyDomainTests/Example.swift',
            'Package.swift',
            'Package.resolved',
            'Assets/icon.png',
            'Packaging/Info.plist',
            'docs/development/guide.md',
            'README.md',
            '.swift-format',
            'AGENTS.md',
            'CONTRIBUTING.md',
            'PRIVACY.md',
            'SECURITY.md',
        ):
            with self.subTest(name=name):
                documentation = name in {
                    'AGENTS.md',
                    'CONTRIBUTING.md',
                    'PRIVACY.md',
                    'README.md',
                    'SECURITY.md',
                    'docs/development/guide.md',
                }
                self.assertEqual(verification_for_paths([name]),
                                 {"rust_needed": False, "macos_needed": not documentation})

    def test_documentation_and_nested_agent_guidance_skip_both_toolchains(self):
        for name in (
            'AGENTS.md',
            'Tests/AGENTS.md',
            'Sources/SpottyPlaybackCore/AGENTS.md',
            'Backend/spotty-playback/AGENTS.md',
            '.github/AGENTS.md',
            'Scripts/AGENTS.md',
            'README.md',
            'CONTRIBUTING.md',
            'SECURITY.md',
            'PRIVACY.md',
            'docs/development/guide.md',
            'docs/images/overview.png',
        ):
            with self.subTest(name=name):
                self.assertEqual(verification_for_paths([name]),
                                 {"rust_needed": False, "macos_needed": False})

    def test_demo_sources_measurements_and_audited_helpers_skip_rust(self):
        for name in (
            'Tests/BrowsingHarness/App/BrowsingHarness.swift',
            'Tests/BrowsingHarness/Checks/BrowsingHarnessChecks.swift',
            'Tests/BrowsingHarness/Support/BrowsingScenario.swift',
            'Tests/BrowsingHarness/queue-rendering.json',
            'Tests/BrowsingHarness/Icon/SpottyDemo.icns',
            'Tests/BrowsingHarness/Support/Artwork/tidal-light.jpg',
            'docs/architecture/measurements/synthetic.json',
            'Scripts/browse-synthetic.sh',
            'Scripts/profile_synthetic.py',
            'Scripts/summarize_synthetic_trace.py',
            'Scripts/compare_synthetic_profiles.py',
            'Scripts/browsing_process.py',
            'Scripts/browsing_preflight.swift',
            'Scripts/acceptance_scenarios.py',
            'Scripts/smoke-synthetic-ui.sh',
            'Scripts/synthetic_ui_smoke.swift',
            'Scripts/test_harness_profile_synthetic.py',
            'Scripts/test_harness_profile_comparison.py',
            'Scripts/test_harness_trace_summary.py',
            'Scripts/test_harness_browsing_process.py',
            'Scripts/test_harness_acceptance_scenarios.py',
        ):
            with self.subTest(name=name):
                self.assertEqual(verification_for_paths([name]),
                                 {"rust_needed": False, "macos_needed": True})

    def test_unreviewed_harness_inputs_and_policy_changes_remain_conservative(self):
        for name in (
            'Tests/BrowsingHarness/unreviewed.rs',
            'Tests/BrowsingHarness/tool.sh',
            'Scripts/new-harness.sh',
            'Scripts/test_harness_new.py',
            'Scripts/ci_rust_policy.py',
            'Scripts/script_tests.py',
            'Scripts/test_ci_rust_policy.py',
            'Scripts/check.sh',
        ):
            with self.subTest(name=name):
                self.assertEqual(verification_for_paths([name]),
                                 {"rust_needed": True, "macos_needed": True})

    def test_engine_headers_ci_scripts_licenses_and_unknown_paths_run_rust(self):
        for name in (
            'Backend/spotty-playback/src/lib.rs',
            'Backend/spotty-playback/tests/new.rs',
            'Backend/spotty-playback/Cargo.lock',
            'Sources/SpottyPlaybackCore/include/new.h',
            'rust-toolchain.toml',
            '.github/workflows/ci.yml',
            'Scripts/check.sh',
            'Scripts/test_playback_header.py',
            'Tests/ABI/example.txt',
            'LICENSE',
            'Scripts/verification_package.py',
            'Scripts/browsing_provenance.py',
            'Scripts/test_harness_browsing_provenance.py',
            'Scripts/test_verify.py',
            'NOTICE',
            'THIRD_PARTY_NOTICES.md',
            'new-build-input',
            '.cargo/config.toml',
        ):
            with self.subTest(name=name):
                self.assertEqual(verification_for_paths([name]),
                                 {"rust_needed": True, "macos_needed": True})

    def test_empty_mixed_and_repeated_paths_accept_single_pass_iterables(self):
        cases = (
            ([], {"rust_needed": False, "macos_needed": False}),
            (["README.md", "Backend/spotty-playback/AGENTS.md"],
             {"rust_needed": False, "macos_needed": False}),
            (["README.md", "Sources/Spotty/View.swift"],
             {"rust_needed": False, "macos_needed": True}),
            (["Sources/Spotty/View.swift", "unknown-input"],
             {"rust_needed": True, "macos_needed": True}),
            (["README.md", "Sources/Spotty/View.swift", "Backend/spotty-playback/src/lib.rs"],
             {"rust_needed": True, "macos_needed": True}),
        )
        for paths, expected in cases:
            for ordered in (paths, list(reversed(paths)), paths + paths):
                with self.subTest(paths=ordered):
                    self.assertEqual(verification_for_paths(iter(ordered)), expected)

    def test_exact_names_and_unknown_documentation_extensions(self):
        for name in (" README.md", "README.md ", "readme.md", "README.MD",
                     "README.md\nSources/Spotty/View.swift", "unknown-\udcff"):
            with self.subTest(name=name):
                self.assertEqual(verification_for_paths([name]),
                                 {"rust_needed": True, "macos_needed": True})
        self.assertEqual(verification_for_paths(["docs/generator.py"]),
                         {"rust_needed": False, "macos_needed": True})


class SelectionAdmissionTests(unittest.TestCase):
    def test_main_and_other_events_need_neither_a_base_nor_git(self):
        with patch("ci_rust_policy.subprocess.run", side_effect=AssertionError("unexpected Git")), \
                patch("ci_rust_policy.subprocess.check_output", side_effect=AssertionError("unexpected Git")):
            for event in ("push", "workflow_dispatch", "unknown"):
                with self.subTest(event=event):
                    self.assertEqual(verification_needed(event, "", Path("unused-repository")),
                                     {"rust_needed": True, "macos_needed": True})

    def test_invalid_pr_base_is_rejected_before_git(self):
        with patch("ci_rust_policy.subprocess.run", side_effect=AssertionError("unexpected Git")), \
                patch("ci_rust_policy.subprocess.check_output", side_effect=AssertionError("unexpected Git")):
            for base in ("", "0" * 40, "not-a-sha", "F" * 40):
                with self.subTest(base=base), self.assertRaises(ValueError):
                    verification_needed("pull_request", base, Path("unused-repository"))


if __name__ == "__main__":
    unittest.main()
