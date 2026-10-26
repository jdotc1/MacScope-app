#!/usr/bin/env python3
"""Focused filesystem-isolation contracts for installed acceptance admission."""

from __future__ import annotations

import contextlib
import hashlib
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from Scripts.reconstruction import (
    compile_installed_acceptance_gate_plan as compiler,
)
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import native_live_preparation_receipt as preparation
from Scripts.reconstruction import run_installed_acceptance_transaction as transaction
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.tests.test_compile_installed_acceptance_gate_plan import CompilerFixture


SHA256 = "a" * 64
SOURCE_COMMIT = "1" * 40
SOURCE_TREE = "2" * 40
SDK_VERSION = "27.2"


class DriverAdmissionFixture:
    """Filesystem-complete fixture with semantic payload validation stubbed out."""

    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="macscope-installed-acceptance-paths."
        )
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.repository_root = self._directory(self.root / "repository")
        self.run_root = self._directory(self.root / "qualification-run")
        self.build_source_root = self._directory(self.run_root / "source")
        self.dependency_cache_root = self._directory(
            self.root / "dependency-cache"
        )
        self.ghostty_source_root = self._directory(
            self.run_root / "dependencies/ghostty-vt-qualification"
        )
        self.ghostty_surface_source_root = self._directory(
            self.run_root / "dependencies/ghostty-surface/GhosttySurface"
        )
        self.ghostty_surface_artifact_root = self._directory(
            self.ghostty_surface_source_root / "macos/GhosttyKit.xcframework"
        )
        self.sleigh_root = self._directory(
            self.run_root
            / "dependencies/sleigh-native-source/SleighNativeSource/materialization"
        )
        self.zig = self.build_source_root / "ThirdParty/Zig/zig-0.16.0/zig"
        self._file(self.zig, b"fixture zig\n", mode=0o700)

        self.products_root = self._directory(
            self.run_root / "DerivedData/Build/Products"
        )
        debug_root = self._directory(self.products_root / "Debug")
        self.source_app = self._directory(self.products_root / "Release/MacScope.app")
        self.provenance = self.source_app / installer.BUILD_PROVENANCE_RELATIVE_PATH
        self._file(self.provenance, b"sealed provenance\n")
        self.native_xctestrun = (
            self.products_root / f"MacScopeApp_macosx{SDK_VERSION}-arm64.xctestrun"
        )
        self._file(self.native_xctestrun, b"native xctestrun\n")
        self.installed_ui_xctestrun = (
            self.products_root
            / f"MacScopeInstalledAppUITests_macosx{SDK_VERSION}-arm64.xctestrun"
        )
        self._file(self.installed_ui_xctestrun, b"installed UI xctestrun\n")
        self.installed_ui_runner = self._directory(
            debug_root / "MacScopeInstalledAppUITests-Runner.app"
        )
        self.installed_ui_bundle = self._directory(
            self.installed_ui_runner
            / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
        )

        self.candidate_root = self._directory(
            self.run_root / "candidate-artifacts"
        )
        self.candidate_identity = self.candidate_root / "candidate.json"
        self._file(self.candidate_identity, b'{"schema_version":3}')
        self.native_preparation = (
            self.candidate_root / transaction.PREPARATION_RECEIPT_NAME
        )
        self._file(self.native_preparation, b'{"schema_version":2}')
        self.installed_ui_preparation = (
            self.candidate_root / transaction.INSTALLED_UI_PREPARATION_RECEIPT_NAME
        )
        self._file(self.installed_ui_preparation, b'{"schema_version":2}')

        self.qualification_receipt = self.run_root / "QUALIFICATION_INPUTS.json"
        self._file(
            self.qualification_receipt,
            canonical_bytes(self._qualification_document()) + b"\n",
        )
        self.developer_dir = self._directory(
            self.root / "Xcode.app/Contents/Developer"
        )
        self.installed_parent = self._directory(self.root / "Applications")
        self.installed_app = self._directory(
            self.installed_parent / "MacScope.app"
        )
        self.work_root = self._directory(self.root / "acceptance-work")

    def close(self) -> None:
        self.temporary.cleanup()

    def __enter__(self) -> DriverAdmissionFixture:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    @staticmethod
    def _directory(path: Path, *, mode: int = 0o700) -> Path:
        path.mkdir(parents=True, exist_ok=False)
        path.chmod(mode)
        return path

    @staticmethod
    def _file(path: Path, payload: bytes, *, mode: int = 0o600) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        path.chmod(mode)
        return path

    def _qualification_document(self) -> dict[str, object]:
        return {
            "build_source_root": str(self.build_source_root),
            "dependency_cache_root": str(self.dependency_cache_root),
            "dependency_network_allowed": False,
            "dependency_network_used": False,
            "ghostty_artifact_manifest_sha256": "3" * 64,
            "ghostty_source_dir": str(self.ghostty_source_root),
            "ghostty_surface_artifact_root": str(
                self.ghostty_surface_artifact_root
            ),
            "ghostty_surface_manifest_sha256": "4" * 64,
            "ghostty_surface_source_dir": str(self.ghostty_surface_source_root),
            "mode": "full-test",
            "schema_version": 4,
            "sleigh_materialization_manifest_sha256": "5" * 64,
            "sleigh_materialization_root": str(self.sleigh_root),
            "source_identity": {
                "canonical_integration_commit": SOURCE_COMMIT,
                "canonical_integration_ref": "refs/remotes/gitfox-local/test",
                "canonical_remote_url": str(self.root / "remote.git"),
                "dependency_contract": {},
                "git_head_commit": SOURCE_COMMIT,
                "git_head_tree": SOURCE_TREE,
                "git_parent_commits": [],
                "repository_clean": True,
                "schema_version": 2,
                "source_file_count": 1,
                "source_files_sha256": "6" * 64,
            },
            "zig_executable": str(self.zig),
        }

    def _preparation_documents(self) -> tuple[dict[str, object], dict[str, object]]:
        source = {
            "commit": SOURCE_COMMIT,
            "tree": SOURCE_TREE,
        }
        toolchain = {
            "developer_dir": str(self.developer_dir),
            "sdk_version": SDK_VERSION,
        }
        native = {
            "artifacts": {
                "app": {"path": str(self.source_app)},
                "xctestrun": {"path": str(self.native_xctestrun)},
            },
            "build": {
                "preparation_mode": preparation.NATIVE_LIVE_PREPARATION_MODE
            },
            "receipt_kind": preparation.RECEIPT_KIND,
            "schema_version": preparation.SCHEMA_VERSION,
            "source": source,
            "toolchain": toolchain,
        }
        installed_ui = {
            "artifacts": {
                "app": {"path": str(self.source_app)},
                "ui_runner": {"path": str(self.installed_ui_runner)},
                "ui_test_bundle": {"path": str(self.installed_ui_bundle)},
                "xctestrun": {"path": str(self.installed_ui_xctestrun)},
            },
            "build": {
                "preparation_mode": preparation.INSTALLED_UI_PREPARATION_MODE
            },
            "receipt_kind": preparation.RECEIPT_KIND,
            "schema_version": preparation.SCHEMA_VERSION,
            "source": source,
            "toolchain": toolchain,
        }
        return native, installed_ui

    def arguments(
        self,
        *,
        work_root: Path | None = None,
        result_output: Path | None = None,
        candidate_root: Path | None = None,
        qualification_receipt: Path | None = None,
        installed_app: Path | None = None,
    ) -> SimpleNamespace:
        selected_work = work_root or self.work_root
        return SimpleNamespace(
            gate_plan_compiler=transaction.EXPECTED_GATE_PLAN_COMPILER,
            qualification_receipt=(
                qualification_receipt or self.qualification_receipt
            ),
            qualification_run_id="path-isolation",
            qualification_run_nonce="7" * 64,
            predecessor_observations_sha256="8" * 64,
            candidate_artifact_root=candidate_root or self.candidate_root,
            work_root=selected_work,
            installed_app=installed_app or self.installed_app,
            begin_timeout_seconds=1.0,
            compiler_timeout_seconds=1.0,
            report_timeout_seconds=1.0,
            commit_timeout_seconds=1.0,
            rollback_timeout_seconds=1.0,
            result_output=(
                result_output
                if result_output is not None
                else selected_work / transaction.RESULT_NAME
            ),
        )

    def bind(self, **overrides: object) -> transaction.BoundRequest:
        native, installed_ui = self._preparation_documents()
        source_authority = SimpleNamespace(
            build_provenance_sha256=hashlib.sha256(
                self.provenance.read_bytes()
            ).hexdigest(),
            candidate_identity_sha256=SHA256,
        )
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(transaction, "REPOSITORY_ROOT", self.repository_root)
            )
            stack.enter_context(
                mock.patch.object(
                    transaction,
                    "_trusted_system_python",
                    return_value=Path(sys.executable).resolve(strict=True),
                )
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.preparation,
                    "parse_document",
                    side_effect=(native, installed_ui),
                )
            )
            stack.enter_context(
                mock.patch.object(transaction.preparation, "validate_prepared")
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.installer,
                    "_load_source_authority",
                    return_value=source_authority,
                )
            )
            return transaction._bind_request(
                self.arguments(**overrides), allow_test_destination=True
            )


