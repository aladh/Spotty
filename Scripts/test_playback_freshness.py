import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('freshness', Path(__file__).with_name('check-playback-freshness.py'))
freshness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(freshness)


class FreshnessTests(unittest.TestCase):
    def test_identical_inputs_are_quiet(self):
        self.assertIsNone(freshness.freshness_warning('a' * 64, 'a' * 64))

    def test_changed_inputs_name_both_identities(self):
        warning = freshness.freshness_warning('a' * 64, 'b' * 64)
        self.assertIn('pinned ' + 'a' * 64, warning)
        self.assertIn('source ' + 'b' * 64, warning)
