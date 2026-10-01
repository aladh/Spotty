"""Runner labels cannot substitute for the executing native environment."""

import unittest

from check_native_environment import validate


class NativeEnvironmentTests(unittest.TestCase):
    def test_runner_and_local_patch_versions_are_admitted(self):
        for version in ("27.0", "27.0.1"):
            validate(version, "arm64", "Xcode 27.0\nBuild version 27A266a", "27.0")

    def test_older_os_wrong_architecture_or_toolchain_fails(self):
        valid = ["27.0", "arm64", "Xcode 27.0\nBuild version 27A266a", "27.0"]
        for index, incorrect in ((0, "26.6"), (0, "28.0"), (1, "x86_64"),
                                 (2, "Xcode 27.2\nBuild version beta"), (3, "26.5")):
            values = valid.copy()
            values[index] = incorrect
            with self.subTest(index=index, incorrect=incorrect), self.assertRaises(ValueError):
                validate(*values)
