"""Compiler probes must use the built module's package access, or fail closed."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from swift_package_identity import package_identity


class SwiftPackageIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def native(self, arguments, module="SpottySessionRuntime"):
        binary = self.root / "arm64-apple-macosx" / "debug"
        binary.mkdir(parents=True, exist_ok=True)
        (binary / "description.json").write_text(json.dumps({"swiftCommands": {
            "module": {"moduleName": module, "otherArguments": arguments},
            "dependency": {"moduleName": "Dependency", "otherArguments": ["-package-name", "dependency"]},
        }}))
        return binary

    def xcode(self, identities):
        binary = self.root / "out" / "Products" / "Debug"
        binary.mkdir(parents=True, exist_ok=True)
        (self.root / "manifest.pif").write_text(json.dumps([
            {"type": "target", "contents": {
                "name": "SpottySessionRuntime", "buildConfigurations": [
                    {"name": "Debug", "buildSettings": {"SWIFT_PACKAGE_NAME": identity}},
                    {"name": "Release", "buildSettings": {"SWIFT_PACKAGE_NAME": "another_configuration"}},
                ],
            }} for identity in identities
        ]))
        return binary

    def test_native_identity_is_not_guessed_from_checkout_or_dependency(self):
        binary = self.native(["-Onone", "-package-name", "different_checkout", "-g"])
        self.assertEqual(package_identity(binary), "different_checkout")
        alias = self.root / "debug"
        alias.symlink_to(binary, target_is_directory=True)
        self.assertEqual(package_identity(alias), "different_checkout")

    def test_xcode_uses_selected_configuration_and_accepts_agreeing_targets(self):
        self.assertEqual(package_identity(self.xcode(["different-checkout"] * 2)), "different-checkout")

    def test_missing_invalid_or_conflicting_native_identity_fails(self):
        for arguments in ([], ["-package-name"], ["-package-name", ""],
                          ["-package-name", 17], ["-package-name", "one", "-package-name", "two"]):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                package_identity(self.native(arguments))

    def test_dependency_identity_cannot_substitute_for_missing_module(self):
        with self.assertRaises(ValueError):
            package_identity(self.native(["-package-name", "wrong_module"], module="Other"))

    def test_one_valid_command_does_not_hide_another_missing_identity(self):
        binary = self.native(["-package-name", "valid"])
        description = binary / "description.json"
        data = json.loads(description.read_text())
        data["swiftCommands"]["incomplete"] = {"moduleName": "SpottySessionRuntime", "otherArguments": []}
        description.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            package_identity(binary)

    def test_missing_invalid_or_conflicting_xcode_identity_fails(self):
        for identities in ([], [None], [""], ["one", None], ["one", "two"]):
            with self.subTest(identities=identities), self.assertRaises(ValueError):
                package_identity(self.xcode(identities))

    def test_cli_fails_without_printing_a_guessed_identity(self):
        binary = self.native([])
        (binary / "description.json").write_text("invalid JSON")
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("swift_package_identity.py")), str(binary)],
            capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Compiler package identity:", result.stderr)


if __name__ == "__main__":
    unittest.main()
