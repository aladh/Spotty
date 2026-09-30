"""Test fixture dependency cuts independently of compiler cache contents."""

import copy
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest import mock


graph_checks = runpy.run_path(str(Path(__file__).with_name("check-package-graphs.py")))
verify_test_support = graph_checks["verify_test_support"]
dependency_closure = graph_checks["dependency_closure"]
verify_selection = graph_checks["verify_selection"]
verify_full_manifest = graph_checks["verify_full_manifest"]


def target(*dependencies):
    return {"dependencies": [{"byName": [name, None]} for name in dependencies]}


def full_manifest_fixture():
    """Synthetic complete inventory; this is not a native manifest receipt."""
    names = ("SpottyPlaybackCore", "SpottyEngineAdapter", "SpottySessionRuntime", "SpottyCore",
             "SpottyApp", "SpottyBrowsingHarness", "SpottyRuntimeTestSupport", "SpottyDomain", "SpottyTestSupport",
             "SpottyBrowsingHarnessTests", *graph_checks["TEST_TARGETS"])
    declarations = {name: {"name": name, "type": "test" if name.endswith("Tests") else "regular",
                           **target()} for name in names}
    declarations["SpottyPlaybackCore"]["type"] = "binary"
    declarations["SpottyApp"]["type"] = "executable"
    declarations["SpottyBrowsingHarness"]["type"] = "executable"
    declarations["SpottyDomainTests"].update(target("SpottyDomain"))
    declarations["SpottyRuntimeTestSupport"].update(target("SpottyTestSupport"))
    declarations["SpottySessionRuntimeTests"].update(target("SpottySessionRuntime", "SpottyRuntimeTestSupport"))
    declarations["SpottyBoundaryTests"].update(target("SpottyCore", "SpottyRuntimeTestSupport"))
    declarations["SpottyCore"]["dependencies"].append({"product": ["Sparkle", "Sparkle", None, None]})
    return {"name": "Spotty", "targets": list(declarations.values()), "products": [{"name": "SpottyApp"}],
            "dependencies": [{"sourceControl": [{"identity": "sparkle", "requirement": "pinned"}]}]}


class FullManifestTests(unittest.TestCase):
    def test_complete_reference_inventory_accepts_shared_support_boundaries(self):
        full = full_manifest_fixture()
        self.assertEqual(set(verify_full_manifest(full)), {item["name"] for item in full["targets"]})

    def test_every_required_inventory_entry_and_external_dependency_must_survive(self):
        full = full_manifest_fixture()
        for missing in ("SpottyPlaybackCore", "SpottyEngineAdapter", "SpottySessionRuntime", "SpottyCore",
                        "SpottyApp", "SpottyBrowsingHarness", "SpottyRuntimeTestSupport", "SpottyBrowsingHarnessTests",
                        *graph_checks["TEST_TARGETS"]):
            changed = copy.deepcopy(full)
            changed["targets"] = [item for item in changed["targets"] if item["name"] != missing]
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "Full verification lost"):
                verify_full_manifest(changed)
        full["dependencies"] = []
        with self.assertRaisesRegex(ValueError, "Full verification lost"):
            verify_full_manifest(full)

    def test_duplicate_targets_and_wrong_or_extra_test_types_are_rejected(self):
        for mode in ("duplicate", "test_is_regular", "shipping_is_test", "extra_test"):
            changed = full_manifest_fixture()
            if mode == "duplicate":
                changed["targets"].append(copy.deepcopy(changed["targets"][0]))
            elif mode == "extra_test":
                changed["targets"].append({"name": "UnexpectedTests", "type": "test", **target()})
            else:
                name = "SpottyDomainTests" if mode == "test_is_regular" else "SpottyApp"
                next(item for item in changed["targets"] if item["name"] == name)["type"] = (
                    "regular" if mode == "test_is_regular" else "test")
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "Full verification"):
                verify_full_manifest(changed)

    def test_full_reference_checks_unknown_edges_and_shared_runtime_support(self):
        for edge in ("Missing", "SpottyCore"):
            changed = full_manifest_fixture()
            next(item for item in changed["targets"] if item["name"] == "SpottyRuntimeTestSupport")[
                "dependencies"].append({"byName": [edge, None]})
            with self.subTest(edge=edge), self.assertRaises(ValueError):
                verify_full_manifest(changed)


class RuntimeFixtureBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.targets = {
            "SpottyApp": target("SpottyCore"),
            "SpottyCore": target("SpottySessionRuntime"),
            "SpottySessionRuntime": target("SpottyDomain"),
            "SpottyDomain": target(),
            "SpottyTestSupport": target("SpottyDomain"),
            "SpottyRuntimeContracts": target("SpottyDomain"),
            "SpottyEngineAdapter": target("SpottyRuntimeContracts"),
            "SpottyGateway": target("SpottyRuntimeContracts"),
            "SpottyRuntimeTestSupport": target("SpottyEngineAdapter", "SpottyGateway", "SpottyTestSupport"),
            "SpottySessionRuntimeTests": target("SpottySessionRuntime", "SpottyRuntimeTestSupport"),
            "SpottyBoundaryTests": target("SpottyCore", "SpottyRuntimeTestSupport"),
        }

    def test_shared_fixtures_do_not_make_shipping_or_runtime_owners_depend_on_desktop(self):
        verify_test_support(self.targets)
        self.targets["SpottyCore"]["dependencies"].append({"product": ["Sparkle", "Sparkle", None, None]})
        verify_test_support(self.targets)

    def test_direct_and_transitive_desktop_edges_are_rejected_for_both_runtime_consumers(self):
        for owner in ("SpottyRuntimeTestSupport", "SpottySessionRuntimeTests"):
            for indirect in (False, True):
                with self.subTest(owner=owner, indirect=indirect):
                    changed = copy.deepcopy(self.targets)
                    changed["Bridge"] = target("SpottyCore")
                    changed[owner]["dependencies"].append({"target": ["Bridge" if indirect else "SpottyCore", None]})
                    with self.assertRaisesRegex(ValueError, "desktop dependency"):
                        verify_test_support(changed)

    def test_shared_fakes_cannot_reach_the_runtime_implementation(self):
        for indirect in (False, True):
            with self.subTest(indirect=indirect):
                changed = copy.deepcopy(self.targets)
                changed["Bridge"] = target("SpottySessionRuntime")
                changed["SpottyRuntimeTestSupport"]["dependencies"].append(
                    {"target": ["Bridge" if indirect else "SpottySessionRuntime", None]})
                with self.assertRaisesRegex(ValueError, "runtime implementation dependency"):
                    verify_test_support(changed)

    def test_shipping_cannot_reach_either_fixture_module_through_an_intermediate(self):
        for fixture in ("SpottyRuntimeTestSupport", "SpottyTestSupport"):
            with self.subTest(fixture=fixture):
                changed = copy.deepcopy(self.targets)
                changed["Bridge"] = target(fixture)
                changed["SpottyApp"]["dependencies"].append({"byName": ["Bridge", None]})
                with self.assertRaisesRegex(ValueError, "test-support dependency"):
                    verify_test_support(changed)

    def test_both_test_targets_must_keep_the_shared_fixture_owner(self):
        for consumer in ("SpottyBoundaryTests", "SpottySessionRuntimeTests"):
            with self.subTest(consumer=consumer):
                changed = copy.deepcopy(self.targets)
                changed[consumer] = target("SpottySessionRuntime")
                with self.assertRaisesRegex(ValueError, "lost its shared runtime fixtures"):
                    verify_test_support(changed)


