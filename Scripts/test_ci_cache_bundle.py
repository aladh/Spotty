"""Exercise portable scoped cache handoff and reject unsafe tar/manifest inputs."""

import copy
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from script_test_fixtures import process_has_stopped


SCRIPT = Path(__file__).with_name("ci_cache_bundle.py")
spec = importlib.util.spec_from_file_location("ci_cache_bundle", SCRIPT)
bundles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundles)
REVISION = "a" * 40


class GitOutputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spotty-git-output-test-")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.environment = {"PATH": os.defpath, "LANG": "C", "LC_ALL": "C"}

    def read(self, code, *arguments, input_data=None):
        return bundles.read_git_output([sys.executable, "-c", code, *map(str, arguments)],
                                       self.environment, input_data)

    def test_unrelated_launcher_file_writes_are_not_limited_by_stdout_bound(self):
        cache = self.base / "developer cache"
        data = self.read("import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b'c' * 131072); "
                         "sys.stdout.buffer.write(b'head\\n')", cache)
        self.assertEqual(data, b"head\n")
        self.assertEqual(cache.stat().st_size, 131072)

    def test_output_boundary_and_small_metadata_input(self):
        self.assertEqual(self.read("import sys; sys.stdout.buffer.write(b'x' * 65536)"), b"x" * 65536)
        data = b"a" * 64 + b"\n"
        self.assertEqual(self.read("import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())",
                                   input_data=data), data)
        with self.assertRaisesRegex(ValueError, "input exceeds bound"):
            self.read("raise SystemExit('should not execute')", input_data=data + b"x")

    def test_oversized_stdout_rejects_before_process_finishes(self):
        started = time.monotonic()
        with self.assertRaisesRegex(ValueError, "output exceeds bound"):
            self.read("import os,time; os.write(1, b'x' * 65537); time.sleep(30)")
        self.assertLess(time.monotonic() - started, 4)

    def test_single_deadline_covers_pipe_read_and_process_exit(self):
        for code in ("import time; time.sleep(30)",
                     "import os,time; os.close(1); time.sleep(30)"):
            with self.subTest(code=code), patch.object(bundles, "GIT_TIMEOUT", 0.15):
                started = time.monotonic()
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    self.read(code)
                self.assertEqual(raised.exception.timeout, 0.15)
                self.assertLess(time.monotonic() - started, 2)

    def test_session_is_signaled_before_reaping_success_and_failed_leaders(self):
        real_popen, real_killpg = subprocess.Popen, os.killpg
        for status in (0, 72):
            events = []
            processes = []

            def remember_process(*args, **kwargs):
                process = real_popen(*args, **kwargs)
                processes.append(process)
                wait = process.wait

                def reap(*args, **kwargs):
                    events.append("reap")
                    return wait(*args, **kwargs)

                process.wait = reap
                return process

            def signal_owned(pid, signal_number):
                self.assertEqual(pid, processes[0].pid)
                self.assertIsNone(processes[0].returncode)
                self.assertNotIn("reap", events)
                self.assertIsNotNone(os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT))
                events.append("signal")
                return real_killpg(pid, signal_number)

            with self.subTest(status=status), patch.object(bundles.subprocess, "Popen", remember_process), \
                    patch.object(bundles.os, "killpg", signal_owned):
                code = f"import sys; sys.stdout.write('head'); sys.exit({status})"
                if status:
                    with self.assertRaises(subprocess.CalledProcessError) as raised:
                        self.read(code)
                    self.assertEqual(raised.exception.returncode, status)
                else:
                    self.assertEqual(self.read(code), b"head")
            self.assertEqual(events, ["signal", "reap"])

    def test_lost_leader_ownership_never_signals_a_reusable_group(self):
        reaped = []

        def externally_reap(identifier, pid, options):
            if not reaped:
                os.waitpid(pid, 0)
                reaped.append(pid)
            raise ChildProcessError("private external reap fixture")

        with patch.object(bundles.os, "waitid", externally_reap), patch.object(bundles.os, "killpg") as signal_group:
            with self.assertRaisesRegex(ValueError, "ownership was lost"):
                self.read("import sys; sys.stdout.write('head')")
        self.assertEqual(len(reaped), 1)
        signal_group.assert_not_called()

    def test_lost_ownership_during_failure_cleanup_never_signals_a_reused_group(self):
        real_popen, real_read = subprocess.Popen, os.read
        for failure in ("overflow", "timeout", "io"):
            processes = []

            def remember_process(*args, **kwargs):
                process = real_popen(*args, **kwargs)
                processes.append(process)
                return process

            def externally_reap(identifier, pid, options):
                self.assertEqual(pid, processes[0].pid)
                self.assertIsNone(processes[0].returncode)
                os.kill(pid, bundles.signal.SIGKILL)
                os.waitpid(pid, 0)
                raise ChildProcessError("private external reap fixture")

            def fail_stdout_read(descriptor, size):
                if processes and descriptor == processes[0].stdout.fileno():
                    raise OSError("private I/O fixture")
                return real_read(descriptor, size)

            code = "import os,time; os.write(1, b'x' * " + ("65537" if failure == "overflow" else "1") + "); time.sleep(30)"
            expected = {"overflow": ValueError, "timeout": subprocess.TimeoutExpired, "io": OSError}[failure]
            output = io.StringIO()
            with self.subTest(failure=failure), patch.object(bundles.subprocess, "Popen", remember_process), \
                    patch.object(bundles.os, "waitid", externally_reap), patch.object(bundles.os, "killpg") as signal_group, \
                    patch.object(bundles, "GIT_TIMEOUT", 0.15), patch.object(sys, "stderr", output):
                if failure == "io":
                    with patch.object(bundles.os, "read", side_effect=fail_stdout_read), self.assertRaises(expected):
                        self.read(code)
                else:
                    with self.assertRaises(expected):
                        self.read(code)
            signal_group.assert_not_called()
            self.assertIsNotNone(processes[0].returncode)
            self.assertEqual(output.getvalue(), "CI cache bundle: Git metadata child cleanup failed\n")

    def test_secondary_cleanup_failure_is_visible_without_replacing_original_error(self):
        real_popen = subprocess.Popen
        output = io.StringIO()

        def cleanup_failure(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            wait = process.wait

            def reap(*args, **kwargs):
                wait(*args, **kwargs)
                raise OSError("private cleanup fixture")

            process.wait = reap
            return process

        with patch.object(bundles.subprocess, "Popen", cleanup_failure), patch.object(sys, "stderr", output):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                self.read("raise SystemExit(72)")
        self.assertEqual(raised.exception.returncode, 72)
        self.assertEqual(output.getvalue(), "CI cache bundle: Git metadata child cleanup failed\n")

    def test_stream_close_failures_preserve_original_subprocess_error_and_private_marker(self):
        real_popen = subprocess.Popen
        for original in ("exit", "timeout", "success"):
            for failed_stream in ("stdout", "stdin"):
                for error_type in (OSError, ValueError):
                    output = io.StringIO()
                    closed = []

                    def close_failure(*args, **kwargs):
                        process = real_popen(*args, **kwargs)
                        for name in ("stdout", "stdin"):
                            stream = getattr(process, name)
                            close = stream.close
                            calls = [0]

                            def finish(name=name, close=close, calls=calls):
                                calls[0] += 1
                                close()
                                # stdin is closed once to submit the metadata query,
                                # then again during final cleanup, which is the failure.
                                if name == "stdout" or calls[0] > 1:
                                    closed.append(name)
                                    if name == failed_stream:
                                        raise error_type("private stream cleanup fixture")

                            stream.close = finish
                        return process

                    code = ("import time; time.sleep(30)" if original == "timeout" else
                            "import sys; sys.stdin.buffer.read(); sys.exit(" + ("72" if original == "exit" else "0") + ")")
                    expected = {"exit": subprocess.CalledProcessError, "timeout": subprocess.TimeoutExpired,
                                "success": ValueError}[original]
                    with self.subTest(original=original, stream=failed_stream, error=error_type.__name__), \
                            patch.object(bundles.subprocess, "Popen", close_failure), patch.object(sys, "stderr", output), \
                            patch.object(bundles, "GIT_TIMEOUT", 0.3):
                        with self.assertRaises(expected) as raised:
                            self.read(code, input_data=b"a\n")
                    self.assertEqual(closed, ["stdout", "stdin"])
                    if original == "success":
                        self.assertEqual(str(raised.exception), "Git metadata child cleanup failed")
                        self.assertEqual(output.getvalue(), "")
                    else:
                        self.assertEqual(output.getvalue(), "CI cache bundle: Git metadata child cleanup failed\n")
                        if original == "exit":
                            self.assertEqual(raised.exception.returncode, 72)
                        else:
                            self.assertEqual(raised.exception.timeout, 0.3)
                    self.assertNotIn("private", str(raised.exception))

    def test_darwin_empty_group_exception_requires_exact_bounded_positive_metadata(self):
        pid = 123
        cases = ((1, [pid], True), (0, [], False), (2, [pid, 124], False),
                 (3, [pid, 124], False), (-1, [], False), (1, [124], False))
        for count, members, expected in cases:
            def list_group(group, buffer, size):
                self.assertEqual((group, size), (pid, 8))
                for index, member in enumerate(members):
                    buffer[index] = member
                return count

            library = SimpleNamespace(proc_listpgrppids=list_group)
            with self.subTest(count=count, members=members), patch.object(bundles.sys, "platform", "darwin"), \
                    patch.object(bundles.os, "waitid", return_value=SimpleNamespace(si_pid=pid)), \
                    patch.object(bundles.ctypes, "CDLL", return_value=library) as loader:
                self.assertEqual(bundles.exited_group_contains_only_leader(pid), expected)
                loader.assert_called_once_with("/usr/lib/libproc.dylib")
        for state in (None, SimpleNamespace(si_pid=124)):
            with patch.object(bundles.sys, "platform", "darwin"), patch.object(bundles.os, "waitid", return_value=state), \
                    patch.object(bundles.ctypes, "CDLL") as loader:
                self.assertFalse(bundles.exited_group_contains_only_leader(pid))
                loader.assert_not_called()
        for failure in (OSError("private library error"), AttributeError("private missing API"),
                        bundles.ctypes.ArgumentError("private ctypes argument"), TypeError("private ctypes type"),
                        ValueError("private ctypes value"), RuntimeError("private native call")):
            with patch.object(bundles.sys, "platform", "darwin"), \
                    patch.object(bundles.os, "waitid", return_value=SimpleNamespace(si_pid=pid)), \
                    patch.object(bundles.ctypes, "CDLL", side_effect=failure):
                self.assertFalse(bundles.exited_group_contains_only_leader(pid))

    def test_darwin_native_call_exception_fails_closed_without_leaking_diagnostics(self):
        def failed_native_call(group, buffer, size):
            raise bundles.ctypes.ArgumentError("private native argument/path")

        library = SimpleNamespace(proc_listpgrppids=failed_native_call)
        output = io.StringIO()
        with patch.object(bundles.sys, "platform", "darwin"), \
                patch.object(bundles.os, "waitid", return_value=SimpleNamespace(si_pid=123)), \
                patch.object(bundles.ctypes, "CDLL", return_value=library), patch.object(sys, "stderr", output):
            self.assertFalse(bundles.exited_group_contains_only_leader(123))
        self.assertEqual(output.getvalue(), "")

    def test_empty_group_exception_never_accepts_other_permission_errors(self):
        for error in (PermissionError(errno.EACCES, "private denied group"), PermissionError("private unknown errno")):
            with self.subTest(errno=error.errno), patch.object(bundles.os, "killpg", side_effect=error), \
                    patch.object(bundles, "exited_group_contains_only_leader", return_value=True) as group_proof:
                with self.assertRaisesRegex(ValueError, "child cleanup failed"):
                    self.read("print('head')")
            group_proof.assert_not_called()

    @unittest.skipUnless(sys.platform == "darwin", "Darwin zombie-only group semantics")
    def test_actual_darwin_exited_group_has_only_its_unreaped_leader(self):
        process = subprocess.Popen([sys.executable, "-c", "print('head')"], stdout=subprocess.PIPE,
                                   start_new_session=True)
        try:
            self.assertEqual(process.stdout.read(), b"head\n")
            deadline = time.monotonic() + 2
            while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            self.assertTrue(bundles.exited_group_contains_only_leader(process.pid))
        finally:
            process.wait(timeout=1)
            process.stdout.close()

    @unittest.skipUnless(sys.platform == "darwin", "Darwin group membership query")
    def test_denied_signal_with_a_live_owned_group_member_cannot_pass(self):
        terminal = self.base / "denied-child.stop"
        self.addCleanup(terminal.touch)
        child_code = ("import pathlib,sys,time\nstop=pathlib.Path(sys.argv[1])\n"
                      "for _ in range(1500):\n if stop.exists(): break\n time.sleep(0.02)\n")
        code = ("import subprocess,sys; subprocess.Popen([sys.executable, '-c', "
                + repr(child_code) + ", sys.argv[1]], stdout=subprocess.DEVNULL)")
        try:
            with patch.object(bundles.os, "killpg", side_effect=PermissionError(errno.EPERM, "private denied group")):
                with self.assertRaisesRegex(ValueError, "child cleanup failed"):
                    self.read(code, terminal)
        finally:
            terminal.touch()

    def test_retirement_observer_preserves_disappearing_proc_reads_and_requires_exit_proof(self):
        for error in (FileNotFoundError(errno.ENOENT, "retired proc entry"),
                      ProcessLookupError(errno.ESRCH, "retired proc entry")):
            with self.subTest(error=type(error).__name__), patch("script_test_fixtures.os.kill") as probe, \
                    patch("script_test_fixtures.Path.read_text", side_effect=error):
                self.assertFalse(process_has_stopped(12345))
                probe.assert_called_once_with(12345, 0)
            with patch("script_test_fixtures.os.kill", side_effect=ProcessLookupError), \
                    patch("script_test_fixtures.Path.read_text") as read:
                self.assertTrue(process_has_stopped(12345))
                read.assert_not_called()
        for state, expected in (("R", False), ("Z", True)):
            with self.subTest(state=state), patch("script_test_fixtures.os.kill"), \
                    patch("script_test_fixtures.Path.read_text", return_value=f"12345 (owned fixture) {state} 1"):
                self.assertEqual(process_has_stopped(12345), expected)
        with patch("script_test_fixtures.os.kill"), \
                patch("script_test_fixtures.Path.read_text", side_effect=PermissionError(errno.EACCES, "denied")):
            with self.assertRaises(PermissionError):
                process_has_stopped(12345)
        with patch("script_test_fixtures.os.kill"), \
                patch("script_test_fixtures.Path.read_text", return_value="malformed"):
            with self.assertRaises(IndexError):
                process_has_stopped(12345)

    def test_owned_children_are_killed_and_direct_process_joined_on_overflow_timeout_and_io_error(self):
        real_popen = subprocess.Popen
        real_read = os.read
        for failure in ("overflow", "timeout", "inherited_stdout", "closed_stdout", "io"):
            processes = []
            child_pid = self.base / (failure + "-child.pid")
            terminal = self.base / (failure + "-child.stop")
            self.addCleanup(terminal.touch)
            child_code = ("import pathlib,sys,time\nstop=pathlib.Path(sys.argv[1])\n"
                          "for _ in range(1500):\n if stop.exists(): break\n time.sleep(0.02)\n")
            code = (
                "import pathlib,subprocess,sys,time,os; "
                "child = subprocess.Popen([sys.executable, '-c', "
                + repr(child_code) + ", sys.argv[2]], "
                + ("stdout=subprocess.DEVNULL); " if failure == "closed_stdout" else "); ")
                + "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); "
                + ("os.write(1, b'x' * 65537); " if failure == "overflow" else
                   "os.write(1, b'ready'); " if failure == "io" else "")
                + ("raise SystemExit(0)" if failure in {"inherited_stdout", "closed_stdout"} else "time.sleep(30)")
            )

            def remember_process(*args, **kwargs):
                process = real_popen(*args, **kwargs)
                processes.append(process)
                return process

            def fail_stdout_read(descriptor, size):
                if processes and descriptor == processes[0].stdout.fileno():
                    raise OSError("private I/O fixture")
                return real_read(descriptor, size)

            with self.subTest(failure=failure), patch.object(bundles.subprocess, "Popen", remember_process), \
                    patch.object(bundles, "GIT_TIMEOUT", 0.5):
                if failure == "io":
                    with patch.object(bundles.os, "read", side_effect=fail_stdout_read):
                        with self.assertRaises(OSError):
                            self.read(code, child_pid, terminal)
                else:
                    if failure == "closed_stdout":
                        self.assertEqual(self.read(code, child_pid, terminal), b"")
                    else:
                        with self.assertRaises(ValueError if failure == "overflow" else subprocess.TimeoutExpired):
                            self.read(code, child_pid, terminal)
            self.assertTrue(child_pid.exists())
            self.assertEqual(len(processes), 1)
            self.assertIsNotNone(processes[0].returncode)
            pid = int(child_pid.read_text())
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if process_has_stopped(pid):
                    break
                time.sleep(0.02)
            else:
                self.fail("owned descendant survived metadata reader cleanup")

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

    def git_checkout(self, files, *, destination=False, links=None):
        cargo = self.destination_cargo if destination else self.source_cargo
        pending = cargo / "git/checkouts/librespot-fixture/pending"
        for name, content in files.items():
            self.write(pending / name, content)
        for name, target in (links or {}).items():
            link = pending / name
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)
        arguments = ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                     "-c", "user.name=Cache Fixture", "-c", "user.email=cache-fixture@example.invalid"]
        environment = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
        for command in (["init", "--quiet", str(pending)], ["-C", str(pending), "add", "--all"],
                        ["-C", str(pending), "commit", "--quiet", "-m", "Public dependency fixture"]):
            subprocess.run(arguments + command, check=True, capture_output=True, env=environment)
        revision = subprocess.run(arguments + ["-C", str(pending), "rev-parse", "HEAD"], check=True,
                                  capture_output=True, text=True, env=environment).stdout.strip()
        checkout = pending.with_name(revision[:7])
        pending.rename(checkout)
        return checkout

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

    def test_tracked_public_credentials_schema_survives_without_credential_stores(self):
        schema = "protocol/proto/spotify/login5/v3/credentials/credentials.proto"
        checkout = self.git_checkout({schema: b'syntax = "proto3"; message Password {}\n', ".cargo-ok": b""},
                                     links={"protocol/proto/spotify/login5/v3/credentials/source.proto": "credentials.proto"})
        public = checkout / schema
        tracked = subprocess.run(["git", "-C", str(checkout), "ls-files", "--", schema],
                                 check=True, capture_output=True, text=True)
        self.assertEqual(tracked.stdout.strip(), schema)
        (checkout / "credential-schema").symlink_to(schema)
        registry = self.source_cargo / "registry/src/registry-fixture/crate-1.0"
        self.write(registry / "proto/CREDENTIALS/public.proto", b"public registry schema")
        secrets = (
            self.source_cargo / "credentials.toml", self.source_cargo / "config.toml",
            self.source_cargo / "config", self.source_cargo / "git/credentials",
            self.source_cargo / "registry/credentials.json", checkout / ".cargo/credentials",
            checkout / ".git/credentials", checkout / "src/credentials",
            checkout / "src/credentials.toml", checkout / "src/CREDENTIALS.JSON",
            checkout / "src/.netrc", checkout / "src/.git-credentials",
            registry / "src/.npmrc", registry / "src/id_ed25519",
        )
        for secret in secrets:
            self.write(secret, b"private credential fixture")
        self.export("rust-debug")
        self.restore("rust-debug")
        restored = self.destination_cargo / checkout.relative_to(self.source_cargo)
        self.assertEqual((restored / schema).read_bytes(), public.read_bytes())
        self.assertEqual((restored / "credential-schema").read_bytes(), public.read_bytes())
        self.assertEqual((restored / "protocol/proto/spotify/login5/v3/credentials/source.proto").read_bytes(), public.read_bytes())
        self.assertTrue((restored / ".cargo-ok").exists())
        self.assertFalse((self.destination_cargo / "registry/src/registry-fixture/crate-1.0/proto/CREDENTIALS").exists())
        for secret in secrets:
            with self.subTest(secret=secret.relative_to(self.source_cargo)):
                self.assertFalse((self.destination_cargo / secret.relative_to(self.source_cargo)).exists())
        with tarfile.open(self.archive) as archive:
            content = b"".join(archive.extractfile(info).read() for info in archive if info.isfile())
        self.assertNotIn(b"private credential fixture", content)

    def test_source_preflight_uses_exact_export_admission_without_mutating_inputs(self):
        schema = "proto/credentials/credentials.proto"
        checkout = self.git_checkout({schema: b"public schema"},
                                     links={"proto/credentials/source.proto": "credentials.proto"})
        secrets = (self.source_cargo / "credentials.toml", self.source_cargo / "config.toml",
                   checkout / ".cargo/credentials", checkout / ".git/credentials",
                   checkout / "src/credentials", checkout / "src/credentials.json",
                   self.source_cargo / "registry/src/credentials/private")
        for path in secrets:
            self.write(path, b"private fixture")
        before = {path.relative_to(self.source_cargo): (path.lstat().st_mode, path.read_bytes())
                  for path in self.source_cargo.rglob("*") if path.is_file() and not path.is_symlink()}
        result = bundles.preflight_credentials(self.source_cargo / "git")
        self.assertEqual(result["proven_public_inputs"], 2)
        self.assertGreater(result["examined_entries"], 2)
        self.assertFalse(self.archive.exists())
        after = {path.relative_to(self.source_cargo): (path.lstat().st_mode, path.read_bytes())
                 for path in self.source_cargo.rglob("*") if path.is_file() and not path.is_symlink()}
        self.assertEqual(after, before)
        self.export("rust-debug")
        self.restore("rust-debug")
        restored = self.destination_cargo / checkout.relative_to(self.source_cargo)
        self.assertEqual((restored / schema).read_bytes(), b"public schema")
        self.assertEqual((restored / "proto/credentials/source.proto").read_bytes(), b"public schema")
        for path in secrets:
            self.assertFalse((self.destination_cargo / path.relative_to(self.source_cargo)).exists())

    def test_source_preflight_reports_untracked_and_modified_source_failures(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        token = self.write(checkout / "proto/credentials/token", b"private fixture")
        with self.assertRaisesRegex(ValueError, r"git-tree:rejected"):
            bundles.preflight_credentials(self.source_cargo / "git")
        self.assertEqual(token.read_bytes(), b"private fixture")
        token.unlink()
        source = checkout / "proto/credentials/credentials.proto"
        source.write_bytes(b"modified private fixture")
        with self.assertRaisesRegex(ValueError, r"source-bytes:rejected"):
            bundles.preflight_credentials(self.source_cargo / "git")
        self.assertEqual(source.read_bytes(), b"modified private fixture")
        self.assertFalse(self.archive.exists())

    def test_source_proof_diagnostics_expose_only_fixed_stage_and_process_status(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        relative = (checkout / "proto/credentials/credentials.proto").relative_to(self.source_cargo / "git")
        failures = (
            (subprocess.CalledProcessError(128, ["private argv"], stderr=b"private stderr"), "git-exit-128"),
            (subprocess.CalledProcessError(-25, ["private argv"]), "git-exit--25"),
            (subprocess.TimeoutExpired(["private argv"], 5, stderr=b"private stderr"), "git-timeout"),
            (OSError("private path"), "io"),
        )
        for failure, reason in failures:
            with self.subTest(reason=reason), patch.object(bundles, "read_git_output", side_effect=failure):
                with self.assertRaises(ValueError) as raised:
                    bundles.verify_credentials_proof(self.source_cargo / "git", "cargo-git", relative)
                self.assertEqual(str(raised.exception),
                                 f"public credentials source lacks exact tracked HEAD proof (git-head:{reason})")
                self.assertNotIn("private", str(raised.exception))

    def test_actual_subprocess_error_and_timeout_keep_fixed_private_source_diagnostics(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        relative = (checkout / "proto/credentials/credentials.proto").relative_to(self.source_cargo / "git")
        reader = bundles.read_git_output
        commands = (
            ("import sys; sys.stderr.write('private stderr path/config/object'); sys.exit(72)", "git-exit-72"),
            ("import time; time.sleep(30)", "git-timeout"),
        )
        for code, reason in commands:
            def launch_fixture(command, environment, input_data=None):
                return reader([sys.executable, "-c", code], environment, input_data)

            with self.subTest(reason=reason), patch.object(bundles, "read_git_output", launch_fixture), \
                    patch.object(bundles, "GIT_TIMEOUT", 0.15):
                with self.assertRaises(ValueError) as raised:
                    bundles.verify_credentials_proof(self.source_cargo / "git", "cargo-git", relative)
            self.assertEqual(str(raised.exception),
                             f"public credentials source lacks exact tracked HEAD proof (git-head:{reason})")
            self.assertNotIn("private", str(raised.exception))

    def test_source_metadata_and_preflight_traversal_errors_do_not_disclose_paths(self):
        root = self.source_cargo / "git"
        root.mkdir()
        relative = bundles.PurePosixPath("checkouts/repo/0000000/proto/credentials/credentials.proto")
        with patch.object(Path, "lstat", side_effect=OSError("private source path")):
            with self.assertRaises(ValueError) as raised:
                bundles.verify_credentials_proof(root, "cargo-git", relative)
        self.assertEqual(str(raised.exception),
                         "public credentials source lacks exact tracked HEAD proof (input-metadata:io)")
        with patch.object(bundles, "paths_in", side_effect=OSError("private traversal path")):
            with self.assertRaises(ValueError) as raised:
                bundles.preflight_credentials(root)
        self.assertEqual(str(raised.exception), "source preflight traversal failed (io)")
        command = [str(SCRIPT), "preflight", "--scope", "rust-debug", "--revision", REVISION,
                   "--cargo-home", str(self.source_cargo)]
        for error in (OSError("private base path"), ValueError("private redirect path")):
            output = io.StringIO()
            with self.subTest(error=type(error).__name__), patch.object(sys, "argv", command), \
                    patch.object(sys, "stderr", output), patch.object(bundles, "roots_for", side_effect=error):
                with self.assertRaises(SystemExit) as raised:
                    bundles.main()
            self.assertEqual(raised.exception.code, 1)
            self.assertEqual(output.getvalue(), "CI cache bundle: source preflight root mapping rejected\n")

    def test_public_credentials_replacement_removes_stale_sources_and_preserves_private_stores(self):
        source = self.git_checkout({"proto/credentials/credentials.proto": b"new public schema"})
        self.export("rust-debug")
        old = self.git_checkout({"proto/credentials/credentials.proto": b"old public schema",
                                 "proto/credentials/obsolete.proto": b"obsolete public schema"}, destination=True)
        public = old / "proto/credentials/credentials.proto"
        stale = public.with_name("obsolete.proto")
        private = self.write(old / ".cargo/credentials", b"retained credential fixture")
        untracked = self.write(old / "proto/credentials/token", b"retained untracked credential fixture")
        self.restore("rust-debug", replace=True)
        self.assertFalse(public.exists())
        self.assertFalse(stale.exists())
        self.assertEqual(private.read_bytes(), b"retained credential fixture")
        self.assertEqual(untracked.read_bytes(), b"retained untracked credential fixture")
        self.assertEqual((self.destination_cargo / source.relative_to(self.source_cargo) / "proto/credentials/credentials.proto")
                         .read_bytes(), b"new public schema")

    def test_manifest_cannot_turn_public_credentials_directory_into_secret_file_or_link(self):
        self.write(self.source_cargo / "git/checkouts/librespot-fixture/939dc5e/src/marker")
        for kind, name in ((tarfile.REGTYPE, "credentials"), (tarfile.SYMTYPE, "CREDENTIALS"),
                           (tarfile.REGTYPE, "credentials.toml")):
            with self.subTest(kind=kind, name=name):
                self.archive.unlink(missing_ok=True)
                self.export("rust-debug")
                path = f"payload/cargo-git/checkouts/librespot-fixture/939dc5e/src/{name}"
                self.rewrite(lambda parts: self.add_member(parts, path, kind=kind, linkname="marker"))
                evidence = self.write(self.destination_cargo / "git/unrelated-evidence", b"retain evidence")
                with self.assertRaisesRegex(ValueError, "private store"):
                    self.restore("rust-debug", replace=True)
                self.assertEqual(evidence.read_bytes(), b"retain evidence")

    def test_public_source_symlink_cannot_reach_excluded_credential_store(self):
        source = self.source_cargo / "git/checkouts/librespot-fixture/939dc5e"
        self.write(source / ".cargo/credentials", b"private credential fixture")
        link = source / "proto/credentials/schema.proto"
        link.parent.mkdir(parents=True)
        link.symlink_to("../../.cargo/credentials")
        with self.assertRaisesRegex(ValueError, "private store"):
            self.export("rust-debug")
        self.assertFalse(self.archive.exists())

    def test_public_credentials_directory_cannot_replace_retained_private_file_or_symlink(self):
        source = self.git_checkout({"src/credentials/credentials.proto": b"public schema"})
        relative = source.relative_to(self.source_cargo) / "src/credentials"
        self.export("rust-debug")
        private = self.destination_cargo / relative
        private.parent.mkdir(parents=True)
        outside = self.base / "outside owned cache"
        outside.mkdir()
        evidence = self.write(outside / "evidence", b"outside evidence")
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                if symlink:
                    private.symlink_to(outside, target_is_directory=True)
                else:
                    self.write(private, b"retained credential fixture")
                stale = self.write(self.destination_cargo / "git/stale", b"retained stale evidence")
                with self.assertRaisesRegex(ValueError, "retained private directory"):
                    self.restore("rust-debug", replace=True)
                self.assertEqual(stale.read_bytes(), b"retained stale evidence")
                self.assertEqual(evidence.read_bytes(), b"outside evidence")
                self.assertFalse((outside / "credentials.proto").exists())
                if not symlink:
                    self.assertEqual(private.read_bytes(), b"retained credential fixture")
                private.unlink()

    def test_public_credentials_symlink_target_must_be_a_manifest_owned_directory(self):
        relative = "git/checkouts/librespot-fixture/939dc5e/src"
        self.write(self.source_cargo / relative / "marker")
        for target in ("credentials", "CREDENTIALS", "alias"):
            with self.subTest(target=target):
                self.archive.unlink(missing_ok=True)
                self.export("rust-debug")
                def change(parts):
                    if target == "alias":
                        self.add_member(parts, f"payload/cargo-git/{relative.removeprefix('git/')}/alias",
                                        kind=tarfile.SYMTYPE, linkname="credentials")
                    self.add_member(parts, f"payload/cargo-git/{relative.removeprefix('git/')}/read-secret",
                                    kind=tarfile.SYMTYPE, linkname=target)
                self.rewrite(change)
                private = self.write(self.destination_cargo / relative / "credentials", b"retained credential fixture")
                stale = self.write(self.destination_cargo / "git/stale", b"retained stale evidence")
                with self.assertRaisesRegex(ValueError, "excluded cache input"):
                    self.restore("rust-debug", replace=True)
                self.assertEqual(private.read_bytes(), b"retained credential fixture")
                self.assertEqual(stale.read_bytes(), b"retained stale evidence")
                self.assertFalse((private.parent / "read-secret").exists())

    def test_untracked_or_modified_credentials_source_cannot_be_exported(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        token = self.write(checkout / "proto/credentials/token", b"untracked credential fixture")
        with self.assertRaises(ValueError):
            self.export("rust-debug")
        self.assertFalse(self.archive.exists())
        token.unlink()
        (checkout / "proto/credentials/credentials.proto").write_bytes(b"modified credential fixture")
        with self.assertRaises(ValueError):
            self.export("rust-debug")
        self.assertFalse(self.archive.exists())

    def test_checkout_revision_and_git_environment_cannot_substitute_public_source_proof(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        with patch.dict(os.environ, {"GIT_DIR": str(self.base / "foreign"), "GIT_WORK_TREE": str(self.base),
                                     "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor",
                                     "GIT_CONFIG_VALUE_0": "must-not-execute"}):
            self.export("rust-debug")
            self.restore("rust-debug")
        self.archive.unlink()
        checkout.rename(checkout.with_name("0000000"))
        with self.assertRaises(ValueError):
            self.export("rust-debug")
        self.assertFalse(self.archive.exists())

    def test_staged_schema_bytes_must_match_git_head_before_replacement(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        self.export("rust-debug")
        path = "payload/cargo-git/" + str(checkout.relative_to(self.source_cargo / "git")) + "/proto/credentials/credentials.proto"
        changed = b"forged credential fixture"
        def change(parts):
            for index, (info, _) in enumerate(parts):
                if info.name == path:
                    info.size = len(changed)
                    parts[index] = info, changed
            def update(manifest):
                entry = next(entry for entry in manifest["entries"] if entry["path"] == path)
                entry.update(size=len(changed), sha256=hashlib.sha256(changed).hexdigest())
            self.change_manifest(parts, update)
        self.rewrite(change)
        stale = self.write(self.destination_cargo / "git/stale", b"unchanged evidence")
        with self.assertRaises(ValueError):
            self.restore("rust-debug", replace=True)
        self.assertEqual(stale.read_bytes(), b"unchanged evidence")
        self.assertFalse((self.destination_cargo / checkout.relative_to(self.source_cargo)).exists())

    def test_existing_modified_credentials_source_is_private_before_git_cleanup(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        self.export("rust-debug")
        old = self.destination_cargo / checkout.relative_to(self.source_cargo)
        old.parent.mkdir(parents=True)
        shutil.copytree(checkout, old, symlinks=True)
        private = self.write(old / "proto/credentials/credentials.proto", b"private modified fixture")
        token = self.write(old / "proto/credentials/token", b"untracked private fixture")
        stale = self.write(self.destination_cargo / "git/stale", b"unchanged evidence")
        with self.assertRaisesRegex(ValueError, "retained private directory"):
            self.restore("rust-debug", replace=True)
        self.assertEqual(private.read_bytes(), b"private modified fixture")
        self.assertEqual(token.read_bytes(), b"untracked private fixture")
        self.assertEqual(stale.read_bytes(), b"unchanged evidence")
        self.assertTrue((old / ".git/HEAD").exists())

    def test_registry_credentials_remain_excluded_without_trusted_source_proof(self):
        crate = self.source_cargo / "registry/src/registry-fixture/crate-1.0"
        relative = "proto/credentials/credentials.proto"
        self.write(crate / relative, b"unproved registry fixture")
        for checksum in (None, "0" * 64, hashlib.sha256(b"unproved registry fixture").hexdigest()):
            with self.subTest(checksum=checksum):
                self.archive.unlink(missing_ok=True)
                if checksum is not None:
                    self.write(crate / ".cargo-checksum.json", json.dumps({"package": "0" * 64,
                                                                        "files": {relative: checksum}}).encode())
                self.export("rust-debug")
                with tarfile.open(self.archive) as archive:
                    self.assertFalse(any("/credentials/" in name for name in archive.getnames()))

    def test_public_source_proof_rejects_git_metadata_redirects_before_export(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        git = checkout / ".git"
        for relative in ("commondir", "objects/info/alternates"):
            with self.subTest(relative=relative):
                redirect = self.write(git / relative, b"outside-metadata\n")
                with self.assertRaises(ValueError):
                    self.export("rust-debug")
                self.assertFalse(self.archive.exists())
                redirect.unlink()
        config = git / "config"
        original = config.read_bytes()
        outside = self.write(self.base / "private-config", b"private config fixture")
        config.write_bytes(original + f'\n[include]\n\tpath = {outside}\n'.encode())
        with self.assertRaises(ValueError):
            self.export("rust-debug")
        self.assertFalse(self.archive.exists())
        self.assertEqual(outside.read_bytes(), b"private config fixture")

    def test_directory_alias_cannot_expose_retained_untracked_credentials(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        old = self.destination_cargo / checkout.relative_to(self.source_cargo)
        old.parent.mkdir(parents=True)
        shutil.copytree(checkout, old, symlinks=True)
        token = self.write(old / "proto/credentials/token", b"retained private fixture")
        outside = self.base / "outside-private-directory"
        outside_secret = self.write(outside / "secret", b"outside private fixture")
        (old / "proto/credentials/private-link").symlink_to(outside, target_is_directory=True)
        stale = self.write(self.destination_cargo / "git/stale", b"retained evidence")
        prefix = "payload/cargo-git/" + str(checkout.relative_to(self.source_cargo / "git"))
        for target in ("proto/credentials", "proto/CREDENTIALS", "directory-chain", ".",
                       "proto/credentials/private-link/secret"):
            with self.subTest(target=target):
                self.archive.unlink(missing_ok=True)
                self.export("rust-debug")
                def change(parts):
                    if target == "directory-chain":
                        self.add_member(parts, prefix + "/directory-chain", kind=tarfile.SYMTYPE,
                                        linkname="proto/credentials")
                    self.add_member(parts, prefix + "/directory-alias", kind=tarfile.SYMTYPE, linkname=target)
                self.rewrite(change)
                with self.assertRaisesRegex(ValueError, "retained private"):
                    self.restore("rust-debug", replace=True)
                self.assertEqual(token.read_bytes(), b"retained private fixture")
                self.assertEqual(stale.read_bytes(), b"retained evidence")
                self.assertEqual(outside_secret.read_bytes(), b"outside private fixture")
                self.assertTrue((old / ".git/HEAD").exists())
                self.assertFalse((old / "directory-alias").is_symlink())

    def test_noncanonical_checkout_cannot_claim_a_public_credentials_directory(self):
        self.write(self.source_cargo / "git/checkouts/repo/not-a-revision/src/marker")
        self.export("rust-debug")
        path = "payload/cargo-git/checkouts/repo/not-a-revision/src/credentials"
        self.rewrite(lambda parts: self.add_member(parts, path, kind=tarfile.DIRTYPE))
        stale = self.write(self.destination_cargo / "git/stale", b"retained evidence")
        with self.assertRaisesRegex(ValueError, "private store"):
            self.restore("rust-debug", replace=True)
        self.assertEqual(stale.read_bytes(), b"retained evidence")

    def test_changed_executable_or_special_bits_cannot_claim_tracked_public_bytes(self):
        checkout = self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        schema = checkout / "proto/credentials/credentials.proto"
        path = "payload/cargo-git/" + str(schema.relative_to(self.source_cargo / "git"))
        stale = self.write(self.destination_cargo / "git/stale", b"retained evidence")
        for mode in (0o755, 0o4644):
            with self.subTest(mode=mode):
                self.export("rust-debug")
                def change(parts):
                    for info, _ in parts:
                        if info.name == path:
                            info.mode = mode
                    def update(manifest):
                        next(entry for entry in manifest["entries"] if entry["path"] == path)["mode"] = mode
                    self.change_manifest(parts, update)
                self.rewrite(change)
                with self.assertRaises(ValueError):
                    self.restore("rust-debug", replace=True)
                self.assertEqual(stale.read_bytes(), b"retained evidence")
                self.archive.unlink()
        schema.chmod(0o755)
        with self.assertRaises(ValueError):
            self.export("rust-debug")
        self.assertFalse(self.archive.exists())

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
            self.write(root / "Package.resolved", b'{"version": 3, "pins": []}')
            self.write(root / "Sources/SpottyDomain/Policy.swift", b"source fixture")
            self.write(root / "Tests/SpottyDomainTests/PolicyTests.swift", b"test fixture")
        graphs = ("domain", "engine-free", *(f"test-target:{target}" for target in packages.TEST_TARGETS))
        for graph in graphs:
            package = packages.prepare(self.source, graph)
            self.write(package.parent / "debug/product", b"compiled scratch")
        self.export()
        self.restore()
        with tarfile.open(self.archive) as archive:
            names = archive.getnames()
        for graph in graphs:
            with self.subTest(graph=graph):
                workspace = packages.workspace(self.destination, graph)
                prefix = "payload/build/" + (workspace / "package").relative_to(self.destination / ".build").as_posix()
                self.assertFalse(any(name == prefix or name.startswith(prefix + "/") for name in names))
                self.assertEqual((workspace / "debug/product").read_bytes(), b"compiled scratch")
                self.assertFalse((workspace / "package").exists())
                package = packages.prepare(self.destination, graph)
                inputs = ("Package.swift", "Sources/SpottyDomain", "Tests/SpottyDomainTests") if graph == "domain" else (
                    "Package.swift", "Sources", "Tests")
                for relative in inputs:
                    self.assertTrue((package / relative).is_symlink())
                    self.assertEqual((package / relative).resolve(), (self.destination / relative).resolve())
                if graph.startswith("test-target:"):
                    self.assertFalse((package / "Package.resolved").is_symlink())
                    self.assertEqual((package / "Package.resolved").read_bytes(), (self.destination / "Package.resolved").read_bytes())

    def test_incoming_target_package_source_links_are_rejected_before_replacement(self):
        package_spec = importlib.util.spec_from_file_location("verification_package", SCRIPT.with_name("verification_package.py"))
        packages = importlib.util.module_from_spec(package_spec)
        package_spec.loader.exec_module(packages)
        self.write(self.source / ".build/product", b"compiled scratch")
        for target in packages.TEST_TARGETS:
            self.write(self.source / f".build/test-targets/{target}/scratch/product", b"compiled scratch")
        for target in packages.TEST_TARGETS:
            for suffix, kind in (("package", tarfile.DIRTYPE), ("package/Package.swift", tarfile.SYMTYPE),
                                 ("PACKAGE/Sources", tarfile.SYMTYPE)):
                with self.subTest(target=target, suffix=suffix):
                    self.archive.unlink(missing_ok=True)
                    self.export()
                    stale = self.write(self.destination / ".build/retained-evidence", b"keep")
                    name = f"payload/build/test-targets/{target}/{suffix}"

                    def change(parts):
                        if kind == tarfile.SYMTYPE:
                            self.add_member(parts, name.rsplit("/", 1)[0], kind=tarfile.DIRTYPE)
                        self.add_member(parts, name, kind=kind, linkname="../scratch/product")

                    self.rewrite(change)
                    with self.assertRaisesRegex(ValueError, "regenerated package"):
                        self.restore(replace=True)
                    self.assertEqual(stale.read_bytes(), b"keep")
                    self.assertFalse((self.destination / ".build/product").exists())

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

    def test_preflight_cli_requires_only_its_read_only_source_scope(self):
        self.git_checkout({"proto/credentials/credentials.proto": b"public schema"})
        command = [sys.executable, str(SCRIPT), "preflight", "--scope", "rust-debug",
                   "--revision", REVISION, "--root", str(self.source), "--cargo-home", str(self.source_cargo)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["action"], "preflight")
        self.assertEqual(receipt["proven_public_inputs"], 1)
        self.assertGreater(receipt["elapsed_seconds"], 0)
        self.assertNotIn("archive_bytes", receipt)
        self.assertNotIn(str(self.source_cargo), result.stdout)
        for options in (["--archive", str(self.archive)], ["--replace-owned-scope"], ["--scope", "swift"]):
            with self.subTest(options=options):
                failed = subprocess.run(command + options, capture_output=True, text=True, timeout=10)
                self.assertEqual(failed.returncode, 1)
                self.assertIn("source preflight requires rust-debug", failed.stderr)
                self.assertFalse(self.archive.exists())
        command[2] = "export"
        failed = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("require --archive", failed.stderr)

    def test_source_preflight_rejects_missing_or_redirected_cargo_git_root(self):
        with self.assertRaisesRegex(ValueError, "regular Cargo Git root"):
            bundles.preflight_credentials(self.source_cargo / "git")
        outside = self.base / "outside"
        outside.mkdir()
        (self.source_cargo / "git").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "regular Cargo Git root"):
            bundles.preflight_credentials(self.source_cargo / "git")
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
