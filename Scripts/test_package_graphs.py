"""Test fixture dependency cuts independently of compiler cache contents."""

import copy
from pathlib import Path
import runpy
import unittest


verify_test_support = runpy.run_path(str(Path(__file__).with_name("check-package-graphs.py")))["verify_test_support"]


def target(*dependencies):
    return {"dependencies": [{"byName": [name, None]} for name in dependencies]}


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


if __name__ == "__main__":
    unittest.main()
