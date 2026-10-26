#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
TOOL = REPOSITORY_ROOT / "Scripts/qualification/dependency_cache.py"


def canonical(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"


class QualificationDependencyCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.source_files = self.root / "SOURCE_FILES.json"
        self.external = self.root / "tool"
        self.external.write_text("tool-v1\n", encoding="utf-8")
        self._write_source_manifest("app-v1")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_source_manifest(self, app_payload: str) -> None:
        records = []
        for path, payload in sorted(
            {
                "App/main.swift": app_payload,
                "Scripts/dependency-builder.sh": "builder-v1",
                "ThirdParty/Dependency/input.txt": "dependency-v1",
            }.items()
        ):
            encoded = payload.encode()
            records.append(
                {
                    "blob_oid": hashlib.sha1(b"blob " + str(len(encoded)).encode() + b"\0" + encoded).hexdigest(),
                    "mode": "100644",
                    "path": path,
                    "sha256": hashlib.sha256(encoded).hexdigest(),
                    "size": len(encoded),
                }
            )
        self.source_files.write_text(
            canonical({"files": records, "schema_version": 2}), encoding="utf-8"
        )

    def _run(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/usr/bin/python3", "-B", str(TOOL), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )

    def _key(self, *, payload_layout: str = "fixture-v1") -> str:
        result = self._run(
            "key",
            "--source-files",
            str(self.source_files),
            "--component",
            "fixture",
            "--prefix",
            "Scripts/dependency-builder.sh",
            "--prefix",
            "ThirdParty/Dependency",
            "--value",
            "configuration=release",
            "--value",
            f"payload-layout={payload_layout}",
            "--external-file",
            f"compiler={self.external}",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_key_ignores_unrelated_app_change_but_tracks_dependency_and_tool_inputs(self) -> None:
        first = self._key()
        self._write_source_manifest("app-v2")
        self.assertEqual(self._key(), first)

        self.external.write_text("tool-v2\n", encoding="utf-8")
        self.assertNotEqual(self._key(), first)
        self.external.write_text("tool-v1\n", encoding="utf-8")
        self.assertNotEqual(self._key(payload_layout="fixture-v2"), first)

    def _add_submodule_metadata(self) -> None:
        # A real Git commit object encoding, independent of the producer helper.
        commit = ("tree " + "b" * 40 + "\nauthor Fixture <fixture@example.invalid> 1 +0000\n"
                  "committer Fixture <fixture@example.invalid> 1 +0000\n\nPinned fixture\n").encode()
        record = {
            "path": "ThirdParty/Lumen", "url": "https://github.com/jdotc1/Lumen.git",
            "commit_oid": hashlib.sha1(b"commit " + str(len(commit)).encode() + b"\0" + commit).hexdigest(),
            "tree_oid": "b" * 40, "commit_object_base64": base64.b64encode(commit).decode(),
        }
        manifest = json.loads(self.source_files.read_text())
        manifest["submodules"] = [record]
        self.source_files.write_text(canonical(manifest))

    def test_unrelated_validated_submodule_metadata_preserves_component_cache_key(self) -> None:
        expected = self._key()
        self._add_submodule_metadata()
        self.assertEqual(self._key(), expected)

    def test_submodule_metadata_cannot_bypass_commit_identity_validation(self) -> None:
        self._add_submodule_metadata()
        manifest = json.loads(self.source_files.read_text())
        manifest["submodules"][0]["tree_oid"] = "c" * 40
        self.source_files.write_text(canonical(manifest))
        result = self._run("key", "--source-files", str(self.source_files),
                           "--component", "fixture", "--prefix", "ThirdParty/Dependency")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("submodule", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_publish_verify_materialize_and_record_event(self) -> None:
        key = self._key()
        payload = self.root / "payload"
        (payload / "nested").mkdir(parents=True)
        (payload / "nested/artifact").write_text("artifact\n", encoding="utf-8")
        executable = payload / "runner"
        executable.write_text("#!/bin/sh\n", encoding="utf-8")
        executable.chmod(0o755)
        entry = self.root / "cache/artifacts/v1/fixture" / key

        published = self._run(
            "publish",
            "--entry",
            str(entry),
            "--component",
            "fixture",
            "--key",
            key,
            "--payload",
            str(payload),
        )
        self.assertEqual(published.returncode, 0, published.stderr)
        self.assertFalse(payload.exists())
        self.assertEqual(entry.stat().st_mode & 0o222, 0)

        verified = self._run(
            "verify",
            "--entry",
            str(entry),
            "--component",
            "fixture",
            "--key",
            key,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)

        destination = self.root / "run/dependency"
        materialized = self._run(
            "materialize",
            "--entry",
            str(entry),
            "--component",
            "fixture",
            "--key",
            key,
            "--destination",
            str(destination),
        )
        self.assertEqual(materialized.returncode, 0, materialized.stderr)
        self.assertEqual((destination / "nested/artifact").read_text(), "artifact\n")
        self.assertEqual(destination.stat().st_mode & 0o222, 0)

        receipt = self.root / "run/CACHE_EVENTS.json"
        event = self._run(
            "record-event",
            "--receipt",
            str(receipt),
            "--source-commit",
            "a" * 40,
            "--source-tree",
            "b" * 40,
            "--cache-root",
            str(self.root / "cache"),
            "--component",
            "fixture",
            "--key",
            key,
            "--status",
            "published-miss",
            "--entry",
            str(entry),
            "--run-view",
            str(destination),
        )
        self.assertEqual(event.returncode, 0, event.stderr)
        document = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(document["events"][0]["status"], "published-miss")
        self.assertGreater(document["events"][0]["bytes"], 0)

    def test_changed_cached_output_is_rejected(self) -> None:
        key = self._key()
        payload = self.root / "payload"
        payload.mkdir()
        artifact = payload / "artifact"
        artifact.write_text("original\n", encoding="utf-8")
        entry = self.root / "cache/artifacts/v1/fixture" / key
        self.assertEqual(
            self._run(
                "publish",
                "--entry",
                str(entry),
                "--component",
                "fixture",
                "--key",
                key,
                "--payload",
                str(payload),
            ).returncode,
            0,
        )
        cached = entry / "payload/artifact"
        cached.chmod(0o600)
        cached.write_text("changed\n", encoding="utf-8")
        rejected = self._run(
            "verify",
            "--entry",
            str(entry),
            "--component",
            "fixture",
            "--key",
            key,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("cache entry verification failed", rejected.stderr)

    def test_entry_with_symlinked_ancestor_is_rejected_on_hit_and_miss(self) -> None:
        key = self._key()
        real = self.root / "real-cache"
        real.mkdir()
        indirect = self.root / "indirect-cache"
        indirect.symlink_to(real, target_is_directory=True)
        entry = indirect / "artifacts/v1/fixture" / key
        payload = self.root / "payload"
        payload.mkdir()
        (payload / "artifact").write_text("artifact\n", encoding="utf-8")
        rejected_miss = self._run(
            "publish", "--entry", str(entry), "--component", "fixture",
            "--key", key, "--payload", str(payload),
        )
        self.assertNotEqual(rejected_miss.returncode, 0)
        self.assertIn("indirect ancestor", rejected_miss.stderr)

        direct_entry = real / "artifacts/v1/fixture" / key
        self.assertEqual(
            self._run("publish", "--entry", str(direct_entry), "--component", "fixture",
                      "--key", key, "--payload", str(payload)).returncode,
            0,
        )
        rejected_hit = self._run(
            "verify", "--entry", str(entry), "--component", "fixture", "--key", key,
        )
        self.assertNotEqual(rejected_hit.returncode, 0)
        self.assertIn("indirect ancestor", rejected_hit.stderr)


if __name__ == "__main__":
    unittest.main()
