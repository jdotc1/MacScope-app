#!/usr/bin/env python3
"""Developer-loop consumer of the shared verified dependency cache."""

from __future__ import annotations

import argparse
import contextlib
import concurrent.futures
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.dont_write_bytecode = True

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
TOOL = REPOSITORY_ROOT / "Scripts/qualification/dev_dependency_cache.py"
QUALIFIER = REPOSITORY_ROOT / "Scripts/qualify_local_private_build.sh"
CI_WORKFLOW = REPOSITORY_ROOT / ".github/workflows/ci.yml"
BOOTSTRAP = REPOSITORY_ROOT / "Scripts/bootstrap.sh"
PROJECT = REPOSITORY_ROOT / "MacScope/project.yml"


def load_tool():
    spec = importlib.util.spec_from_file_location("macscope_dev_dependency_cache_under_test", TOOL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DEV = load_tool()
BUILD_PAYLOAD = DEV.build_payload
QUALIFIER_PLACEHOLDERS = {
    "${MACSCOPE_GHOSTTY_SIMD:-false}": "@SIMD@",
    "${CACHE_PLATFORM_IDENTITY}": "@PLATFORM@",
    "${MACSCOPE_NATIVE_SOURCE_JOBS:-8}": "@JOBS@",
    "${CACHE_SLEIGH_TOOL_IDENTITY}": "@NATIVE_TOOLS@",
    "${CACHE_XCODE_VERSION_PLIST}": "@XCODE_VERSION_PLIST@",
    "${CACHE_SDK_SETTINGS}": "@SDK_SETTINGS@",
    "${CACHE_CLANG}": "@CLANG@",
    "${CACHE_CMAKE}": "@CMAKE@",
    "${CACHE_NINJA}": "@NINJA@",
}


def qualifier_block(script: str, start_marker: str) -> str:
    start = script.index(start_marker)
    end = script.index(')"\n', start)
    return script[start:end]


def placeholder(value: str) -> str:
    for raw, replacement in QUALIFIER_PLACEHOLDERS.items():
        value = value.replace(raw, replacement)
    return value


class QualifierParityTests(unittest.TestCase):
    """The developer key must stay byte-identical to the qualifier's key."""

    def test_component_prefixes_and_values_mirror_the_qualifier(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        markers = {
            "ghostty-vt": 'GHOSTTY_VT_CACHE_KEY="$("${DEPENDENCY_CACHE_TOOL[@]}" key',
            "ghostty-surface": 'GHOSTTY_SURFACE_CACHE_KEY="$("${DEPENDENCY_CACHE_TOOL[@]}" key',
            "sleigh-native-source": 'SLEIGH_CACHE_KEY="$("${DEPENDENCY_CACHE_TOOL[@]}" key',
        }
        self.assertEqual(set(markers), set(DEV.QUALIFIER_COMPONENTS))
        # Developer-loop-only components are never keyed by the qualifier.
        self.assertEqual(set(DEV.COMPONENTS) - set(DEV.QUALIFIER_COMPONENTS), {"native-bridge"})
        self.assertNotIn("--component native-bridge", script)
        for component, marker in markers.items():
            with self.subTest(component=component):
                block = qualifier_block(script, marker)
                self.assertIn(f"--component {component} ", block)
                prefixes = tuple(re.findall(r"--prefix (\S+)", block))
                values = tuple(
                    tuple(placeholder(value).split("=", 1))
                    for value in re.findall(r'--value "([^"]+)"', block)
                )
                self.assertEqual(prefixes, DEV.COMPONENTS[component]["prefixes"])
                self.assertEqual(values, DEV.COMPONENTS[component]["values"])

    def test_platform_and_native_tool_identities_mirror_the_qualifier(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        for marker, expected in (
            ('CACHE_PLATFORM_IDENTITY="$("${DEPENDENCY_CACHE_TOOL[@]}" external-identity', DEV.PLATFORM_FILES),
            ('CACHE_SLEIGH_TOOL_IDENTITY="$("${DEPENDENCY_CACHE_TOOL[@]}" external-identity', DEV.NATIVE_TOOL_FILES),
        ):
            with self.subTest(marker=marker):
                block = qualifier_block(script, marker)
                observed = tuple(
                    tuple(placeholder(value).split("=", 1))
                    for value in re.findall(r'--external-file "([^"]+)"', block)
                )
                self.assertEqual(observed, expected)
        self.assertIn('CACHE_CLANG="${CACHE_DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"', script)
        self.assertIn(
            'CACHE_SDK_SETTINGS="${CACHE_DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist"',
            script,
        )
        self.assertIn('CACHE_XCODE_VERSION_PLIST="${CACHE_XCODE_CONTENTS_ROOT}/version.plist"', script)

    def test_default_cache_root_is_the_ci_qualification_cache(self) -> None:
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        # Read the shell block actually appended to GITHUB_ENV, not YAML env.
        exports = re.findall(r'(?ms)^\s*\{\s*\n(.*?)^\s*\} >> "\$GITHUB_ENV"\s*$', workflow)
        cache_exports = re.findall(
            r'^\s*echo "MACSCOPE_DEPENDENCY_CACHE_ROOT=([^"\n]+)"\s*$',
            "\n".join(exports), re.MULTILINE,
        )
        self.assertEqual(len(cache_exports), 1)
        ci_root = cache_exports[0]
        self.assertEqual(ci_root, "$MACSCOPE_WORK_ROOT/" + DEV.DEFAULT_CACHE_ROOT.name)
        self.assertEqual(DEV.DEFAULT_CACHE_ROOT.parent, DEV.macscope_work_root())
        self.assertTrue(any(part.endswith(".noindex") for part in DEV.DEFAULT_VIEW_ROOT.parts))

    def test_consumers_keep_the_qualifier_paths_first_and_fall_back_only_on_status_3(self) -> None:
        bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
        sleigh = bootstrap.index("dev_dependency_resolve sleigh-native-source")
        legacy = bootstrap.index("build_vendored_sleigh_native_source.sh")
        self.assertLess(sleigh, legacy)
        surface = bootstrap.index("dev_dependency_resolve ghostty-surface")
        admission = bootstrap.index("verified_ghostty_surface_admission.py")
        self.assertLess(surface, admission)
        self.assertIn('elif [[ "${DEV_DEPENDENCY_STATUS}" != 3 ]]; then', bootstrap)
        project = PROJECT.read_text(encoding="utf-8")
        start = project.index("- name: Build repository-owned Ghostty VT")
        phase = project[start:project.index("dependencies:", start)]
        self.assertIn('"$(SRCROOT)/../Scripts/qualification/dev_dependency_cache.py"', phase)
        phase = phase[phase.index("script: |"):]
        # Qualification-supplied verified VT always wins; the shared cache is a
        # routine-Debug path only (PHASE_STAMP is set only for Debug runtime-only).
        self.assertLess(phase.index("MACSCOPE_GHOSTTY_VT_VERIFIED_ARTIFACT_ROOT"), phase.index("dev_dependency_cache.py"))
        self.assertIn('[ -n "$PHASE_STAMP" ]', phase)
        self.assertIn('elif [ "$VT_STATUS" != 3 ]; then', phase)
        self.assertIn('"$SRCROOT/../Scripts/build_ghostty_vt.sh"', phase)


class GitRepository:
    def __init__(self, root: Path) -> None:
        self.root = root
        root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@invalid")
        self.git("config", "user.name", "Test")

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["/usr/bin/git", "-C", str(self.root), *arguments],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ).stdout

    def write(self, relative: str, payload: bytes, executable: bool = False) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        path.chmod(0o755 if executable else 0o644)

    def commit(self) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "fixture")


def blob_oid(payload: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(payload)).encode() + b"\0" + payload).hexdigest()


class DevDependencyCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.repository = GitRepository(self.root / "repository")
        self.cache_root = self.root / "cache"
        self.cache_root.mkdir(mode=0o700)
        self.view_root = self.root / "views.noindex"
        self.lfs_payload = b"real toolchain bytes\n"
        lfs_digest = hashlib.sha256(self.lfs_payload).hexdigest()
        self.files = {
            "ThirdParty/Dep/input.txt": b"dependency-v1\n",
            "ThirdParty/Dep/tool": (
                b"version https://git-lfs.github.com/spec/v1\noid sha256:"
                + lfs_digest.encode()
                + b"\nsize "
                + str(len(self.lfs_payload)).encode()
                + b"\n"
            ),
            "Scripts/build_dep.sh": b"#!/bin/sh\n",
            "App/main.swift": b"print(1)\n",
        }
        for relative, payload in self.files.items():
            self.repository.write(relative, payload, executable=relative.endswith(".sh"))
        self.repository.commit()
        self.spec = {
            "prefixes": ("ThirdParty/Dep", "Scripts/build_dep.sh"),
            "values": (("architecture", "arm64"), ("platform-toolchain", "@PLATFORM@")),
            "view_name": "DepView",
        }
        patches = [
            mock.patch.dict(DEV.COMPONENTS, {"fixture-dep": self.spec}),
            mock.patch.object(DEV, "platform_identity", lambda view_root: "f" * 64),
            mock.patch.object(DEV, "verify_view", self._verify_view),
            mock.patch.object(DEV, "descriptors", lambda *arguments: {}),
            mock.patch.object(DEV, "build_payload", self._build_payload),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.verifications = 0
        self.builds = 0
        self.view_root.mkdir(mode=0o700)

    def tearDown(self) -> None:
        for path in [self.root, *self.root.rglob("*")]:
            if not path.is_symlink():
                try:
                    path.chmod(0o700 if path.is_dir() else 0o600)
                except OSError:
                    pass
        self.temporary.cleanup()

    def _verify_view(self, component: str, repository: Path, view: Path) -> None:
        self.verifications += 1
        if (view / "artifact.bin").read_bytes() != b"artifact-v1\n":
            raise DEV.DevCacheError("domain verifier rejected the view")

    def _build_payload(self, component: str, repository: Path, temporary: Path) -> Path:
        self.builds += 1
        payload = temporary / "payload"
        payload.mkdir()
        (payload / "artifact.bin").write_bytes(b"artifact-v1\n")
        return payload

    def _expected_key(self) -> str:
        records = []
        for relative, payload in sorted(self.files.items(), key=lambda item: os.fsencode(item[0])):
            sha256, size = hashlib.sha256(payload).hexdigest(), len(payload)
            if relative == "ThirdParty/Dep/tool":
                sha256, size = hashlib.sha256(self.lfs_payload).hexdigest(), len(self.lfs_payload)
            records.append(
                {
                    "blob_oid": blob_oid(payload),
                    "mode": "100755" if relative.endswith(".sh") else "100644",
                    "path": relative,
                    "sha256": sha256,
                    "size": size,
                }
            )
        manifest = self.root / "SOURCE_FILES.json"
        manifest.write_bytes(DEV.canonical_json({"files": records, "schema_version": 2}))
        result = subprocess.run(
            ["/usr/bin/python3", "-B", str(REPOSITORY_ROOT / "Scripts/qualification/dependency_cache.py"),
             "key", "--source-files", str(manifest), "--component", "fixture-dep",
             "--prefix", "ThirdParty/Dep", "--prefix", "Scripts/build_dep.sh",
             "--value", "architecture=arm64", "--value", "platform-toolchain=" + "f" * 64],
            check=True, stdout=subprocess.PIPE, text=True,
        )
        return result.stdout.strip()

    def _resolve(self, build: bool = True) -> dict:
        with contextlib.redirect_stderr(io.StringIO()):
            return DEV.resolve("fixture-dep", self.repository.root, self.cache_root, self.view_root, build)

    def _lock_fixture(self, owner: dict[str, str] | None, *, old: bool = False):
        key = "d" * 64
        lock = self.cache_root / "locks/v1/fixture-dep" / f"{key}.lock"
        lock.mkdir(parents=True)
        if owner is not None:
            (lock / "owner").write_text("".join(f"{name}={value}\n" for name, value in owner.items()))
        if old:
            timestamp = DEV.time.time() - DEV.LOCK_OWNER_GRACE_SECONDS - 10
            os.utime(lock, (timestamp, timestamp))
        self.assertTrue(lock.is_dir())
        return key, lock

    def _live_owner(self):
        start = DEV.process_start_identity(os.getpid())
        self.assertIsNotNone(start)
        self.assertIsNone(os.kill(os.getpid(), 0))
        return {"pid": str(os.getpid()), "hostname": DEV.socket.gethostname(),
                "start": start, "token": "former-owner"}

    def _dead_owner(self):
        # A reaped child supplies an actually dead pid, not a guessed pid limit.
        child = subprocess.Popen(["/bin/sh", "-c", "exit 0"])
        self.assertEqual(child.wait(), 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(child.pid, 0)
        return {"pid": str(child.pid), "hostname": DEV.socket.gethostname(),
                "start": "known-former-start", "token": "former-owner"}

    def _ensure_fixture(self, key):
        return DEV.ensure_entry("fixture-dep", key, self.repository.root, self.cache_root, True)

    def _assert_lock_waits(self, key, lock):
        before = (lock / "owner").read_bytes() if (lock / "owner").exists() else None
        self.assertTrue(lock.is_dir())
        with mock.patch.object(DEV, "LOCK_TIMEOUT_SECONDS", 0), \
                mock.patch.object(DEV, "time", wraps=DEV.time) as clock, \
                self.assertRaisesRegex(DEV.DevCacheError, "timed out waiting"):
            self._ensure_fixture(key)
        clock.sleep.assert_not_called()
        self.assertEqual(self.builds, 0)
        self.assertTrue(lock.is_dir())
        self.assertEqual((lock / "owner").read_bytes() if (lock / "owner").exists() else None, before)

    def test_dead_pid_lock_is_reclaimed_and_built_once(self):
        owner = self._dead_owner()
        key, lock = self._lock_fixture(owner)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            entry, status = self._ensure_fixture(key)
        self.assertEqual(status, "published-miss")
        self.assertEqual(self.builds, 1)
        self.assertTrue(entry.is_dir())
        self.assertEqual(list(lock.parent.iterdir()), [])
        self.assertEqual(stderr.getvalue().count(f"dead pid {owner['pid']}"), 1)
        self.assertIn(str(lock), stderr.getvalue())

    def test_live_pid_lock_times_out_without_reclaim(self):
        key, lock = self._lock_fixture(self._live_owner(), old=True)
        self._assert_lock_waits(key, lock)

    def test_permission_denied_pid_waits_without_reclaim(self):
        owner = self._live_owner()
        key, lock = self._lock_fixture(owner, old=True)
        with mock.patch.object(DEV.os, "kill", side_effect=PermissionError("EPERM")):
            with self.assertRaises(PermissionError):
                DEV.os.kill(int(owner["pid"]), 0)
            self._assert_lock_waits(key, lock)

    def test_reused_live_pid_waits_even_when_start_identity_differs(self):
        owner = self._live_owner()
        self.assertNotEqual(owner["start"], "previous-incarnation")
        owner["start"] = "previous-incarnation"
        key, lock = self._lock_fixture(owner, old=True)
        self.assertNotEqual(DEV.process_start_identity(int(owner["pid"])), owner["start"])
        self._assert_lock_waits(key, lock)

    def test_ownerless_young_lock_waits(self):
        key, lock = self._lock_fixture(None)
        self.assertFalse((lock / "owner").exists())
        self.assertLess(DEV.time.time() - lock.stat().st_mtime, DEV.LOCK_OWNER_GRACE_SECONDS)
        self._assert_lock_waits(key, lock)

    def test_ownerless_old_lock_is_reclaimed(self):
        key, lock = self._lock_fixture(None, old=True)
        self.assertFalse((lock / "owner").exists())
        self.assertGreater(DEV.time.time() - lock.stat().st_mtime, DEV.LOCK_OWNER_GRACE_SECONDS)
        _, status = self._ensure_fixture(key)
        self.assertEqual((status, self.builds), ("published-miss", 1))
        self.assertEqual(list(lock.parent.iterdir()), [])

    def test_partial_young_owner_waits_and_old_local_partial_reclaims(self):
        owner = {"hostname": DEV.socket.gethostname()}
        key, lock = self._lock_fixture(owner)
        self.assertNotIn("pid", DEV.read_lock_owner(lock))
        self._assert_lock_waits(key, lock)
        timestamp = DEV.time.time() - DEV.LOCK_OWNER_GRACE_SECONDS - 10
        os.utime(lock, (timestamp, timestamp))
        self.assertGreater(DEV.time.time() - lock.stat().st_mtime, DEV.LOCK_OWNER_GRACE_SECONDS)
        _, status = self._ensure_fixture(key)
        self.assertEqual((status, self.builds), ("published-miss", 1))
        self.assertFalse(lock.exists())

    def test_foreign_dead_pid_lock_never_reclaims_even_when_old(self):
        owner = self._dead_owner()
        owner["hostname"] = DEV.socket.gethostname() + ".foreign"
        self.assertNotEqual(owner["hostname"], DEV.socket.gethostname())
        key, lock = self._lock_fixture(owner, old=True)
        self._assert_lock_waits(key, lock)

    def test_foreign_partial_owner_never_reclaims_even_when_old(self):
        hostname = DEV.socket.gethostname() + ".foreign"
        self.assertNotEqual(hostname, DEV.socket.gethostname())
        key, lock = self._lock_fixture({"hostname": hostname}, old=True)
        self.assertNotIn("pid", DEV.read_lock_owner(lock))
        self._assert_lock_waits(key, lock)

    def test_legacy_dead_pid_without_host_or_start_is_reclaimed(self):
        owner = self._dead_owner()
        key, lock = self._lock_fixture({"pid": owner["pid"], "component": "fixture-dep", "key": "d" * 64})
        self.assertNotIn("hostname", DEV.read_lock_owner(lock))
        self.assertNotIn("start", DEV.read_lock_owner(lock))
        self.assertEqual(DEV.admit_owner_directory(self.cache_root, "test cache", create=False), self.cache_root)
        _, status = self._ensure_fixture(key)
        self.assertEqual((status, self.builds), ("published-miss", 1))
        self.assertEqual(list(lock.parent.iterdir()), [])

    def test_legacy_live_pid_without_host_or_start_waits(self):
        owner = self._live_owner()
        key, lock = self._lock_fixture({"pid": owner["pid"], "component": "fixture-dep", "key": "d" * 64}, old=True)
        self.assertNotIn("hostname", DEV.read_lock_owner(lock))
        self.assertNotIn("start", DEV.read_lock_owner(lock))
        self._assert_lock_waits(key, lock)

    def test_legacy_permission_denied_pid_waits(self):
        owner = self._live_owner()
        key, lock = self._lock_fixture({"pid": owner["pid"], "component": "fixture-dep", "key": "d" * 64}, old=True)
        with mock.patch.object(DEV.os, "kill", side_effect=PermissionError("EPERM")):
            with self.assertRaises(PermissionError):
                DEV.os.kill(int(owner["pid"]), 0)
            self._assert_lock_waits(key, lock)

    def test_missing_current_identity_fails_closed_without_build(self):
        key, lock = self._lock_fixture(self._live_owner(), old=True)
        before = (lock / "owner").read_bytes()
        with mock.patch.object(DEV, "process_start_identity", return_value=None) as identity, \
                mock.patch.object(DEV, "time", wraps=DEV.time) as clock, \
                self.assertRaisesRegex(DEV.DevCacheError, r"/bin/ps failed.*current process"):
            self._ensure_fixture(key)
        identity.assert_called_once_with(os.getpid())
        clock.sleep.assert_not_called()
        self.assertEqual(self.builds, 0)
        self.assertEqual((lock / "owner").read_bytes(), before)

    def test_current_process_ps_failure_without_lock_fails_immediately(self):
        key = "d" * 64
        lock = self.cache_root / "locks/v1/fixture-dep" / f"{key}.lock"
        self.assertFalse(lock.exists())
        failures = [OSError("ps unavailable"), subprocess.TimeoutExpired("ps", 5),
                    subprocess.CompletedProcess([], 1, "", "ps denied")]
        for failure in failures:
            with self.subTest(failure=failure), \
                    mock.patch.object(DEV.subprocess, "run") as run, \
                    mock.patch.object(DEV, "time", wraps=DEV.time) as clock:
                if isinstance(failure, Exception):
                    run.side_effect = failure
                else:
                    run.return_value = failure
                with self.assertRaisesRegex(DEV.DevCacheError, r"/bin/ps failed.*current process"):
                    self._ensure_fixture(key)
                run.assert_called_once()
                self.assertEqual(run.call_args.args[0], ["/bin/ps", "-p", str(os.getpid()), "-o", "lstart="])
                clock.sleep.assert_not_called()
                self.assertFalse(lock.exists())
                self.assertEqual(self.builds, 0)

    def test_reclaim_race_preserves_contender_and_returns_to_wait(self):
        for published in (False, True):
            with self.subTest(published=published):
                key, lock = self._lock_fixture(self._dead_owner())
                entry = self.cache_root / "artifacts/v1/fixture-dep" / key
                self.assertFalse(entry.exists())
                contender_owner = f"pid={os.getpid()}\ncomponent=fixture-dep\nkey={key}\n"
                original_rename = Path.rename
                contender_identity = []
                def rename_then_contender(path, target):
                    result = original_rename(path, target)
                    if path == lock:
                        lock.mkdir()
                        (lock / "owner").write_text(contender_owner)
                        (lock / "contender-payload").write_bytes(b"untouched")
                        metadata = lock.stat()
                        contender_identity.append((metadata.st_dev, metadata.st_ino))
                    return result
                def wait_once(seconds):
                    self.assertEqual(seconds, 1)
                    if published:
                        entry.mkdir(parents=True)
                with mock.patch.object(Path, "rename", rename_then_contender), \
                        mock.patch.object(DEV, "LOCK_TIMEOUT_SECONDS", 1), \
                        mock.patch.object(DEV, "time", wraps=DEV.time) as clock:
                    clock.sleep.side_effect = wait_once
                    if published:
                        self.assertEqual(self._ensure_fixture(key), (entry, "verified-after-wait"))
                    else:
                        with self.assertRaisesRegex(DEV.DevCacheError, "timed out waiting"):
                            self._ensure_fixture(key)
                clock.sleep.assert_called_once_with(1)
                self.assertEqual(len(contender_identity), 1)
                metadata = lock.stat()
                self.assertEqual((metadata.st_dev, metadata.st_ino), contender_identity[0])
                self.assertEqual((lock / "owner").read_text(), contender_owner)
                self.assertEqual((lock / "contender-payload").read_bytes(), b"untouched")
                self.assertEqual(self.builds, 0)
                self.assertEqual(list(lock.parent.glob("*.retired-*")), [])
                # Remove only this test's contender between the two subcases.
                shutil.rmtree(lock)

    def test_two_waiters_on_dead_lock_build_once(self):
        key, lock = self._lock_fixture(self._dead_owner())
        barrier = threading.Barrier(2)
        local = threading.local()
        original_identity = DEV.process_start_identity
        def identity_after_both_initial_misses(pid):
            if not getattr(local, "entered", False):
                local.entered = True
                # ensure_entry has already checked the entry is absent. Both
                # callers must reach this point before either can take the lock.
                barrier.wait(timeout=10)
            return original_identity(pid)
        with mock.patch.object(DEV, "process_start_identity", side_effect=identity_after_both_initial_misses), \
                concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(self._ensure_fixture, key) for _ in range(2)]
            results = [future.result(timeout=20) for future in futures]
        self.assertEqual(self.builds, 1)
        self.assertEqual(len({str(entry) for entry, _ in results}), 1)
        self.assertEqual(sum(status == "published-miss" for _, status in results), 1)
        self.assertTrue(all(status in {"published-miss", "verified-after-wait"}
                            for _, status in results))
        self.assertEqual(list(lock.parent.iterdir()), [])

    def test_resumed_former_owner_cannot_remove_replacement_lock(self):
        owner = self._live_owner()
        key, lock = self._lock_fixture(owner)
        identity = (lock.stat().st_dev, lock.stat().st_ino)
        guard = self.cache_root / "lock-guards/v1/fixture-dep" / f"{key}.guard"
        retired = lock.with_name("retired-for-test")
        with DEV.entry_lock_guard(guard) as acquired:
            self.assertTrue(acquired)
            lock.rename(retired)
            lock.mkdir()
            replacement = dict(owner, token="new-owner")
            (lock / "owner").write_text("".join(f"{name}={value}\n" for name, value in replacement.items()))
        self.assertNotEqual((lock.stat().st_dev, lock.stat().st_ino), identity)
        before = (lock / "owner").read_bytes()
        DEV.release_entry_lock(lock, guard, owner["token"], identity)
        self.assertTrue(lock.is_dir())
        self.assertEqual((lock / "owner").read_bytes(), before)
        self.assertEqual(self.builds, 0)

    def test_old_token_cannot_remove_same_inode_replacement(self):
        owner = self._live_owner()
        key, lock = self._lock_fixture(owner)
        identity = (lock.stat().st_dev, lock.stat().st_ino)
        guard = self.cache_root / "lock-guards/v1/fixture-dep" / f"{key}.guard"
        (lock / "owner").write_text("token=new-owner\n")
        self.assertEqual((lock.stat().st_dev, lock.stat().st_ino), identity)
        self.assertNotEqual(DEV.read_lock_owner(lock)["token"], owner["token"])
        DEV.release_entry_lock(lock, guard, owner["token"], identity)
        self.assertTrue(lock.is_dir())
        self.assertEqual((lock / "owner").read_text(), "token=new-owner\n")

    def test_entry_published_while_waiting_preserves_verified_after_wait(self):
        key, lock = self._lock_fixture(self._live_owner())
        entry = self.cache_root / "artifacts/v1/fixture-dep" / key
        self.assertFalse(entry.exists())
        before = (lock / "owner").read_bytes()
        def publish_during_wait(seconds):
            self.assertEqual(seconds, 1)
            entry.mkdir(parents=True)
        with mock.patch.object(DEV, "time", wraps=DEV.time) as clock:
            clock.sleep.side_effect = publish_during_wait
            actual, status = self._ensure_fixture(key)
        self.assertEqual((actual, status), (entry, "verified-after-wait"))
        clock.sleep.assert_called_once_with(1)
        self.assertEqual(self.builds, 0)
        self.assertTrue(lock.is_dir())
        self.assertEqual((lock / "owner").read_bytes(), before)

    def test_guard_held_by_paused_creator_fences_old_ownerless_lock(self):
        key, lock = self._lock_fixture(None, old=True)
        guard = self.cache_root / "lock-guards/v1/fixture-dep" / f"{key}.guard"
        self.assertFalse((lock / "owner").exists())
        self.assertGreater(DEV.time.time() - lock.stat().st_mtime, DEV.LOCK_OWNER_GRACE_SECONDS)
        with DEV.entry_lock_guard(guard) as acquired:
            self.assertTrue(acquired)
            self._assert_lock_waits(key, lock)
        self.assertTrue(lock.is_dir())

    def test_malformed_or_special_owner_records_fail_closed(self):
        key, lock = self._lock_fixture(None, old=True)
        cases = ["pid=0\n", "pid=-1\n", "pid=garbage\n", "pid=1\npid=2\n",
                 "unfinished", "x" * 4097]
        for text in cases:
            with self.subTest(text=text[:40]):
                (lock / "owner").write_text(text)
                timestamp = DEV.time.time() - DEV.LOCK_OWNER_GRACE_SECONDS - 10
                os.utime(lock, (timestamp, timestamp))
                self.assertEqual((lock / "owner").read_text(), text)
                self._assert_lock_waits(key, lock)
        (lock / "owner").unlink()
        os.mkfifo(lock / "owner")
        self.assertTrue(DEV.stat.S_ISFIFO((lock / "owner").lstat().st_mode))
        self.assertIsNone(DEV.read_lock_owner(lock))
        with mock.patch.object(DEV, "LOCK_TIMEOUT_SECONDS", 0), \
                self.assertRaisesRegex(DEV.DevCacheError, "timed out waiting"):
            self._ensure_fixture(key)
        self.assertTrue(DEV.stat.S_ISFIFO((lock / "owner").lstat().st_mode))
        self.assertEqual(self.builds, 0)

    def test_symlink_owner_and_symlink_lock_fail_closed(self):
        key, lock = self._lock_fixture(None, old=True)
        target = self.root / "owner-target"
        target.write_text("hostname=foreign-host\n")
        (lock / "owner").symlink_to(target)
        self.assertTrue((lock / "owner").is_symlink())
        self._assert_lock_waits(key, lock)
        (lock / "owner").unlink()
        lock.rmdir()
        target_dir = self.root / "foreign-lock"
        target_dir.mkdir()
        lock.symlink_to(target_dir, target_is_directory=True)
        self.assertTrue(lock.is_symlink())
        self._assert_lock_waits(key, lock)
        self.assertTrue(lock.is_symlink())
        self.assertEqual(target.read_text(), "hostname=foreign-host\n")

    def test_owner_record_contains_host_start_pid_and_token(self):
        key = "e" * 64
        lock = self.cache_root / "locks/v1/fixture-dep" / f"{key}.lock"
        observed = {}
        def build(component, repository, temporary):
            observed.update(DEV.read_lock_owner(lock))
            return self._build_payload(component, repository, temporary)
        with mock.patch.object(DEV, "build_payload", side_effect=build):
            _, status = self._ensure_fixture(key)
        self.assertEqual(status, "published-miss")
        self.assertEqual(observed["pid"], str(os.getpid()))
        self.assertEqual(observed["hostname"], DEV.socket.gethostname())
        self.assertEqual(observed["start"], DEV.process_start_identity(os.getpid()))
        self.assertRegex(observed["token"], r"^[a-f0-9]{32}$")
        self.assertEqual((observed["component"], observed["key"]), ("fixture-dep", key))
        self.assertEqual(list(lock.parent.iterdir()), [])

    def test_release_guard_timeout_preserves_lock_instead_of_unguarded_delete(self):
        owner = self._live_owner()
        key, lock = self._lock_fixture(owner)
        identity = (lock.stat().st_dev, lock.stat().st_ino)
        guard = self.cache_root / "lock-guards/v1/fixture-dep" / f"{key}.guard"
        before = (lock / "owner").read_bytes()
        with DEV.entry_lock_guard(guard) as acquired, \
                mock.patch.object(DEV, "LOCK_TIMEOUT_SECONDS", 0):
            self.assertTrue(acquired)
            DEV.release_entry_lock(lock, guard, owner["token"], identity)
        self.assertTrue(lock.is_dir())
        self.assertEqual((lock / "owner").read_bytes(), before)

    def test_guard_failure_does_not_fall_back_to_unguarded_reclaim(self):
        key, lock = self._lock_fixture(self._dead_owner())
        before = (lock / "owner").read_bytes()
        with mock.patch.object(DEV.fcntl, "flock", side_effect=OSError("unsupported")), \
                self.assertRaisesRegex(OSError, "unsupported"):
            self._ensure_fixture(key)
        self.assertTrue(lock.is_dir())
        self.assertEqual((lock / "owner").read_bytes(), before)
        self.assertEqual(self.builds, 0)

    def test_special_or_symlink_guard_fails_closed(self):
        key, lock = self._lock_fixture(self._dead_owner())
        guard = self.cache_root / "lock-guards/v1/fixture-dep" / f"{key}.guard"
        guard.parent.mkdir(parents=True)
        os.mkfifo(guard)
        self.assertTrue(DEV.stat.S_ISFIFO(guard.lstat().st_mode))
        with self.assertRaises((DEV.DevCacheError, OSError)):
            self._ensure_fixture(key)
        self.assertTrue(lock.is_dir())
        guard.unlink()
        target = self.root / "guard-target"
        target.write_text("unchanged")
        guard.symlink_to(target)
        self.assertTrue(guard.is_symlink())
        with self.assertRaises(OSError):
            self._ensure_fixture(key)
        self.assertTrue(lock.is_dir())
        self.assertEqual(target.read_text(), "unchanged")
        self.assertEqual(self.builds, 0)

    def test_process_start_identity_uses_fixed_locale_timezone_and_fails_closed(self):
        result = subprocess.CompletedProcess([], 0, "Mon Oct 26 00:00:00 2026\n", "")
        with mock.patch.object(DEV.subprocess, "run", return_value=result) as run:
            self.assertEqual(DEV.process_start_identity(123), "Mon Oct 26 00:00:00 2026")
        self.assertEqual(run.call_args.args[0], ["/bin/ps", "-p", "123", "-o", "lstart="])
        self.assertEqual(run.call_args.kwargs["env"]["LC_ALL"], "C")
        self.assertEqual(run.call_args.kwargs["env"]["TZ"], "UTC")
        self.assertEqual(run.call_args.kwargs["timeout"], 5)
        for failure in [OSError("unavailable"), subprocess.TimeoutExpired("ps", 5)]:
            with self.subTest(failure=failure), \
                    mock.patch.object(DEV.subprocess, "run", side_effect=failure):
                self.assertIsNone(DEV.process_start_identity(123))
        for output in ["", "unknown\n", "Mon Oct 26 00:00:00 2026\nsecond\n"]:
            with self.subTest(output=output), mock.patch.object(
                    DEV.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")):
                self.assertIsNone(DEV.process_start_identity(123))

    def test_key_matches_the_export_manifest_key_including_lfs_payload_identity(self) -> None:
        key = DEV.component_key("fixture-dep", self.repository.root, self.view_root)
        self.assertEqual(key, self._expected_key())
        # A second computation is served from the listing memo and is identical.
        with mock.patch.object(DEV, "blob_records", side_effect=AssertionError("memo bypassed")):
            self.assertEqual(DEV.component_key("fixture-dep", self.repository.root, self.view_root), key)

    def test_unrelated_changes_keep_the_key_and_governed_changes_miss(self) -> None:
        key = DEV.component_key("fixture-dep", self.repository.root, self.view_root)
        self.repository.write("App/main.swift", b"print(2)\n")
        self.assertEqual(DEV.component_key("fixture-dep", self.repository.root, self.view_root), key)
        self.repository.write("ThirdParty/Dep/input.txt", b"dependency-v2\n")
        with self.assertRaises(DEV.Unavailable):
            DEV.component_key("fixture-dep", self.repository.root, self.view_root)
        self.repository.commit()
        self.assertNotEqual(DEV.component_key("fixture-dep", self.repository.root, self.view_root), key)

    def test_untracked_or_ignored_governed_files_make_the_component_unavailable(self) -> None:
        self.repository.write(".gitignore", b"*.tmp\n")
        self.repository.commit()
        self.repository.write("ThirdParty/Dep/scratch.tmp", b"debris\n")
        with self.assertRaises(DEV.Unavailable):
            DEV.component_key("fixture-dep", self.repository.root, self.view_root)

    def test_miss_builds_once_publishes_and_views_are_reused_without_rehashing(self) -> None:
        first = self._resolve()
        self.assertEqual(first["status"], "published-miss")
        self.assertEqual(self.builds, 1)
        entry = self.cache_root / "artifacts/v1/fixture-dep" / first["key"]
        DEV.CACHE.load_entry(entry, "fixture-dep", first["key"])
        self.assertEqual(list((self.cache_root / "locks/v1/fixture-dep").iterdir()), [])
        self.assertEqual((first["view"] / "artifact.bin").read_bytes(), b"artifact-v1\n")
        self.assertEqual(first["view"].stat().st_mode & 0o222, 0)
        second = self._resolve()
        self.assertEqual(second["status"], "view-reused")
        self.assertEqual((self.builds, self.verifications), (1, 1))
        with mock.patch.object(DEV.CACHE, "materialize_command", side_effect=AssertionError("rehashed")):
            self.assertEqual(self._resolve()["status"], "view-reused")

    def test_failed_build_keeps_its_root_and_shows_tool_output(self) -> None:
        def failing_build(component: str, repository: Path, temporary: Path) -> Path:
            (temporary / "build").mkdir()
            (temporary / "build/LastTest.log").write_text("ctest failure detail\n")
            DEV.run_tool(["/bin/sh", "-c", "echo 'tool stdout detail'; exit 8"])
            raise AssertionError("unreachable")
        stderr = io.StringIO()
        with mock.patch.object(DEV, "build_payload", failing_build), \
                contextlib.redirect_stderr(stderr), \
                self.assertRaisesRegex(DEV.DevCacheError, "failed with exit 8"):
            DEV.resolve("fixture-dep", self.repository.root, self.cache_root, self.view_root, True)
        self.assertIn("tool stdout detail", stderr.getvalue())
        kept = list((self.cache_root / "failed/v1/fixture-dep").iterdir())
        self.assertEqual(len(kept), 1)
        self.assertEqual((kept[0] / "build/LastTest.log").read_text(), "ctest failure detail\n")
        self.assertIn(str(kept[0]), stderr.getvalue())
        self.assertEqual(list((self.cache_root / "locks/v1/fixture-dep").iterdir()), [])
        self.assertEqual(list((self.cache_root / "temporary/v1/fixture-dep").iterdir()), [])

    def test_passing_build_keeps_its_test_log_beside_the_entry(self) -> None:
        def logging_build(component: str, repository: Path, temporary: Path) -> Path:
            (temporary / "test-log").mkdir()
            (temporary / "test-log/LastTest.log").write_text("100% tests passed\n")
            return self._build_payload(component, repository, temporary)
        stderr = io.StringIO()
        with mock.patch.object(DEV, "build_payload", logging_build), contextlib.redirect_stderr(stderr):
            first = DEV.resolve("fixture-dep", self.repository.root, self.cache_root, self.view_root, True)
        self.assertEqual(first["status"], "published-miss")
        kept = self.cache_root / "test-logs/v1/fixture-dep" / first["key"]
        self.assertEqual((kept / "LastTest.log").read_text(), "100% tests passed\n")
        self.assertIn(str(kept), stderr.getvalue())
        self.assertEqual(list((self.cache_root / "temporary/v1/fixture-dep").iterdir()), [])
        self.assertEqual(list((self.cache_root / "locks/v1/fixture-dep").iterdir()), [])

    def test_native_bridge_payload_carries_the_ctest_log_out_of_the_build_root(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        temporary = Path(directory.name)
        def fake_tool(arguments: list[str]) -> str:
            if arguments[0].endswith("build_native_bridge.sh"):
                log = Path(arguments[arguments.index("--build-root") + 1]) / "Testing/Temporary/LastTest.log"
                log.parent.mkdir(parents=True)
                log.write_text("28/28 passed\n")
            return "wrapper-revision\n"
        def fake_extract(repository: Path, *arguments: str) -> None:
            Path(arguments[arguments.index("--payload") + 1]).mkdir()
        with mock.patch.object(DEV, "run_tool", side_effect=fake_tool), \
                mock.patch.object(DEV, "native_bridge_payload_tool", side_effect=fake_extract), \
                contextlib.redirect_stderr(io.StringIO()):
            payload = BUILD_PAYLOAD("native-bridge", self.repository.root, temporary, temporary / "m")
        self.assertEqual(payload, temporary / "payload")
        self.assertFalse((temporary / "build").exists())
        self.assertEqual((temporary / "test-log/LastTest.log").read_text(), "28/28 passed\n")

    def test_no_build_reports_an_absent_entry_as_unavailable(self) -> None:
        with self.assertRaises(DEV.Unavailable):
            self._resolve(build=False)
        self.assertEqual(self.builds, 0)

    def test_sleigh_reuse_admits_verified_view_without_hashing_and_rejects_mutation(self) -> None:
        identity = {"package": {"treeSha256": "a" * 64}}

        def build_fixture(component, repository, temporary):
            payload = temporary / "payload"
            materialization = payload / "materialization"
            (materialization / "package").mkdir(parents=True)
            (materialization / "package/libdecomp.a").write_bytes(b"new synthetic dependency")
            (materialization / "MATERIALIZATION.json").write_bytes(DEV.canonical_json(identity))
            return payload

        with mock.patch.dict(DEV.COMPONENTS, {"sleigh-native-source": self.spec}), \
             mock.patch.object(DEV, "build_payload", side_effect=build_fixture), \
             mock.patch.object(DEV, "verify_view") as verify:
            with contextlib.redirect_stderr(io.StringIO()):
                built = DEV.resolve("sleigh-native-source", self.repository.root, self.cache_root, self.view_root, True)
            self.assertEqual(verify.call_count, 1)
            source = built["view"] / "materialization"
            with mock.patch.object(DEV, "verify_view", side_effect=AssertionError("domain verifier repeated")), \
                 mock.patch.object(DEV.CACHE, "load_entry", side_effect=AssertionError("dependency bytes rehashed")), \
                 mock.patch.object(DEV, "build_payload", side_effect=AssertionError("dependency rebuilt")):
                accepted = DEV.reused_sleigh_materialization(self.repository.root, source, self.cache_root, self.view_root)
                self.assertEqual(accepted["identity"], identity)
                self.assertEqual(set(accepted["files"]), {"MATERIALIZATION.json", "package/libdecomp.a"})
                with self.assertRaisesRegex(DEV.DevCacheError, "receipt-bound"):
                    DEV.reused_sleigh_materialization(self.repository.root, self.root / "other", self.cache_root, self.view_root)
                library = source / "package/libdecomp.a"
                metadata = library.stat()
                # Metadata-only drift (touch, mode round trip -> new ctime/mtime)
                # is not a content change: the receipt is reused without rehash.
                library.chmod(0o600)
                library.chmod(0o444)
                os.utime(library, ns=(1, 1))
                self.assertNotEqual(library.stat().st_ctime_ns, metadata.st_ctime_ns)
                self.assertEqual(DEV.reused_sleigh_materialization(
                    self.repository.root, source, self.cache_root, self.view_root)["identity"], identity)
                library.chmod(0o600)
                library.write_bytes(b"bad, longer synthetic dependency")
                library.chmod(0o444)
                with self.assertRaisesRegex(DEV.DevCacheError, "missing or stale"):
                    DEV.reused_sleigh_materialization(self.repository.root, source, self.cache_root, self.view_root)

    def test_a_changed_view_is_rebuilt_from_the_verified_entry(self) -> None:
        first = self._resolve()
        artifact = first["view"] / "artifact.bin"
        artifact.chmod(0o600)
        artifact.write_bytes(b"tampered\n")
        second = self._resolve()
        self.assertEqual(second["status"], "view-verified")
        self.assertEqual(artifact.read_bytes(), b"artifact-v1\n")
        self.assertEqual(self.builds, 1)

    def test_a_tampered_entry_fails_closed(self) -> None:
        first = self._resolve()
        entry = self.cache_root / "artifacts/v1/fixture-dep" / first["key"]
        leaf = entry / "payload/artifact.bin"
        leaf.chmod(0o600)
        leaf.write_bytes(b"artifact-v2\n")
        leaf.chmod(0o444)
        # The verified read-only view still matches ENTRY; it stays reused.
        self.assertEqual(self._resolve()["status"], "view-reused")
        # Any new view is materialized from the entry with a full hash and
        # fails closed on the tampered bytes.
        DEV.remove_tree(first["view"].parent)
        with self.assertRaises(DEV.CACHE.CacheError):
            self._resolve()

    def test_disabled_or_absent_cache_is_unavailable(self) -> None:
        arguments = argparse.Namespace(cache_root=None, view_root=str(self.view_root))
        with mock.patch.dict(os.environ, {"MACSCOPE_DEV_DEPENDENCY_CACHE": "0"}):
            with self.assertRaises(DEV.Unavailable):
                DEV.roots(arguments)
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MACSCOPE_DEPENDENCY_CACHE_ROOT", None)
            with mock.patch.object(DEV, "DEFAULT_CACHE_ROOT", self.root / "absent"):
                with self.assertRaises(DEV.Unavailable):
                    DEV.roots(arguments)

    def test_sealed_source_export_without_git_is_unavailable(self) -> None:
        export = self.root / "sealed-export"
        export.mkdir()
        with self.assertRaises(DEV.Unavailable):
            DEV.require_git_checkout(export)
        DEV.require_git_checkout(TOOL.parents[2])
        result = subprocess.run(
            [sys.executable, "-B", str(TOOL), "resolve", "--component", "native-bridge",
             "--repository-root", str(export), "--no-build"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, DEV.UNAVAILABLE_STATUS, result.stderr)
        self.assertIn("not a Git checkout", result.stderr)

    def test_view_root_must_be_spotlight_excluded_and_disjoint(self) -> None:
        with self.assertRaises(DEV.DevCacheError):
            DEV.roots(argparse.Namespace(cache_root=str(self.cache_root), view_root=str(self.root / "views")))
        nested = self.cache_root / "views.noindex"
        with self.assertRaises(DEV.DevCacheError):
            DEV.roots(argparse.Namespace(cache_root=str(self.cache_root), view_root=str(nested)))

    def test_contract_lines_name_the_consumer_roots(self) -> None:
        view = self.view_root / "ghostty-vt" / ("a" * 64) / "ghostty-vt"
        resolved = {
            "key": "a" * 64,
            "view": view,
            "receipt": {"descriptors": {"consumer": {"path": "/d/vt.json", "sha256": "b" * 64}}},
        }
        self.assertEqual(
            DEV.contract("ghostty-vt", resolved),
            [
                "MACSCOPE_DEV_DEPENDENCY_KEY=" + "a" * 64,
                f"MACSCOPE_GHOSTTY_VT_VERIFIED_ARTIFACT_ROOT={view}/artifacts",
                "MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR=/d/vt.json",
                "MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR_SHA256=" + "b" * 64,
            ],
        )


if __name__ == "__main__":
    unittest.main()
