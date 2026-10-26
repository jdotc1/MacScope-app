"""Durable, exact-key recovery around admitted MacScope UI execution.

No process signalling, domain export, or automatic stale-owner recovery. A killed
parent leaves pending.json; only explicit recovery may consume that baseline.
Private injection arguments are for synthetic tests and native disposable-domain
qualification. Native writes are restricted to disposable test domains; old real-app
journals remain untouched and cannot be replayed through this helper.
"""
from __future__ import annotations

import base64
from contextlib import contextmanager
import ctypes
import fcntl
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import uuid

from Scripts.reconstruction.app_quiescence import require_app_quiescent

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402


DOMAIN = "org.macscope.app"
KEY = "phase2.localAI.providerPreference.v1"
TEST_DOMAIN_PREFIX = "org.macscope.app.tests."
RECOVERY_DIRECTORY = macscope_work_root() / ".macscope-provider-preference-recovery"
MAX_DATA_BYTES = 16 * 1024 * 1024
MAX_JOURNAL_BYTES = 24 * 1024 * 1024
RESTORATION_FAILURE_NOTE = "provider preference restoration failed; private journal retained for explicit recovery"
WRITER_UNSETTLED_NOTE = "provider preference writer settlement unproven; private journal retained for explicit recovery"
JOURNAL_CLOSEOUT_FAILURE_NOTE = "provider preference journal closeout unproven; inspect private journal before explicit recovery"


class PreferenceRecoveryError(RuntimeError):
    """Recovery admission or restoration failed; messages never contain values."""


class _JournalCloseoutError(PreferenceRecoveryError):
    """Preference readback passed, but journal retirement did not finish."""


def _add_fixed_diagnostic(error, note):
    """Keep the original failure even without exception notes or a working sink."""
    try:
        add_note = getattr(error, "add_note", None)
        if callable(add_note):
            add_note(note)
            return
    except BaseException:
        pass
    try:
        print(note, file=sys.stderr)
    except BaseException:
        pass


def _mark_provider_preference_writer_unsettled(error):
    """Owned runner could not stop every writer; app census alone is insufficient."""
    error._macscope_preference_writer_unsettled = True
    _add_fixed_diagnostic(error, WRITER_UNSETTLED_NOTE)


def _require_test_domain(domain):
    """Reject the application domain and malformed or noncanonical suite names."""
    if not isinstance(domain, str) or not domain.startswith(TEST_DOMAIN_PREFIX):
        raise PreferenceRecoveryError("native preference writes require an isolated test domain")
    suffix = domain[len(TEST_DOMAIN_PREFIX):]
    try:
        valid = str(uuid.UUID(suffix)) == suffix
    except (ValueError, AttributeError):
        valid = False
    if not valid:
        raise PreferenceRecoveryError("native preference writes require an isolated test domain")
    return domain


