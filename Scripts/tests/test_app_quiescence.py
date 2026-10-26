"""Behavioral tests for the read-only installed-app admission guard."""

from __future__ import annotations

import ctypes
import errno
import importlib
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest import mock

try:
    quiescence = importlib.import_module("Scripts.reconstruction.app_quiescence")
except ModuleNotFoundError:
    quiescence = None


class FakeLibproc:
    def __init__(self) -> None:
        self.paths = {os.getpid(): b"/usr/bin/python3\0", 123: b"/bin/sleep\0"}
        self.path_error = 0
        self.info_result = 0
        self.info_error = errno.ESRCH
        self.list_result = None

    def proc_listpids(self, kind, uid, buffer, capacity):
        assert kind == 4 and uid == os.geteuid()
        for index, pid in enumerate(self.paths):
            buffer[index] = pid
        return self.list_result if self.list_result is not None else len(self.paths) * ctypes.sizeof(ctypes.c_int)

    def proc_pidpath(self, pid, buffer, capacity):
        if pid == 123 and self.path_error:
            ctypes.set_errno(self.path_error)
            return 0
        value = self.paths[pid]
        ctypes.memmove(buffer, value, len(value))
        return len(value) - 1

    def proc_pidinfo(self, pid, flavor, arg, buffer, capacity):
        assert pid == 123 and flavor == 3 and arg == 0
        ctypes.set_errno(self.info_error)
        return self.info_result


class AppQuiescenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertIsNotNone(quiescence, "the fail-closed app quiescence guard must exist")
        self.source = Path("/private/source/MacScope.app")
        self.installed = Path("/Applications/MacScope.app")

    def guard(self, paths, applications=()):
        with mock.patch.object(quiescence, "_process_paths", side_effect=paths), mock.patch.object(
            quiescence, "_bundle_applications", return_value=applications
        ):
            quiescence.require_app_quiescent(self.source, self.installed)

    def test_two_stable_absent_observations_admit(self):
        self.guard([{42: "/usr/bin/python3"}] * 2)

    def test_source_and_installed_executables_refuse(self):
        for app in (self.source, self.installed):
            path = str(app / "Contents/MacOS/MacScope")
            with self.subTest(path=path), self.assertRaisesRegex(quiescence.QuiescenceError, "PID 123"):
                self.guard([{123: path}])

    def test_foreign_bundle_id_refuses_with_pid_and_path(self):
        with self.assertRaisesRegex(quiescence.QuiescenceError, "PID 456.*foreign"):
            self.guard([], ((456, "/foreign/MacScope"),))

    def test_unrelated_process_churn_admits_after_two_absent_observations(self):
        try:
            self.guard([{1: "/usr/bin/python3"}, {2: "/bin/sleep"}])
        except (quiescence.QuiescenceError, StopIteration) as error:
            self.fail(f"unrelated process churn must not prevent target absence: {error}")

    def test_target_appearing_during_process_churn_refuses(self):
        for app in (self.source, self.installed):
            path = str(app / "Contents/MacOS/MacScope")
            with self.subTest(path=path), self.assertRaisesRegex(quiescence.QuiescenceError, "PID 123"):
                self.guard([{1: "/usr/bin/python3"}, {2: "/bin/sleep", 123: path}])

    def test_unknown_path_in_second_observation_refuses(self):
        first, second = FakeLibproc(), FakeLibproc()
        second.path_error = errno.EPERM
        census = iter((first, second))
        with mock.patch.object(quiescence, "_load_libproc", side_effect=lambda: next(census)), mock.patch.object(
            quiescence, "_bundle_applications", return_value=()
        ), self.assertRaisesRegex(quiescence.QuiescenceError, "PID 123 path=unknown"):
            quiescence.require_app_quiescent(self.source, self.installed)

    def test_bundle_id_census_is_refreshed_each_round(self):
        with mock.patch.object(quiescence, "_process_paths", return_value={1: "/a"}), mock.patch.object(
            quiescence, "_bundle_applications", side_effect=[(), ((789, "/foreign/MacScope"),)]
        ), self.assertRaisesRegex(quiescence.QuiescenceError, "PID 789"):
            quiescence.require_app_quiescent(self.source, self.installed)

    def test_valid_libproc_census_decodes_exact_paths(self):
        self.assertEqual(quiescence._process_paths(libproc=FakeLibproc())[123], "/bin/sleep")

    def test_libproc_absent_pid_requires_two_esrch_results(self):
        library = FakeLibproc()
        library.path_error = errno.ESRCH
        self.assertNotIn(123, quiescence._process_paths(libproc=library))

    def test_libproc_unknown_path_or_live_bsd_probe_refuses(self):
        for path_error, info_result, info_error in (
            (errno.EPERM, 0, errno.ESRCH),
            (errno.ESRCH, 0, errno.EPERM),
            (errno.ESRCH, 1, 0),
        ):
            library = FakeLibproc()
            library.path_error, library.info_result, library.info_error = path_error, info_result, info_error
            with self.subTest(case=(path_error, info_result, info_error)), self.assertRaisesRegex(
                quiescence.QuiescenceError, "PID 123"
            ):
                quiescence._process_paths(libproc=library)

    def test_libproc_empty_truncated_and_misaligned_pid_lists_refuse(self):
        for result in (0, -1, 3, 16384 * ctypes.sizeof(ctypes.c_int)):
            library = FakeLibproc()
            library.list_result = result
            with self.subTest(result=result), self.assertRaises(quiescence.QuiescenceError):
                quiescence._process_paths(libproc=library)

    def test_libproc_missing_self_or_invalid_pid_refuses(self):
        for paths in ({123: b"/bin/sleep\0"}, {os.getpid(): b"/usr/bin/python3\0", -1: b"/bad\0"}):
            library = FakeLibproc()
            library.paths = paths
            with self.subTest(paths=paths), self.assertRaises(quiescence.QuiescenceError):
                quiescence._process_paths(libproc=library)

    def test_libproc_invalid_path_refuses(self):
        for path in (b"relative\0", b"/bad\xff\0", b"/bad\0hidden\0", b"x" * 4096):
            library = FakeLibproc()
            library.paths[123] = path
            with self.subTest(path=path[:30]), self.assertRaises(quiescence.QuiescenceError):
                quiescence._process_paths(libproc=library)

    def test_appkit_output_is_strict_and_unknown_identity_refuses(self):
        for value in ({}, [{"pid": True, "path": "/x"}], [{"pid": 7, "path": None}],
                      [{"pid": 7, "path": "relative"}], [{"pid": 7}], [{"pid": 7, "path": "/x", "extra": 1}]):
            with self.subTest(value=value), self.assertRaises(quiescence.QuiescenceError):
                quiescence._decode_applications(json.dumps(value).encode())

    def test_appkit_valid_and_empty_output(self):
        self.assertEqual(quiescence._decode_applications(b"[]\n"), ())
        self.assertEqual(quiescence._decode_applications(b'[{"pid":7,"path":"/foreign/MacScope"}]'), ((7, "/foreign/MacScope"),))

    def test_helper_timeout_refuses_without_signal_or_unbounded_wait(self):
        process = mock.Mock(pid=999)
        process.communicate.side_effect = subprocess.TimeoutExpired("osascript", 3)
        with mock.patch.object(quiescence.subprocess, "Popen", return_value=process), self.assertRaisesRegex(
            quiescence.QuiescenceError, "helper PID 999"
        ):
            quiescence._bundle_applications()
        process.kill.assert_not_called()
        process.terminate.assert_not_called()
        process.send_signal.assert_not_called()
        process.wait.assert_not_called()


if __name__ == "__main__":
    unittest.main()
