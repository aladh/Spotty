import unittest

import contract
import inline_comments
import review


PATH = "Sources/Changed.swift"


def meta():
    return {
        "changed": [PATH],
        "files": {PATH: 4},
        "diff_lines": {PATH: [1, 2, 3]},
    }


def finding(identity="F0123456789ab", line=2, title="A concrete bug"):
    return {
        "id": identity,
        "path": PATH,
        "line": line,
        "severity": "P2",
        "title": title,
        "body": "The changed code has a concrete consequence.",
    }


class ReviewContractTests(unittest.TestCase):
    def test_path_policy_is_shared_by_runtime_and_inline_publisher(self):
        cases = ((PATH, True), ("", False), ("/absolute.swift", False),
                 ("../outside.swift", False), ("Sources\\Changed.swift", False),
                 (".git/config", False), ("Sources/\x00.swift", False))
        for path, expected in cases:
            with self.subTest(path=path):
                self.assertEqual(contract.safe_path(path), expected)
                self.assertEqual(review.safe_path(path), expected)
                self.assertEqual(inline_comments.safe_path(path), expected)

    def test_finding_validation_and_canonical_id_are_shared(self):
        raw = finding(identity="", title="  A concrete bug  ")
        normalized = contract.validate_finding(raw, meta(), allow_empty_id=True)
        self.assertEqual(normalized["title"], "A concrete bug")
        self.assertEqual(contract.canonical_finding_id(PATH, normalized["line"], normalized["title"]),
                         review.validate_result(
                             {"summary": "ok", "findings": [raw], "resolved": []},
                             {**meta(), "previous": []},
                         )["findings"][0]["id"])

        with self.assertRaises(ValueError):
            contract.validate_finding(finding(line=4), meta())

    def test_contract_module_participates_in_policy_digest(self):
        self.assertIn(".github/review/contract.py", review.policy_files())
        self.assertTrue(review.policy_digest())


if __name__ == "__main__":
    unittest.main()