class _NativePreferenceStore:
    """CFPreferences current-user/any-host exact Data key, without domain copies."""

    def __init__(self, *, _domain):
        _require_test_domain(_domain)
        if sys.platform != "darwin":
            raise PreferenceRecoveryError("native preference store requires macOS")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        pointer = ctypes.c_void_p
        signatures = {
            "CFStringCreateWithCString": (pointer, [pointer, ctypes.c_char_p, ctypes.c_uint32]),
            "CFRelease": (None, [pointer]),
            "CFPreferencesSynchronize": (ctypes.c_bool, [pointer, pointer, pointer]),
            "CFPreferencesCopyValue": (pointer, [pointer, pointer, pointer, pointer]),
            "CFPreferencesSetValue": (None, [pointer, pointer, pointer, pointer, pointer]),
            "CFGetTypeID": (ctypes.c_ulong, [pointer]),
            "CFDataGetTypeID": (ctypes.c_ulong, []),
            "CFDataGetLength": (ctypes.c_long, [pointer]),
            "CFDataGetBytePtr": (pointer, [pointer]),
            "CFDataCreate": (pointer, [pointer, pointer, ctypes.c_long]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(self.cf, name)
            function.restype, function.argtypes = result, arguments
        self.user = pointer.in_dll(self.cf, "kCFPreferencesCurrentUser").value
        self.host = pointer.in_dll(self.cf, "kCFPreferencesAnyHost").value
        self.domain = self.cf.CFStringCreateWithCString(None, _domain.encode(), 0x08000100)
        self.key = self.cf.CFStringCreateWithCString(None, KEY.encode(), 0x08000100)
        if not self.domain or not self.key:
            self.close()
            raise PreferenceRecoveryError("native preference key allocation failed")

    def close(self):
        for name in ("key", "domain"):
            value = getattr(self, name, None)
            if value:
                self.cf.CFRelease(value)
                setattr(self, name, None)

    def _synchronize(self):
        if not self.cf.CFPreferencesSynchronize(self.domain, self.user, self.host):
            raise PreferenceRecoveryError("native preference synchronization failed")

    def read(self):
        self._synchronize()
        value = self.cf.CFPreferencesCopyValue(self.key, self.domain, self.user, self.host)
        if not value:
            return None
        try:
            if self.cf.CFGetTypeID(value) != self.cf.CFDataGetTypeID():
                raise PreferenceRecoveryError("provider preference has unsupported existing type")
            size = self.cf.CFDataGetLength(value)
            if not 0 <= size <= MAX_DATA_BYTES:
                raise PreferenceRecoveryError("provider preference exceeds recovery size bound")
            return ctypes.string_at(self.cf.CFDataGetBytePtr(value), size)
        finally:
            self.cf.CFRelease(value)

    def write(self, value):
        _validate_value(value)
        data = None
        if value is not None:
            buffer = ctypes.create_string_buffer(value)
            data = self.cf.CFDataCreate(None, buffer, len(value))
            if not data:
                raise PreferenceRecoveryError("native preference data allocation failed")
        try:
            self.cf.CFPreferencesSetValue(self.key, data, self.domain, self.user, self.host)
            self._synchronize()
        finally:
            if data:
                self.cf.CFRelease(data)


def _validate_value(value):
    if value is not None and type(value) is not bytes:
        raise PreferenceRecoveryError("provider preference has unsupported existing type")
    if value is not None and len(value) > MAX_DATA_BYTES:
        raise PreferenceRecoveryError("provider preference exceeds recovery size bound")


def _canonical_path(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise PreferenceRecoveryError("recovery requires unaliased absolute paths")
    for ancestor in reversed((path, *path.parents)):
        if ancestor.is_symlink():
            raise PreferenceRecoveryError("recovery refuses symlinks or aliased parents")
    if path != path.resolve():
        raise PreferenceRecoveryError("recovery refuses noncanonical paths")
    return path


def _admit_apps(app_paths):
    if not isinstance(app_paths, (tuple, list)) or not 1 <= len(app_paths) <= 2:
        raise PreferenceRecoveryError("one or two admitted app paths are required")
    paths = tuple(_canonical_path(path) for path in app_paths)
    try:
        for app in paths:
            info = _canonical_path(app / "Contents/Info.plist")
            executable = _canonical_path(app / "Contents/MacOS/MacScope")
            if not app.is_dir() or not executable.is_file() or not info.is_file():
                raise PreferenceRecoveryError("unknown app identity")
            document = plistlib.loads(info.read_bytes())
            if document.get("CFBundleIdentifier") != DOMAIN or document.get("CFBundleExecutable") != "MacScope":
                raise PreferenceRecoveryError("unknown app identity")
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException):
        raise PreferenceRecoveryError("unknown app identity") from None
    return paths


def _private_stat(item, *, directory=False):
    expected = 0o700 if directory else 0o600
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(item.st_mode) or item.st_uid != os.geteuid()
            or stat.S_IMODE(item.st_mode) != expected or (not directory and item.st_nlink != 1)):
        raise PreferenceRecoveryError("recovery file identity or private ownership is invalid")


def _same_inode(first, second):
    return (first.st_dev, first.st_ino) == (second.st_dev, second.st_ino)


def _open_directory_without_aliases(path):
    """Walk each parent through owned descriptors; never follow a raced alias."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


class _LockedRecovery:
    def __init__(self, path):
        self.path = _canonical_path(path)
        self.directory_fd = self.lock_fd = None

    def __enter__(self):
        try:
            parent_fd = _open_directory_without_aliases(self.path.parent)
            try:
                try:
                    os.mkdir(self.path.name, mode=0o700, dir_fd=parent_fd)
                except FileExistsError:
                    pass
                self.directory_fd = os.open(self.path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                            dir_fd=parent_fd)
            finally:
                os.close(parent_fd)
            _private_stat(os.fstat(self.directory_fd), directory=True)
            self.lock_fd = os.open("owner.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                                   0o600, dir_fd=self.directory_fd)
            _private_stat(os.fstat(self.lock_fd))
            try:
                fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise PreferenceRecoveryError("provider preference recovery already has an owner") from None
            self.check()
            os.fsync(self.lock_fd)
            os.fsync(self.directory_fd)
            return self
        except OSError:
            self.__exit__(None, None, None)
            raise PreferenceRecoveryError("private recovery directory or lock admission failed") from None
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *unused):
        for name in ("lock_fd", "directory_fd"):
            fd = getattr(self, name)
            if fd is not None:
                os.close(fd)
                setattr(self, name, None)

    def check(self):
        _canonical_path(self.path)
        directory = os.stat(self.path, follow_symlinks=False)
        _private_stat(directory, directory=True)
        lock = os.stat("owner.lock", dir_fd=self.directory_fd, follow_symlinks=False)
        _private_stat(lock)
        if not _same_inode(directory, os.fstat(self.directory_fd)) or not _same_inode(lock, os.fstat(self.lock_fd)):
            raise PreferenceRecoveryError("recovery directory or ownership lock changed identity")

    def pending(self):
        try:
            os.stat("pending.json", dir_fd=self.directory_fd, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False

    def publish(self, name, document):
        self.check()
        payload = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=self.directory_fd)
        try:
            _private_stat(os.fstat(fd))
            with os.fdopen(fd, "wb", closefd=False) as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(self.directory_fd)
        return os.stat(name, dir_fd=self.directory_fd, follow_symlinks=False)

    def load(self):
        self.check()
        fd = os.open("pending.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.directory_fd)
        try:
            identity = os.fstat(fd)
            _private_stat(identity)
            if identity.st_size > MAX_JOURNAL_BYTES:
                raise PreferenceRecoveryError("recovery journal exceeds bound")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                payload = stream.read(MAX_JOURNAL_BYTES + 1)
            document = json.loads(payload)
            if not _same_inode(identity, os.stat("pending.json", dir_fd=self.directory_fd, follow_symlinks=False)):
                raise PreferenceRecoveryError("recovery journal changed identity")
            return document, identity
        except (ValueError, UnicodeError):
            raise PreferenceRecoveryError("recovery journal is invalid") from None
        finally:
            os.close(fd)


def _journal(paths, value, domain=DOMAIN):
    return {"version": 1, "domain": domain, "key": KEY, "uid": os.geteuid(),
            "owner_pid": os.getpid(), "transaction": str(uuid.uuid4()),
            "app_paths": [str(path) for path in paths],
            "baseline": {"present": value is not None,
                         "data": base64.b64encode(value).decode() if value is not None else None}}


def _baseline(document, paths, domain=DOMAIN):
    try:
        if (set(document) != {"version", "domain", "key", "uid", "owner_pid", "transaction", "app_paths", "baseline"}
                or type(document["version"]) is not int or document["version"] != 1
                or document["domain"] != domain or document["key"] != KEY
                or type(document["uid"]) is not int or document["uid"] != os.geteuid()
                or type(document["owner_pid"]) is not int or document["owner_pid"] <= 0
                or str(uuid.UUID(document["transaction"])) != document["transaction"]
                or document["app_paths"] != [str(path) for path in paths]):
            raise ValueError()
        baseline = document["baseline"]
        if set(baseline) != {"present", "data"} or type(baseline["present"]) is not bool:
            raise ValueError()
        if baseline["present"]:
            value = base64.b64decode(baseline["data"], validate=True)
        else:
            if baseline["data"] is not None:
                raise ValueError()
            value = None
        _validate_value(value)
        return value
    except (ValueError, TypeError, AttributeError, KeyError):
        raise PreferenceRecoveryError("recovery journal policy or baseline is invalid") from None


def _restore(locked, document, identity, paths, store, quiescent, domain=DOMAIN):
    value = _baseline(document, paths, domain)
    locked.check()
    current, current_identity = locked.load()
    if not _same_inode(identity, current_identity) or current != document:
        raise PreferenceRecoveryError("recovery baseline changed identity")
    quiescent(paths[0], paths[-1])
    _admit_apps(paths)
    locked.check()
    current, current_identity = locked.load()
    if not _same_inode(identity, current_identity) or current != document:
        raise PreferenceRecoveryError("recovery baseline changed before restoration")
    store.write(value)
    observed = store.read()
    _validate_value(observed)
    if observed != value:
        raise PreferenceRecoveryError("provider preference restoration readback differs")
    locked.check()
    if not _same_inode(identity, os.stat("pending.json", dir_fd=locked.directory_fd, follow_symlinks=False)):
        raise PreferenceRecoveryError("recovery baseline changed before retirement")
    os.unlink("pending.json", dir_fd=locked.directory_fd)
    try:
        os.fsync(locked.directory_fd)
    except OSError:
        # Preserve the baseline again when possible. Persistent filesystem
        # failure may also prevent republication; do not claim it was retained.
        try:
            locked.publish("pending.json", document)
        except Exception:
            pass
        raise _JournalCloseoutError(JOURNAL_CLOSEOUT_FAILURE_NOTE) from None
    metadata = {key: document[key] for key in ("version", "domain", "key", "uid", "transaction", "app_paths")}
    metadata["recovered_by_pid"] = os.getpid()
    return metadata


@contextmanager
def provider_preference_recovery(app_paths, *, _store=None, _recovery_directory=None, _require_quiescent=None, _domain=None):
    """Yield after durable snapshot; callback must settle all its preference writers.

    An owned runner that cannot prove settlement marks its original exception
    with _mark_provider_preference_writer_unsettled, retaining the baseline.
    """
    domain = _require_test_domain(_domain) if _store is None else (_domain or DOMAIN)
    paths = _admit_apps(app_paths)
    store = _store
    quiescent = _require_quiescent or require_app_quiescent
    try:
        with _LockedRecovery(_recovery_directory or RECOVERY_DIRECTORY) as locked:
            try:
                if locked.pending():
                    raise PreferenceRecoveryError("unresolved provider preference journal; explicit recovery required")
                quiescent(paths[0], paths[-1])
                if store is None:
                    store = _NativePreferenceStore(_domain=domain)
                value = store.read()
                _validate_value(value)
                document = _journal(paths, value, domain)
                identity = locked.publish("pending.json", document)
            except PreferenceRecoveryError:
                raise
            except Exception:
                raise PreferenceRecoveryError("provider preference recovery admission failed") from None
            try:
                yield
            except BaseException as original:
                if getattr(original, "_macscope_preference_writer_unsettled", False) is True:
                    raise
                try:
                    _restore(locked, document, identity, paths, store, quiescent, domain)
                except _JournalCloseoutError:
                    _add_fixed_diagnostic(original, JOURNAL_CLOSEOUT_FAILURE_NOTE)
                except BaseException:
                    _add_fixed_diagnostic(original, RESTORATION_FAILURE_NOTE)
                raise
            else:
                try:
                    _restore(locked, document, identity, paths, store, quiescent, domain)
                except _JournalCloseoutError:
                    raise
                except Exception:
                    raise PreferenceRecoveryError("provider preference restoration failed; private journal retained for explicit recovery") from None
    finally:
        if _store is None and store is not None:
            store.close()


def run_with_provider_preference_recovery(app_paths, callback, **private_boundary):
    """Preserve callback outcome; restoration failure never returns success."""
    with provider_preference_recovery(app_paths, **private_boundary):
        return callback()


def run_with_isolated_provider_preference_recovery(app_paths, callback):
    """Keep host recovery away from both the app and per-test UI suites.

    Each UI test owns its separate UUID suite. This host fence does not claim to
    recover those suites. A killed process leaves only inert isolated data and a
    domain-bound journal; it cannot contaminate later tests or the application.
    """
    domain = TEST_DOMAIN_PREFIX + str(uuid.uuid4())
    # Retain the shared admission lock and pending-journal hold across runs.
    with provider_preference_recovery(app_paths, _domain=domain):
        return callback()


def recover_provider_preference(app_paths, *, _store=None, _recovery_directory=None, _require_quiescent=None, _domain=None):
    """Explicit replay after caller proves previous owned writers have stopped.

    Rechecks app quiescence and private identity. Never signals a stale owner or
    supplies proof that an interrupted caller's runner has stopped on its behalf.
    """
    paths = _admit_apps(app_paths)
    store = _store
    try:
        with _LockedRecovery(_recovery_directory or RECOVERY_DIRECTORY) as locked:
            document, identity = locked.load()
            # Native replay requires an explicit caller domain, matching the journal.
            # Never infer native write authority from an old journal.
            domain = _require_test_domain(_domain) if store is None else (_domain or DOMAIN)
            _baseline(document, paths, domain)
            if store is None:
                store = _NativePreferenceStore(_domain=domain)
            return _restore(locked, document, identity, paths, store, _require_quiescent or require_app_quiescent, domain)
    except _JournalCloseoutError:
        raise
    except Exception:
        raise PreferenceRecoveryError("explicit provider preference recovery failed; inspect private journal before retrying") from None
    finally:
        if _store is None and store is not None:
            store.close()
