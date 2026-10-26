from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Scripts" / "verify_machokit_analysis_worker_identity.py"


def load_module():
    specification = importlib.util.spec_from_file_location(
        "machokit_analysis_worker_identity_test", HELPER
    )
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


MODULE = load_module()

# Deliberate independent anchor: these values must not derive from the verifier
# constants, or changing verifier and marker generation together would leave the
# test green while silently moving the dependency identity.
REVIEWED_REVISION = "773e10797abc53914b94c2ee8c6f40f5da0b06eb"
REVIEWED_GOVERNED_SOURCE_IDENTITY = (
    "b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea"
)
FINAL_MATERIALIZATION_DIGEST = (
    "e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950"
)
REVIEWED_MARKER = (
    "MACSCOPE_MACHOKIT_BUILD_ID:"
    f"{REVIEWED_REVISION}:"
    f"{REVIEWED_GOVERNED_SOURCE_IDENTITY}"
).encode("ascii")


class MachOKitAnalysisWorkerIdentityTests(unittest.TestCase):
    def write_binary(self, root: Path, payload: bytes) -> Path:
        path = root / "AnalysisWorkerXPCService"
        path.write_bytes(b"mach-o-prefix\0" + payload + b"\0mach-o-suffix")
        path.chmod(0o755)
        return path

    def test_accepts_exactly_one_canonical_compiled_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = self.write_binary(Path(temporary), REVIEWED_MARKER)
            self.assertEqual(
                MODULE.verify_analysis_worker_executable(binary),
                {
                    "schema": "macscope-machokit-compiled-identity-v1",
                    "revision": REVIEWED_REVISION,
                    "governed_source_identity": REVIEWED_GOVERNED_SOURCE_IDENTITY,
                },
            )

    def test_rejects_missing_duplicate_malformed_and_drifted_markers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cases = {
                "missing": (b"no marker", "missing"),
                "duplicate": (
                    REVIEWED_MARKER + b"\0" + REVIEWED_MARKER,
                    "duplicate",
                ),
                "malformed": (
                    MODULE.MARKER_PREFIX + b"not-a-revision:not-an-identity",
                    "malformed",
                ),
                "revision drift": (
                    REVIEWED_MARKER.replace(
                        REVIEWED_REVISION.encode("ascii"), b"0" * 40
                    ),
                    "revision",
                ),
                "source drift": (
                    REVIEWED_MARKER.replace(
                        REVIEWED_GOVERNED_SOURCE_IDENTITY.encode("ascii"), b"0" * 64
                    ),
                    "governed source identity",
                ),
                "materialization digest is not governed identity": (
                    REVIEWED_MARKER.replace(
                        REVIEWED_GOVERNED_SOURCE_IDENTITY.encode("ascii"),
                        FINAL_MATERIALIZATION_DIGEST.encode("ascii"),
                    ),
                    "governed source identity",
                ),
            }
            for index, (name, (payload, diagnostic)) in enumerate(cases.items()):
                with self.subTest(name=name):
                    binary = root / f"worker-{index}"
                    binary.write_bytes(b"prefix\0" + payload + b"\0suffix")
                    with self.assertRaisesRegex(
                        MODULE.MachOKitCompiledIdentityError, diagnostic
                    ):
                        MODULE.verify_analysis_worker_executable(binary)

    def test_rejects_oversized_nonregular_symlink_and_multiply_linked_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = self.write_binary(root, REVIEWED_MARKER)
            with mock.patch.object(MODULE, "MAX_EXECUTABLE_BYTES", binary.stat().st_size - 1):
                with self.assertRaisesRegex(
                    MODULE.MachOKitCompiledIdentityError, "size bound"
                ):
                    MODULE.verify_analysis_worker_executable(binary)

            directory = root / "directory"
            directory.mkdir()
            with self.assertRaisesRegex(
                MODULE.MachOKitCompiledIdentityError, "regular file"
            ):
                MODULE.verify_analysis_worker_executable(directory)

            symlink = root / "worker-symlink"
            symlink.symlink_to(binary.name)
            with self.assertRaisesRegex(
                MODULE.MachOKitCompiledIdentityError, "symbolic link"
            ):
                MODULE.verify_analysis_worker_executable(symlink)

            hardlink = root / "worker-hardlink"
            os.link(binary, hardlink)
            with self.assertRaisesRegex(
                MODULE.MachOKitCompiledIdentityError, "multiply linked"
            ):
                MODULE.verify_analysis_worker_executable(binary)

    def test_cli_emits_canonical_json_and_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = self.write_binary(root, REVIEWED_MARKER)
            accepted = subprocess.run(
                [sys.executable, "-B", str(HELPER), "--executable", str(binary), "--json"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertEqual(
                json.loads(accepted.stdout),
                MODULE.verify_analysis_worker_executable(binary),
            )

            binary.write_bytes(b"missing marker")
            rejected = subprocess.run(
                [sys.executable, "-B", str(HELPER), "--executable", str(binary)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("missing the MachOKit identity marker", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
