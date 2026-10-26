#!/usr/bin/env python3
"""Pure tests and one read-only self-process smoke for the Darwin backend."""

from __future__ import annotations

import importlib.util
import ctypes
import hashlib
import os
import platform
import signal
import struct
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from typing import Dict, List


FIXTURE_DIR = Path(__file__).resolve().parents[1] / "debugger-fixture"
sys.path.insert(0, str(FIXTURE_DIR))


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


supervisor = load_module("process_supervisor", FIXTURE_DIR / "process_supervisor.py")
darwin = load_module("darwin_process_backend", FIXTURE_DIR / "darwin_process_backend.py")


ABASnapshotInspector = supervisor.ABASnapshotInspector
GracefulAction = supervisor.GracefulAction
ImmutableProcessIdentity = supervisor.ImmutableProcessIdentity
InspectionState = supervisor.InspectionState
ProcessRegistry = supervisor.ProcessRegistry
ProcessRole = supervisor.ProcessRole
ProcessSnapshot = supervisor.ProcessSnapshot
ProcessTopology = supervisor.ProcessTopology

BSDProcessInfo = darwin.BSDProcessInfo
CPU_TYPE_ARM64 = darwin.CPU_TYPE_ARM64
CPU_SUBTYPE_ARM64E = 2
CPU_SUBTYPE_LIB64 = 0x80000000
CodesignIdentityReader = darwin.CodesignIdentityReader
CommandResult = darwin.CommandResult
DarwinBackendError = darwin.DarwinBackendError
DarwinLibprocAPI = darwin.DarwinLibprocAPI
DarwinProcessArchitecture = darwin.DarwinProcessArchitecture
DarwinExactChildEnumerator = darwin.DarwinExactChildEnumerator
DarwinRegisteredProcessController = darwin.DarwinRegisteredProcessController
DarwinRegisteredProcessWaiter = darwin.DarwinRegisteredProcessWaiter
DarwinSnapshotBackend = darwin.DarwinSnapshotBackend
ExecutableContentReader = darwin.ExecutableContentReader
LC_UUID = darwin.LC_UUID
MachOIdentityReader = darwin.MachOIdentityReader
SelectedProcessClaim = darwin.SelectedProcessClaim
SelectedProcessClaims = darwin.SelectedProcessClaims


MACHO_UUID = uuid.UUID("01234567-89ab-cdef-0123-456789abcdef")


def arm64_macho_bytes(
    identifier: uuid.UUID = MACHO_UUID, cpu_subtype: int = 0
) -> bytes:
    command = struct.pack("<II", LC_UUID, 24) + identifier.bytes
    header = struct.pack(
        "<IiiIIIII",
        0xFEEDFACF,
        CPU_TYPE_ARM64,
        ctypes.c_int32(cpu_subtype).value,
        2,
        1,
        len(command),
        0,
        0,
    )
    return header + command


def fat_arm64_macho_bytes(*slices: tuple[int, bytes]) -> bytes:
    table_size = 8 + 20 * len(slices)
    offset = table_size
    entries = []
    payloads = []
    for cpu_subtype, payload in slices:
        entries.append(
            struct.pack(
                ">iiIII",
                CPU_TYPE_ARM64,
                ctypes.c_int32(cpu_subtype).value,
                offset,
                len(payload),
                0,
            )
        )
        payloads.append(payload)
        offset += len(payload)
    return struct.pack(">II", 0xCAFEBABE, len(slices)) + b"".join(entries + payloads)


class FakeProcessAPI:
    def __init__(self, info: BSDProcessInfo, path: str, session_id: int = 700):
        self.info = info
        self.paths: List[str] = [path]
        self.session = session_id
        self.bsd_calls: List[int] = []
        self.path_calls: List[int] = []
        self.child_calls: List[tuple[int, int]] = []
        self.child_results: List[tuple[int, ...]] = [()]
        self.architecture_calls: List[int] = []
        self.architecture_results: List[DarwinProcessArchitecture] = [
            DarwinProcessArchitecture(CPU_TYPE_ARM64, 0)
        ]

    def bsd_info(self, pid: int) -> BSDProcessInfo:
        self.bsd_calls.append(pid)
        return self.info

    def pid_path(self, pid: int) -> str:
        self.path_calls.append(pid)
        if len(self.paths) > 1:
            return self.paths.pop(0)
        return self.paths[0]

    def session_id(self, pid: int) -> int:
        return self.session

    def child_pids(self, parent_pid: int, capacity: int) -> tuple[int, ...]:
        self.child_calls.append((parent_pid, capacity))
        result = self.child_results.pop(0) if len(self.child_results) > 1 else self.child_results[0]
        return result[:capacity]

    def architecture(self, pid: int) -> DarwinProcessArchitecture:
        self.architecture_calls.append(pid)
        if len(self.architecture_results) > 1:
            return self.architecture_results.pop(0)
        return self.architecture_results[0]


class FakeSigningReader:
    def __init__(self, identity: str = "Apple Development: Test (TEAM)"):
        self.identity = identity
        self.paths: List[str] = []

    def signing_identity(self, path: str) -> str:
        self.paths.append(path)
        return self.identity


class FakeCommandRunner:
    def __init__(self, *results: CommandResult):
        self.results = list(results)
        self.calls: List[tuple[tuple[str, ...], float]] = []

    def run(self, arguments, timeout_seconds: float) -> CommandResult:
        self.calls.append((tuple(arguments), timeout_seconds))
        if not self.results:
            raise AssertionError("unexpected command")
        return self.results.pop(0)