class FocusedDependencyClosureTests(unittest.TestCase):
    def setUp(self):
        # Synthetic declarations exercise the validator; expectations derive from these
        # declarations rather than reproducing the production package's dependency map.
        declarations = {
            "Domain": target(), "Ports": target("Domain"), "Support": target("Ports"),
            "Binary": target(), "Engine": target("Binary", "Domain"),
            "Gateway": target("Ports"), "Runtime": target("Engine", "Gateway"),
            "Desktop": target("Runtime"), "App": target("Desktop"),
            "SelectedTests": target("Support", "Runtime"), "OtherTests": target("Desktop"),
        }
        declarations["Desktop"]["dependencies"].append({"product": ["Sparkle", "Sparkle", None, None]})
        self.targets = {name: {"name": name, "type": "test" if name.endswith("Tests") else "regular", **value}
                        for name, value in declarations.items()}
        self.full = {"targets": list(self.targets.values()), "products": [{"name": "App"}],
                     "dependencies": [{"sourceControl": [{"identity": "sparkle", "requirement": "pinned"}]}]}

    def focused(self, name="SelectedTests"):
        local, external = dependency_closure(self.targets, name)
        return {"targets": [copy.deepcopy(value) for key, value in self.targets.items() if key in local],
                "products": [], "dependencies": copy.deepcopy(self.full["dependencies"] if external else [])}

    def test_transitive_closure_excludes_unrelated_tests_executables_and_external_packages(self):
        local, external = dependency_closure(self.targets, "SelectedTests")
        self.assertEqual(local, {"SelectedTests", "Support", "Ports", "Domain", "Runtime", "Engine",
                                 "Binary", "Gateway"})
        self.assertEqual(external, set())
        verify_selection(self.full, self.focused(), "SelectedTests")
        self.targets["SelectedTests"]["dependencies"].append({"target": ["Desktop", None]})
        self.assertEqual(dependency_closure(self.targets, "SelectedTests")[1], {"sparkle"})
        verify_selection(self.full, self.focused(), "SelectedTests")

    def test_every_original_declaration_field_is_preserved_including_conditions_and_resources(self):
        self.targets["SelectedTests"]["resources"] = [{"copy": "Fixtures"}]
        self.targets["SelectedTests"]["dependencies"][0] = {"target": ["Support", {"platformNames": ["macos"]}]}
        verify_selection(self.full, self.focused(), "SelectedTests")
        changed = self.focused()
        next(item for item in changed["targets"] if item["name"] == "SelectedTests")["resources"] = []
        with self.assertRaisesRegex(ValueError, "shared declaration"):
            verify_selection(self.full, changed, "SelectedTests")

    def test_missing_extra_or_duplicate_local_declarations_are_rejected(self):
        for mode in ("missing", "extra", "duplicate"):
            with self.subTest(mode=mode):
                changed = self.focused()
                if mode == "missing":
                    changed["targets"].pop()
                elif mode == "extra":
                    changed["targets"].append(copy.deepcopy(self.targets["OtherTests"]))
                else:
                    changed["targets"].append(copy.deepcopy(changed["targets"][0]))
                with self.assertRaisesRegex(ValueError, "exact local dependency closure"):
                    verify_selection(self.full, changed, "SelectedTests")

    def test_external_pin_and_shipping_product_changes_are_rejected(self):
        for mode in ("extra_external", "changed_pin", "product"):
            with self.subTest(mode=mode):
                changed = self.focused("OtherTests")
                if mode == "extra_external":
                    changed["dependencies"].append({"sourceControl": [{"identity": "another"}]})
                elif mode == "changed_pin":
                    changed["dependencies"][0]["sourceControl"][0]["requirement"] = "changed"
                else:
                    changed["products"] = [{"name": "App"}]
                with self.assertRaisesRegex(ValueError, "unexpected external dependencies or products"):
                    verify_selection(self.full, changed, "OtherTests")

    def test_only_local_binary_path_is_normalized_against_each_package_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            full_package = root / "repository"
            focused_package = full_package / ".build/test-targets/SelectedTests/package"
            binary = root / "engine.xcframework"
            self.targets["Binary"].update(type="binary", path="../engine.xcframework", checksum="original")
            focused = self.focused()
            declaration = next(item for item in focused["targets"] if item["name"] == "Binary")
            declaration["path"] = "../../../../../engine.xcframework"
            verify_selection(self.full, focused, "SelectedTests", full_package=full_package,
                             focused_package=focused_package)
            for changed_field, changed_value in (("path", "../wrong.xcframework"), ("checksum", "changed")):
                changed = copy.deepcopy(focused)
                next(item for item in changed["targets"] if item["name"] == "Binary")[changed_field] = changed_value
                with self.subTest(changed_field=changed_field), self.assertRaisesRegex(ValueError, "shared declaration"):
                    verify_selection(self.full, changed, "SelectedTests", full_package=full_package,
                                     focused_package=focused_package)
            # Production source paths are compared literally even if they could resolve
            # to the same directory. This exception is solely for actual local binaries.
            changed = copy.deepcopy(focused)
            next(item for item in changed["targets"] if item["name"] == "Domain")["path"] = "Sources/Domain"
            with self.assertRaisesRegex(ValueError, "shared declaration"):
                verify_selection(self.full, changed, "SelectedTests", full_package=full_package,
                                 focused_package=focused_package)

    def test_graph_probe_rebases_relative_override_and_keeps_absolute_override(self):
        swift = graph_checks["swift"]
        root = graph_checks["ROOT"]
        for override in ("artifacts/local engine.xcframework", "/tmp/local engine.xcframework"):
            with self.subTest(override=override), mock.patch("subprocess.run") as run:
                swift(root / ".build/test-targets/SelectedTests/package", "test-target:SelectedTests",
                      "dump-package", SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK=override)
                self.assertEqual(run.call_args.kwargs["env"]["SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"], str(root / override))

    def test_positional_graph_overrides_ambient_and_explicit_conflicting_environment(self):
        for requested, conflicting in (("full", "test-target:SpottyDomainTests"),
                                       ("test-target:SpottyDomainTests", "full")):
            with self.subTest(requested=requested), \
                 mock.patch.dict("os.environ", {"SPOTTY_PACKAGE_GRAPH": conflicting}), \
                 mock.patch("subprocess.run") as run:
                graph_checks["swift"](Path("/synthetic/package"), requested, "dump-package",
                                      SPOTTY_PACKAGE_GRAPH=conflicting, SPOTTY_BUILD_BROWSING_HARNESS="1")
                self.assertEqual(run.call_args.kwargs["env"]["SPOTTY_PACKAGE_GRAPH"], requested)
                self.assertEqual(run.call_args.kwargs["env"]["SPOTTY_BUILD_BROWSING_HARNESS"], "1")

    def test_unknown_edges_fail_closed_and_second_reachable_test_is_rejected(self):
        for dependency in ({"byName": ["Missing", None]}, {"unknown": ["Missing"]},
                           {"product": ["Unbound", None, None, None]}):
            with self.subTest(dependency=dependency):
                changed = copy.deepcopy(self.targets)
                changed["SelectedTests"]["dependencies"].append(dependency)
                with self.assertRaises(ValueError):
                    dependency_closure(changed, "SelectedTests")
        self.targets["SelectedTests"]["dependencies"].append({"target": ["OtherTests", None]})
        with self.assertRaisesRegex(ValueError, "only focused test target"):
            verify_selection(self.full, self.focused(), "SelectedTests")


if __name__ == "__main__":
    unittest.main()
