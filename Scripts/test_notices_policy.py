"""THIRD_PARTY_NOTICES.md must start with an exact, byte-for-byte copy of the preamble."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


class NoticesPreambleTests(unittest.TestCase):
    def test_preamble_is_an_exact_prefix_of_third_party_notices(self):
        preamble = (ROOT / "Scripts/playback-notices-preamble.md").read_bytes()
        notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_bytes()
        self.assertEqual(notices[: len(preamble)], preamble)


if __name__ == "__main__":
    unittest.main()