class MutableInspector:
    def __init__(self) -> None:
        self.current: Dict[int, ProcessSnapshot] = {}
        self.queued: Dict[int, List[ProcessSnapshot]] = {}
        self.capture_calls: List[int] = []

    def capture(self, pid: int) -> ProcessSnapshot:
        self.capture_calls.append(pid)
        queue = self.queued.get(pid, [])
        if queue:
            return queue.pop(0)
        return self.current.get(pid, ProcessSnapshot.gone("gone"))

    def set_exact(self, identity: ImmutableProcessIdentity, parent_pid: int = 1) -> None:
        self.current[identity.pid] = ProcessSnapshot(
            InspectionState.EXACT,
            identity,
            ProcessTopology(parent_pid, identity.pid, identity.pid),
        )


def fake_identity(pid: int, path: str, role: ProcessRole) -> ImmutableProcessIdentity:
    stat_result = os.lstat(path)
    return ImmutableProcessIdentity(
        pid,
        1_700_000_000,
        42,
        path,
        stat_result.st_dev,
        stat_result.st_ino,
        501,
        501,
        CPU_TYPE_ARM64,
        0,
        str(MACHO_UUID).upper(),
        "Apple Development: Test (TEAM)",
        "nonce",
        role,
    )


class MachOIdentityTests(unittest.TestCase):
    def test_reads_exact_arm64_uuid(self) -> None:
        result = MachOIdentityReader().inspect_bytes(arm64_macho_bytes())

        self.assertEqual(result.cpu_type, CPU_TYPE_ARM64)
        self.assertEqual(result.cpu_subtype, 0)
        self.assertEqual(result.macho_uuid, str(MACHO_UUID).upper())

    def test_reads_only_exact_arm64_slice_from_universal_binary(self) -> None:
        thin = arm64_macho_bytes()
        table_size = 8 + 20
        fat = (
            struct.pack(">II", 0xCAFEBABE, 1)
            + struct.pack(">iiIII", CPU_TYPE_ARM64, 0, table_size, len(thin), 0)
            + thin
        )

        result = MachOIdentityReader().inspect_bytes(fat)

        self.assertEqual(result.macho_uuid, str(MACHO_UUID).upper())

    def test_selects_debugserver_like_arm64e_slice_from_running_architecture(self) -> None:
        all_uuid = uuid.UUID("11111111-1111-1111-1111-111111111111")
        arm64e_uuid = uuid.UUID("22222222-2222-2222-2222-222222222222")
        fat = fat_arm64_macho_bytes(
            (0, arm64_macho_bytes(all_uuid, 0)),
            (
                CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E,
                arm64_macho_bytes(
                    arm64e_uuid, CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E
                ),
            ),
        )

        result = MachOIdentityReader().inspect_bytes(
            fat,
            DarwinProcessArchitecture(
                CPU_TYPE_ARM64, CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E
            ),
        )

        self.assertEqual(result.cpu_subtype & 0xFFFFFFFF, CPU_SUBTYPE_LIB64 | 2)
        self.assertEqual(result.macho_uuid, str(arm64e_uuid).upper())

    def test_fat_slice_selection_fails_closed_without_one_base_subtype_match(self) -> None:
        arm64e = arm64_macho_bytes(MACHO_UUID, CPU_SUBTYPE_ARM64E)
        duplicate = arm64_macho_bytes(
            uuid.UUID("33333333-3333-3333-3333-333333333333"),
            CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E,
        )
        fat = fat_arm64_macho_bytes(
            (CPU_SUBTYPE_ARM64E, arm64e),
            (CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E, duplicate),
        )

        with self.assertRaisesRegex(DarwinBackendError, "ambiguous"):
            MachOIdentityReader().inspect_bytes(
                fat, DarwinProcessArchitecture(CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E)
            )
        with self.assertRaisesRegex(DarwinBackendError, "matching ARM64"):
            MachOIdentityReader().inspect_bytes(
                fat, DarwinProcessArchitecture(CPU_TYPE_ARM64, 0)
            )
        with self.assertRaisesRegex(DarwinBackendError, "ambiguous"):
            MachOIdentityReader().inspect_bytes(fat)

    def test_thin_slice_must_match_running_architecture_base_subtype(self) -> None:
        with self.assertRaisesRegex(DarwinBackendError, "running architecture"):
            MachOIdentityReader().inspect_bytes(
                arm64_macho_bytes(MACHO_UUID, 0),
                DarwinProcessArchitecture(CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E),
            )

    def test_rejects_non_arm64_duplicate_uuid_and_truncated_commands(self) -> None:
        non_arm = bytearray(arm64_macho_bytes())
        struct.pack_into("<i", non_arm, 4, 7)
        with self.assertRaisesRegex(DarwinBackendError, "not ARM64"):
            MachOIdentityReader().inspect_bytes(bytes(non_arm))

        command = struct.pack("<II", LC_UUID, 24) + MACHO_UUID.bytes
        duplicate = struct.pack(
            "<IiiIIIII", 0xFEEDFACF, CPU_TYPE_ARM64, 0, 2, 2, 48, 0, 0
        ) + command + command
        with self.assertRaisesRegex(DarwinBackendError, "duplicate"):
            MachOIdentityReader().inspect_bytes(duplicate)

        with self.assertRaisesRegex(DarwinBackendError, "bounds|truncated"):
            MachOIdentityReader().inspect_bytes(arm64_macho_bytes()[:-1])


