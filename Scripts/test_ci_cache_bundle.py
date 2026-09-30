"""Exercise portable scoped cache handoff and reject unsafe tar/manifest inputs."""

import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("ci_cache_bundle.py")
spec = importlib.util.spec_from_file_location("ci_cache_bundle", SCRIPT)
bundles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundles)
REVISION = "a" * 40


class CacheBundleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spotty-cache-test-")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.source = self.base / "source checkout"
        self.destination = self.base / "fresh publisher"
        self.source_cargo = self.base / "source cargo"
        self.destination_cargo = self.base / "publisher cargo"
        self.source_temp = self.base / "source runner"
        self.destination_temp = self.base / "publisher runner"
        for path in (self.source, self.destination, self.source_cargo, self.destination_cargo,
                     self.source_temp, self.destination_temp):
            path.mkdir()
        self.archive = self.base / "cache.tar.gz"

    def roots(self, scope, *, destination=False):
        return bundles.roots_for(scope, root=self.destination if destination else self.source,
                                 cargo_home=self.destination_cargo if destination else self.source_cargo,
                                 runner_temp=self.destination_temp if destination else self.source_temp)

    def write(self, path, content=b"compiled fixture", mode=0o644):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        path.chmod(mode)
        return path

    def export(self, scope="swift"):
        return bundles.export_bundle(self.archive, scope=scope, revision=REVISION, roots=self.roots(scope))

    def restore(self, scope="swift", *, revision=REVISION, replace=False):
        return bundles.restore_bundle(self.archive, scope=scope, revision=revision,
                                      roots=self.roots(scope, destination=True), replace_owned_scope=replace)

    def tar_parts(self):
        with tarfile.open(self.archive) as archive:
            return [(copy.copy(info), archive.extractfile(info).read() if info.isfile() else None)
                    for info in archive.getmembers()]

    def rewrite(self, change):
        parts = self.tar_parts()
        change(parts)
        with tarfile.open(self.archive, "w:gz") as archive:
            for info, data in parts:
                archive.addfile(info, io.BytesIO(data) if data is not None else None)

    def change_manifest(self, parts, change):
        for index, (info, data) in enumerate(parts):
            if info.name == "manifest.json":
                manifest = json.loads(data)
                change(manifest)
                encoded = json.dumps(manifest).encode()
                info.size = len(encoded)
                parts[index] = info, encoded
                return
        self.fail("fixture manifest missing")

    def add_member(self, parts, name, *, kind=tarfile.REGTYPE, data=b"untrusted", linkname=""):
        info = tarfile.TarInfo(name)
        info.type = kind
        info.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
        info.mtime = 0
        info.linkname = linkname
        info.size = len(data) if kind == tarfile.REGTYPE else 0
        parts.append((info, data if info.isfile() else None))
        digest = hashlib.sha256(data).hexdigest() if info.isfile() else None
        self.change_manifest(parts, lambda manifest: manifest["entries"].append(bundles.member_record(info, digest)))

    def prepare_swift(self):
        product = self.write(self.source / ".build/out/Products/Debug/Spotty", mode=0o751)
        os.utime(product, (1_700_000_000, 1_700_000_000))
        os.link(product, self.source / ".build/out/Products/Debug/Spotty-linked")
        (self.source / ".build/debug").symlink_to("out/Products/Debug")
        self.write(self.source / ".build/spotty-signing/private-key", b"signing-secret")
        self.write(self.source / ".build/.netrc", b"credential-secret")
        self.write(self.source / "outside-cache.txt", b"outside")
        return product

    def test_swift_round_trip_preserves_modes_links_and_mapping_across_checkout_names(self):
        self.prepare_swift()
        exported = self.export()
        restored = self.restore()
        product = self.destination / ".build/out/Products/Debug/Spotty"
        linked = product.with_name("Spotty-linked")
        self.assertEqual(product.read_bytes(), b"compiled fixture")
        self.assertEqual(stat.S_IMODE(product.stat().st_mode), 0o751)
        self.assertEqual(product.stat().st_mtime, 1_700_000_000)
        self.assertEqual(product.stat().st_ino, linked.stat().st_ino)
        self.assertEqual(os.readlink(self.destination / ".build/debug"), "out/Products/Debug")
        self.assertFalse((self.destination / ".build/spotty-signing").exists())
        self.assertFalse((self.destination / ".build/.netrc").exists())
        self.assertFalse((self.destination / "outside-cache.txt").exists())
        self.assertEqual(exported, restored)
        self.assertGreater(exported["archive_bytes"], 0)
        self.assertEqual(exported["payload_bytes"], len(b"compiled fixture"))
        with tarfile.open(self.archive) as archive:
            manifest = json.load(archive.extractfile("manifest.json"))
            self.assertEqual(manifest["roots"], [{"name": "build", "base": "repo", "path": ".build"}])
            self.assertEqual(manifest["revision"], REVISION)
            self.assertEqual(manifest["scope"], "swift")
            content = b"".join(archive.extractfile(info).read() for info in archive if info.isfile())
        self.assertNotIn(b"signing-secret", content)
        self.assertNotIn(b"credential-secret", content)

    def test_each_rust_and_tool_scope_exports_only_explicit_roots(self):
        target = self.source / "Backend/spotty-playback/target"
        self.write(target / "debug/deps/bridge", b"debug")
        self.write(target / ".rustc_info.json", b"rustc-info")
        self.write(target / "aarch64-apple-darwin/release/bridge", b"release-target")
        self.write(target / "release/build/helper", b"release-host")
        self.write(target / "unowned/file", b"unowned")
        self.write(self.source_cargo / "git/db/repository", b"git")
        self.write(self.source_cargo / "registry/cache/crate", b"registry")
        self.write(self.source_cargo / "credentials.toml", b"cargo-secret")
        self.write(self.source_cargo / "bin/rustup", b"unowned-tool")
        self.write(self.source_temp / "spotty-cbindgen/bin/cbindgen", b"tool", mode=0o755)
        self.write(self.source_temp / "private-token", b"runner-secret")
        expected = {
            "rust-debug": {"rust-debug", "rust-info", "cargo-git", "cargo-registry"},
            "rust-release": {"rust-release-target", "rust-release-host"},
            "cbindgen": {"cbindgen"},
        }
        for scope, names in expected.items():
            with self.subTest(scope=scope):
                self.archive.unlink(missing_ok=True)
                self.export(scope)
                self.restore(scope)
                with tarfile.open(self.archive) as archive:
                    manifest = json.load(archive.extractfile("manifest.json"))
                    self.assertEqual({entry["path"].split("/")[1] for entry in manifest["entries"]}, names)
                self.assertFalse((self.destination_cargo / "credentials.toml").exists())
                self.assertFalse((self.destination_temp / "private-token").exists())
                self.assertFalse((self.destination / "Backend/spotty-playback/target/unowned").exists())
        self.assertEqual(stat.S_IMODE((self.destination_temp / "spotty-cbindgen/bin/cbindgen").stat().st_mode), 0o755)

    def test_hardlinks_between_logical_roots_keep_one_inode(self):
        compiled = self.write(self.source / "Backend/spotty-playback/target/debug/compiled", b"shared")
        linked = self.source_cargo / "git/shared"
        linked.parent.mkdir()
        os.link(compiled, linked)
        self.export("rust-debug")
        self.restore("rust-debug")
        restored = self.destination / "Backend/spotty-playback/target/debug/compiled"
        self.assertEqual(restored.stat().st_ino, (self.destination_cargo / "git/shared").stat().st_ino)

    def test_directory_permissions_and_symlink_mtime_survive_restore(self):
        self.write(self.source / ".build/directory/product")
        directory = self.source / ".build/directory"
        directory.chmod(0o750)
        link = self.source / ".build/alias"
        link.symlink_to("directory")
        os.utime(link, (1_700_000_000, 1_700_000_000), follow_symlinks=False)
        self.export()
        self.restore()
        self.assertEqual(stat.S_IMODE((self.destination / ".build/directory").stat().st_mode), 0o750)
        self.assertEqual((self.destination / ".build/alias").lstat().st_mtime, 1_700_000_000)

    def test_default_restore_never_overwrites_or_cleans_existing_cache(self):
        self.prepare_swift()
        self.export()
        existing = self.write(self.destination / ".build/out/Products/Debug/Spotty", b"existing")
        unrelated = self.write(self.destination / ".build/unrelated-evidence", b"evidence")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            self.restore()
        self.assertEqual(existing.read_bytes(), b"existing")
        self.assertEqual(unrelated.read_bytes(), b"evidence")

    def test_replace_clears_only_selected_roots_and_preserves_private_stores(self):
        self.prepare_swift()
        self.export()
        stale = self.write(self.destination / ".build/stale", b"stale")
        private = self.write(self.destination / ".build/spotty-signing/private", b"keep-signing")
        credential = self.write(self.destination / ".build/.netrc", b"keep-credential")
        unrelated = self.write(self.destination / "evidence/outside-scope", b"keep-evidence")
        engine = self.write(self.destination / "Backend/spotty-playback/target/debug/unrelated", b"keep-engine")
        self.restore(replace=True)
        self.assertFalse(stale.exists())
        self.assertEqual(private.read_bytes(), b"keep-signing")
        self.assertEqual(credential.read_bytes(), b"keep-credential")
        self.assertEqual(unrelated.read_bytes(), b"keep-evidence")
        self.assertEqual(engine.read_bytes(), b"keep-engine")
        # A second toolchain's cache can replace the first; its old debug symlink is safely unlinked.
        self.restore(replace=True)
        self.assertEqual(os.readlink(self.destination / ".build/debug"), "out/Products/Debug")

    def test_bad_hash_is_rejected_before_replace_can_clear_existing_evidence(self):
        self.prepare_swift()
        self.export()
        def corrupt(parts):
            for index, (info, data) in enumerate(parts):
                if info.name.endswith("/Spotty"):
                    parts[index] = info, b"x" * len(data)
        self.rewrite(corrupt)
        evidence = self.write(self.destination / ".build/evidence", b"unchanged")
        with self.assertRaisesRegex(ValueError, "hash or size mismatch"):
            self.restore(replace=True)
        self.assertEqual(evidence.read_bytes(), b"unchanged")
        self.assertFalse((self.destination / ".build/debug").exists())

    def test_default_restore_rejects_existing_unlisted_symlink_target_chains(self):
        self.write(self.source / ".build/product")
        (self.source / ".build/escape").symlink_to("unlisted/../outside")
        self.export()
        self.write(self.destination / "outside", b"outside evidence")
        (self.destination / ".build").mkdir()
        (self.destination / ".build/unlisted").symlink_to(".")
        with self.assertRaisesRegex(ValueError, "existing cache root"):
            self.restore()
        self.assertFalse((self.destination / ".build/escape").exists())
        self.assertEqual((self.destination / "outside").read_bytes(), b"outside evidence")

    def test_retained_private_ancestor_collision_fails_before_replacement_cleanup(self):
        self.write(self.source / ".build/out", b"new regular file")
        self.export()
        private = self.write(self.destination / ".build/out/spotty-signing/private", b"private")
        stale = self.write(self.destination / ".build/stale", b"stale evidence")
        with self.assertRaisesRegex(ValueError, "retained private directory"):
            self.restore(replace=True)
        self.assertEqual(private.read_bytes(), b"private")
        self.assertEqual(stale.read_bytes(), b"stale evidence")

    def test_unsupported_metadata_fails_before_replacement_cleanup(self):
        self.write(self.source / ".build/product")
        self.export()
        def change(parts):
            for info, _ in parts:
                if info.name == "payload/build":
                    info.mtime = 1e300
                    info.pax_headers = {}
            self.change_manifest(parts, lambda manifest: manifest["entries"][0].update(mtime=1e300))
        self.rewrite(change)
        stale = self.write(self.destination / ".build/stale", b"stale evidence")
        with self.assertRaisesRegex(ValueError, "unsupported cache metadata"):
            self.restore(replace=True)
        self.assertEqual(stale.read_bytes(), b"stale evidence")

    def test_regenerated_package_inputs_are_excluded_and_scratch_products_remain(self):
        package_spec = importlib.util.spec_from_file_location("verification_package", SCRIPT.with_name("verification_package.py"))
        packages = importlib.util.module_from_spec(package_spec)
        package_spec.loader.exec_module(packages)
        for root in (self.source, self.destination):
            self.write(root / "Package.swift", b"manifest fixture")
            self.write(root / "Sources/SpottyDomain/Policy.swift", b"source fixture")
            self.write(root / "Tests/SpottyDomainTests/PolicyTests.swift", b"test fixture")
        for graph in ("domain", "engine-free"):
            packages.prepare(self.source, graph)
            self.write(self.source / f".build/{graph}/debug/product", b"compiled scratch")
        self.export()
        self.restore()
        with tarfile.open(self.archive) as archive:
            names = archive.getnames()
        for graph in ("domain", "engine-free"):
            self.assertFalse(any(f"payload/build/{graph}/package" in name for name in names))
            self.assertEqual((self.destination / f".build/{graph}/debug/product").read_bytes(), b"compiled scratch")
            self.assertFalse((self.destination / f".build/{graph}/package").exists())
            package = packages.prepare(self.destination, graph)
            self.assertEqual((package / "Package.swift").resolve(), (self.destination / "Package.swift").resolve())

    def test_wrong_source_scope_and_mapping_fail_before_restore(self):
        self.prepare_swift()
        self.export()
        with self.assertRaisesRegex(ValueError, "mismatch"):
            self.restore(revision="b" * 40)
        with self.assertRaisesRegex(ValueError, "mismatch"):
            self.restore("cbindgen")
        self.rewrite(lambda parts: self.change_manifest(parts, lambda manifest: manifest["roots"][0].update(path="../outside")))
        with self.assertRaisesRegex(ValueError, "mismatch"):
            self.restore()
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_tar_paths_and_entries_fail_closed(self):
        for name in ("/outside", "../outside", "payload/build/../outside", "payload/build/a//b",
                     "payload/cargo-git/foreign", "payload/build/spotty-signing/secret"):
            with self.subTest(name=name):
                self.archive.unlink(missing_ok=True)
                self.prepare_swift_once()
                self.export()
                self.rewrite(lambda parts: self.add_member(parts, name))
                with self.assertRaises(ValueError):
                    self.restore(replace=True)
                self.assertEqual(list(self.destination.iterdir()), [])

    def prepare_swift_once(self):
        if not (self.source / ".build").exists():
            self.prepare_swift()

    def test_duplicate_tar_and_manifest_entries_and_unlisted_members_are_rejected(self):
        def duplicate_tar(parts):
            parts.append(parts[0])
        def duplicate_manifest(parts):
            self.change_manifest(parts, lambda manifest: manifest["entries"].append(manifest["entries"][0]))
        def unlisted(parts):
            info = tarfile.TarInfo("payload/build/unlisted")
            info.size = 1
            parts.append((info, b"x"))
        for change in (duplicate_tar, duplicate_manifest, unlisted):
            with self.subTest(change=change.__name__):
                self.archive.unlink(missing_ok=True)
                self.prepare_swift_once()
                self.export()
                self.rewrite(change)
                with self.assertRaises(ValueError):
                    self.restore()

    def test_symlink_and_hardlink_escapes_and_non_directory_ancestors_are_rejected(self):
        for kind, linkname, name in (
            (tarfile.SYMTYPE, "/tmp/outside", "payload/build/unsafe"),
            (tarfile.SYMTYPE, "../outside", "payload/build/unsafe"),
            (tarfile.LNKTYPE, "../outside", "payload/build/unsafe"),
            (tarfile.LNKTYPE, "payload/build/debug", "payload/build/unsafe"),
            (tarfile.REGTYPE, "", "payload/build/debug/child"),
            (tarfile.FIFOTYPE, "", "payload/build/fifo"),
        ):
            with self.subTest(kind=kind, linkname=linkname, name=name):
                self.archive.unlink(missing_ok=True)
                self.prepare_swift_once()
                self.export()
                def change(parts):
                    self.add_member(parts, name, kind=kind, linkname=linkname)
                    if kind == tarfile.LNKTYPE:
                        self.change_manifest(parts, lambda manifest: manifest["entries"][-1].update(sha256="0" * 64))
                if kind == tarfile.FIFOTYPE:
                    with self.assertRaisesRegex(ValueError, "unsupported"):
                        self.rewrite(change)
                else:
                    self.rewrite(change)
                    with self.assertRaises(ValueError):
                        self.restore()

    def test_symlink_chain_with_dotdot_is_not_accepted_by_lexical_normalization(self):
        self.write(self.source / ".build/product")
        (self.source / ".build/alias").symlink_to(".")
        (self.source / ".build/escape").symlink_to("alias/../outside")
        with self.assertRaisesRegex(ValueError, "chain escapes"):
            self.export()
        self.assertFalse(self.archive.exists())

    def test_private_case_aliases_and_case_folded_symlink_chains_fail_closed(self):
        self.write(self.source / ".build/product")
        (self.source / ".build/Alias").symlink_to(".")
        (self.source / ".build/escape").symlink_to("alias/../outside")
        with self.assertRaisesRegex(ValueError, "chain escapes"):
            self.export()
        (self.source / ".build/escape").unlink()
        self.export()
        self.rewrite(lambda parts: self.add_member(parts, "payload/build/SPOTTY-SIGNING", kind=tarfile.DIRTYPE))
        private = self.write(self.destination / ".build/spotty-signing/private", b"keep")
        with self.assertRaisesRegex(ValueError, "private store"):
            self.restore(replace=True)
        self.assertEqual(private.read_bytes(), b"keep")

    def test_case_and_unicode_path_aliases_are_rejected_on_every_test_host(self):
        self.prepare_swift()
        for aliases in (("Spotty", "spotty"), ("caf\u00e9", "cafe\u0301")):
            with self.subTest(aliases=aliases):
                self.archive.unlink(missing_ok=True)
                self.export()
                def change(parts):
                    for alias in aliases:
                        self.add_member(parts, f"payload/build/{alias}")
                self.rewrite(change)
                with self.assertRaisesRegex(ValueError, "alias on macOS"):
                    self.restore()

    def test_absolute_export_links_and_symlinked_destination_roots_are_rejected(self):
        self.write(self.source / ".build/product")
        (self.source / ".build/absolute").symlink_to(self.source / ".build/product")
        with self.assertRaisesRegex(ValueError, "absolute"):
            self.export()
        (self.source / ".build/absolute").unlink()
        self.export()
        outside = self.base / "outside"
        outside.mkdir()
        (self.destination / ".build").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.restore(replace=True)
        self.assertEqual(list(outside.iterdir()), [])

    def test_logical_directory_roots_cannot_be_replaced_by_files_or_symlinks(self):
        self.write(self.source / ".build/product")
        for kind in (tarfile.REGTYPE, tarfile.SYMTYPE):
            with self.subTest(kind=kind):
                self.archive.unlink(missing_ok=True)
                self.export()
                def change(parts):
                    root_info = tarfile.TarInfo("payload/build")
                    root_info.type = kind
                    root_info.linkname = "build" if kind == tarfile.SYMTYPE else ""
                    root_info.size = 0
                    record = bundles.member_record(root_info, hashlib.sha256(b"").hexdigest() if kind == tarfile.REGTYPE else None)
                    parts[:] = [(root_info, b"" if kind == tarfile.REGTYPE else None),
                                next(part for part in parts if part[0].name == "manifest.json")]
                    self.change_manifest(parts, lambda manifest: manifest.update(entries=[record]))
                self.rewrite(change)
                with self.assertRaises(ValueError):
                    self.restore(replace=True)
                self.assertEqual(list(self.destination.iterdir()), [])

    def test_export_refuses_existing_or_in_scope_archive_and_requires_explicit_bases(self):
        self.write(self.source / ".build/product")
        with self.assertRaisesRegex(ValueError, "inside"):
            bundles.export_bundle(self.source / ".build/cache.tar.gz", scope="swift", revision=REVISION,
                                  roots=self.roots("swift"))
        self.export()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.export()
        with self.assertRaisesRegex(ValueError, "cargo-home"):
            bundles.roots_for("rust-debug", root=self.source, cargo_home=None, runner_temp=self.source_temp)
        with self.assertRaisesRegex(ValueError, "runner-temp"):
            bundles.roots_for("cbindgen", root=self.source, cargo_home=self.source_cargo, runner_temp=None)
        with self.assertRaisesRegex(ValueError, "complete"):
            self.restore(revision="main")

    def test_cli_reports_elapsed_and_transfer_sizes_and_rejects_export_reset(self):
        self.write(self.source / ".build/product")
        command = [sys.executable, str(SCRIPT), "export", "--scope", "swift", "--archive", str(self.archive),
                   "--revision", REVISION, "--root", str(self.source)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertGreater(receipt["elapsed_seconds"], 0)
        self.assertGreater(receipt["archive_bytes"], 0)
        self.assertEqual(receipt["payload_bytes"], len(b"compiled fixture"))
        result = subprocess.run(command + ["--replace-owned-scope"], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("only to restore", result.stderr)


if __name__ == "__main__":
    unittest.main()