class InstalledAcceptancePathIsolationTests(unittest.TestCase):
    def test_valid_request_binds_exact_governed_direct_children(self) -> None:
        with DriverAdmissionFixture() as fixture:
            request = fixture.bind()
            expected = {
                request.artifact_root: transaction.INSTALLER_ARTIFACT_ROOT_NAME,
                request.evidence_root: transaction.GATE_EVIDENCE_ROOT_NAME,
                request.qualification_root: transaction.QUALIFICATION_ROOT_NAME,
                request.result_output.path: transaction.RESULT_NAME,
            }
            for path, basename in expected.items():
                with self.subTest(path=path):
                    self.assertEqual(path.parent, fixture.work_root)
                    self.assertEqual(path.name, basename)
                    self.assertEqual(path, fixture.work_root / basename)
                    self.assertFalse(os.path.lexists(path))
            self.assertEqual(
                request.gate_plan_path,
                request.evidence_root / transaction.GATE_PLAN_NAME,
            )
            self.assertEqual(
                stat.S_IMODE(fixture.work_root.lstat().st_mode), 0o700
            )
            self.assertEqual(tuple(fixture.work_root.iterdir()), ())

    def test_work_root_rejects_nonempty_nonprivate_and_noncanonical_inputs(self) -> None:
        with DriverAdmissionFixture() as fixture:
            nonempty = fixture._directory(fixture.root / "nonempty-work")
            fixture._file(nonempty / "unexpected", b"x")
            with self.assertRaisesRegex(transaction.TransactionError, "empty"):
                fixture.bind(work_root=nonempty)

            nonprivate = fixture._directory(
                fixture.root / "nonprivate-work", mode=0o755
            )
            with self.assertRaisesRegex(transaction.TransactionError, "private|mode"):
                fixture.bind(work_root=nonprivate)

            canonical = fixture._directory(fixture.root / "canonical-work")
            alias = fixture.root / "work-alias"
            alias.symlink_to(canonical, target_is_directory=True)
            with self.assertRaisesRegex(
                transaction.TransactionError, "symlink|symbolic|canonical"
            ):
                fixture.bind(work_root=alias)

            real_parent = fixture._directory(fixture.root / "real-parent")
            nested = fixture._directory(real_parent / "nested-work")
            parent_alias = fixture.root / "parent-alias"
            parent_alias.symlink_to(real_parent, target_is_directory=True)
            with self.assertRaisesRegex(
                transaction.TransactionError, "symlink|symbolic|canonical"
            ):
                fixture.bind(work_root=parent_alias / nested.name)

    def test_work_root_is_disjoint_from_every_protected_authority(self) -> None:
        with DriverAdmissionFixture() as fixture:
            protected_work_roots = {
                "repository": fixture._directory(
                    fixture.repository_root / "acceptance-work"
                ),
                "candidate": fixture._directory(
                    fixture.candidate_root / "acceptance-work"
                ),
                "source app": fixture._directory(
                    fixture.source_app / "acceptance-work"
                ),
                "installed destination": fixture._directory(
                    fixture.installed_app / "acceptance-work"
                ),
                "dependency cache": fixture.dependency_cache_root,
                "Ghostty dependency": fixture.ghostty_source_root,
                "SLEIGH dependency": fixture.sleigh_root,
                "qualification receipt authority": fixture._directory(
                    fixture.run_root / "acceptance-work"
                ),
            }
            for label, work_root in protected_work_roots.items():
                with self.subTest(label=label, work_root=work_root):
                    self.assertEqual(tuple(work_root.iterdir()), ())
                    with self.assertRaisesRegex(
                        transaction.TransactionError,
                        "disjoint|overlap|qualification|dependency",
                    ):
                        fixture.bind(work_root=work_root)

    def test_overlap_helpers_reject_ancestors_descendants_and_identity(self) -> None:
        with DriverAdmissionFixture() as fixture:
            authorities = (
                fixture.repository_root,
                fixture.candidate_root,
                fixture.source_app,
                fixture.installed_app,
                fixture.dependency_cache_root,
                fixture.ghostty_source_root,
                fixture.ghostty_surface_source_root,
                fixture.ghostty_surface_artifact_root,
                fixture.sleigh_root,
                fixture.qualification_receipt,
            )
            for authority in authorities:
                with self.subTest(authority=authority):
                    self.assertTrue(transaction._path_related(authority, authority))
                    self.assertTrue(
                        transaction._path_related(authority.parent, authority)
                    )
                    self.assertTrue(
                        compiler._paths_overlap(authority, authority / "descendant")
                    )
                    self.assertFalse(
                        transaction._path_related(fixture.work_root, authority)
                    )

    def test_result_output_rejects_depth_traversal_alias_and_case_variants(self) -> None:
        with DriverAdmissionFixture() as fixture:
            rejected = {
                "nested": fixture.work_root / "nested" / transaction.RESULT_NAME,
                "traversal": (
                    fixture.work_root / "nested/../" / transaction.RESULT_NAME
                ),
                "wrong basename": fixture.work_root / "result.json",
                "case variant": (
                    fixture.work_root
                    / "installedacceptancetransaction.result.json"
                ),
            }
            for label, result in rejected.items():
                with self.subTest(label=label, result=result):
                    with self.assertRaisesRegex(
                        transaction.TransactionError, "exactly|canonical|direct child"
                    ):
                        fixture.bind(result_output=result)

    def test_real_output_helpers_enforce_direct_children_and_private_roots(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="macscope-installed-acceptance-output-paths."
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            root.chmod(0o700)
            for name in (
                transaction.INSTALLER_ARTIFACT_ROOT_NAME,
                transaction.GATE_EVIDENCE_ROOT_NAME,
                transaction.QUALIFICATION_ROOT_NAME,
            ):
                path = transaction._create_private_directory(
                    root / name, parent=root, label=name
                )
                self.assertEqual(path, root / name)
                self.assertEqual(stat.S_IMODE(path.lstat().st_mode), 0o700)
                self.assertFalse(path.is_symlink())

            nested_parent = root / "nested"
            nested_parent.mkdir(mode=0o700)
            with self.assertRaisesRegex(transaction.TransactionError, "direct child"):
                transaction._require_absent_path(
                    nested_parent / transaction.RESULT_NAME,
                    parent=root,
                    label="nested result",
                )

    def test_plan_output_is_exact_canonical_evidence_root_child(self) -> None:
        with CompilerFixture() as fixture:
            inputs = compiler._load_inputs(
                compiler.parse_arguments(fixture.arguments())
            )
            self.assertEqual(inputs.output_path, fixture.evidence_root / compiler.PLAN_FILENAME)
            self.assertEqual(inputs.output_path.parent, fixture.evidence_root)
            self.assertEqual(
                inputs.qualification_output_root,
                fixture.work_root / "InstalledAcceptanceQualification.evidence",
            )

        for basename in ("plan.json", compiler.PLAN_FILENAME.swapcase()):
            with self.subTest(basename=basename), CompilerFixture() as fixture:
                arguments = fixture.arguments()
                arguments[arguments.index("--output") + 1] = str(
                    fixture.evidence_root / basename
                )
                with self.assertRaisesRegex(
                    compiler.PlanCompilationError, "exact governed filename"
                ):
                    compiler._load_inputs(compiler.parse_arguments(arguments))

    def test_compiler_absent_path_rejects_depth_traversal_and_symlinked_parent(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="macscope-installed-acceptance-plan-paths."
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            evidence = root / "InstalledAcceptanceGate.evidence"
            evidence.mkdir(mode=0o700)
            plan = evidence / compiler.PLAN_FILENAME
            self.assertEqual(
                compiler._canonical_absent_path(
                    plan,
                    root=evidence,
                    label="plan output",
                    direct_child=True,
                ),
                plan,
            )

            nested = evidence / "nested"
            nested.mkdir(mode=0o700)
            with self.assertRaisesRegex(compiler.PlanCompilationError, "depth"):
                compiler._canonical_absent_path(
                    nested / compiler.PLAN_FILENAME,
                    root=evidence,
                    label="plan output",
                    direct_child=True,
                )

            real_parent = evidence / "real-parent"
            real_parent.mkdir(mode=0o700)
            alias = evidence / "parent-alias"
            alias.symlink_to(real_parent, target_is_directory=True)
            with self.assertRaisesRegex(
                compiler.PlanCompilationError, "symlink|alias|canonical"
            ):
                compiler._canonical_absent_path(
                    alias / "future" / compiler.PLAN_FILENAME,
                    root=evidence,
                    label="plan output",
                )

    def test_authority_files_reject_symlinks_and_hardlinks(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="macscope-installed-acceptance-file-paths."
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            authority = root / "QUALIFICATION_INPUTS.json"
            authority.write_bytes(b"{}\n")
            authority.chmod(0o600)
            alias = root / "receipt-alias.json"
            alias.symlink_to(authority)
            with self.assertRaisesRegex(
                transaction.TransactionError, "symbolic|symlink"
            ):
                transaction._canonical_existing(
                    alias, directory=False, label="qualification receipt"
                )

            hardlink = root / "receipt-hardlink.json"
            os.link(authority, hardlink)
            for helper, error in (
                (transaction._read_stable_file, transaction.TransactionError),
                (compiler._stable_file, compiler.PlanCompilationError),
            ):
                with self.subTest(helper=helper.__module__), self.assertRaisesRegex(
                    error, "ordinary|single|singly linked"
                ):
                    helper(
                        authority,
                        maximum_bytes=1024,
                        label="qualification receipt",
                    )

    def test_authority_wrong_basenames_and_case_variants_fail_closed(self) -> None:
        with DriverAdmissionFixture() as fixture:
            wrong_receipt = fixture.run_root / "qualification.json"
            fixture._file(wrong_receipt, fixture.qualification_receipt.read_bytes())
            wrong_candidate = fixture._directory(
                fixture.run_root / "CandidateArtifacts"
            )
            rejected = (
                {"qualification_receipt": wrong_receipt},
                {
                    "qualification_receipt": (
                        fixture.run_root / "qualification_inputs.json"
                    )
                },
                {"candidate_root": wrong_candidate},
                {"installed_app": fixture.installed_parent / "Macscope.app"},
            )
            for overrides in rejected:
                with self.subTest(overrides=overrides), self.assertRaises(
                    transaction.TransactionError
                ):
                    fixture.bind(**overrides)


if __name__ == "__main__":
    unittest.main()
