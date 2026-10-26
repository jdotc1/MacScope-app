from __future__ import annotations

import copy
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

from Scripts.reconstruction import validate_qualification_product_identity as product_identity

from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.reconstruction_gate_f.schema import (
    candidate_identity_sha256,
    parse_candidate_identity,
)
from Scripts.reconstruction_gate_f.tests import candidate_mapping


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Scripts/reconstruction/validate_qualification_product_identity.py"


def canonical_line(value: object) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


class QualificationBuildFixture:
    integration_ref = "refs/remotes/gitfox-local/feature/qualification-candidate"
    commit = "a" * 40
    tree = "b" * 40

    def __init__(
        self, root: Path, *, mode: str = "smoke", configuration: str | None = None
    ) -> None:
        self.mode = mode
        self.expected_configuration = configuration
        self.run = root / "work/runs/run.fixture"
        self.source = self.run / "source"
        self.derived = self.run / "DerivedData"
        self.cache = root / "work/dependencies"
        self.dependencies = self.run / "dependencies"
        self.receipt = self.run / "QUALIFICATION_INPUTS.json"
        for directory in (self.source, self.derived, self.cache, self.dependencies):
            directory.mkdir(parents=True, exist_ok=True)

        self.zig = self.source / "ThirdParty/Zig/zig-0.16.0/zig"
        self._write(self.zig, b"#!/bin/sh\nexit 0\n", executable=True)
        self.sealed_ghostty_source = self.source / "ThirdParty/GhosttyVT/Source"
        self.sealed_ghostty_source.mkdir(parents=True)
        self.ghostty = self.dependencies / "ghostty-vt-qualification"
        self.vt_manifest = self.ghostty / "zig-out/lib/.macscope-ghostty-vt-manifest"
        self.ghostty_vt = self.dependencies / "ghostty-vt"
        vt_payloads = {
            "artifacts/lib/libghostty-vt.0.1.0.dylib": b"ghostty vt dylib\n",
            "artifacts/include/ghostty/vt.h": b"ghostty vt header\n",
            "artifacts/include/module.modulemap": b"ghostty vt module map\n",
        }
        for relative, payload in vt_payloads.items():
            self._write(self.ghostty_vt / relative, payload)
        vt_manifest_bytes = (
            "schema=5\n"
            f"dylib_sha256={hashlib.sha256(vt_payloads['artifacts/lib/libghostty-vt.0.1.0.dylib']).hexdigest()}\n"
            f"umbrella_header_sha256={hashlib.sha256(vt_payloads['artifacts/include/ghostty/vt.h']).hexdigest()}\n"
            f"module_map_sha256={hashlib.sha256(vt_payloads['artifacts/include/module.modulemap']).hexdigest()}\n"
        ).encode()
        self._write(
            self.ghostty_vt / "artifacts/lib/.macscope-ghostty-vt-manifest",
            vt_manifest_bytes,
        )
        self._write(self.vt_manifest, vt_manifest_bytes)
        self._write(
            self.ghostty / "zig-out/lib/libghostty-vt.dylib",
            vt_payloads["artifacts/lib/libghostty-vt.0.1.0.dylib"],
        )
        (self.ghostty_vt / "artifacts/lib/libghostty-vt.dylib").symlink_to(
            "libghostty-vt.0.1.0.dylib"
        )
        self.surface = self.dependencies / "ghostty-surface/GhosttySurface"
        self.surface_artifact = self.surface / "macos/GhosttyKit.xcframework"
        self.surface_artifact.mkdir(parents=True)
        self.surface_manifest = self.surface / "macos/.macscope-ghostty-surface-manifest"
        self.sleigh = (
            self.dependencies
            / "sleigh-native-source/SleighNativeSource/materialization"
        )
        self.sleigh_manifest = self.sleigh / "MATERIALIZATION.json"
        self._write(self.sleigh_manifest, b'{"fixture":"sleigh"}\n')

        self.staged_payloads = {
            "libghostty-internal.a": b"archive\n",
            "Headers/ghostty.h": b"header\n",
            "Headers/module.modulemap": b"module map\n",
        }
        surface_values = {
            "schema": "3",
            "archive_sha256": hashlib.sha256(
                self.staged_payloads["libghostty-internal.a"]
            ).hexdigest(),
            "header_sha256": hashlib.sha256(
                self.staged_payloads["Headers/ghostty.h"]
            ).hexdigest(),
            "module_map_sha256": hashlib.sha256(
                self.staged_payloads["Headers/module.modulemap"]
            ).hexdigest(),
        }
        self._write(
            self.surface_manifest,
            "".join(f"{key}={value}\n" for key, value in surface_values.items()).encode(),
        )
        source_files = {"files": [], "schema_version": 2}
        source_files_bytes = canonical_line(source_files)
        self._write(self.source / "SOURCE_FILES.json", source_files_bytes)
        self.source_identity = {
            "canonical_integration_commit": self.commit,
            "canonical_integration_ref": self.integration_ref,
            "canonical_remote_url": "https://github.com/jdotc1/MacScope-app.git",
            "dependency_contract": {},
            "git_head_commit": self.commit,
            "git_head_tree": self.tree,
            "git_parent_commits": ["c" * 40],
            "repository_clean": True,
            "schema_version": 2,
            "source_file_count": 0,
            "source_files_sha256": hashlib.sha256(source_files_bytes).hexdigest(),
        }
        self._write(
            self.source / "SOURCE_PROVENANCE.json",
            canonical_line(self.source_identity),
        )
        self.receipt_document = {
            "build_source_root": str(self.source),
            "dependency_cache_root": str(self.cache),
            "dependency_network_allowed": False,
            "dependency_network_used": False,
            "ghostty_artifact_manifest_sha256": hashlib.sha256(
                self.vt_manifest.read_bytes()
            ).hexdigest(),
            "ghostty_source_dir": str(self.ghostty),
            "ghostty_surface_artifact_root": str(self.surface_artifact),
            "ghostty_surface_manifest_sha256": hashlib.sha256(
                self.surface_manifest.read_bytes()
            ).hexdigest(),
            "ghostty_surface_source_dir": str(self.surface),
            "mode": mode,
            "schema_version": 4,
            "sleigh_materialization_manifest_sha256": hashlib.sha256(
                self.sleigh_manifest.read_bytes()
            ).hexdigest(),
            "sleigh_materialization_root": str(self.sleigh),
            "source_identity": self.source_identity,
            "zig_executable": str(self.zig),
        }
        self.write_receipt()
        self.configuration = configuration or (
            "Release" if mode in {"release", "full-test"} else "Debug"
        )
        self.staged_root = (
            self.derived
            / "Build/Intermediates.noindex/MacScope.build/MacScopeGhosttySurface"
        )
        for relative, payload in self.staged_payloads.items():
            self._write(self.staged_root / relative, payload)
        descriptor = {
            "leaves": [
                {
                    "role": role,
                    "relative_path": relative,
                    "sha256": surface_values[digest_field],
                }
                for role, relative, digest_field in (
                    ("archive", "libghostty-internal.a", "archive_sha256"),
                    ("header", "Headers/ghostty.h", "header_sha256"),
                    ("module_map", "Headers/module.modulemap", "module_map_sha256"),
                )
            ],
            "schema_version": 1,
            "source_manifest_sha256": hashlib.sha256(
                self.surface_manifest.read_bytes()
            ).hexdigest(),
        }
        self.staged_descriptor = self.staged_root / "STAGED_GHOSTTY_SURFACE.json"
        self._write(self.staged_descriptor, canonical_line(descriptor))
        self.app = (
            self.derived
            / f"Build/Products/{self.configuration}/MacScope.app"
        )
        info = self.app / "Contents/Info.plist"
        info.parent.mkdir(parents=True, exist_ok=True)
        with info.open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleExecutable": "MacScope",
                    "CFBundleIdentifier": "org.macscope.app",
                },
                stream,
            )
        self._write(
            self.app / "Contents/MacOS/MacScope",
            b"qualification executable\n",
            executable=True,
        )
        self.xcode_vt = (
            self.derived
            / f"Build/Intermediates.noindex/MacScope.build/{self.configuration}/MacScopeApp.build/MacScopeGhosttyVT"
        )
        for relative, payload in vt_payloads.items():
            self._write(self.xcode_vt / relative, payload)
        (self.xcode_vt / "artifacts/lib/libghostty-vt.dylib").symlink_to(
            "libghostty-vt.0.1.0.dylib"
        )
        self._write(
            self.xcode_vt / "artifacts/lib/.macscope-ghostty-vt-manifest",
            vt_manifest_bytes,
        )
        self.bundled_vt = self.app / "Contents/Frameworks/libghostty-vt.dylib"
        self._write(self.bundled_vt, vt_payloads["artifacts/lib/libghostty-vt.0.1.0.dylib"])
        provenance: dict[str, object] = {
            "configuration": self.configuration,
            "git_head_commit": None,
            "git_head_tree": None,
            "qualification_eligible": self.configuration == "Release",
            "repository_clean": False,
            "schema_version": 1,
        }
        if self.configuration == "Release":
            descriptor_bytes = self.staged_descriptor.read_bytes()
            staged_tree = hashlib.sha256()
            staged_files = {
                **self.staged_payloads,
                "STAGED_GHOSTTY_SURFACE.json": descriptor_bytes,
            }
            for relative, payload in sorted(
                staged_files.items(), key=lambda item: os.fsencode(item[0])
            ):
                staged_tree.update(relative.encode())
                staged_tree.update(b"\0")
                staged_tree.update(str(len(payload)).encode())
                staged_tree.update(b"\0")
                staged_tree.update(hashlib.sha256(payload).hexdigest().encode())
                staged_tree.update(b"\0")
            provenance.update(
                {
                    "git_head_commit": self.commit,
                    "git_head_tree": self.tree,
                    "ghostty_source_dir_sha256": hashlib.sha256(
                        os.fsencode(str(self.sealed_ghostty_source))
                    ).hexdigest(),
                    "ghostty_surface_archive_sha256": surface_values[
                        "archive_sha256"
                    ],
                    "ghostty_surface_compilation_condition": "MACSCOPE_FULL_GHOSTTY_SURFACE",
                    "ghostty_surface_header_sha256": surface_values["header_sha256"],
                    "ghostty_surface_module_map_sha256": surface_values[
                        "module_map_sha256"
                    ],
                    "ghostty_surface_source_manifest_sha256": hashlib.sha256(
                        self.surface_manifest.read_bytes()
                    ).hexdigest(),
                    "ghostty_surface_staged_descriptor_relative_path": "STAGED_GHOSTTY_SURFACE.json",
                    "ghostty_surface_staged_descriptor_sha256": hashlib.sha256(
                        descriptor_bytes
                    ).hexdigest(),
                    "ghostty_surface_staged_tree_sha256": staged_tree.hexdigest(),
                    "qualification_eligible": True,
                    "repository_clean": True,
                    "sleigh_materialization_manifest_sha256": self.receipt_document[
                        "sleigh_materialization_manifest_sha256"
                    ],
                    "sleigh_materialization_root_sha256": hashlib.sha256(
                        os.fsencode(str(self.sleigh))
                    ).hexdigest(),
                }
            )
        self.provenance = (
            self.app / "Contents/Resources/MacScopeBuildProvenance.json"
        )
        self._write(self.provenance, canonical_line(provenance))

    @staticmethod
    def _write(path: Path, payload: bytes, *, executable: bool = False) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        if executable:
            path.chmod(0o755)

    def write_receipt(self) -> None:
        self._write(self.receipt, canonical_line(self.receipt_document))

    def arguments(self, command: str) -> list[str]:
        values = [
            command,
            "--receipt",
            str(self.receipt),
            "--run-root",
            str(self.run),
            "--derived-data-root",
            str(self.derived),
            "--build-source-root",
            str(self.source),
            "--dependency-cache-root",
            str(self.cache),
            "--expected-mode",
            self.mode,
            "--expected-integration-ref",
            self.integration_ref,
            "--expected-integration-commit",
            self.commit,
            "--expected-integration-tree",
            self.tree,
        ]
        if command == "validate-build":
            values.extend(("--app-bundle", str(self.app)))
            if self.expected_configuration is not None:
                values.extend(("--expected-configuration", self.expected_configuration))
        return values

    def validate(self, command: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/usr/bin/python3", "-B", str(VALIDATOR), *self.arguments(command)],
            text=True,
            capture_output=True,
            check=False,
        )


class QualificationProductIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "MacScope.app"
        self.native_app = self.root / "MacScopeNativeLive.app"
        self.document = candidate_mapping()
        payloads = {
            "app": b"app",
            "ai-agent-worker": b"ai",
            "native-live-app": b"native-live-app",
            "native-decompiler": b"native",
        }
        layouts = {
            "app": (self.app, "MacScope", "org.macscope.app"),
            "native-live-app": (
                self.native_app,
                "MacScope",
                "org.macscope.app",
            ),
            "ai-agent-worker": (
                self.app / "Contents/XPCServices/AIAgentWorkerXPCService.xpc",
                "AIAgentWorkerXPCService",
                "org.macscope.app.AIAgentWorker",
            ),
            "native-decompiler": (
                self.native_app
                / "Contents/XPCServices/NativeDecompilerXPCService.xpc",
                "NativeDecompilerXPCService",
                "org.macscope.app.NativeDecompiler",
            ),
        }
        import hashlib

        identities = {
            item["identity_id"]: item
            for item in self.document["application"]["qualification_executables"]
        }
        for identity_id, (bundle, executable_name, bundle_id) in layouts.items():
            info = bundle / "Contents/Info.plist"
            executable = bundle / "Contents/MacOS" / executable_name
            info.parent.mkdir(parents=True, exist_ok=True)
            executable.parent.mkdir(parents=True, exist_ok=True)
            with info.open("wb") as stream:
                plistlib.dump(
                    {
                        "CFBundleExecutable": executable_name,
                        "CFBundleIdentifier": bundle_id,
                    },
                    stream,
                )
            executable.write_bytes(payloads[identity_id])
            executable.chmod(0o755)
            identities[identity_id]["bundle_identifier"] = bundle_id
            identities[identity_id]["sha256"] = hashlib.sha256(
                payloads[identity_id]
            ).hexdigest()
        self.candidate = self.root / "candidate.json"
        self.candidate.write_bytes(canonical_bytes(self.document))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_validator(
        self,
        *products: str,
        document: dict[str, object] | None = None,
        app: Path | None = None,
        transaction: tuple[str, str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if document is not None:
            self.candidate.write_bytes(canonical_bytes(document))
        argv = [
            "/usr/bin/python3",
            "-B",
            str(VALIDATOR),
            "--candidate-identity",
            str(self.candidate),
            "--app-bundle",
            str(app or self.app),
        ]
        for product in products:
            argv.extend(("--product", product))
        if transaction is not None:
            digest, commit, tree = transaction
            argv.extend(
                (
                    "--expected-candidate-sha256",
                    digest,
                    "--expected-source-commit",
                    commit,
                    "--expected-source-tree",
                    tree,
                )
            )
        return subprocess.run(argv, text=True, capture_output=True, check=False)

    def test_accepts_the_exact_named_debug_products(self) -> None:
        regular = self.run_validator(
            "app",
            "ai-agent-worker",
        )
        self.assertEqual(regular.returncode, 0, regular.stderr)
        self.assertIn(
            "verified qualification products: app, ai-agent-worker",
            regular.stdout,
        )
        native = self.run_validator(
            "native-live-app",
            "native-decompiler",
            app=self.native_app,
        )
        self.assertEqual(native.returncode, 0, native.stderr)
        self.assertIn(
            "verified qualification products: native-live-app, native-decompiler",
            native.stdout,
        )

    def test_rejects_cross_family_test_host_substitution(self) -> None:
        regular_as_native = self.run_validator("native-live-app", app=self.app)
        self.assertEqual(regular_as_native.returncode, 1)
        self.assertIn("native-live-app", regular_as_native.stderr)
        self.assertIn("executable mismatch", regular_as_native.stderr)

        native_as_regular = self.run_validator("app", app=self.native_app)
        self.assertEqual(native_as_regular.returncode, 1)
        self.assertIn("app", native_as_regular.stderr)
        self.assertIn("executable mismatch", native_as_regular.stderr)

    def test_rejects_executable_or_bundle_identity_drift(self) -> None:
        worker = (
            self.app
            / "Contents/XPCServices/AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService"
        )
        worker.write_bytes(b"drift")
        worker.chmod(0o755)
        digest_drift = self.run_validator("app", "ai-agent-worker")
        self.assertEqual(digest_drift.returncode, 1)
        self.assertIn("ai-agent-worker", digest_drift.stderr)
        self.assertIn("executable mismatch", digest_drift.stderr)

        worker.write_bytes(b"ai")
        worker.chmod(0o755)
        info = worker.parents[1] / "Info.plist"
        with info.open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleExecutable": "AIAgentWorkerXPCService",
                    "CFBundleIdentifier": "com.example.Drift",
                },
                stream,
            )
        bundle_drift = self.run_validator("ai-agent-worker")
        self.assertEqual(bundle_drift.returncode, 1)
        self.assertIn("bundle identifier mismatch", bundle_drift.stderr)

    def test_rejects_release_identity_substituted_for_debug_qualification(self) -> None:
        document = copy.deepcopy(self.document)
        application = document["application"]
        identity = next(
            item
            for item in application["qualification_executables"]
            if item["identity_id"] == "app"
        )
        identity["sha256"] = application["executable_sha256"]
        result = self.run_validator("app", document=document)
        self.assertEqual(result.returncode, 1)
        self.assertIn("qualification product executable mismatch", result.stderr)

    def test_rejects_symlinked_product_components(self) -> None:
        info = self.app / "Contents/Info.plist"
        original = self.root / "Info.plist"
        info.replace(original)
        info.symlink_to(original)
        result = self.run_validator("app")
        self.assertEqual(result.returncode, 1)
        self.assertIn("non-symlink regular file", result.stderr)

    def test_rejects_candidate_indirection_and_noncanonical_json(self) -> None:
        original = self.root / "candidate-original.json"
        self.candidate.replace(original)
        self.candidate.symlink_to(original)
        symlinked = self.run_validator("app")
        self.assertEqual(symlinked.returncode, 1)
        self.assertIn("safely open candidate identity", symlinked.stderr)

        self.candidate.unlink()
        os.link(original, self.candidate)
        hardlinked = self.run_validator("app")
        self.assertEqual(hardlinked.returncode, 1)
        self.assertIn("single-link file", hardlinked.stderr)

        self.candidate.unlink()
        original.unlink()
        self.candidate.write_text(json.dumps(self.document, indent=2), encoding="utf-8")
        noncanonical = self.run_validator("app")
        self.assertEqual(noncanonical.returncode, 1)
        self.assertIn("not canonical JSON", noncanonical.stderr)

        self.candidate.write_bytes(b'{"schema_version":3,"schema_version":3}')
        duplicate = self.run_validator("app")
        self.assertEqual(duplicate.returncode, 1)
        self.assertIn("not canonical JSON", duplicate.stderr)

    def test_binds_candidate_digest_commit_and_tree_as_one_transaction(self) -> None:
        candidate, issues = parse_candidate_identity(self.document)
        self.assertIsNotNone(candidate)
        self.assertEqual(issues, ())
        assert candidate is not None
        transaction = (
            candidate_identity_sha256(candidate),
            candidate.source.commit,
            candidate.source.tree,
        )

        accepted = self.run_validator("app", transaction=transaction)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        wrong_digest = self.run_validator(
            "app",
            transaction=("0" * 64, transaction[1], transaction[2]),
        )
        self.assertEqual(wrong_digest.returncode, 1)
        self.assertIn("differs from the transaction token", wrong_digest.stderr)

        wrong_commit = self.run_validator(
            "app",
            transaction=(transaction[0], "e" * 40, transaction[2]),
        )
        self.assertEqual(wrong_commit.returncode, 1)
        self.assertIn("source commit differs", wrong_commit.stderr)

    def test_rejects_bundle_executable_declaration_drift(self) -> None:
        info = self.app / "Contents/Info.plist"
        with info.open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleExecutable": "SubstitutedMacScope",
                    "CFBundleIdentifier": "org.macscope.app",
                },
                stream,
            )

        result = self.run_validator("app")

        self.assertEqual(result.returncode, 1)
        self.assertIn("does not name the expected executable", result.stderr)


