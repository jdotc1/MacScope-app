"""Exact-key recovery behavior with real private files and fake native boundaries."""
from __future__ import annotations

import importlib
from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


class MissingNoteError(RuntimeError):
    add_note = None


class FailingNoteError(RuntimeError):
    def add_note(self, note):
        raise KeyboardInterrupt("private synthetic diagnostic failure")


class Store:
    def __init__(self, value=None):
        self.value = value
        self.unrelated = object()
        self.fail_write = False

    def read(self):
        return self.value

    def write(self, value):
        if self.fail_write:
            raise RuntimeError("synthetic native failure")
        self.value = value


class ProviderPreferenceRecoveryTests(unittest.TestCase):
    def setUp(self):
        try:
            self.recovery = importlib.import_module("Scripts.reconstruction.app_preference_recovery")
        except ModuleNotFoundError:
            self.fail("exact-key recovery safeguard is not implemented")
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.directory = self.root / "private-recovery"
        self.app = self.root / "MacScope.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/MacScope").write_bytes(b"synthetic executable")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.macscope.app", "CFBundleExecutable": "MacScope"}))
        self.store = Store()
        self.observations = []
        self.quiescence_failure = False

    def tearDown(self):
        self.temporary.cleanup()

    def quiescent(self, first, second):
        self.observations.append((first, second))
        if self.quiescence_failure:
            raise RuntimeError("synthetic live application")

    def execute(self, callback):
        return self.recovery.run_with_provider_preference_recovery(
            (self.app,), callback, _store=self.store, _recovery_directory=self.directory,
            _require_quiescent=self.quiescent)

    def recover(self):
        return self.recovery.recover_provider_preference(
            (self.app,), _store=self.store, _recovery_directory=self.directory,
            _require_quiescent=self.quiescent)

    def assert_safe_diagnostic(self, original, stderr, expected):
        notes = getattr(original, "__notes__", [])
        self.assertIn(expected, notes + stderr.getvalue().splitlines())
        if notes:
            self.assertEqual(notes, [expected])
            self.assertEqual(stderr.getvalue(), "")
        else:
            self.assertEqual(stderr.getvalue(), expected + "\n")

    def test_present_and_absent_restore_only_key_before_return(self):
        for baseline in (None, bytes(range(256))):
            with self.subTest(present=baseline is not None):
                self.store.value = baseline
                unrelated = self.store.unrelated
                def child():
                    journal = self.directory / "pending.json"
                    self.assertTrue(journal.is_file())
                    self.assertEqual(journal.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
                    self.store.value = b"synthetic child state"
                    return 17
                self.assertEqual(self.execute(child), 17)
                self.assertEqual(self.store.value, baseline)
                self.assertIs(self.store.unrelated, unrelated)
                self.assertFalse((self.directory / "pending.json").exists())
        self.assertEqual(len(self.observations), 4)

    def test_failed_callback_preserves_original_error_after_restoring(self):
        self.store.value = b"synthetic original"
        original = RuntimeError("synthetic callback failure")
        def child():
            self.store.value = b"synthetic child state"
            raise original
        with self.assertRaises(RuntimeError) as caught:
            self.execute(child)
        self.assertIs(caught.exception, original)
        self.assertEqual(self.store.value, b"synthetic original")

    def test_callback_oserror_and_valueerror_are_not_replaced_by_admission_error(self):
        for kind in (OSError, ValueError):
            original = kind("synthetic callback failure")
            def child():
                raise original
            with self.assertRaises(kind) as caught:
                self.execute(child)
            self.assertIs(caught.exception, original)

    def test_replay_after_failed_retirement_preserves_present_and_absent_baselines(self):
        for baseline in (b"synthetic baseline", None):
            self.store.value = baseline
            def child():
                self.store.value = b"synthetic child state"
            with mock.patch.object(self.recovery.os, "unlink", side_effect=OSError("synthetic retirement failure")):
                with self.assertRaises(self.recovery.PreferenceRecoveryError):
                    self.execute(child)
            self.assertTrue((self.directory / "pending.json").exists())
            self.store.value = b"synthetic child state"
            metadata = self.recover()
            self.assertEqual(self.store.value, baseline)
            self.assertNotIn("baseline", metadata)
            self.assertFalse((self.directory / "pending.json").exists())

    def test_failed_retirement_flush_republishes_baseline_and_reports_closeout(self):
        self.store.value = b"synthetic baseline"
        real_fsync = self.recovery.os.fsync
        failed = False
        def fsync(fd):
            nonlocal failed
            if not failed and self.directory.exists() and (self.directory / "owner.lock").exists() and not (self.directory / "pending.json").exists():
                # Only fail the retirement directory flush, after execution.
                if self.store.value == b"synthetic baseline" and len(self.observations) == 2:
                    failed = True
                    raise OSError("synthetic retirement flush failure")
            return real_fsync(fd)
        def child():
            self.store.value = None
        with mock.patch.object(self.recovery.os, "fsync", side_effect=fsync):
            with self.assertRaises(self.recovery.PreferenceRecoveryError) as caught:
                self.execute(child)
        self.assertTrue((self.directory / "pending.json").exists())
        self.assertIn("closeout", str(caught.exception))
        self.assertEqual(self.store.value, b"synthetic baseline")
        self.recover()

    def test_restoration_rechecks_journal_after_quiescence(self):
        self.store.value = b"synthetic baseline"
        original_quiescence = self.quiescent
        def quiescent(first, second):
            original_quiescence(first, second)
            if len(self.observations) == 2:
                (self.directory / "pending.json").chmod(0o644)
        self.quiescent = quiescent
        def child():
            self.store.value = None
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(child)
        self.assertIsNone(self.store.value)

    def test_replaced_ownership_lock_refuses_restoration(self):
        self.store.value = b"synthetic baseline"
        def child():
            self.store.value = None
            lock = self.directory / "owner.lock"
            lock.rename(self.directory / "old.lock")
            lock.write_bytes(b"")
            lock.chmod(0o600)
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(child)
        self.assertIsNone(self.store.value)
        self.assertTrue((self.directory / "pending.json").exists())

    def test_abrupt_child_exit_restores_before_return(self):
        self.store.value = b"synthetic original"
        def child():
            self.store.value = None
            return subprocess.run([sys.executable, "-c", "import os; os._exit(23)"], check=False).returncode
        self.assertEqual(self.execute(child), 23)
        self.assertEqual(self.store.value, b"synthetic original")

    def test_wrong_type_refuses_before_launch_without_logging_value(self):
        self.store.value = "private synthetic marker"
        launched = []
        with self.assertRaises(self.recovery.PreferenceRecoveryError) as caught:
            self.execute(lambda: launched.append(True))
        self.assertEqual(launched, [])
        self.assertNotIn(self.store.value, str(caught.exception))
        self.assertFalse((self.directory / "pending.json").exists())

    def test_live_application_leaves_journal_for_explicit_recovery(self):
        self.store.value = b"synthetic baseline"
        def child():
            self.store.value = None
            self.quiescence_failure = True
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(child)
        self.assertIsNone(self.store.value)
        self.assertTrue((self.directory / "pending.json").exists())
        self.quiescence_failure = False
        launched = []
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(lambda: launched.append(True))
        self.assertEqual(launched, [])
        self.recover()
        self.assertEqual(self.store.value, b"synthetic baseline")
        self.assertFalse((self.directory / "pending.json").exists())
        self.assertEqual(list(self.directory.glob("recovered-*.json")), [])

    def test_restore_failure_does_not_discard_baseline_and_keeps_original_error(self):
        original = RuntimeError("synthetic callback failure")
        self.store.value = b"synthetic baseline"
        def child():
            self.store.value = None
            self.store.fail_write = True
            raise original
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(RuntimeError) as caught:
            self.execute(child)
        self.assertIs(caught.exception, original)
        self.assert_safe_diagnostic(original, stderr,
            "provider preference restoration failed; private journal retained for explicit recovery")
        self.assertTrue((self.directory / "pending.json").exists())
        self.store.fail_write = False
        self.recover()
        self.assertEqual(self.store.value, b"synthetic baseline")

    def check_failure_diagnostics(self, failure, expected):
        real_fsync = self.recovery.os.fsync
        for kind in (RuntimeError, MissingNoteError, FailingNoteError):
            with self.subTest(error=kind.__name__):
                self.observations.clear()
                self.directory = self.root / ("private-" + failure + "-" + kind.__name__)
                self.store.fail_write = False
                original = kind("private synthetic callback failure")
                self.store.value = b"private synthetic baseline"
                journal_bytes = []
                closeout_failed = False

                def fsync(fd):
                    nonlocal closeout_failed
                    if (failure == "closeout" and not closeout_failed
                            and len(self.observations) == 2
                            and not (self.directory / "pending.json").exists()):
                        closeout_failed = True
                        raise OSError("private synthetic closeout failure")
                    return real_fsync(fd)

                def child():
                    journal_bytes.append((self.directory / "pending.json").read_bytes())
                    self.store.value = None
                    if failure == "restoration":
                        self.store.fail_write = True
                    if failure == "unsettled":
                        self.recovery._mark_provider_preference_writer_unsettled(original)
                    raise original

                stderr = io.StringIO()
                with mock.patch.object(self.recovery.os, "fsync", side_effect=fsync):
                    with redirect_stderr(stderr), self.assertRaises(BaseException) as caught:
                        self.execute(child)
                self.assertIs(caught.exception, original)
                self.assert_safe_diagnostic(original, stderr, expected)
                self.assertEqual((self.directory / "pending.json").read_bytes(), journal_bytes[0])
                if failure == "unsettled":
                    self.assertIs(original._macscope_preference_writer_unsettled, True)
                    self.assertEqual(len(self.observations), 1)
                self.assertEqual(closeout_failed, failure == "closeout")
                self.assertEqual(self.store.value,
                    b"private synthetic baseline" if failure == "closeout" else None)
                self.store.fail_write = False
                self.recover()
                self.assertEqual(self.store.value, b"private synthetic baseline")

    def test_restoration_diagnostic_failure_never_replaces_original(self):
        self.check_failure_diagnostics("restoration",
            "provider preference restoration failed; private journal retained for explicit recovery")

    def test_unsettled_writer_diagnostic_failure_preserves_marker_and_prevents_restore(self):
        self.check_failure_diagnostics("unsettled",
            "provider preference writer settlement unproven; private journal retained for explicit recovery")

    def test_closeout_diagnostic_failure_never_replaces_original(self):
        self.check_failure_diagnostics("closeout",
            "provider preference journal closeout unproven; inspect private journal before explicit recovery")

    def test_unverified_readback_cannot_return_success(self):
        self.store.value = b"synthetic baseline"
        def child():
            self.store.write = lambda value: None
            self.store.value = None
            return "would publish success"
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(child)
        self.assertTrue((self.directory / "pending.json").exists())

    def test_concurrent_owner_refuses_without_second_launch(self):
        launched = []
        def child():
            with self.assertRaises(self.recovery.PreferenceRecoveryError):
                self.execute(lambda: launched.append(True))
        self.execute(child)
        self.assertEqual(launched, [])

    def test_separate_process_cannot_take_live_ownership_lock(self):
        code = '''
import os
from pathlib import Path
from Scripts.reconstruction.app_preference_recovery import PreferenceRecoveryError, run_with_provider_preference_recovery
class Fake:
    def read(self): raise AssertionError("second owner accessed key")
try:
    run_with_provider_preference_recovery((Path(os.environ["SYNTHETIC_APP"]),), lambda: os._exit(42),
        _store=Fake(), _recovery_directory=Path(os.environ["SYNTHETIC_RECOVERY"]),
        _require_quiescent=lambda first, second: None)
except PreferenceRecoveryError:
    raise SystemExit(19)
'''
        def child():
            result = subprocess.run([sys.executable, "-c", code], env={**os.environ,
                "SYNTHETIC_APP": str(self.app), "SYNTHETIC_RECOVERY": str(self.directory)}, check=False)
            self.assertEqual(result.returncode, 19)
        self.execute(child)

    def test_replay_refuses_different_app_paths_or_malformed_policy(self):
        def child():
            self.quiescence_failure = True
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(child)
        self.quiescence_failure = False
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.recovery.recover_provider_preference((self.app, self.app), _store=self.store,
                _recovery_directory=self.directory, _require_quiescent=self.quiescent)
        journal = self.directory / "pending.json"
        document = json.loads(journal.read_bytes())
        document["key"] = "foreign synthetic key"
        journal.write_bytes(json.dumps(document).encode())
        self.store.write = lambda value: self.fail("invalid recovery mutated key")
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.recover()
        self.assertTrue(journal.exists())

    def test_unknown_app_identity_refuses_before_key_read(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "foreign"}))
        self.store.read = lambda: self.fail("key accessed before app admission")
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(lambda: self.fail("launched foreign app"))

    def test_private_directory_and_symlink_parent_refusal(self):
        self.directory.mkdir(mode=0o755)
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(lambda: self.fail("launched through public directory"))
        self.directory.rmdir()
        real = self.root / "real"
        real.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(real, target_is_directory=True)
        self.directory = alias / "private-recovery"
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(lambda: self.fail("launched through aliased parent"))

    def test_parent_alias_race_cannot_create_recovery_files_in_other_directory(self):
        parent = self.root / "container"
        parent.mkdir()
        other = self.root / "other"
        other.mkdir()
        self.directory = parent / "private-recovery"
        canonical = self.recovery._canonical_path
        replaced = False
        def race(path):
            nonlocal replaced
            result = canonical(path)
            if path == self.directory and not replaced:
                replaced = True
                parent.rename(self.root / "original-parent")
                parent.symlink_to(other, target_is_directory=True)
            return result
        with mock.patch.object(self.recovery, "_canonical_path", side_effect=race):
            with self.assertRaises(self.recovery.PreferenceRecoveryError):
                self.execute(lambda: self.fail("launched through raced alias"))
        self.assertFalse((other / "private-recovery").exists())

    def test_explicit_recovery_refuses_linked_or_public_journal(self):
        def child():
            self.store.value = None
            self.quiescence_failure = True
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(child)
        self.quiescence_failure = False
        journal = self.directory / "pending.json"
        journal.chmod(0o644)
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.recover()
        journal.chmod(0o600)
        alias = self.directory / "linked"
        os.link(journal, alias)
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.recover()
        alias.unlink()
        journal.rename(alias)
        journal.symlink_to(alias)
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.recover()

    def test_killed_parent_journal_blocks_launch_and_replays_explicitly(self):
        code = '''
import os
from pathlib import Path
from Scripts.reconstruction.app_preference_recovery import run_with_provider_preference_recovery
class Fake:
    def read(self): return b"synthetic interrupted baseline"
    def write(self, value): pass
run_with_provider_preference_recovery((Path(os.environ["SYNTHETIC_APP"]),), lambda: os._exit(31),
    _store=Fake(), _recovery_directory=Path(os.environ["SYNTHETIC_RECOVERY"]),
    _require_quiescent=lambda first, second: None)
'''
        result = subprocess.run([sys.executable, "-c", code], env={**os.environ,
            "SYNTHETIC_APP": str(self.app), "SYNTHETIC_RECOVERY": str(self.directory)}, check=False)
        self.assertEqual(result.returncode, 31)
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.execute(lambda: self.fail("launched over interrupted baseline"))
        self.recover()
        self.assertEqual(self.store.value, b"synthetic interrupted baseline")