class DarwinLibprocArchitectureTests(unittest.TestCase):
    @staticmethod
    def api_with_result(size: int, cpu_type: int, cpu_subtype: int):
        class ProcPIDInfo:
            def __init__(self):
                self.calls = []

            def __call__(self, pid, flavor, argument, buffer, buffer_size):
                self.calls.append((pid, flavor, argument, buffer_size))
                record = ctypes.cast(
                    buffer, ctypes.POINTER(darwin._ProcArchInfo)
                ).contents
                record.p_cputype = cpu_type
                record.p_cpusubtype = ctypes.c_int32(cpu_subtype).value
                return size

        function = ProcPIDInfo()
        api = object.__new__(DarwinLibprocAPI)
        api._library = type("Library", (), {"proc_pidinfo": function})()
        return api, function

    def test_reads_exact_public_proc_pidarchinfo_record(self) -> None:
        api, function = self.api_with_result(
            ctypes.sizeof(darwin._ProcArchInfo),
            CPU_TYPE_ARM64,
            CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E,
        )

        result = api.architecture(771)

        self.assertEqual(result.cpu_type, CPU_TYPE_ARM64)
        self.assertEqual(
            result.cpu_subtype & 0xFFFFFFFF,
            CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E,
        )
        self.assertEqual(
            function.calls,
            [(771, darwin.PROC_PIDARCHINFO, 0, ctypes.sizeof(darwin._ProcArchInfo))],
        )

    def test_rejects_short_invalid_and_nonpositive_architecture_results(self) -> None:
        short, _ = self.api_with_result(4, CPU_TYPE_ARM64, 0)
        with self.assertRaisesRegex(DarwinBackendError, "short architecture"):
            short.architecture(771)

        invalid, _ = self.api_with_result(
            ctypes.sizeof(darwin._ProcArchInfo), 0, 0
        )
        with self.assertRaisesRegex(DarwinBackendError, "invalid process architecture"):
            invalid.architecture(771)

        valid, _ = self.api_with_result(
            ctypes.sizeof(darwin._ProcArchInfo), CPU_TYPE_ARM64, 0
        )
        with self.assertRaisesRegex(ValueError, "positive"):
            valid.architecture(0)


