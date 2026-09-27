"""Prove that engine metadata cannot hide incompatible or stale compiled objects."""

import unittest

from playback_deployment import validate


def commands(*versions):
    return "".join(f"Load command 1\n cmd LC_BUILD_VERSION\n platform 1\n minos {value}\n sdk 27.0\n"
                   for value in versions)


class PlaybackDeploymentTests(unittest.TestCase):
    def test_current_candidate_accepts_older_precompiled_dependencies(self):
        validate("26.0", "26.0", True, commands("11.0", "15.0", "26.0"))

    def test_published_pin_can_precede_producer_floor(self):
        validate("26.0", "15.0", False, commands("11.0", "15.0"))
        validate("26.0", "26.0", False, commands("26.0"))

    def test_source_or_publication_rejects_old_target_even_with_matching_metadata(self):
        with self.assertRaisesRegex(ValueError, "does not match producer"):
            validate("26.0", "15.0", True, commands("15.0"))

    def test_relabeling_old_objects_does_not_make_a_current_candidate(self):
        with self.assertRaisesRegex(ValueError, "no object targeting"):
            validate("26.0", "26.0", True, commands("15.0"))

    def test_binary_cannot_exceed_declared_floor_in_any_mode(self):
        for check_source in (True, False):
            for newer in ("26.0.1", "26.1", "27.0"):
                with self.subTest(source=check_source, newer=newer):
                    with self.assertRaisesRegex(ValueError, "newer than declared"):
                        validate("26.0", "26.0", check_source, commands("26.0", newer))
        with self.assertRaisesRegex(ValueError, "newer than declared"):
            validate("26.0", "15.0", False, commands("15.0.1"))

    def test_published_dependency_cannot_require_a_future_os(self):
        with self.assertRaisesRegex(ValueError, "does not match producer"):
            validate("26.0", "27.0", False, commands("27.0"))

    def test_legacy_load_command_and_zero_patch_version(self):
        validate("26.0", "26.0.0", True,
                 "cmd LC_VERSION_MIN_MACOSX\n version 10.9\n sdk 11.0\n" + commands("26.0"))

    def test_missing_or_invalid_versions_fail_closed(self):
        for value in ("", "26", "26.bad", "-1.0", "26.0.0.1"):
            for field in ("minimum", "declared", "object"):
                with self.subTest(value=value, field=field), self.assertRaises(ValueError):
                    validate(value if field == "minimum" else "26.0",
                             value if field == "declared" else "26.0", True,
                             commands(value if field == "object" else "26.0"))
        for dump in ("", "cmd LC_UUID\n minos 26.0\n", "cmd LC_BUILD_VERSION\n sdk 26.0\n"):
            with self.subTest(dump=dump), self.assertRaisesRegex(ValueError, "no macOS deployment"):
                validate("26.0", "26.0", True, dump)

    def test_valid_objects_cannot_hide_a_malformed_load_command(self):
        for broken in ("cmd LC_BUILD_VERSION\n minos\n", "cmd LC_BUILD_VERSION\n",
                       "cmd LC_BUILD_VERSION\n minos bad\n"):
            with self.subTest(broken=broken), self.assertRaises(ValueError):
                validate("26.0", "26.0", True, broken + commands("26.0"))


if __name__ == "__main__":
    unittest.main()