class IsolatedNativePreferenceBoundaryTests(unittest.TestCase):
    """Source-authored safety checks; never construct a native writable store."""

    def setUp(self):
        self.recovery = importlib.import_module("Scripts.reconstruction.app_preference_recovery")

    def test_native_store_rejects_application_domain_before_native_loading(self):
        with mock.patch.object(self.recovery.ctypes, "CDLL") as load:
            with self.assertRaises(self.recovery.PreferenceRecoveryError):
                self.recovery._NativePreferenceStore(_domain=self.recovery.DOMAIN)
            load.assert_not_called()

    def test_test_domain_requires_canonical_uuid_suffix(self):
        valid = self.recovery.TEST_DOMAIN_PREFIX + "12345678-1234-4234-8234-123456789abc"
        self.assertEqual(self.recovery._require_test_domain(valid), valid)
        for invalid in (None, self.recovery.DOMAIN, valid.upper(), valid + ".other",
                        self.recovery.TEST_DOMAIN_PREFIX + "not-a-uuid"):
            with self.subTest(domain=invalid):
                with self.assertRaises(self.recovery.PreferenceRecoveryError):
                    self.recovery._require_test_domain(invalid)

    def test_journal_is_bound_to_exact_disposable_domain(self):
        first = self.recovery.TEST_DOMAIN_PREFIX + "12345678-1234-4234-8234-123456789abc"
        second = self.recovery.TEST_DOMAIN_PREFIX + "12345678-1234-4234-8234-123456789abd"
        document = self.recovery._journal([], b"synthetic", first)
        self.assertEqual(self.recovery._baseline(document, [], first), b"synthetic")
        for mismatched in (second, self.recovery.DOMAIN):
            with self.assertRaises(self.recovery.PreferenceRecoveryError):
                self.recovery._baseline(document, [], mismatched)
        legacy = self.recovery._journal([], b"synthetic")
        with self.assertRaises(self.recovery.PreferenceRecoveryError):
            self.recovery._baseline(legacy, [], first)

    def test_matrix_host_fences_have_distinct_domains_and_preserve_callback_result(self):
        with mock.patch.object(self.recovery, "provider_preference_recovery") as fence:
            self.assertEqual(self.recovery.run_with_isolated_provider_preference_recovery(
                (), lambda: 17), 17)
            self.assertEqual(self.recovery.run_with_isolated_provider_preference_recovery(
                (), lambda: 23), 23)
        first, second = fence.call_args_list
        self.assertNotEqual(first.kwargs["_domain"], second.kwargs["_domain"])
        for call in (first, second):
            self.assertNotIn("_recovery_directory", call.kwargs)
            self.recovery._require_test_domain(call.kwargs["_domain"])


if __name__ == "__main__":
    unittest.main()
