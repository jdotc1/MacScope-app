from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/dependencies/stage_verified_ghostty_surface.py"


def load_module():
    specification = importlib.util.spec_from_file_location(
        "stage_verified_ghostty_surface", SCRIPT
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load Ghostty surface stager")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class StageVerifiedGhosttySurfaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.artifact = self.root / "artifact"
        self.allowed = self.root / "build-owned"
        self.destination = self.allowed / "MacScopeGhosttySurface"
        self.allowed.mkdir()
        leaves = {
            "macos-arm64/libghostty-internal.a": b"archive\0payload",
            "macos-arm64/Headers/ghostty.h": b"#define GHOSTTY_EXTERNAL_IO_ABI_VERSION 1\n",
            "macos-arm64/Headers/module.modulemap": b"module GhosttySurface {}\n",
        }
        for relative, payload in leaves.items():
            path = self.artifact / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        self.values = {
            "schema": "3",
            "external_io_abi_version": "1",
            "networking": "disabled",
            "architecture": "arm64",
            "library_identifier": "macos-arm64",
            "archive_sha256": hashlib.sha256(
                leaves["macos-arm64/libghostty-internal.a"]
            ).hexdigest(),
            "header_sha256": hashlib.sha256(
                leaves["macos-arm64/Headers/ghostty.h"]
            ).hexdigest(),
            "module_map_sha256": hashlib.sha256(
                leaves["macos-arm64/Headers/module.modulemap"]
            ).hexdigest(),
        }
        self.manifest = self.root / "surface.manifest"
        self._write_manifest()
        self.module = load_module()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_manifest(self) -> None:
        self.manifest.write_text(
            "".join(f"{key}={value}\n" for key, value in self.values.items()),
            encoding="utf-8",
        )

    def stage(self):
        return self.module.stage_surface(
            self.manifest, self.artifact, self.destination, self.allowed
        )

    def test_stages_only_manifest_bound_compiler_and_linker_leaves(self) -> None:
        descriptor = self.stage()

        self.assertEqual(descriptor["schema_version"], 1)
        self.assertEqual(
            descriptor["source_manifest_sha256"],
            hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            sorted(path.relative_to(self.destination).as_posix() for path in self.destination.rglob("*") if path.is_file()),
            [
                "Headers/ghostty.h",
                "Headers/module.modulemap",
                "STAGED_GHOSTTY_SURFACE.json",
                "libghostty-internal.a",
            ],
        )
        on_disk = json.loads(
            (self.destination / "STAGED_GHOSTTY_SURFACE.json").read_text(encoding="utf-8")
        )
        self.assertEqual(on_disk, descriptor)

    def test_replaces_only_the_exact_build_owned_destination(self) -> None:
        self.stage()
        (self.destination / "stale").write_text("stale", encoding="utf-8")

        self.stage()

        self.assertFalse((self.destination / "stale").exists())
        self.assertFalse(any(self.allowed.glob(".MacScopeGhosttySurface.previous.*")))

    def test_rejects_artifact_mutation_against_the_manifest(self) -> None:
        (self.artifact / "macos-arm64/libghostty-internal.a").write_bytes(b"changed")

        with self.assertRaisesRegex(
            self.module.GhosttySurfaceStageError,
            "archive does not match the verified manifest",
        ):
            self.stage()

        self.assertFalse(self.destination.exists())

    def test_rejects_symlinked_leaf(self) -> None:
        header = self.artifact / "macos-arm64/Headers/ghostty.h"
        header.unlink()
        header.symlink_to(self.manifest)

        with self.assertRaisesRegex(
            self.module.GhosttySurfaceStageError,
            "traverses a symbolic link",
        ):
            self.stage()

    def test_rejects_wrong_product_manifest(self) -> None:
        self.values["architecture"] = "x86_64"
        self._write_manifest()

        with self.assertRaisesRegex(
            self.module.GhosttySurfaceStageError,
            "unexpected architecture",
        ):
            self.stage()

    def test_rejects_destination_outside_the_build_owned_root(self) -> None:
        with self.assertRaisesRegex(
            self.module.GhosttySurfaceStageError,
            "outside the build-owned staging root",
        ):
            self.module.stage_surface(
                self.manifest,
                self.artifact,
                self.root / "outside",
                self.allowed,
            )


if __name__ == "__main__":
    unittest.main()
