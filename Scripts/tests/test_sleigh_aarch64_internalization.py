from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/dependencies/internalize_sleigh_aarch64_resources.py"
spec = importlib.util.spec_from_file_location("sleigh_aarch64_resources", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SleighAArch64InternalizationTests(unittest.TestCase):
    def test_committed_closure_has_exact_accepted_identity(self) -> None:
        analysis = module.inspect(ROOT / "ThirdParty/SleighNative/AARCH64")
        self.assertEqual(analysis["fileCount"], 29)
        # Re-pinned after the CP1 SME/AMX resources (05b385708) added three
        # .sinc files; matches ThirdParty/SleighNative/PATCHED_RESOURCES.json.
        self.assertEqual(analysis["totalBytes"], 11_398_861)
        self.assertEqual(analysis["treeSha256"], "c7e6f7fc0c4d5228f1073d4e3f0a3b510ab80252784e95869f8c5c26d015aa8d")
        self.assertEqual(set(analysis["criticalFileSha256"]), set(module.CRITICAL_NAMES))

    def test_materializer_is_offline_and_external(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = pathlib.Path(temporary) / "derived" / "sleigh-aarch64"
            manifest = module.materialize(ROOT / "ThirdParty/SleighNative/AARCH64", destination, ROOT)
            self.assertEqual(json.loads((destination / "MATERIALIZATION.json").read_text()), manifest)
            self.assertEqual(len([path for path in (destination / "package").rglob("*") if path.is_file()]), 29)
            self.assertEqual(manifest["upstreamArtifactSha256"], module.ARCHIVE_SHA256)

    def test_existing_destination_and_repository_destination_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            existing = pathlib.Path(temporary) / "existing"
            existing.mkdir()
            with self.assertRaises(module.MaterializationError):
                module.materialize(ROOT / "ThirdParty/SleighNative/AARCH64", existing, ROOT)
        with self.assertRaises(module.MaterializationError):
            module.materialize(ROOT / "ThirdParty/SleighNative/AARCH64", ROOT / "generated", ROOT)

    def test_source_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary) / "source"
            source.mkdir()
            for path in (ROOT / "ThirdParty/SleighNative/AARCH64").iterdir():
                (source / path.name).write_bytes(path.read_bytes())
            (source / module.CRITICAL_NAMES[0]).unlink()
            (source / module.CRITICAL_NAMES[0]).symlink_to("AARCH64.ldefs")
            with self.assertRaises(module.MaterializationError):
                module.inspect(source)
