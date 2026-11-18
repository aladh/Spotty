"""Check the shared notice preamble, dependency identity and bundle validation."""

from pathlib import Path
import runpy
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
GENERATOR = runpy.run_path(str(ROOT / "Scripts/generate-rune-notices.py"))


class NoticesPreambleTests(unittest.TestCase):
    def test_preamble_is_an_exact_prefix_of_third_party_notices(self):
        preamble = (ROOT / "Scripts/playback-notices-preamble.md").read_bytes()
        notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_bytes()
        self.assertEqual(notices[: len(preamble)], preamble)


class RuneNoticesTests(unittest.TestCase):
    def test_cargo_tree_distinguishes_registry_and_rune_vendor_sources(self):
        revision = "10a39584cc1ff739477be52e333a742a024ac956"
        url = f"https://github.com/anomalyco/rune?rev={revision}"
        registry = {"name": "tiny-skia-path", "version": "0.11.4", "source": "registry+https://example.org"}
        git = {**registry, "source": f"git+{url}#{revision}"}
        graph = GENERATOR["parse_tree"](
            f"tiny-skia-path v0.11.4\ntiny-skia-path v0.11.4 ({url}#{revision[:8]}) (*)\n"
        )
        self.assertEqual(graph, {GENERATOR["tree_key"](registry), GENERATOR["tree_key"](git)})
        self.assertEqual(len(graph), 2)

    def test_collects_dotted_licenses_and_embedded_font_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("LICENSE.APACHE", "LICENSE.MIT", "Inter-LICENSE.txt", "copyright.rs"):
                (root / name).touch()
            files = GENERATOR["package_license_candidates"]({"manifest_path": root / "Cargo.toml"})
            self.assertEqual({file.name for file in files}, {"LICENSE.APACHE", "LICENSE.MIT", "Inter-LICENSE.txt"})

    def test_bundle_validation_rejects_missing_or_changed_license_text(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            documents = {}
            license_text = GENERATOR["document_reference"](
                b"Example license text", package="example@1.2.3", license_name="MIT",
                origin="example", source_path="LICENSE", source_url="https://example.org",
                source_revision=None, documents=documents,
            )
            target = GENERATOR["DEFAULT_TARGET"]
            GENERATOR["write_output"](
                output, target=target, root_package={"name": "spotty-rune", "version": "0.1.0"},
                package_records=[{"name": "example", "version": "1.2.3", "license_expression": "MIT",
                                  "source_url": "https://example.org", "license_files": [license_text]}],
                documents=documents, override_inputs=set(),
            )
            verifier = GENERATOR["verify_output"]
            self.assertEqual(verifier(output, target), (1, 1))
            text = output / license_text["bundle_path"]
            text.write_bytes(b"Example changed text")
            with self.assertRaisesRegex(GENERATOR["GenerationError"], "does not match"):
                verifier(output, target)
            text.unlink()
            with self.assertRaisesRegex(GENERATOR["GenerationError"], "cannot verify"):
                verifier(output, target)


if __name__ == "__main__":
    unittest.main()