class QualificationRunnerAuthorityTests(unittest.TestCase):
    def test_submodule_manifest_preserves_input_binding_and_closed_metadata(self) -> None:
        commit_object = b"tree " + b"d" * 40 + b"\n\nfixture\n"
        commit_oid = hashlib.sha1(
            b"commit " + str(len(commit_object)).encode() + b"\0" + commit_object
        ).hexdigest()
        submodule = {
            "path": "ThirdParty/Lumen/Source",
            "url": "https://github.com/example/lumen.git",
            "commit_oid": commit_oid,
            "tree_oid": "d" * 40,
            "commit_object_base64": base64.b64encode(commit_object).decode(),
        }
        for mutation in ("valid", "unknown", "empty", "drift", "record-extra", "old-package", "commit-drift", "missing-modules"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                fixture = QualificationBuildFixture(Path(temporary).resolve())
                document = {"files": [], "schema_version": 2, "submodules": [dict(submodule)]}
                if mutation == "unknown":
                    document["unexpected"] = []
                elif mutation == "empty":
                    document["submodules"] = []
                elif mutation == "record-extra":
                    document["submodules"][0]["unexpected"] = "value"
                elif mutation == "commit-drift":
                    document["submodules"][0]["commit_oid"] = "a" * 40
                elif mutation == "missing-modules":
                    del document["submodules"]
                payload = canonical_line(document)
                (fixture.source / "SOURCE_FILES.json").write_bytes(payload)
                fixture.source_identity["dependency_contract"] = {
                    "source_export_package": {"version": 4 if mutation == "old-package" else 5}
                }
                fixture.source_identity["source_files_sha256"] = hashlib.sha256(payload).hexdigest()
                (fixture.source / "SOURCE_PROVENANCE.json").write_bytes(canonical_line(fixture.source_identity))
                fixture.write_receipt()
                if mutation == "drift":
                    document["submodules"][0]["url"] += "/changed"
                    (fixture.source / "SOURCE_FILES.json").write_bytes(canonical_line(document))
                result = fixture.validate("validate-inputs")
                self.assertEqual(result.returncode, 0 if mutation == "valid" else 1, result.stderr)
                if mutation != "valid":
                    self.assertIn("qualification product identity validation failed: sealed source", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)

    def test_zig_executable_uses_a_bounded_binary_ceiling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve())
            fixture.zig.write_bytes(b"")
            with fixture.zig.open("r+b") as stream:
                stream.truncate(185_346_592)
            fixture.zig.chmod(0o755)

            accepted = fixture.validate("validate-inputs")

            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            with fixture.zig.open("r+b") as stream:
                stream.truncate(192 * 1024 * 1024 + 1)
            rejected = fixture.validate("validate-inputs")

            self.assertEqual(rejected.returncode, 1)
            self.assertIn("Zig executable exceeds its size bound", rejected.stderr)

    def test_validates_the_exact_input_and_debug_build_transaction(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve())

            inputs = fixture.validate("validate-inputs")
            build = fixture.validate("validate-build")

            self.assertEqual(inputs.returncode, 0, inputs.stderr)
            self.assertIn(
                f"MACSCOPE_QUALIFICATION_SOURCE_COMMIT={fixture.commit}",
                inputs.stdout,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            self.assertIn("verified qualification build transaction", build.stdout)
            self.assertIn(
                f"MACSCOPE_QUALIFICATION_GHOSTTY_SURFACE_STAGED_ROOT={fixture.staged_root}",
                build.stdout,
            )

    def test_full_test_without_release_candidate_validates_its_debug_app_only(self) -> None:
        # --release-candidate skip: the qualifier passes Debug for full-test.
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(
                Path(temporary).resolve(), mode="full-test", configuration="Debug"
            )
            accepted = fixture.validate("validate-build")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertIn("/Build/Products/Debug/MacScope.app", accepted.stdout)

            # Without the explicit configuration full-test still requires Release.
            fixture.expected_configuration = None
            rejected = fixture.validate("validate-build")
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("not the exact run-owned Xcode product", rejected.stderr)

        for mode, requested in (("release", "Debug"), ("focused-test", "Release"),
                                ("smoke", "Release")):
            with self.subTest(mode=mode, requested=requested):
                with self.assertRaises(product_identity.ProductIdentityError):
                    product_identity.expected_build_configuration(mode, requested)
        for mode, requested, expected in (
            ("full-test", None, "Release"), ("full-test", "Release", "Release"),
            ("full-test", "Debug", "Debug"), ("release", "Release", "Release"),
            ("focused-test", None, "Debug"), ("smoke", "Debug", "Debug"),
        ):
            with self.subTest(mode=mode, requested=requested):
                self.assertEqual(
                    product_identity.expected_build_configuration(mode, requested), expected
                )

    def test_input_authority_preserves_all_runner_modes(self) -> None:
        for mode in ("prepare", "smoke", "focused-test", "full-test", "release"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                fixture = QualificationBuildFixture(Path(temporary).resolve(), mode=mode)

                result = fixture.validate("validate-inputs")

                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_receipt_and_staged_surface_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve())
            fixture.receipt_document["ghostty_surface_artifact_root"] = str(
                fixture.surface_artifact.parent
            )
            fixture.write_receipt()

            receipt_drift = fixture.validate("validate-inputs")

            self.assertEqual(receipt_drift.returncode, 1)
            self.assertIn("differs from the exact consumed path", receipt_drift.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve())
            descriptor = json.loads(fixture.staged_descriptor.read_text(encoding="utf-8"))
            descriptor["source_manifest_sha256"] = "0" * 64
            fixture.staged_descriptor.write_bytes(canonical_line(descriptor))

            descriptor_drift = fixture.validate("validate-build")

            self.assertEqual(descriptor_drift.returncode, 1)
            self.assertIn("does not bind the exact verified leaves", descriptor_drift.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve())
            (fixture.staged_root / "Headers/ghostty.h").write_bytes(b"substitution\n")

            leaf_drift = fixture.validate("validate-build")

            self.assertEqual(leaf_drift.returncode, 1)
            self.assertIn("differs from its source manifest", leaf_drift.stderr)

    def test_release_build_binds_source_dependencies_and_staged_surface(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="release")

            accepted = fixture.validate("validate-build")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            provenance = json.loads(fixture.provenance.read_text(encoding="utf-8"))
            provenance["git_head_commit"] = "0" * 40
            fixture.provenance.write_bytes(canonical_line(provenance))
            rejected = fixture.validate("validate-build")

            self.assertEqual(rejected.returncode, 1)
            self.assertIn(
                "Release provenance git_head_commit differs",
                rejected.stderr,
            )

    def test_debug_modes_accept_absent_release_only_provenance(self) -> None:
        for mode in ("smoke", "focused-test"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                fixture = QualificationBuildFixture(Path(temporary).resolve(), mode=mode)
                fixture.provenance.unlink()
                accepted = fixture.validate("validate-build")
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                self.assertFalse(fixture.provenance.exists())
                self.assertEqual(fixture.configuration, "Debug")

    def test_release_and_full_test_still_require_provenance(self) -> None:
        for mode in ("release", "full-test"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                fixture = QualificationBuildFixture(Path(temporary).resolve(), mode=mode)
                fixture.provenance.unlink()
                rejected = fixture.validate("validate-build")
                self.assertEqual(rejected.returncode, 1)
                self.assertIn("qualification build provenance", rejected.stderr)

    def test_debug_present_provenance_accepts_exact_source_identity_without_release_eligibility(self) -> None:
        for mode in ("smoke", "focused-test"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                fixture = QualificationBuildFixture(Path(temporary).resolve(), mode=mode)
                document = json.loads(fixture.provenance.read_bytes())
                document.update(git_head_commit=fixture.commit, git_head_tree=fixture.tree,
                    selected_build_inputs_sha256="c" * 64)
                fixture.provenance.write_bytes(canonical_line(document))
                accepted = fixture.validate("validate-build")
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                self.assertIs(document["qualification_eligible"], False)
                self.assertIs(document["repository_clean"], False)

    def test_debug_present_provenance_retains_legacy_null_identity_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="focused-test")
            document = json.loads(fixture.provenance.read_bytes())
            self.assertIsNone(document["git_head_commit"])
            self.assertIsNone(document["git_head_tree"])
            accepted = fixture.validate("validate-build")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_debug_present_provenance_rejects_partial_mismatched_and_malformed_identity(self) -> None:
        for mutation in ("commit-only", "tree-only", "wrong-commit", "wrong-tree",
                         "uppercase", "wrong-type", "missing-tree"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="focused-test")
                document = json.loads(fixture.provenance.read_bytes())
                document.update(git_head_commit=fixture.commit, git_head_tree=fixture.tree)
                if mutation == "commit-only": document["git_head_tree"] = None
                elif mutation == "tree-only": document["git_head_commit"] = None
                elif mutation == "wrong-commit": document["git_head_commit"] = "0" * 40
                elif mutation == "wrong-tree": document["git_head_tree"] = "0" * 40
                elif mutation == "uppercase": document["git_head_commit"] = fixture.commit.upper()
                elif mutation == "wrong-type": document["git_head_tree"] = 0
                else: del document["git_head_tree"]
                fixture.provenance.write_bytes(canonical_line(document))
                rejected = fixture.validate("validate-build")
                self.assertEqual(rejected.returncode, 1)
                self.assertIn("Debug provenance source identity differs", rejected.stderr)

    def test_exact_debug_source_identity_does_not_admit_release_flags(self) -> None:
        for field in ("qualification_eligible", "repository_clean"):
            for value in (True, 0, None):
                with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as temporary:
                    fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="focused-test")
                    document = json.loads(fixture.provenance.read_bytes())
                    document.update(git_head_commit=fixture.commit, git_head_tree=fixture.tree)
                    document[field] = value
                    fixture.provenance.write_bytes(canonical_line(document))
                    rejected = fixture.validate("validate-build")
                    self.assertEqual(rejected.returncode, 1)
                    self.assertIn("Debug provenance must remain Release-ineligible", rejected.stderr)

    def test_debug_present_provenance_cannot_claim_release_authority(self) -> None:
        for changed in ({"configuration": "Release"}, {"qualification_eligible": True},
                        {"repository_clean": True}, {"git_head_commit": "a" * 40},
                        {"git_head_tree": "b" * 40}):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="focused-test")
                document = json.loads(fixture.provenance.read_bytes())
                document.update(changed)
                fixture.provenance.write_bytes(canonical_line(document))
                rejected = fixture.validate("validate-build")
                self.assertEqual(rejected.returncode, 1)
                self.assertIn("provenance", rejected.stderr)

    def test_debug_symlink_provenance_is_not_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="focused-test")
            fixture.provenance.unlink()
            fixture.provenance.symlink_to(fixture.provenance.parent / "absent.json")
            rejected = fixture.validate("validate-build")
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("provenance", rejected.stderr)

    def test_debug_absence_is_rechecked_after_other_identity_fences(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="focused-test")
            payload = fixture.provenance.read_bytes()
            fixture.provenance.unlink()
            original = product_identity._require_unchanged

            def inject(snapshot, *, label):
                if label == "qualification app Info.plist" and not fixture.provenance.exists():
                    fixture.provenance.write_bytes(payload)
                return original(snapshot, label=label)

            arguments = product_identity._parse_runner_arguments(fixture.arguments("validate-build"))
            with mock.patch.object(product_identity, "_require_unchanged", side_effect=inject):
                with self.assertRaisesRegex(product_identity.ProductIdentityError, "appeared during"):
                    product_identity.validate_qualification_build(arguments)

    def test_accepts_ordinary_staged_ghostty_vt_without_versioned_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="release")
            library = fixture.xcode_vt / "artifacts/lib"
            consumer = library / "libghostty-vt.dylib"
            consumer.unlink()
            (library / "libghostty-vt.0.1.0.dylib").rename(consumer)

            accepted = fixture.validate("validate-build")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_rejects_staged_ghostty_vt_drift_even_with_valid_versioned_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="release")
            consumer = fixture.xcode_vt / "artifacts/lib/libghostty-vt.dylib"
            consumer.unlink()
            consumer.write_bytes(b"substituted consumer\n")

            rejected = fixture.validate("validate-build")
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("Xcode Ghostty VT dylib differs", rejected.stderr)

    def test_ghostty_vt_builder_aliases_remain_bounded_and_nofollow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="release")
            library = fixture.xcode_vt / "artifacts/lib"
            consumer = library / "libghostty-vt.dylib"
            major = library / "libghostty-vt.0.dylib"
            versioned = library / "libghostty-vt.0.1.0.dylib"
            consumer.unlink()
            consumer.symlink_to(major.name)
            major.symlink_to(versioned.name)
            accepted = fixture.validate("validate-build")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            for invalid in ("../lib/libghostty-vt.0.1.0.dylib", str(versioned), "other.dylib"):
                with self.subTest(consumer_alias=invalid):
                    consumer.unlink()
                    consumer.symlink_to(invalid)
                    rejected = fixture.validate("validate-build")
                    self.assertEqual(rejected.returncode, 1)
                    self.assertIn("consumer alias differs", rejected.stderr)
            consumer.unlink()
            consumer.symlink_to(major.name)
            major.unlink()
            major.symlink_to("../lib/libghostty-vt.0.1.0.dylib")
            rejected = fixture.validate("validate-build")
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("major-version alias differs", rejected.stderr)

            consumer.unlink()
            consumer.symlink_to(versioned.name)
            versioned.unlink()
            versioned.symlink_to(fixture.bundled_vt)
            rejected = fixture.validate("validate-build")
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("cannot safely open Xcode Ghostty VT dylib", rejected.stderr)

    def test_rejects_xcode_or_bundled_ghostty_vt_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="release")
            fixture.xcode_vt.joinpath("artifacts/include/ghostty/vt.h").write_bytes(b"drift\n")
            rejected = fixture.validate("validate-build")
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("Xcode Ghostty VT product differs", rejected.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            fixture = QualificationBuildFixture(Path(temporary).resolve(), mode="release")
            fixture.bundled_vt.write_bytes(b"drift\n")
            rejected = fixture.validate("validate-build")
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("bundled Ghostty VT dylib", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