class ClaimAndSigningTests(unittest.TestCase):
    def test_claim_add_is_idempotent_only_for_the_same_claim_and_role_mapping(self) -> None:
        path = os.path.realpath(sys.executable)
        executable_identity = "sha256:" + "0" * 64
        cases = (
            SelectedProcessClaim(100, path, "adapter", ProcessRole.ADAPTER),
            SelectedProcessClaim(
                101,
                path,
                "launched",
                ProcessRole.LAUNCHED_TARGET,
                executable_identity,
            ),
            SelectedProcessClaim(
                102,
                path,
                "attached",
                ProcessRole.ATTACHED_HELPER,
                executable_identity,
            ),
            SelectedProcessClaim(
                103,
                path,
                "debugserver",
                ProcessRole.LOCAL_DEBUGSERVER,
            ),
        )

        for claim in cases:
            with self.subTest(role=claim.role):
                claims = SelectedProcessClaims()
                claims.add(claim)
                duplicate = SelectedProcessClaim(
                    claim.pid,
                    claim.canonical_path,
                    claim.nonce,
                    claim.role,
                    claim.expected_executable_identity,
                )
                self.assertIsNot(duplicate, claim)

                claims.add(duplicate)

                self.assertEqual(claims.exact(claim.pid, path), claim)

    def test_claim_add_rejects_same_pid_when_any_claim_field_changes(self) -> None:
        path = os.path.realpath(sys.executable)
        other_path = os.path.realpath("/bin/sh")
        claim = SelectedProcessClaim(100, path, "nonce", ProcessRole.ADAPTER)
        changed_claims = (
            SelectedProcessClaim(100, other_path, "nonce", ProcessRole.ADAPTER),
            SelectedProcessClaim(100, path, "other", ProcessRole.ADAPTER),
            SelectedProcessClaim(
                100,
                path,
                "nonce",
                ProcessRole.LOCAL_DEBUGSERVER,
            ),
            SelectedProcessClaim(
                100,
                path,
                "nonce",
                ProcessRole.ADAPTER,
                "sha256:" + "0" * 64,
            ),
        )

        for changed in changed_claims:
            with self.subTest(changed=changed):
                claims = SelectedProcessClaims()
                claims.add(claim)

                with self.assertRaisesRegex(ValueError, "PID reuse"):
                    claims.add(changed)

    def test_claim_add_rejects_exact_duplicate_when_role_index_is_not_exact(self) -> None:
        path = os.path.realpath(sys.executable)
        claim = SelectedProcessClaim(100, path, "nonce", ProcessRole.ADAPTER)

        for indexed_pid in (None, 101):
            with self.subTest(indexed_pid=indexed_pid):
                claims = SelectedProcessClaims()
                claims.add(claim)
                if indexed_pid is None:
                    del claims._roles[claim.role]
                else:
                    claims._roles[claim.role] = indexed_pid

                with self.assertRaisesRegex(ValueError, "PID reuse"):
                    claims.add(claim)

    def test_claims_are_exact_append_only_and_forbid_pid_or_role_reuse(self) -> None:
        path = os.path.realpath(sys.executable)
        claims = SelectedProcessClaims()
        claim = SelectedProcessClaim(100, path, "nonce", ProcessRole.ADAPTER)
        claims.add(claim)

        self.assertEqual(claims.exact(100, path), claim)
        with self.assertRaises(PermissionError):
            claims.exact(100, "/tmp/different")
        with self.assertRaisesRegex(ValueError, "PID reuse"):
            claims.add(
                SelectedProcessClaim(
                    100,
                    path,
                    "other",
                    ProcessRole.LAUNCHED_TARGET,
                    "sha256:" + "0" * 64,
                )
            )
        with self.assertRaisesRegex(ValueError, "role reuse"):
            claims.add(SelectedProcessClaim(101, path, "other", ProcessRole.ADAPTER))

        with self.assertRaisesRegex(ValueError, "accepted executable identity"):
            SelectedProcessClaim(102, path, "target", ProcessRole.ATTACHED_HELPER)
        with self.assertRaisesRegex(ValueError, "canonical sha256"):
            SelectedProcessClaim(
                102,
                path,
                "target",
                ProcessRole.ATTACHED_HELPER,
                "SHA256:not-canonical",
            )

    def test_codesign_reader_uses_bounded_exact_argv_and_parses_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = os.path.realpath(Path(temporary) / "tool")
            Path(path).write_bytes(arm64_macho_bytes())
            runner = FakeCommandRunner(
                CommandResult(0, b"", b"valid on disk\n"),
                CommandResult(
                    0,
                    b"",
                    b"Identifier=tool\nCDHash=0123456789abcdef0123456789abcdef01234567\n"
                    b"Authority=Apple Development: Test (TEAM)\nTeamIdentifier=TEAMTEAM12\n",
                ),
            )
            reader = CodesignIdentityReader(runner)

            result = reader.signing_identity(path)

        self.assertEqual(result, "Apple Development: Test (TEAM)")
        self.assertEqual(
            runner.calls[0][0],
            (
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "--verbose=4",
                "--",
                path,
            ),
        )
        self.assertEqual(
            runner.calls[1][0],
            (
                "/usr/bin/codesign",
                "-d",
                "--verbose=4",
                "--",
                path,
            ),
        )

    def test_codesign_verification_failure_prevents_metadata_acceptance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = os.path.realpath(Path(temporary) / "tool")
            Path(path).write_bytes(arm64_macho_bytes())
            runner = FakeCommandRunner(
                CommandResult(1, b"", b"invalid signature"),
                CommandResult(
                    0,
                    b"",
                    b"Identifier=tool\nCDHash=0123456789abcdef0123456789abcdef01234567\n"
                    b"Authority=Apple Development: Forged (TEAM)\nTeamIdentifier=TEAMTEAM12\n",
                ),
            )

            with self.assertRaisesRegex(DarwinBackendError, "strict codesign"):
                CodesignIdentityReader(runner).signing_identity(path)

        self.assertEqual(len(runner.calls), 1)

    def test_codesign_rejects_symlink_dropped_or_malformed_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            target = os.path.realpath(Path(temporary) / "tool")
            link = str(Path(temporary) / "tool-link")
            Path(target).write_bytes(arm64_macho_bytes())
            os.symlink(target, link)

            no_calls = FakeCommandRunner()
            with self.assertRaisesRegex(DarwinBackendError, "canonical|symlink"):
                CodesignIdentityReader(no_calls).signing_identity(link)
            self.assertEqual(no_calls.calls, [])

            dropped = FakeCommandRunner(
                CommandResult(0, b"", b"valid", stderr_dropped=1)
            )
            with self.assertRaisesRegex(DarwinBackendError, "strict codesign"):
                CodesignIdentityReader(dropped).signing_identity(target)

            malformed = FakeCommandRunner(
                CommandResult(0, b"", b"valid"),
                CommandResult(0, b"", b"Authority=Only A Name\n"),
            )
            with self.assertRaisesRegex(DarwinBackendError, "malformed"):
                CodesignIdentityReader(malformed).signing_identity(target)

    def test_exact_content_reader_returns_canonical_sha256_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = os.path.realpath(Path(temporary) / "tool")
            payload = arm64_macho_bytes()
            Path(path).write_bytes(payload)
            descriptor = os.open(path, os.O_RDONLY)
            try:
                observed, evidence = ExecutableContentReader().read_fd(descriptor)
            finally:
                os.close(descriptor)

        digest = hashlib.sha256(payload).hexdigest()
        self.assertEqual(observed, payload)
        self.assertEqual(evidence.sha256, digest)
        self.assertEqual(evidence.executable_identity, "sha256:" + digest)


class DarwinSnapshotBackendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.path = os.path.realpath(Path(self.temporary.name) / "fixture")
        Path(self.path).write_bytes(arm64_macho_bytes())
        os.chmod(self.path, 0o700)
        self.pid = 700
        self.info = BSDProcessInfo(
            self.pid,
            1,
            self.pid,
            501,
            501,
            0x2,
            2,
            1_700_000_000,
            123_456,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def backend(self, api: FakeProcessAPI):
        executable_identity = "sha256:" + hashlib.sha256(
            Path(self.path).read_bytes()
        ).hexdigest()
        claims = SelectedProcessClaims()
        claims.add(
            SelectedProcessClaim(
                self.pid,
                self.path,
                "fixture-nonce",
                ProcessRole.ATTACHED_HELPER,
                executable_identity,
            )
        )
        return DarwinSnapshotBackend(
            api, claims, MachOIdentityReader(), FakeSigningReader()
        )

    def test_exact_backend_populates_immutable_identity_and_dynamic_topology(self) -> None:
        api = FakeProcessAPI(self.info, self.path, session_id=909)
        snapshot = ABASnapshotInspector(self.backend(api)).capture(self.pid)

        self.assertEqual(snapshot.state, InspectionState.EXACT)
        assert snapshot.identity and snapshot.topology
        self.assertEqual(snapshot.identity.canonical_path, self.path)
        self.assertEqual(snapshot.identity.start_microseconds, 123_456)
        self.assertEqual(snapshot.identity.macho_uuid, str(MACHO_UUID).upper())
        self.assertEqual(
            snapshot.identity.executable_identity,
            "sha256:" + hashlib.sha256(Path(self.path).read_bytes()).hexdigest(),
        )
        self.assertEqual(snapshot.identity.nonce, "fixture-nonce")
        self.assertEqual(snapshot.identity.role, ProcessRole.ATTACHED_HELPER)
        self.assertTrue(snapshot.topology.traced)
        self.assertEqual(snapshot.topology.session_id, 909)
        self.assertEqual(api.bsd_calls, [self.pid, self.pid, self.pid])
        self.assertEqual(api.architecture_calls, [self.pid, self.pid])

    def test_backend_binds_debugserver_like_fat_identity_to_running_subtype(self) -> None:
        all_uuid = uuid.UUID("11111111-1111-1111-1111-111111111111")
        arm64e_uuid = uuid.UUID("22222222-2222-2222-2222-222222222222")
        Path(self.path).write_bytes(
            fat_arm64_macho_bytes(
                (0, arm64_macho_bytes(all_uuid, 0)),
                (
                    CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E,
                    arm64_macho_bytes(
                        arm64e_uuid, CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E
                    ),
                ),
            )
        )
        api = FakeProcessAPI(self.info, self.path)
        api.architecture_results = [
            DarwinProcessArchitecture(
                CPU_TYPE_ARM64, CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_ARM64E
            )
        ]

        snapshot = ABASnapshotInspector(self.backend(api)).capture(self.pid)

        self.assertEqual(snapshot.state, InspectionState.EXACT, snapshot.detail)
        assert snapshot.identity
        self.assertEqual(snapshot.identity.macho_uuid, str(arm64e_uuid).upper())
        self.assertEqual(snapshot.identity.cpu_subtype & 0xFFFFFFFF, 0x80000002)

    def test_backend_rejects_running_architecture_change_during_capture(self) -> None:
        api = FakeProcessAPI(self.info, self.path)
        api.architecture_results = [
            DarwinProcessArchitecture(CPU_TYPE_ARM64, 0),
            DarwinProcessArchitecture(CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E),
        ]

        snapshot = ABASnapshotInspector(self.backend(api)).capture(self.pid)

        self.assertEqual(snapshot.state, InspectionState.UNSTABLE)
        self.assertIn("changed during inspection", snapshot.detail)

    def test_backend_rejects_unselected_or_changed_executable_path(self) -> None:
        other_path = os.path.realpath(Path(self.temporary.name) / "replacement")
        Path(other_path).write_bytes(arm64_macho_bytes())
        api = FakeProcessAPI(self.info, self.path)
        api.paths = [self.path, other_path]

        snapshot = ABASnapshotInspector(self.backend(api)).capture(self.pid)

        self.assertEqual(snapshot.state, InspectionState.UNSTABLE)
        self.assertIn("changed during inspection", snapshot.detail)

    def test_backend_rejects_content_not_in_accepted_fixture_manifest(self) -> None:
        claims = SelectedProcessClaims()
        claims.add(
            SelectedProcessClaim(
                self.pid,
                self.path,
                "fixture-nonce",
                ProcessRole.ATTACHED_HELPER,
                "sha256:" + "0" * 64,
            )
        )
        backend = DarwinSnapshotBackend(
            FakeProcessAPI(self.info, self.path),
            claims,
            MachOIdentityReader(),
            FakeSigningReader(),
        )

        snapshot = ABASnapshotInspector(backend).capture(self.pid)

        self.assertEqual(snapshot.state, InspectionState.UNSTABLE)
        self.assertIn("accepted fixture identity", snapshot.detail)

    def test_backend_rejects_in_place_content_drift_during_signing_query(self) -> None:
        class MutatingSigningReader:
            def signing_identity(inner_self, path: str) -> str:
                with open(path, "ab") as stream:
                    stream.write(b"drift")
                return "Apple Development: Test (TEAM)"

        executable_identity = "sha256:" + hashlib.sha256(
            Path(self.path).read_bytes()
        ).hexdigest()
        claims = SelectedProcessClaims()
        claims.add(
            SelectedProcessClaim(
                self.pid,
                self.path,
                "fixture-nonce",
                ProcessRole.ATTACHED_HELPER,
                executable_identity,
            )
        )
        backend = DarwinSnapshotBackend(
            FakeProcessAPI(self.info, self.path),
            claims,
            MachOIdentityReader(),
            MutatingSigningReader(),
        )

        snapshot = ABASnapshotInspector(backend).capture(self.pid)

        self.assertEqual(snapshot.state, InspectionState.UNSTABLE)
        self.assertIn("changed during inspection", snapshot.detail)


class ControllerAndWaiterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        path = os.path.realpath(Path(self.temporary.name) / "fixture")
        Path(path).write_bytes(arm64_macho_bytes())
        self.identity = fake_identity(800, path, ProcessRole.ATTACHED_HELPER)
        self.inspector = MutableInspector()
        self.inspector.set_exact(self.identity)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        self.registration = self.registry.register(self.identity)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_controller_requires_role_specific_signal_authority(self) -> None:
        signals: List[tuple[int, int]] = []
        callbacks: List[int] = []

        def graceful(registration, timeout):
            callbacks.append(registration.identity.pid)
            return GracefulAction(True, True, "fixtureExit")

        controller = DarwinRegisteredProcessController(
            self.registry,
            self.inspector,
            {ProcessRole.ATTACHED_HELPER: graceful},
            lambda pid, number: signals.append((pid, number)),
        )

        self.assertTrue(controller.request_graceful(self.registration, 1).acknowledged)
        self.assertFalse(controller.send_signal(self.registration, signal.SIGKILL))
        self.assertFalse(controller.send_signal(self.registration, signal.SIGSTOP))
        self.assertTrue(controller.send_signal(self.registration, signal.SIGTERM))
        self.assertEqual(callbacks, [self.identity.pid])
        self.assertEqual(signals, [
            (self.identity.pid, signal.SIGTERM),
        ])

    def test_controller_allows_sigstop_only_for_exact_launched_target(self) -> None:
        signals: List[tuple[int, int]] = []
        launched = fake_identity(801, self.identity.canonical_path,
                                   ProcessRole.LAUNCHED_TARGET)
        self.inspector.set_exact(launched)
        registration = self.registry.register(launched)
        controller = DarwinRegisteredProcessController(
            self.registry, self.inspector,
            kill_function=lambda pid, number: signals.append((pid, number)))

        self.assertTrue(controller.send_signal(registration, signal.SIGSTOP))
        replacement = ImmutableProcessIdentity(
            **{**launched.__dict__, "start_microseconds": launched.start_microseconds + 1})
        self.inspector.set_exact(replacement)
        self.assertFalse(controller.send_signal(registration, signal.SIGSTOP))
        self.assertEqual(signals, [(launched.pid, signal.SIGSTOP)])

    def test_controller_never_signals_after_identity_change(self) -> None:
        signals: List[tuple[int, int]] = []
        replacement = ImmutableProcessIdentity(
            **{
                **self.identity.__dict__,
                "start_microseconds": self.identity.start_microseconds + 1,
            }
        )
        self.inspector.set_exact(replacement)
        controller = DarwinRegisteredProcessController(
            self.registry,
            self.inspector,
            kill_function=lambda pid, number: signals.append((pid, number)),
        )

        self.assertFalse(controller.send_signal(self.registration, signal.SIGTERM))
        self.assertEqual(signals, [])

    def test_waiter_is_bounded_and_returns_gone_without_any_signal_surface(self) -> None:
        clock_value = [0.0]

        def clock() -> float:
            return clock_value[0]

        def sleep(interval: float) -> None:
            clock_value[0] += interval

        self.inspector.queued[self.identity.pid] = [
            self.inspector.current[self.identity.pid],
            ProcessSnapshot.gone("exited"),
        ]
        waiter = DarwinRegisteredProcessWaiter(
            self.registry,
            self.inspector,
            clock=clock,
            sleeper=sleep,
            poll_interval_seconds=0.1,
        )

        result = waiter.wait_after_action(self.identity, 1.0)

        self.assertEqual(result.state, InspectionState.GONE)
        self.assertEqual(clock_value[0], 0.1)

    def test_waiter_reports_exact_timeout_and_refuses_foreign_identity(self) -> None:
        clock_value = [0.0]

        def clock() -> float:
            return clock_value[0]

        def sleep(interval: float) -> None:
            clock_value[0] += interval

        waiter = DarwinRegisteredProcessWaiter(
            self.registry,
            self.inspector,
            clock=clock,
            sleeper=sleep,
            poll_interval_seconds=0.1,
        )
        timeout = waiter.wait_after_action(self.identity, 0.2)
        self.assertEqual(timeout.state, InspectionState.EXACT)
        self.assertIn("expired", timeout.detail)

        foreign = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "start_microseconds": 999}
        )
        with self.assertRaises(KeyError):
            waiter.wait_after_action(foreign, 0.2)

    def test_child_enumerator_is_rooted_in_exact_registered_adapter(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        child_info = BSDProcessInfo(
            901, adapter.pid, 901, 501, 501, 0, 2, 1_700_000_001, 7
        )
        api = FakeProcessAPI(child_info, self.identity.canonical_path)
        api.child_results = [(901,), (901,)]

        result = DarwinExactChildEnumerator(
            api, self.registry, self.inspector
        ).enumerate(registration)

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].pid, 901)
        self.assertEqual(result[0].parent_pid, adapter.pid)
        self.assertEqual(result[0].start_microseconds, 7)
        self.assertEqual(result[0].canonical_path, self.identity.canonical_path)

    def test_child_enumerator_accepts_only_exact_adapter_owned_debugserver_parent(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        debugserver = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "pid": 902,
               "start_microseconds": 902,
               "role": ProcessRole.LOCAL_DEBUGSERVER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        adapter_registration = self.registry.register(adapter)
        self.inspector.set_exact(debugserver, parent_pid=adapter.pid)
        debugserver_registration = self.registry.register_debugserver(
            debugserver,
            adapter_key=adapter_registration.process_key,
            ancestry=(
                self.inspector.capture(debugserver.pid),
                self.inspector.capture(adapter.pid),
            ),
        )
        child_info = BSDProcessInfo(
            903, debugserver.pid, 903, 501, 501, 0, 2, 1_700_000_001, 9
        )
        api = FakeProcessAPI(child_info, self.identity.canonical_path)
        api.child_results = [(903,), (903,)]

        result = DarwinExactChildEnumerator(
            api, self.registry, self.inspector
        ).enumerate_debugserver_children(debugserver_registration)

        self.assertEqual(tuple(item.pid for item in result), (903,))
        self.assertEqual(result[0].parent_pid, debugserver.pid)

    def test_child_enumerator_does_not_capture_explicitly_excluded_target(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        api = FakeProcessAPI(
            BSDProcessInfo(902, adapter.pid, 902, 501, 501, 0, 2, 1, 7),
            self.identity.canonical_path,
        )
        api.child_results = [(901, 902), (901, 902)]

        result = DarwinExactChildEnumerator(
            api, self.registry, self.inspector
        ).enumerate(registration, excluded_pids=(901,))

        self.assertEqual(tuple(child.pid for child in result), (902,))
        self.assertEqual(api.bsd_calls, [902, 902])
        self.assertEqual(api.path_calls, [902, 902])

    def test_child_enumerator_ignores_excluded_target_reparenting_race(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        api = FakeProcessAPI(
            BSDProcessInfo(902, adapter.pid, 902, 501, 501, 0, 2, 1, 7),
            self.identity.canonical_path,
        )
        api.child_results = [(901, 902), (902,)]
        retry_sleeps: List[float] = []

        result = DarwinExactChildEnumerator(
            api,
            self.registry,
            self.inspector,
            retry_sleeper=retry_sleeps.append,
        ).enumerate(registration, excluded_pids=(901,))

        self.assertEqual(tuple(child.pid for child in result), (902,))
        self.assertEqual(api.bsd_calls, [902, 902])
        self.assertEqual(retry_sleeps, [])

    def test_child_enumerator_keeps_parent_check_for_unexcluded_children(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        api = FakeProcessAPI(
            BSDProcessInfo(902, 999, 902, 501, 501, 0, 2, 1, 7),
            self.identity.canonical_path,
        )
        api.child_results = [(901, 902), (901, 902)]

        with self.assertRaisesRegex(DarwinBackendError, "identity changed"):
            DarwinExactChildEnumerator(
                api, self.registry, self.inspector, max_attempts=1
            ).enumerate(registration, excluded_pids=(901,))

        self.assertEqual(api.bsd_calls, [902, 902])

    def test_child_enumerator_rejects_invalid_excluded_pids(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        api = FakeProcessAPI(
            BSDProcessInfo(901, adapter.pid, 901, 501, 501, 0, 2, 1, 7),
            self.identity.canonical_path,
        )

        for excluded_pids in ((0,), (-1,), (True,), ("901",)):
            with self.subTest(excluded_pids=excluded_pids):
                with self.assertRaisesRegex(ValueError, "excluded PIDs"):
                    DarwinExactChildEnumerator(
                        api, self.registry, self.inspector
                    ).enumerate(registration, excluded_pids=excluded_pids)

        self.assertEqual(api.child_calls, [])

    def test_child_enumerator_retries_transient_exec_identity_race(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        child_info = BSDProcessInfo(
            901, adapter.pid, 901, 501, 501, 0, 2, 1_700_000_001, 7
        )
        api = FakeProcessAPI(child_info, self.identity.canonical_path)
        api.paths = [
            "/tmp/transient-child-before-exec",
            "/tmp/transient-child-after-exec",
            self.identity.canonical_path,
            self.identity.canonical_path,
        ]
        api.child_results = [(901,), (901,), (901,), (901,)]
        adapter_captures_before = len(self.inspector.capture_calls)
        retry_sleeps: List[float] = []

        result = DarwinExactChildEnumerator(
            api,
            self.registry,
            self.inspector,
            max_attempts=2,
            retry_interval_seconds=0.025,
            retry_sleeper=retry_sleeps.append,
        ).enumerate(registration)

        self.assertEqual(result[0].canonical_path, self.identity.canonical_path)
        self.assertEqual(api.bsd_calls, [901, 901, 901, 901])
        self.assertEqual(api.child_calls, [(adapter.pid, 4)] * 4)
        self.assertEqual(
            self.inspector.capture_calls[adapter_captures_before:],
            [adapter.pid] * 4,
        )
        self.assertEqual(retry_sleeps, [0.025])

    def test_child_enumerator_revalidates_adapter_after_child_identity_race(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        exact = self.inspector.current[adapter.pid]
        self.inspector.queued[adapter.pid] = [
            exact,
            ProcessSnapshot.gone("adapter exited during child capture"),
        ]
        child_info = BSDProcessInfo(
            901, adapter.pid, 901, 501, 501, 0, 2, 1_700_000_001, 7
        )
        api = FakeProcessAPI(child_info, "/tmp/transient-child-before-exec")
        api.paths = [
            "/tmp/transient-child-before-exec",
            "/tmp/transient-child-after-exec",
        ]
        api.child_results = [(901,), (901,)]
        retry_sleeps: List[float] = []

        with self.assertRaisesRegex(DarwinBackendError, "adapter identity changed"):
            DarwinExactChildEnumerator(
                api,
                self.registry,
                self.inspector,
                max_attempts=2,
                retry_interval_seconds=0.025,
                retry_sleeper=retry_sleeps.append,
            ).enumerate(registration)

        self.assertEqual(retry_sleeps, [])

    def test_child_enumerator_fails_closed_after_bounded_identity_races(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        child_info = BSDProcessInfo(
            901, adapter.pid, 901, 501, 501, 0, 2, 1_700_000_001, 7
        )
        api = FakeProcessAPI(child_info, "/tmp/transient-child-a")
        api.paths = [
            "/tmp/transient-child-a",
            "/tmp/transient-child-b",
            "/tmp/transient-child-c",
            "/tmp/transient-child-d",
        ]
        api.child_results = [(901,), (901,), (901,), (901,)]
        retry_sleeps: List[float] = []

        with self.assertRaisesRegex(
            DarwinBackendError,
            r"identity changed.*beforePath='[^']*/transient-child-c'.*"
            r"afterPath='[^']*/transient-child-d'",
        ):
            DarwinExactChildEnumerator(
                api,
                self.registry,
                self.inspector,
                max_attempts=2,
                retry_interval_seconds=0.025,
                retry_sleeper=retry_sleeps.append,
            ).enumerate(registration)

        self.assertEqual(api.bsd_calls, [901, 901, 901, 901])
        self.assertEqual(api.child_calls, [(adapter.pid, 4)] * 4)
        self.assertEqual(retry_sleeps, [0.025])

    def test_child_enumerator_waits_after_retryable_child_pid_set_race(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        child_info = BSDProcessInfo(
            901, adapter.pid, 901, 501, 501, 0, 2, 1_700_000_001, 7
        )
        api = FakeProcessAPI(child_info, self.identity.canonical_path)
        api.child_results = [(901,), (), (901,), (901,)]
        retry_sleeps: List[float] = []

        result = DarwinExactChildEnumerator(
            api,
            self.registry,
            self.inspector,
            max_attempts=2,
            retry_interval_seconds=0.025,
            retry_sleeper=retry_sleeps.append,
        ).enumerate(registration)

        self.assertEqual(tuple(child.pid for child in result), (901,))
        self.assertEqual(retry_sleeps, [0.025])

    def test_child_enumerator_does_not_wait_on_success(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        child_info = BSDProcessInfo(
            901, adapter.pid, 901, 501, 501, 0, 2, 1_700_000_001, 7
        )
        retry_sleeps: List[float] = []

        success_api = FakeProcessAPI(child_info, self.identity.canonical_path)
        success_api.child_results = [(901,), (901,)]
        DarwinExactChildEnumerator(
            success_api,
            self.registry,
            self.inspector,
            retry_interval_seconds=0.025,
            retry_sleeper=retry_sleeps.append,
        ).enumerate(registration)

        self.assertEqual(retry_sleeps, [])

    def test_child_enumerator_does_not_wait_on_nonretryable_failure(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        child_info = BSDProcessInfo(
            901, adapter.pid, 901, 501, 501, 0, 2, 1_700_000_001, 7
        )
        retry_sleeps: List[float] = []

        saturated_api = FakeProcessAPI(child_info, self.identity.canonical_path)
        saturated_api.child_results = [(901,)]
        with self.assertRaisesRegex(DarwinBackendError, "saturated"):
            DarwinExactChildEnumerator(
                saturated_api,
                self.registry,
                self.inspector,
                initial_capacity=1,
                max_children=1,
                retry_interval_seconds=0.025,
                retry_sleeper=retry_sleeps.append,
            ).enumerate(registration)

        self.assertEqual(retry_sleeps, [])

    def test_child_enumerator_grows_buffer_and_rejects_saturation(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        api = FakeProcessAPI(
            BSDProcessInfo(901, adapter.pid, 901, 501, 501, 0, 2, 1, 1),
            self.identity.canonical_path,
        )
        api.child_results = [(901, 902, 903, 904)]

        with self.assertRaisesRegex(DarwinBackendError, "saturated"):
            DarwinExactChildEnumerator(
                api, self.registry, self.inspector,
                initial_capacity=2, max_children=4,
            ).enumerate(registration)

    def test_child_enumerator_rejects_parent_or_child_identity_race(self) -> None:
        adapter = ImmutableProcessIdentity(
            **{**self.identity.__dict__, "role": ProcessRole.ADAPTER}
        )
        self.inspector = MutableInspector()
        self.inspector.set_exact(adapter)
        self.registry = ProcessRegistry("run-owner", self.inspector)
        registration = self.registry.register(adapter)
        wrong_parent = BSDProcessInfo(901, 999, 901, 501, 501, 0, 2, 1, 1)
        api = FakeProcessAPI(wrong_parent, self.identity.canonical_path)
        api.child_results = [(901,), (901,)]

        with self.assertRaisesRegex(DarwinBackendError, "identity changed"):
            DarwinExactChildEnumerator(api, self.registry, self.inspector).enumerate(
                registration
            )

        self.inspector.current[adapter.pid] = ProcessSnapshot.gone("adapter exited")
        with self.assertRaises(PermissionError):
            DarwinExactChildEnumerator(api, self.registry, self.inspector).enumerate(
                registration
            )


@unittest.skipUnless(
    sys.platform == "darwin" and platform.machine() == "arm64",
    "read-only smoke requires ARM64 Darwin",
)
class LiveReadOnlySelfProcessSmokeTests(unittest.TestCase):
    def test_reads_only_current_process_identity_without_signalling(self) -> None:
        api = DarwinLibprocAPI()
        pid = os.getpid()
        path = os.path.realpath(api.pid_path(pid))
        claims = SelectedProcessClaims()
        claims.add(SelectedProcessClaim(pid, path, "self-read-only", ProcessRole.ADAPTER))
        backend = DarwinSnapshotBackend(
            api,
            claims,
            MachOIdentityReader(),
            CodesignIdentityReader(darwin.BoundedCommandRunner()),
        )

        snapshot = ABASnapshotInspector(backend).capture(pid)

        self.assertEqual(snapshot.state, InspectionState.EXACT, snapshot.detail)
        assert snapshot.identity
        self.assertEqual(snapshot.identity.pid, pid)
        self.assertEqual(snapshot.identity.canonical_path, path)
        self.assertEqual(snapshot.identity.cpu_type, CPU_TYPE_ARM64)
        self.assertRegex(
            snapshot.identity.executable_identity, r"^sha256:[0-9a-f]{64}$"
        )


if __name__ == "__main__":
    unittest.main()
