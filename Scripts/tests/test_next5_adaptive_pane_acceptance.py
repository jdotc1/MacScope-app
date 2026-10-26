from __future__ import annotations

import copy
import os
from pathlib import Path
import stat
import tempfile
import time
import unittest
from unittest import mock

from Scripts import next5_adaptive_pane_acceptance as pane
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    decode_canonical_bytes,
    file_sha256,
)


def _sha(character: str) -> str:
    return character * 64


class FinalCandidateFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.candidate_root = root / "candidate-artifacts"
        self.candidate_root.mkdir()
        self.products_root = root / "qualification/DerivedData/Build/Products"
        self.products_root.mkdir(parents=True)
        self.evidence_root = root / "acceptance-evidence"
        self.evidence_root.mkdir()
        self.final_receipt = root / "FinalLocalCandidate.receipt.json"
        self.plan = self.evidence_root / "InstalledAcceptanceGate.plan.json"
        self.qualification = root / "qualification/QUALIFICATION_INPUTS.json"
        self.preparation = (
            self.candidate_root / "InstalledUIPreparation.receipt.json"
        )
        self.candidate_identity = self.candidate_root / "candidate.json"
        self.prepared_xctestrun = (
            self.products_root
            / "MacScopeInstalledAppUITests_macosx27.0-arm64.xctestrun"
        )
        self.ui_runner = (
            self.products_root
            / "Debug/MacScopeInstalledAppUITests-Runner.app"
        )
        self.test_bundle = (
            self.ui_runner
            / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
        )
        self.source_app = self.products_root / "Release/MacScope.app"
        self.source_commit = "a" * 40
        self.source_tree = "b" * 40
        self.candidate_file_sha256 = _sha("1")
        self.candidate_identity_sha256 = _sha("2")
        self.plan_authority_sha256 = _sha("3")
        self.run_nonce = _sha("4")
        self.run_id = "next5-full-test-fixture"
        self._write(self.qualification, {"fixture": "qualification"})
        self._write(self.preparation, {"fixture": "installed-ui-preparation"})
        self._write(self.plan, {"fixture": "compiled-plan"})
        self.plan_sha256 = file_sha256(self.plan)
        self.plan_document = self._plan_document()
        self.document = self._final_document()
        self.publish_final()

    @staticmethod
    def _write(path: Path, document: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(canonical_bytes(document))

    def _plan_document(self) -> dict[str, object]:
        authority = {
            "application_executable_sha256": _sha("5"),
            "candidate_file_sha256": self.candidate_file_sha256,
            "candidate_identity_path": str(self.candidate_identity),
            "candidate_identity_sha256": self.candidate_identity_sha256,
            "installed_app_path": str(pane.INSTALLED_APP),
            "installed_ui_preparation_receipt_path": str(self.preparation),
            "installed_ui_preparation_receipt_sha256": file_sha256(
                self.preparation
            ),
            "installed_ui_runner_path": str(self.ui_runner),
            "installed_ui_test_bundle_path": str(self.test_bundle),
            "installed_ui_xctestrun_path": str(self.prepared_xctestrun),
            "qualification_receipt_path": str(self.qualification),
            "qualification_receipt_sha256": file_sha256(self.qualification),
            "qualification_run_id": self.run_id,
            "qualification_run_nonce": self.run_nonce,
            "source_app_path": str(self.source_app),
            "source_commit": self.source_commit,
            "source_tree": self.source_tree,
        }
        return {
            "authority": authority,
            "authority_sha256": self.plan_authority_sha256,
            "candidate_artifact_root": str(self.candidate_root),
        }

    def _final_document(self) -> dict[str, object]:
        return {
            "acceptance_gates": [],
            "candidate": {
                "application_bundle_sha256": _sha("6"),
                "application_closed_tree_sha256": _sha("7"),
                "application_executable_sha256": _sha("5"),
                "application_root_mode": 493,
                "identity_file_sha256": self.candidate_file_sha256,
                "identity_path": str(self.candidate_identity),
                "identity_sha256": self.candidate_identity_sha256,
                "provenance_path": str(self.candidate_root / "provenance.json"),
                "provenance_sha256": _sha("8"),
                "source_app_path": str(self.source_app),
            },
            "installation": {
                "acceptance_receipt_path": str(self.root / "acceptance.json"),
                "acceptance_receipt_sha256": _sha("9"),
                "acceptance_produced_at_unix_ns": 2,
                "began_at_unix_ns": 1,
                "commit_authority_path": str(self.root / "commit.json"),
                "commit_authority_sha256": _sha("a"),
                "destination_identity_sha256": _sha("b"),
                "execution_identity_sha256": _sha("c"),
                "exposed_at_unix_ns": 2,
                "installed_app_path": str(pane.INSTALLED_APP),
                "predecessor_digest": None,
                "predecessor_observations_sha256": _sha("d"),
                "pending_state_path_at_begin": str(self.root / "pending.json"),
                "rolled_back": False,
                "source_equality_sha256": _sha("e"),
                "terminal_state_path": str(self.root / "terminal.json"),
                "terminal_state_sha256": _sha("f"),
                "transaction_id": _sha("1"),
                "transaction_nonce": _sha("2"),
                "transaction_phase": "committed",
            },
            "integration": {
                "branch": "feature/next5-integration",
                "commit": self.source_commit,
                "ref": "refs/remotes/next5-local/feature/next5-integration",
                "remote": "next5-local",
                "remote_url": str(self.root / "archive.git"),
                "tree": self.source_tree,
            },
            "produced_at_unix_ns": max(1, time.time_ns() - 1_000_000_000),
            "qualification": {
                "coverage_path": str(self.root / "coverage.json"),
                "coverage_sha256": _sha("3"),
                "dependency_network_allowed": False,
                "dependency_network_used": False,
                "mode": "full-test",
                "receipt_path": str(self.qualification),
                "receipt_sha256": file_sha256(self.qualification),
                "result_bundle_path": str(self.root / "qualification.xcresult"),
                "run_id": self.run_id,
                "run_nonce": self.run_nonce,
                "run_root": str(self.root / "qualification"),
                "source_provenance_sha256": _sha("4"),
            },
            "receipt_kind": pane.final_local.RECEIPT_KIND,
            "result": "passed",
            "schema_version": pane.final_local.SCHEMA_VERSION,
            "scope": {
                "authority": pane.final_local.AUTHORITY_SCOPE,
                "gate_f_claimed": False,
                "online_delivery_claimed": False,
                "post_2026_09_11_proof_claimed": False,
                "public_release_claimed": False,
            },
            "transaction_result": {
                "candidate_artifact_root": str(self.candidate_root),
                "gate_plan_authority_sha256": self.plan_authority_sha256,
                "gate_plan_path": str(self.plan),
                "gate_plan_sha256": self.plan_sha256,
                "installed_task10": {"fixture": "passed"},
                "native_preparation_receipt_path": str(
                    self.candidate_root / "NativeLivePreparation.receipt.json"
                ),
                "native_preparation_receipt_sha256": _sha("5"),
                "native_xctestrun_path": str(
                    self.products_root / "MacScopeApp_macosx27.0-arm64.xctestrun"
                ),
                "native_xctestrun_sha256": _sha("6"),
                "path": str(self.root / "transaction-result.json"),
                "produced_at_unix_ns": 3,
                "sha256": _sha("7"),
                "ws24_aggregate_path": str(self.root / "WS24.json"),
                "ws24_aggregate_sha256": _sha("8"),
            },
        }

    def publish_final(self) -> None:
        self.final_receipt.write_bytes(canonical_bytes(self.document))
        self.final_receipt.chmod(0o600)

    def load(self) -> pane.InstalledAuthority:
        with mock.patch.object(
            pane.gate_plan,
            "load_plan",
            return_value=(copy.deepcopy(self.plan_document), self.plan_sha256),
        ):
            return pane.load_installed_authority(self.final_receipt)


def _summary(**changes: object) -> dict[str, object]:
    value: dict[str, object] = {
        "title": "Test - MacScopeInstalledAppUITests",
        "result": "Passed",
        "totalTestCount": 3,
        "passedTests": 3,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
    }
    value.update(changes)
    return value


def _tests_document(selectors: list[str]) -> dict[str, object]:
    return {
        "testNodes": [
            {
                "nodeType": "UI test bundle",
                "name": "MacScopeInstalledAppUITests",
                "children": [
                    {
                        "nodeType": "Test Suite",
                        "name": "WorkspaceAdaptivePaneInstalledAppUITests",
                        "children": [
                            {
                                "nodeType": "Test Case",
                                "name": selector.rsplit("/", 1)[-1],
                                "nodeIdentifier": selector,
                                "result": "Passed",
                                "children": [],
                            }
                            for selector in selectors
                        ],
                    }
                ],
            }
        ]
    }


class Next5AdaptivePaneAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.fixture = FinalCandidateFixture(self.root)

    def test_final_receipt_derives_and_cross_binds_every_execution_authority(self) -> None:
        authority = self.fixture.load()
        self.assertEqual(authority.installed_app, Path("/Applications/MacScope.app"))
        self.assertEqual(authority.source_commit, self.fixture.source_commit)
        self.assertEqual(authority.source_tree, self.fixture.source_tree)
        self.assertEqual(authority.candidate_identity, self.fixture.candidate_identity)
        self.assertEqual(authority.prepared_xctestrun, self.fixture.prepared_xctestrun)
        self.assertEqual(authority.test_bundle, self.fixture.test_bundle)
        self.assertEqual(authority.ui_runner, self.fixture.ui_runner)
        self.assertEqual(authority.qualification_receipt.path, self.fixture.qualification)
        self.assertEqual(authority.preparation_receipt.path, self.fixture.preparation)

    def test_wrong_installed_app_path_is_rejected_before_plan_execution(self) -> None:
        installation = self.fixture.document["installation"]
        assert isinstance(installation, dict)
        installation["installed_app_path"] = str(self.root / "MacScope.app")
        self.fixture.publish_final()
        with self.assertRaisesRegex(
            pane.AdaptivePaneAcceptanceError,
            "committed /Applications installation",
        ):
            self.fixture.load()

    def test_final_receipt_symlink_and_hardlink_are_rejected(self) -> None:
        symlink_root = self.root / "symlink"
        symlink_root.mkdir()
        symlink = symlink_root / "FinalLocalCandidate.receipt.json"
        symlink.symlink_to(self.fixture.final_receipt)
        with self.assertRaisesRegex(
            pane.AdaptivePaneAcceptanceError, "single-link non-symlink"
        ):
            pane.load_installed_authority(symlink)

        hardlink_root = self.root / "hardlink"
        hardlink_root.mkdir()
        hardlink = hardlink_root / "FinalLocalCandidate.receipt.json"
        os.link(self.fixture.final_receipt, hardlink)
        with self.assertRaisesRegex(
            pane.AdaptivePaneAcceptanceError, "single-link non-symlink"
        ):
            pane.load_installed_authority(hardlink)

    def test_output_refuses_overwrite_symlink_and_hardlink(self) -> None:
        ordinary = self.root / "ordinary.json"
        ordinary.write_bytes(b"existing")
        with self.assertRaisesRegex(pane.AdaptivePaneAcceptanceError, "absent"):
            pane._canonical_absent(ordinary, label="output")

        symlink = self.root / "symlink.json"
        symlink.symlink_to(ordinary)
        with self.assertRaisesRegex(pane.AdaptivePaneAcceptanceError, "absent"):
            pane._canonical_absent(symlink, label="output")

        hardlink = self.root / "hardlink.json"
        os.link(ordinary, hardlink)
        with self.assertRaisesRegex(pane.AdaptivePaneAcceptanceError, "absent"):
            pane._canonical_absent(hardlink, label="output")

    def test_publication_parent_rename_and_symlink_race_leaves_no_receipt(self) -> None:
        parent = self.root / "publication"
        parent.mkdir()
        moved_parent = self.root / "publication-moved"
        attacker_parent = self.root / "attacker"
        attacker_parent.mkdir()
        output = parent / "WorkspaceAdaptivePane.receipt.json"
        real_link = os.link

        def link_then_redirect(
            source: str,
            destination: str,
            *,
            src_dir_fd: int,
            dst_dir_fd: int,
            follow_symlinks: bool,
        ) -> None:
            real_link(
                source,
                destination,
                src_dir_fd=src_dir_fd,
                dst_dir_fd=dst_dir_fd,
                follow_symlinks=follow_symlinks,
            )
            parent.rename(moved_parent)
            parent.symlink_to(attacker_parent, target_is_directory=True)

        with mock.patch.object(pane.os, "link", side_effect=link_then_redirect):
            with self.assertRaisesRegex(
                pane.AdaptivePaneAcceptanceError, "parent changed"
            ):
                pane._publish_receipt_create_only(
                    output,
                    {"fixture": "receipt"},
                    closure_check=lambda: None,
                )

        self.assertFalse(output.exists())
        self.assertFalse((moved_parent / output.name).exists())
        self.assertFalse((attacker_parent / output.name).exists())
        self.assertEqual(list(moved_parent.iterdir()), [])
        self.assertEqual(list(attacker_parent.iterdir()), [])

    def test_publication_input_fence_failure_cleans_exact_output(self) -> None:
        parent = self.root / "fenced-publication"
        parent.mkdir()
        output = parent / "WorkspaceAdaptivePane.receipt.json"
        checks = 0

        def changed_after_link() -> None:
            nonlocal checks
            checks += 1
            raise pane.AdaptivePaneAcceptanceError("fixture input changed")

        with self.assertRaisesRegex(
            pane.AdaptivePaneAcceptanceError, "fixture input changed"
        ):
            pane._publish_receipt_create_only(
                output,
                {"fixture": "receipt"},
                closure_check=changed_after_link,
            )
        self.assertEqual(checks, 1)
        self.assertFalse(output.exists())
        self.assertEqual(list(parent.iterdir()), [])

    def test_exact_selector_validator_rejects_mismatch_skip_and_duplicate(self) -> None:
        selectors = list(pane.SELECTORS)
        semantics = pane.validate_selector_documents(
            _summary(), _tests_document(selectors)
        )
        self.assertEqual(semantics["executed_selector_count"], 3)

        mismatched = selectors[:-1] + [
            "WorkspaceAdaptivePaneInstalledAppUITests/testUnexpected()"
        ]
        with self.assertRaisesRegex(
            pane.AdaptivePaneAcceptanceError, "selectors differ"
        ):
            pane.validate_selector_documents(_summary(), _tests_document(mismatched))

        with self.assertRaisesRegex(
            pane.AdaptivePaneAcceptanceError, "exclusively pass"
        ):
            pane.validate_selector_documents(
                _summary(passedTests=2, skippedTests=1),
                _tests_document(selectors),
            )

        with self.assertRaisesRegex(
            pane.AdaptivePaneAcceptanceError, "exclusively pass"
        ):
            pane.validate_selector_documents(
                _summary(passedTests=2, expectedFailures=1),
                _tests_document(selectors),
            )

        duplicated = [selectors[0], selectors[0], selectors[2]]
        with self.assertRaisesRegex(
            pane.AdaptivePaneAcceptanceError, "selectors differ"
        ):
            pane.validate_selector_documents(
                _summary(), _tests_document(duplicated)
            )

    def _run_arguments(self) -> tuple[object, Path, Path, Path]:
        output_root = self.root / "output"
        output_root.mkdir()
        xcresult = output_root / "WorkspaceAdaptivePane.xcresult"
        receipt = output_root / "WorkspaceAdaptivePane.receipt.json"
        developer_dir = self.root / "Xcode.app/Contents/Developer"
        xcodebuild = developer_dir / "usr/bin/xcodebuild"
        xcodebuild.parent.mkdir(parents=True)
        xcodebuild.write_bytes(b"#!/bin/sh\nexit 0\n")
        xcodebuild.chmod(0o755)
        arguments = pane.parse_arguments(
            [
                "--final-candidate",
                str(self.fixture.final_receipt),
                "--xcresult",
                str(xcresult),
                "--receipt-output",
                str(receipt),
                "--developer-dir",
                str(developer_dir),
                "--timeout-seconds",
                "60",
            ]
        )
        return arguments, xcresult, receipt, xcodebuild

    @staticmethod
    def _input_snapshot(
        authority: pane.InstalledAuthority, xcodebuild: Path
    ) -> dict[str, object]:
        return {
            "candidate_identity": {"fixture": "candidate"},
            "preparation_receipt": {"fixture": "preparation"},
            "installed_app": {
                "path": str(authority.installed_app),
                "bundle_identifier": "org.macscope.MacScope",
                "content_sha256": _sha("1"),
                "closed_tree_sha256": _sha("2"),
                "executable_path": str(
                    authority.installed_app / "Contents/MacOS/MacScope"
                ),
                "executable_sha256": _sha("3"),
            },
            "prepared_xctestrun": {
                "path": str(authority.prepared_xctestrun),
                "sha256": _sha("4"),
            },
            "execution_xctestrun": {"fixture": "overlay"},
            "test_bundle": {"path": str(authority.test_bundle), "fixture": "test"},
            "ui_runner": {"path": str(authority.ui_runner), "fixture": "runner"},
            "xcodebuild": {"path": str(xcodebuild), "sha256": file_sha256(xcodebuild)},
        }

    def test_success_publishes_closed_canonical_mode_0600_receipt(self) -> None:
        authority = self.fixture.load()
        arguments, xcresult, receipt, xcodebuild = self._run_arguments()
        snapshot = self._input_snapshot(authority, xcodebuild)
        captured: dict[str, object] = {}

        def write_overlay(_prepared: Path, execution: Path, _app: Path) -> str:
            execution.write_bytes(b"overlay")
            snapshot["execution_xctestrun"] = {
                "path": str(execution),
                "sha256": file_sha256(execution),
            }
            return file_sha256(execution)

        def execute(
            command: list[str], environment: dict[str, str], timeout: int
        ) -> tuple[int, bool]:
            captured["command"] = command
            captured["environment"] = environment
            captured["timeout"] = timeout
            xcresult.mkdir()
            (xcresult / "Info.plist").write_bytes(b"result")
            return 0, False

        selector_semantics = {
            "expected_selector_count": 3,
            "executed_selector_count": 3,
            "passed_selector_count": 3,
            "failed_selector_count": 0,
            "expected_failure_count": 0,
            "skipped_selector_count": 0,
            "selectors": [
                {"test_identifier": selector, "status": "passed"}
                for selector in pane.SELECTORS
            ],
        }
        produced_at = max(time.time_ns(), authority.final_receipt.metadata[5] + 1)
        with (
            mock.patch.object(pane, "load_installed_authority", return_value=authority),
            mock.patch.object(
                pane.matrix,
                "write_execution_xctestrun_create_only",
                side_effect=write_overlay,
            ),
            mock.patch.object(
                pane.matrix, "preflight_execution", return_value=snapshot
            ),
            mock.patch.object(
                pane.matrix, "capture_input_snapshot", return_value=snapshot
            ),
            mock.patch.object(
                pane, "_validate_exact_xcresult", return_value=selector_semantics
            ),
        ):
            observed = pane.run_acceptance(
                arguments,
                run_process=execute,
                clock_ms=iter((1000, 1250)).__next__,
                clock_ns=lambda: produced_at,
            )

        self.assertEqual(observed, receipt)
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
        self.assertEqual(receipt.stat().st_nlink, 1)
        payload = receipt.read_bytes()
        self.assertFalse(payload.endswith(b"\n"))
        document = decode_canonical_bytes(payload)
        self.assertEqual(payload, canonical_bytes(document))
        self.assertEqual(set(document), pane.RECEIPT_TOP_FIELDS)
        self.assertEqual(set(document["authority"]), pane.RECEIPT_AUTHORITY_FIELDS)
        self.assertEqual(set(document["products"]), pane.RECEIPT_PRODUCT_FIELDS)
        self.assertEqual(document["authority"]["source_commit"], authority.source_commit)
        self.assertEqual(
            document["authority"]["final_local_candidate_sha256"],
            authority.final_receipt.sha256,
        )
        self.assertEqual(document["products"]["installed_app"], snapshot["installed_app"])
        self.assertEqual(
            set(document["products"]["xcresult"]),
            {"bundle_sha256", "closed_tree_sha256", "path"},
        )
        self.assertEqual(document["execution"]["selectors"], list(pane.SELECTORS))
        command = captured["command"]
        assert isinstance(command, list)
        self.assertEqual(
            [item for item in command if item.startswith("-only-testing:")],
            [
                "-only-testing:MacScopeInstalledAppUITests/"
                + selector.removesuffix("()")
                for selector in pane.SELECTORS
            ],
        )

    def test_mutated_upstream_input_refuses_receipt(self) -> None:
        authority = self.fixture.load()
        arguments, xcresult, receipt, xcodebuild = self._run_arguments()
        snapshot = self._input_snapshot(authority, xcodebuild)

        def write_overlay(_prepared: Path, execution: Path, _app: Path) -> str:
            execution.write_bytes(b"overlay")
            return file_sha256(execution)

        def execute(
            _command: list[str], _environment: dict[str, str], _timeout: int
        ) -> tuple[int, bool]:
            xcresult.mkdir()
            (xcresult / "Info.plist").write_bytes(b"result")
            self.fixture.qualification.write_bytes(b"mutated")
            return 0, False

        with (
            mock.patch.object(pane, "load_installed_authority", return_value=authority),
            mock.patch.object(
                pane.matrix,
                "write_execution_xctestrun_create_only",
                side_effect=write_overlay,
            ),
            mock.patch.object(
                pane.matrix, "preflight_execution", return_value=snapshot
            ),
            mock.patch.object(
                pane.matrix, "capture_input_snapshot", return_value=snapshot
            ),
        ):
            with self.assertRaisesRegex(
                pane.AdaptivePaneAcceptanceError, "changed during final closure"
            ):
                pane.run_acceptance(arguments, run_process=execute)
        self.assertFalse(receipt.exists())


if __name__ == "__main__":
    unittest.main()
