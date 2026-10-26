from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

from Scripts.reconstruction import compile_installed_acceptance_gate_plan as compiler
from Scripts.reconstruction import validate_final_local_candidate as validator
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.schema import parse_candidate_identity
from Scripts.reconstruction_gate_f.tests import candidate_mapping


def _sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class LocalRefAuthorityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.remote = self.root / "MacScope-next5.git"
        self.repository.mkdir()
        self._git("init", "-q")
        self._git("config", "user.name", "MacScope Tests")
        self._git("config", "user.email", "macscope-tests@example.invalid")
        (self.repository / "fixture.txt").write_text("fixture\n", encoding="utf-8")
        self._git("add", "fixture.txt")
        self._git("commit", "-q", "-m", "fixture")
        subprocess.run(
            ["/usr/bin/git", "init", "-q", "--bare", str(self.remote)],
            check=True,
        )
        self._git("remote", "add", "next5-local", str(self.remote))
        self._git("push", "-q", "next5-local", "HEAD:refs/heads/feature/next5-integration")
        self._git("fetch", "-q", "next5-local")
        self.commit = self._git("rev-parse", "HEAD")
        self.tree = self._git("rev-parse", "HEAD^{tree}")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _git(self, *arguments: str) -> str:
        return subprocess.run(
            ["/usr/bin/git", "-C", str(self.repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def _publish_tracking_ref(self, remote_name: str, branch: str = "candidate") -> str:
        integration_ref = f"refs/remotes/{remote_name}/{branch}"
        self._git("update-ref", integration_ref, self.commit)
        return integration_ref

    def test_next5_local_and_gitfox_compatibility_resolve_exact_authority(self) -> None:
        next5 = validator._resolve_local_ref(
            self.repository,
            "refs/remotes/next5-local/feature/next5-integration",
        )
        self.assertEqual(next5.remote_name, "next5-local")
        self.assertEqual(next5.branch_name, "feature/next5-integration")
        self.assertEqual(next5.remote_url, str(self.remote))
        self.assertEqual((next5.commit, next5.tree), (self.commit, self.tree))

        self._git("remote", "add", "gitfox-local", str(self.remote))
        gitfox_ref = self._publish_tracking_ref("gitfox-local")
        gitfox = validator._resolve_local_ref(self.repository, gitfox_ref)
        self.assertEqual(gitfox.remote_name, "gitfox-local")
        self.assertEqual((gitfox.commit, gitfox.tree), (self.commit, self.tree))

    def test_nonlocal_or_ambiguous_remote_urls_are_rejected(self) -> None:
        symlink = self.root / "remote-link"
        symlink.symlink_to(self.remote, target_is_directory=True)
        ancestor_link = self.root / "parent-link"
        ancestor_link.symlink_to(self.root, target_is_directory=True)
        rejected = {
            "https-remote": "https://example.invalid/MacScope.git",
            "lookalike-host": "https://github.com.example.invalid/jdotc1/MacScope-app.git",
            "owner-case": "https://github.com/Jdotc1/MacScope-app.git",
            "repository-case": "https://github.com/jdotc1/macscope-app.git",
            "wrong-owner": "https://github.com/other/MacScope.git",
            "wrong-repository": "https://github.com/octocat/other.git",
            "credentials": "https://token@github.com/jdotc1/MacScope-app.git",
            "query": "https://github.com/jdotc1/MacScope-app.git?x=1",
            "fragment": "https://github.com/jdotc1/MacScope-app.git#main",
            "missing-suffix": "https://github.com/jdotc1/MacScope-app",
            "trailing-slash": "https://github.com/jdotc1/MacScope-app.git/",
            "host-case": "https://GitHub.com/jdotc1/MacScope-app.git",
            "github-ssh": "git@github.com:jdotc1/MacScope-app.git",
            "ssh-remote": "ssh://example.invalid/MacScope.git",
            "file-remote": f"file://{self.remote}",
            "relative-remote": "../MacScope.git",
            "trailing-remote": str(self.remote) + "/",
            "dotdot-remote": str(self.root / "child" / ".." / self.remote.name),
            "double-remote": str(self.root) + "//" + self.remote.name,
            "symlink-remote": str(symlink),
            "symlink-ancestor": str(ancestor_link / self.remote.name),
        }
        for remote_name, remote_url in rejected.items():
            with self.subTest(remote_name=remote_name):
                self._git("remote", "add", remote_name, remote_url)
                integration_ref = self._publish_tracking_ref(remote_name)
                with self.assertRaises(validator.FinalLocalCandidateError):
                    validator._resolve_local_ref(self.repository, integration_ref)

        duplicate_ref = self._publish_tracking_ref("duplicate-remote")
        self._git("config", "--add", "remote.duplicate-remote.url", str(self.remote))
        self._git("config", "--add", "remote.duplicate-remote.url", str(self.remote))
        with self.assertRaises(validator.FinalLocalCandidateError):
            validator._resolve_local_ref(self.repository, duplicate_ref)

        missing_ref = self._publish_tracking_ref("missing-remote")
        with self.assertRaises(validator.FinalLocalCandidateError):
            validator._resolve_local_ref(self.repository, missing_ref)

    def test_canonical_github_authority_uses_only_local_reads(self) -> None:
        url = "https://github.com/jdotc1/MacScope-app.git"
        self._git("remote", "add", "github", url)
        integration_ref = self._publish_tracking_ref("github", "feature/candidate")
        with mock.patch.object(validator, "_git", wraps=validator._git) as git:
            authority = validator._resolve_local_ref(self.repository, integration_ref)
        self.assertEqual(authority.remote_url, url)
        self.assertEqual(authority.integration_ref, integration_ref)
        self.assertEqual((authority.commit, authority.tree), (self.commit, self.tree))
        self.assertEqual(
            [call.args[1][0] for call in git.call_args_list],
            ["check-ref-format", "rev-parse", "rev-parse", "config"],
        )
        # Configuration drift is not normalized back to the admitted URL.
        self._git("remote", "set-url", "github", url + "/")
        with self.assertRaises(validator.FinalLocalCandidateError):
            validator._resolve_local_ref(self.repository, integration_ref)

    def test_duplicate_canonical_github_urls_are_rejected(self) -> None:
        self._git("remote", "add", "github", "https://github.com/jdotc1/MacScope-app.git")
        integration_ref = self._publish_tracking_ref("github")
        self._git("config", "--add", "remote.github.url", "https://github.com/jdotc1/MacScope-app.git")
        with self.assertRaises(validator.FinalLocalCandidateError):
            validator._resolve_local_ref(self.repository, integration_ref)

    def test_unsafe_remote_or_branch_syntax_is_rejected(self) -> None:
        rejected = (
            "refs/remotes/next5-local/HEAD",
            "refs/remotes/next5-local/candidate~0",
            "refs/remotes/next5-local/candidate@{1}",
            "refs/remotes/next5-local/.hidden",
            "refs/remotes/next5-local/path/.hidden",
            "refs/remotes/next5-local/path/branch.lock",
            "refs/remotes/unsafe.lock/candidate",
            "refs/remotes/unsafe.LOCK/candidate",
            "refs/remotes/-evil/candidate",
        )
        for integration_ref in rejected:
            with self.subTest(integration_ref=integration_ref):
                with self.assertRaises(validator.FinalLocalCandidateError):
                    validator._resolve_local_ref(self.repository, integration_ref)

    def test_candidate_repository_label_must_match_derived_remote(self) -> None:
        mapping = candidate_mapping()
        source = mapping["source"]
        source.update(
            {
                "branch_label": "feature/next5-integration",
                "commit": self.commit,
                "repository": "next5-local:MacScope",
                "tree": self.tree,
            }
        )
        candidate, issues = parse_candidate_identity(mapping)
        self.assertIsNotNone(candidate)
        self.assertEqual(issues, ())
        authority = validator._resolve_local_ref(
            self.repository,
            "refs/remotes/next5-local/feature/next5-integration",
        )
        assert candidate is not None
        self.assertTrue(validator._candidate_matches_local_ref(candidate, authority))

        source["repository"] = "gitfox-local:MacScope"
        mismatched, issues = parse_candidate_identity(mapping)
        self.assertIsNotNone(mismatched)
        self.assertEqual(issues, ())
        assert mismatched is not None
        self.assertFalse(validator._candidate_matches_local_ref(mismatched, authority))

    def test_canonical_repository_identity_is_independent_of_transport_alias(self) -> None:
        self._git("remote", "add", "github", "https://github.com/jdotc1/MacScope-app.git")
        github_ref = self._publish_tracking_ref("github", "feature/next5-integration")
        for integration_ref in ("refs/remotes/next5-local/feature/next5-integration", github_ref):
            authority = validator._resolve_local_ref(self.repository, integration_ref)
            mapping = candidate_mapping()
            mapping["source"].update({
                "branch_label": authority.branch_name,
                "commit": self.commit,
                "tree": self.tree,
            })
            candidate, issues = parse_candidate_identity(mapping)
            self.assertEqual(issues, ())
            assert candidate is not None
            self.assertTrue(validator._candidate_matches_local_ref(candidate, authority))
            for label in (
                "https://github.com/other/MacScope",
                "https://github.com/octocat/Other",
                "https://github.com.example.invalid/jdotc1/MacScope-app",
                "https://token@github.com/jdotc1/MacScope-app",
                "https://github.com/jdotc1/MacScope-app?ref=main",
                "https://github.com/jdotc1/MacScope-app/",
                "unrelated:MacScope",
            ):
                with self.subTest(ref=integration_ref, label=label):
                    changed = copy.deepcopy(mapping)
                    changed["source"]["repository"] = label
                    rejected, issues = parse_candidate_identity(changed)
                    self.assertEqual(issues, ())
                    assert rejected is not None
                    self.assertFalse(validator._candidate_matches_local_ref(rejected, authority))
            for field, value in (("commit", "f" * 40), ("tree", "e" * 40), ("branch_label", "feature/foreign"), ("dirty", True)):
                with self.subTest(ref=integration_ref, drift=field):
                    changed = copy.deepcopy(mapping)
                    changed["source"][field] = value
                    rejected, issues = parse_candidate_identity(changed)
                    if field == "dirty":
                        self.assertTrue(any(issue.code == "candidate-dirty" for issue in issues))
                        continue
                    self.assertEqual(issues, ())
                    assert rejected is not None
                    self.assertFalse(validator._candidate_matches_local_ref(rejected, authority))


class TransactionFixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.qualification_root = self.root / "qualification" / "runs" / "run.final"
        self.qualification_root.mkdir(parents=True)
        self.artifact_root = self.qualification_root / "candidate-artifacts"
        self.artifact_root.mkdir()
        self.work_root = self.root / "transaction-work"
        self.work_root.mkdir()
        self.evidence_root = self.work_root / validator.PLAN_EVIDENCE_DIRECTORY_NAME
        self.evidence_root.mkdir()
        self.ws24_root = self.work_root / validator.WS24_EVIDENCE_DIRECTORY_NAME
        self.ws24_root.mkdir()
        self.installer_artifact_root = (
            self.work_root / validator.INSTALLER_ARTIFACT_DIRECTORY_NAME
        )
        self.installer_artifact_root.mkdir()
        self.qualification_receipt = self.qualification_root / "QUALIFICATION_INPUTS.json"
        self._write_bytes(self.qualification_receipt, b"{}\n")
        self.coverage = self.qualification_root / "COVERAGE.json"
        self._write_bytes(self.coverage, b"{}")
        self.result_bundle = self.qualification_root / "TestResults.xcresult"
        self.result_bundle.mkdir()

        self.candidate_path = self.artifact_root / "candidate.json"
        self.candidate_mapping = candidate_mapping()
        parsed_candidate, issues = parse_candidate_identity(self.candidate_mapping)
        if parsed_candidate is None or issues:
            raise AssertionError(f"repository candidate fixture is invalid: {issues}")
        self.parsed_candidate = parsed_candidate
        self._write_document(self.candidate_path, self.candidate_mapping)
        self.native_preparation_receipt = (
            self.artifact_root / "NativeLivePreparation.receipt.json"
        )
        self._write_document(self.native_preparation_receipt, {})
        self.native_xctestrun = self.artifact_root / "NativeLive.xctestrun"
        self._write_bytes(self.native_xctestrun, b"fixture-xctestrun")
        self.source_app = (
            self.qualification_root
            / "DerivedData"
            / "Build"
            / "Products"
            / "Release"
            / "MacScope.app"
        )
        self.provenance_path = (
            self.source_app / "Contents" / "Resources" / "MacScopeBuildProvenance.json"
        )
        self._write_bytes(self.provenance_path, b"{}\n")
        self.installed_app = self.root / "Applications" / "MacScope.app"
        self.installed_app.mkdir(parents=True)

        self.source_commit = parsed_candidate.source.commit
        self.source_tree = parsed_candidate.source.tree
        self.candidate_identity_sha256 = validator.candidate_identity_sha256(
            parsed_candidate
        )
        self.application_executable_sha256 = (
            parsed_candidate.application.executable_sha256
        )
        self.build_provenance_sha256 = _sha(self.provenance_path.read_bytes())
        self.source_equality_sha256 = "3" * 64
        self.execution_identity_sha256 = "4" * 64
        self.destination_identity = {"fixture": "destination"}
        self.destination_identity_sha256 = _sha(canonical_bytes(self.destination_identity))
        self.artifact_root_identity = {"fixture": "artifact-root"}
        self.predecessor_digest = "6" * 64
        self.predecessor_observations_sha256 = "7" * 64
        self.transaction_id = "8" * 64
        self.transaction_nonce = "9" * 64
        self.run_id = "final-local-full-test"
        self.run_nonce = "c" * 64
        self.began_at = time.time_ns()
        self.exposed_at = self.began_at + 10
        self.produced_at = self.exposed_at + 10_000

        self.applications_root = self.installed_app.parent
        self.pending_path = (
            self.applications_root
            / f".MacScope.pending-{self.candidate_identity_sha256}"
            / "transaction.json"
        )
        self.terminal_root = self.applications_root / (
            ".MacScope.committed-"
            f"{self.candidate_identity_sha256}-{self.transaction_id}"
        )
        self.terminal_root.mkdir(mode=0o700)
        self.terminal_state = self.terminal_root / "transaction.json"
        self._write_document(self.terminal_state, {"fixture": "terminal-state"})

        self.plan_path = self.evidence_root / "InstalledAcceptanceGate.plan.json"
        self.plan_authority = self._plan_authority()
        self.plan_authority_sha256 = _sha(canonical_bytes(self.plan_authority))
        self.plan_document = self._plan_document()
        self.frozen_plan_payload = canonical_bytes(self.plan_document)
        self._write_document(self.plan_path, self.plan_document)
        self.plan_path.chmod(0o600)

        self.primary_outputs: dict[str, Path] = {}
        for gate_id in validator.installer.REQUIRED_ACCEPTANCE_GATES:
            kind, relative = validator.GATE_PLAN_OUTPUTS[gate_id]
            output_root = self.ws24_root if gate_id == "signing" else self.evidence_root
            path = output_root / relative
            if kind == "command-file":
                self._write_document(path, {"fixture": gate_id})
            elif gate_id == "signing":
                self._write_bytes(
                    path,
                    b"PASS: source and installed MacScope.app bundles match under the "
                    b"repository checker\n",
                )
            else:
                self._write_bytes(path, b"temporary GUI status\n")
            self.primary_outputs[gate_id] = path

        self.cli_gui_report = self.evidence_root / "cli-gui-operability.report.json"
        self.mcp_report = self.evidence_root / "mcp-operability.report.json"
        operability_authority = self._operability_authority()
        self._write_document(
            self.cli_gui_report,
            {
                "authority": operability_authority,
                "probeResults": {"cli": True, "gui": True},
                "reportKind": "macscope-cli-gui-operability-report-v1",
                "schemaVersion": 1,
                "status": "passed",
            },
        )
        self._write_document(
            self.mcp_report,
            {
                "authority": operability_authority,
                "probeResults": {
                    "initialize": True,
                    "readOnlyInfo": True,
                    "toolsList": True,
                },
                "reportKind": "macscope-mcp-operability-report-v1",
                "schemaVersion": 1,
                "status": "passed",
            },
        )
        self._write_bytes(
            self.primary_outputs["gui"],
            (
                "PASS: installed CLI/GUI operability report sha256="
                f"{_sha(self.cli_gui_report.read_bytes())}\n"
            ).encode("utf-8"),
        )
        self.ws24_aggregate = self.ws24_root / validator.WS24_AGGREGATE_NAME
        self._write_document(
            self.ws24_aggregate,
            {
                "accepted": True,
                "acceptedGates": list(validator.ws24.REQUIRED_GATES),
                "deficiencies": [],
                "evidence": [{"fixture": "accepted"}],
                "generatedAtUnixMilliseconds": self.exposed_at // 1_000_000,
                "installedExecutableSHA256": self.application_executable_sha256,
                "liveEvidenceSHA256": _sha(
                    self.primary_outputs["shellbroker-launchagent"].read_bytes()
                ),
                "operabilityAuthority": operability_authority,
                "operabilityReportSHA256": {
                    "cliGUI": _sha(self.cli_gui_report.read_bytes()),
                    "mcp": _sha(self.mcp_report.read_bytes()),
                },
                "performanceThresholds": validator.ws24.PERFORMANCE_THRESHOLDS,
                "schemaVersion": (
                    validator.ws24.INSTALLED_QUALIFICATION_REPORT_SCHEMA_VERSION
                ),
                "sourceCommit": self.source_commit,
                "sourceTree": self.source_tree,
            },
        )

        self.gate_envelopes: dict[str, Path] = {}
        self.gate_documents: dict[str, dict[str, object]] = {}
        for offset, gate_id in enumerate(validator.installer.REQUIRED_ACCEPTANCE_GATES):
            document = self._gate_document(gate_id, offset)
            path = self.ws24_root / f"{gate_id}.acceptance-gate.json"
            self._write_document(path, document)
            self.gate_documents[gate_id] = document
            self.gate_envelopes[gate_id] = path

        self.acceptance_receipt = (
            self.installer_artifact_root / validator.installer.ACCEPTANCE_RECEIPT_NAME
        )
        self._write_document(self.acceptance_receipt, {"fixture": "acceptance"})
        self.commit_authority = self.terminal_root / validator.installer.COMMIT_AUTHORITY_NAME
        self._write_document(self.commit_authority, {"fixture": "commit"})

        self._create_installed_task10()

        self.result_path = self.work_root / "InstalledAcceptanceTransaction.result.json"
        self.result_document = self._result_document()
        self.rewrite_result()

    def cleanup(self) -> None:
        self.temporary.cleanup()

    def _write_bytes(self, path: Path, payload: bytes, *, mode: int = 0o600) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        path.chmod(mode)

    def _write_document(self, path: Path, document: object) -> None:
        self._write_bytes(path, canonical_bytes(document))

    def _plan_authority(self) -> dict[str, object]:
        return {
            "application_executable_sha256": self.application_executable_sha256,
            "artifact_root_identity_sha256": _sha(
                canonical_bytes(self.artifact_root_identity)
            ),
            "artifact_root_path": str(self.installer_artifact_root),
            "began_at_unix_ns": self.began_at,
            "build_provenance_sha256": self.build_provenance_sha256,
            "candidate_file_sha256": _sha(self.candidate_path.read_bytes()),
            "candidate_identity_path": str(self.candidate_path),
            "candidate_identity_sha256": self.candidate_identity_sha256,
            "destination_identity_sha256": self.destination_identity_sha256,
            "execution_identity_sha256": self.execution_identity_sha256,
            "exposed_at_unix_ns": self.exposed_at,
            "installed_app_path": str(self.installed_app),
            "installed_task10_incremental_evidence_path": str(
                self.evidence_root
                / "installed-task10-network"
                / "InstalledTask10.incremental-xcuitest.evidence.json"
            ),
            "installed_task10_matrix_receipt_path": str(
                self.evidence_root / "InstalledTask10.matrix-receipt.json"
            ),
            "installed_task10_network_artifact_root": str(
                self.evidence_root / "installed-task10-network"
            ),
            "installed_task10_xcresult_path": str(
                self.evidence_root / "InstalledTask10.xcresult"
            ),
            "installed_task10_xcresult_semantic_manifest_path": str(
                self.evidence_root / "InstalledTask10.xcresult-semantic.json"
            ),
            "installed_ui_preparation_receipt_path": str(
                self.artifact_root / "InstalledUIPreparation.receipt.json"
            ),
            "installed_ui_preparation_receipt_sha256": "d" * 64,
            "installed_ui_runner_closed_tree_sha256": "e" * 64,
            "installed_ui_runner_executable_sha256": "f" * 64,
            "installed_ui_runner_path": str(
                self.qualification_root
                / "DerivedData/Build/Products/Debug/MacScopeInstalledAppUITests-Runner.app"
            ),
            "installed_ui_test_bundle_closed_tree_sha256": "1" * 64,
            "installed_ui_test_bundle_executable_sha256": "2" * 64,
            "installed_ui_test_bundle_path": str(
                self.qualification_root
                / "DerivedData/Build/Products/Debug/MacScopeInstalledAppUITests-Runner.app"
                / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
            ),
            "installed_ui_xctestrun_path": str(
                self.qualification_root
                / "DerivedData/Build/Products/MacScopeInstalledAppUITests_macosx27.0-arm64.xctestrun"
            ),
            "installed_ui_xctestrun_sha256": "3" * 64,
            "native_preparation_receipt_path": str(
                self.native_preparation_receipt
            ),
            "native_preparation_receipt_sha256": _sha(
                self.native_preparation_receipt.read_bytes()
            ),
            "native_xctestrun_path": str(self.native_xctestrun),
            "native_xctestrun_sha256": _sha(self.native_xctestrun.read_bytes()),
            "pending_state_path": str(self.pending_path),
            "pending_state_sha256": _sha(self.terminal_state.read_bytes()),
            "predecessor_digest": self.predecessor_digest,
            "predecessor_observations_sha256": self.predecessor_observations_sha256,
            "qualification_receipt_path": str(self.qualification_receipt),
            "qualification_receipt_sha256": _sha(self.qualification_receipt.read_bytes()),
            "qualification_run_id": self.run_id,
            "qualification_run_nonce": self.run_nonce,
            "source_app_path": str(self.source_app),
            "source_commit": self.source_commit,
            "source_equality_sha256": self.source_equality_sha256,
            "source_tree": self.source_tree,
            "transaction_id": self.transaction_id,
            "transaction_nonce": self.transaction_nonce,
        }

    def _plan_document(self) -> dict[str, object]:
        gates: list[dict[str, object]] = []
        environment = dict(validator.GATE_PLAN_ENVIRONMENT)
        environment["MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256"] = (
            self.plan_authority_sha256
        )
        for gate_id in validator.installer.REQUIRED_ACCEPTANCE_GATES:
            output_kind, relative = validator.GATE_PLAN_OUTPUTS[gate_id]
            operation_id = (
                "renderer-dual"
                if gate_id in {"forced-legacy-grid", "full-surface"}
                else "cli-gui-operability"
                if gate_id in {"cli", "gui"}
                else gate_id
            )
            argv = (
                ["/usr/bin/true", "renderer-dual"]
                if operation_id == "renderer-dual"
                else ["/usr/bin/true", "cli-gui-operability"]
                if operation_id == "cli-gui-operability"
                else ["/usr/bin/true", gate_id]
            )
            gates.append(
                {
                    "argv": argv,
                    "authority_sha256": self.plan_authority_sha256,
                    "depends_on": [],
                    "environment": environment,
                    "gate_id": gate_id,
                    "operation_id": operation_id,
                    "output": {
                        "kind": output_kind,
                        "maximum_bytes": validator.GATE_PLAN_MAXIMUM_BYTES[gate_id],
                        "path": str(
                            (self.ws24_root if gate_id == "signing" else self.evidence_root)
                            / relative
                        ),
                        "publication": "create-only",
                    },
                    "timeout_seconds": validator.GATE_PLAN_TIMEOUTS[gate_id],
                }
            )
        return {
            "authority": self.plan_authority,
            "authority_sha256": self.plan_authority_sha256,
            "candidate_artifact_root": str(self.artifact_root),
            "evidence_root": str(self.evidence_root),
            "gates": gates,
            "output_path": str(self.plan_path),
            "plan_kind": "macscope-installed-acceptance-gate-plan",
            "schema_version": 1,
        }

    def _gate_document(self, gate_id: str, offset: int) -> dict[str, object]:
        if gate_id in {"cli", "gui"}:
            evidence_path = self.cli_gui_report
        elif gate_id == "mcp":
            evidence_path = self.mcp_report
        elif gate_id in {"signing", "shellbroker-launchagent"}:
            evidence_path = self.ws24_aggregate
        else:
            evidence_path = self.primary_outputs[gate_id]
        return {
            "application_executable_sha256": self.application_executable_sha256,
            "build_provenance_sha256": self.build_provenance_sha256,
            "candidate_file_sha256": _sha(self.candidate_path.read_bytes()),
            "candidate_identity_sha256": self.candidate_identity_sha256,
            "destination_identity_sha256": self.destination_identity_sha256,
            "ended_at_unix_ns": self.exposed_at + 100 + offset,
            "evidence_sha256": _sha(evidence_path.read_bytes()),
            "execution_identity_sha256": self.execution_identity_sha256,
            "gate_id": gate_id,
            "input_kind": validator.installer.ACCEPTANCE_GATE_INPUT_KIND,
            "qualification_run_id": self.run_id,
            "qualification_run_nonce": self.run_nonce,
            "result": "passed",
            "rolled_back": False,
            "schema_version": validator.installer.ACCEPTANCE_GATE_INPUT_SCHEMA_VERSION,
            "source_commit": self.source_commit,
            "source_equality_sha256": self.source_equality_sha256,
            "source_tree": self.source_tree,
            "started_at_unix_ns": self.exposed_at + 50 + offset,
            "transaction_id": self.transaction_id,
            "transaction_nonce": self.transaction_nonce,
            "transaction_phase": "pending",
        }

    def _operability_authority(self) -> dict[str, object]:
        return {
            "applicationExecutableSHA256": self.application_executable_sha256,
            "buildProvenanceSHA256": self.build_provenance_sha256,
            "candidateFileSHA256": _sha(self.candidate_path.read_bytes()),
            "candidateIdentitySHA256": self.candidate_identity_sha256,
            "destinationIdentitySHA256": self.destination_identity_sha256,
            "executionIdentitySHA256": self.execution_identity_sha256,
            "exposedAtUnixNanoseconds": self.exposed_at,
            "forcedLegacyGridReportSHA256": _sha(
                self.primary_outputs["forced-legacy-grid"].read_bytes()
            ),
            "fullSurfaceReportSHA256": _sha(
                self.primary_outputs["full-surface"].read_bytes()
            ),
            "installedExecutableSHA256": self.application_executable_sha256,
            "installationPendingStateSHA256": _sha(self.terminal_state.read_bytes()),
            "nativeLiveXPCReportSHA256": _sha(
                self.primary_outputs["native-xpc"].read_bytes()
            ),
            "predecessorObservationsSHA256": self.predecessor_observations_sha256,
            "qualificationRunID": self.run_id,
            "shellBrokerExecutableSHA256": "d" * 64,
            "shellBrokerInfoPlistSHA256": "e" * 64,
            "sourceCommit": self.source_commit,
            "sourceEqualitySHA256": self.source_equality_sha256,
            "sourceTree": self.source_tree,
            "transactionID": self.transaction_id,
        }

    def _transaction_document(self) -> dict[str, object]:
        return {
            "application_executable_sha256": self.application_executable_sha256,
            "began_at_unix_ns": self.began_at,
            "build_provenance_sha256": self.build_provenance_sha256,
            "candidate_file_sha256": _sha(self.candidate_path.read_bytes()),
            "candidate_identity_sha256": self.candidate_identity_sha256,
            "destination_identity_sha256": self.destination_identity_sha256,
            "execution_identity_sha256": self.execution_identity_sha256,
            "exposed_at_unix_ns": self.exposed_at,
            "predecessor_digest": self.predecessor_digest,
            "predecessor_observations_sha256": self.predecessor_observations_sha256,
            "source_commit": self.source_commit,
            "source_equality_sha256": self.source_equality_sha256,
            "source_tree": self.source_tree,
            "transaction_id": self.transaction_id,
            "transaction_nonce": self.transaction_nonce,
        }

    def _create_installed_task10(self) -> None:
        self.task10_matrix_receipt = (
            self.evidence_root / "InstalledTask10.matrix-receipt.json"
        )
        self.task10_xcresult = self.evidence_root / "InstalledTask10.xcresult"
        self.task10_xcresult.mkdir()
        self._write_bytes(self.task10_xcresult / "result.json", b"fixture-xcresult")
        self.task10_semantic = (
            self.evidence_root / "InstalledTask10.xcresult-semantic.json"
        )
        self.task10_network_root = self.evidence_root / "installed-task10-network"
        self.task10_network_root.mkdir(mode=0o700)
        self.task10_audit = (
            self.task10_network_root / "InstalledNetworkAcquisition.audit.json"
        )
        self.task10_execution = self.task10_network_root / (
            "InstalledNetworkAcquisition.execution-report.json"
        )
        self.task10_observation = (
            self.task10_network_root / "InstalledNetworkAcquisition.nettop.csv"
        )
        self.task10_incremental = self.task10_network_root / (
            "InstalledTask10.incremental-xcuitest.evidence.json"
        )
        tree = validator._capture_xcresult_tree(
            self.task10_xcresult, label="fixture Task10 xcresult"
        )
        self.task10_bundle_sha256 = tree.bundle_sha256
        self.task10_closed_tree_sha256 = tree.closed_tree_sha256
        projection = validator.ws24.installed_selector_projection()
        selectors = [item["test_identifier"] for item in projection]
        observed_projection = [
            {
                "observed_identifiers": sorted(item["required_identifiers"]),
                "test_identifier": item["test_identifier"],
                "vector_id": item["vector_id"],
            }
            for item in projection
        ]
        snapshot = {
            key: {"fixture": key}
            for key in (
                "candidate_identity",
                "preparation_receipt",
                "installed_app",
                "prepared_xctestrun",
                "execution_xctestrun",
                "test_bundle",
                "ui_runner",
                "xcodebuild",
            )
        }
        bundle = {
            "bundle_identifier": "fixture.bundle",
            "closed_tree_sha256": "a" * 64,
            "content_sha256": "b" * 64,
            "executable_path": str(self.root / "fixture-executable"),
            "executable_sha256": "c" * 64,
            "path": str(self.root / "fixture.bundle"),
        }
        installed_bundle = dict(bundle)
        installed_bundle.update(
            {
                "bundle_identifier": self.parsed_candidate.application.bundle_identifier,
                "closed_tree_sha256": self.parsed_candidate.application.closed_tree_sha256,
                "content_sha256": self.parsed_candidate.application.bundle_sha256,
                "executable_path": str(self.installed_app / "Contents/MacOS/MacScope"),
                "executable_sha256": self.application_executable_sha256,
                "path": str(self.installed_app),
            }
        )
        self.task10_matrix_document = {
            "accessibility_observations": {"state": "absent"},
            "candidate": {
                "identity_path": str(self.candidate_path),
                "identity_sha256": self.candidate_identity_sha256,
                "preparation_receipt_path": str(self.native_preparation_receipt),
                "preparation_receipt_sha256": _sha(
                    self.native_preparation_receipt.read_bytes()
                ),
                "source_commit": self.source_commit,
                "source_tree": self.source_tree,
            },
            "execution": {
                "argv": ["/usr/bin/true"],
                "duration_ms": 600,
                "ended_at_unix_ms": 1_800,
                "environment": {
                    "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                    "HOME": str(self.root),
                    "LOGNAME": "fixture",
                    "MACSCOPE_WS24_INSTALLED_APP": str(self.installed_app),
                    "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST": "1",
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": str(self.root),
                    "USER": "fixture",
                },
                "exit_code": 0,
                "failure": None,
                "input_snapshot_after": snapshot,
                "input_snapshot_before": snapshot,
                "result": "passed",
                "selector_projection": projection,
                "selector_projection_sha256": _sha(canonical_bytes(projection)),
                "selectors": selectors,
                "started_at_unix_ms": 1_200,
            },
            "presentation_screenshots": {"state": "absent"},
            "products": {
                "execution_xctestrun": {
                    "path": str(self.native_xctestrun),
                    "sha256": _sha(self.native_xctestrun.read_bytes()),
                },
                "installed_app": installed_bundle,
                "prepared_xctestrun": {
                    "path": str(self.native_xctestrun),
                    "sha256": _sha(self.native_xctestrun.read_bytes()),
                },
                "test_bundle": bundle,
                "ui_runner": dict(bundle),
                "xcresult": {
                    "closed_tree_sha256": self.task10_closed_tree_sha256,
                    "path": str(self.task10_xcresult),
                },
            },
            "receipt_kind": validator.installed_matrix_receipt.RECEIPT_KIND,
            "schema_version": validator.installed_matrix_receipt.SCHEMA_VERSION,
        }
        self._write_document(self.task10_matrix_receipt, self.task10_matrix_document)
        self.task10_semantic_document = {
            "candidate_identity_sha256": self.candidate_identity_sha256,
            "executed_selector_count": 22,
            "expected_selector_count": 22,
            "failed_selector_count": 0,
            "observed_selector_projection": observed_projection,
            "observed_selector_projection_sha256": _sha(
                canonical_bytes(observed_projection)
            ),
            "passed_selector_count": 22,
            "result": "passed",
            "schema_version": 3,
            "selector_catalog_sha256": _sha(canonical_bytes(selectors)),
            "selector_projection": projection,
            "selector_projection_sha256": _sha(canonical_bytes(projection)),
            "selectors": [
                {"status": "passed", "test_identifier": identifier}
                for identifier in selectors
            ],
            "skipped_selector_count": 0,
            "source_xcresult": {
                "bundle_sha256": self.task10_bundle_sha256,
                "closed_tree_sha256": self.task10_closed_tree_sha256,
            },
        }
        self._write_document(self.task10_semantic, self.task10_semantic_document)
        observation_payload = b",bytes_in,bytes_out,\n"
        self._write_bytes(self.task10_observation, observation_payload)
        roles = ["app", *sorted(validator.network_audit.MANDATORY_EXECUTABLE_NAMES)]
        self.task10_audit_document = {
            "artifacts": [],
            "attribution": {
                "policy_id": "prearmed-kqueue-path-v1", "observer_spawn_ns": 10,
                "observer_eof_ns": 20, "queue_closed_ns": 30, "proofs": [],
                "drains": [{"drain_id": 1, "begin_monotonic_ns": 25,
                            "end_monotonic_ns": 26, "completed_to_empty": True, "events": []}],
            },
            "candidate": {
                "document_sha256": _sha(self.candidate_path.read_bytes()),
                "identity_sha256": self.candidate_identity_sha256,
                "source_commit": self.source_commit,
                "source_tree": self.source_tree,
            },
            "command_id": "installed.network-acquisition-audit",
            "diagnostic": None,
            "ended_at_unix_ms": 2_000,
            "evidence_layer": "installed-launch-log",
            "executables": [
                {
                    "executable_path": str(self.installed_app / "Contents/MacOS/MacScope") if role == "app" else str(
                        self.installed_app / "Contents/XPCServices"
                        / f"{validator.network_audit.MANDATORY_EXECUTABLE_NAMES[role]}.xpc"
                        / "Contents/MacOS" / validator.network_audit.MANDATORY_EXECUTABLE_NAMES[role]),
                    "executable_sha256": (
                        self.application_executable_sha256 if role == "app" else "d" * 64
                    ),
                    "identity_id": role,
                    "processes": (
                        [{"pid": 123, "start_time_unix_us": 1}] if role == "app" else []
                    ),
                }
                for role in roles
            ],
            "exit_code": 0,
            "observer": {
                "availability": "available",
                "continuity_proven": True,
                "continuous_interval_ended_at_unix_ms": 2_000,
                "continuous_interval_ready_at_unix_ms": 1_100,
                "continuous_interval_started_at_unix_ms": 1_000,
                "interface_scope": ["external", "undefined"],
                "loopback_excluded": True,
                "observation_byte_count": len(observation_payload),
                "observation_sha256": _sha(observation_payload),
                "observed_process_row_count": 0,
                "observed_sample_count": 1,
                "observer_id": validator.network_audit.MATRIX_OBSERVER_ID,
                "evidence_scope": validator.network_audit.MATRIX_EVIDENCE_SCOPE,
                "limitations": list(validator.network_audit.MATRIX_LIMITATIONS),
                "observed_candidate_row_count": 0,
                "observed_foreign_row_count": 0,
                "observed_unresolved_row_count": 0,
                "observer_invocation_count": 1,
                "readiness_frame_sha256": "e" * 64,
                "readiness_proven": True,
                "stopped_by_auditor": True,
                "tool_path": "/usr/bin/nettop",
                "tool_sha256": "f" * 64,
            },
            "result": "passed",
            "schema_version": 4,
            "started_at_unix_ms": 1_000,
            "workload": {
                "command_id": "installed.task10-workflow",
                "ended_at_unix_ms": 1_800,
                "executed_selector_count": 22,
                "expected_selector_count": 22,
                "failed_selector_count": 0,
                "matrix_receipt_sha256": _sha(
                    self.task10_matrix_receipt.read_bytes()
                ),
                "matrix_result": "passed",
                "observation_contains_workload": True,
                "observer_readiness_precedes_workload": True,
                "observer_ready_at_unix_ms": 1_100,
                "passed_selector_count": 22,
                "selector_catalog_sha256": self.task10_semantic_document[
                    "selector_catalog_sha256"
                ],
                "selector_projection_sha256": self.task10_semantic_document[
                    "selector_projection_sha256"
                ],
                "skipped_selector_count": 0,
                "started_at_unix_ms": 1_200,
                "xcresult_bundle_sha256": self.task10_bundle_sha256,
                "xcresult_closed_tree_sha256": self.task10_closed_tree_sha256,
                "xcresult_semantic_manifest_sha256": _sha(
                    self.task10_semantic.read_bytes()
                ),
            },
        }
        self._write_document(self.task10_audit, self.task10_audit_document)
        self.task10_execution_document = {
            "ended_at_unix_ms": 2_000,
            "exit_code": 0,
            "predecessor_observations_sha256": self.predecessor_observations_sha256,
            "qualification_run": {"nonce": self.run_nonce, "run_id": self.run_id},
            "result": "passed",
            "schema_version": 2,
            "started_at_unix_ms": 1_000,
            "stress": None,
        }
        self._write_document(self.task10_execution, self.task10_execution_document)
        self.task10_incremental_document = {
            "evidence": [
                {
                    "gate": "incremental-xcuitest",
                    "proofArtifacts": [
                        {
                            "kind": validator.installed_matrix_receipt.PROOF_ARTIFACT_KIND,
                            "path": str(self.task10_matrix_receipt),
                            "sha256": _sha(self.task10_matrix_receipt.read_bytes()),
                        },
                        {
                            "kind": validator.TASK10_NETWORK_EXECUTION_ARTIFACT_KIND,
                            "path": str(self.task10_execution),
                            "sha256": _sha(self.task10_execution.read_bytes()),
                        },
                        {
                            "kind": validator.TASK10_NETWORK_OBSERVATION_ARTIFACT_KIND,
                            "path": str(self.task10_observation),
                            "sha256": _sha(self.task10_observation.read_bytes()),
                        },
                        {
                            "kind": validator.TASK10_NETWORK_REPORT_ARTIFACT_KIND,
                            "path": str(self.task10_audit),
                            "sha256": _sha(self.task10_audit.read_bytes()),
                        },
                        {
                            "kind": validator.TASK10_SEMANTIC_ARTIFACT_KIND,
                            "path": str(self.task10_semantic),
                            "sha256": _sha(self.task10_semantic.read_bytes()),
                        },
                        {"kind": "xcresult", "path": str(self.task10_xcresult)},
                    ],
                }
            ]
        }
        self._write_document(
            self.task10_incremental, self.task10_incremental_document
        )
        self.task10_result_record = {
            "incremental_evidence": {
                "path": str(self.task10_incremental),
                "sha256": _sha(self.task10_incremental.read_bytes()),
            },
            "matrix_receipt": {
                "path": str(self.task10_matrix_receipt),
                "sha256": _sha(self.task10_matrix_receipt.read_bytes()),
            },
            "network_artifact_root": {
                "audit_report_path": str(self.task10_audit),
                "audit_report_sha256": _sha(self.task10_audit.read_bytes()),
                "execution_report_path": str(self.task10_execution),
                "execution_report_sha256": _sha(self.task10_execution.read_bytes()),
                "observation_path": str(self.task10_observation),
                "observation_sha256": _sha(self.task10_observation.read_bytes()),
                "path": str(self.task10_network_root),
            },
            "xcresult": {
                "bundle_sha256": self.task10_bundle_sha256,
                "closed_tree_sha256": self.task10_closed_tree_sha256,
                "path": str(self.task10_xcresult),
            },
            "xcresult_semantic_manifest": {
                "path": str(self.task10_semantic),
                "sha256": _sha(self.task10_semantic.read_bytes()),
            },
        }

    def _result_document(self) -> dict[str, object]:
        return {
            "acceptance_receipt": {
                "path": str(self.acceptance_receipt),
                "sha256": _sha(self.acceptance_receipt.read_bytes()),
            },
            "candidate": {
                "application_executable_sha256": self.application_executable_sha256,
                "artifact_root": str(self.artifact_root),
                "identity_file_sha256": _sha(self.candidate_path.read_bytes()),
                "identity_path": str(self.candidate_path),
                "identity_sha256": self.candidate_identity_sha256,
                "provenance_path": str(self.provenance_path),
                "provenance_sha256": _sha(self.provenance_path.read_bytes()),
                "source_app_path": str(self.source_app),
                "source_commit": self.source_commit,
                "source_tree": self.source_tree,
            },
            "commit_authority": {
                "path": str(self.commit_authority),
                "sha256": _sha(self.commit_authority.read_bytes()),
            },
            "gate_envelopes": [
                {
                    "gate_id": gate_id,
                    "path": str(self.gate_envelopes[gate_id]),
                    "sha256": _sha(self.gate_envelopes[gate_id].read_bytes()),
                }
                for gate_id in validator.installer.REQUIRED_ACCEPTANCE_GATES
            ],
            "gate_plan": {
                "path": str(self.plan_path),
                "sha256": _sha(self.plan_path.read_bytes()),
            },
            "installed_task10": self.task10_result_record,
            "pending_state": {
                "path_at_begin": str(self.pending_path),
                "sha256": _sha(self.terminal_state.read_bytes()),
                "terminal_path": str(self.terminal_state),
            },
            "produced_at_unix_ns": self.produced_at,
            "qualification_run": {"nonce": self.run_nonce, "run_id": self.run_id},
            "result": "passed",
            "result_kind": validator.TRANSACTION_RESULT_KIND,
            "rolled_back": False,
            "schema_version": 1,
            "terminal_committed_state": {
                "path": str(self.terminal_state),
                "sha256": _sha(self.terminal_state.read_bytes()),
            },
            "transaction": self._transaction_document(),
            "transaction_phase": "committed",
        }

    def rewrite_result(self, *, canonical: bool = True) -> None:
        payload = (
            canonical_bytes(self.result_document)
            if canonical
            else json.dumps(self.result_document, indent=2).encode("utf-8") + b"\n"
        )
        self._write_bytes(self.result_path, payload)

    def validate_result(self) -> validator.TransactionResultAuthority:
        return validator._validate_transaction_result(
            self.result_path,
            candidate_artifact_root=self.artifact_root,
            qualification_run_root=self.qualification_root,
        )

    def closure(self) -> validator.Closure:
        result = self.validate_result()
        candidate_authority = validator.CandidateAuthority(
            candidate=self.parsed_candidate,
            identity=validator._read_stable_file(
                self.candidate_path,
                maximum_bytes=4 * 1024 * 1024,
                label="candidate fixture",
            ),
            provenance=validator._read_stable_file(
                self.provenance_path,
                maximum_bytes=1024,
                label="provenance fixture",
            ),
            provenance_document={},
            source_app=self.source_app,
            source_authority=SimpleNamespace(),
        )
        qualification_authority = validator.QualificationAuthority(
            document={
                "dependency_network_allowed": False,
                "dependency_network_used": False,
            },
            receipt=validator._read_stable_file(
                self.qualification_receipt,
                maximum_bytes=1024,
                label="qualification fixture",
            ),
            validated=SimpleNamespace(
                run_root=self.qualification_root,
                dependency_files=(),
            ),
            source_provenance={},
            source_provenance_sha256="d" * 64,
            result_bundle=self.result_bundle,
            coverage=validator._read_stable_file(
                self.coverage,
                maximum_bytes=1024,
                label="coverage fixture",
            ),
        )
        state = self._transaction_document()
        state.update(
            {
                "artifact_root": str(self.installer_artifact_root),
                "artifact_root_identity": self.artifact_root_identity,
                "destination_identity": self.destination_identity,
                "installed_app_path": str(self.installed_app),
            }
        )
        gate_files = result.gate_envelopes
        gate_records = {
            gate_id: {
                "ended_at_unix_ns": self.gate_documents[gate_id]["ended_at_unix_ns"],
                "evidence_sha256": self.gate_documents[gate_id]["evidence_sha256"],
                "input_sha256": snapshot.sha256,
                "result": "passed",
                "started_at_unix_ns": self.gate_documents[gate_id][
                    "started_at_unix_ns"
                ],
            }
            for gate_id, snapshot in gate_files
        }
        installation = validator.InstallationAuthority(
            state=state,
            state_file=result.terminal_state,
            installer_state_file=SimpleNamespace(payload=result.terminal_state.payload),
            terminal_root=self.terminal_root,
            installed_app=self.installed_app,
            installed_snapshot=SimpleNamespace(),
            acceptance_receipt=result.acceptance_receipt,
            acceptance_document={"produced_at_unix_ns": self.produced_at - 1},
            commit_authority=result.commit_authority,
            commit_document={},
            gate_files=gate_files,
            gate_records=gate_records,
        )
        local_ref = validator.LocalRefAuthority(
            repository_root=self.root,
            integration_ref="refs/remotes/gitfox-local/final",
            remote_name="gitfox-local",
            branch_name="final",
            remote_url=str(self.root),
            commit=self.source_commit,
            tree=self.source_tree,
        )
        inputs = (
            result.result_file,
            qualification_authority.receipt,
            qualification_authority.coverage,
            candidate_authority.identity,
            candidate_authority.provenance,
            result.terminal_state,
            result.acceptance_receipt,
            result.commit_authority,
            result.gate_plan,
            result.native_preparation_receipt,
            result.native_xctestrun,
            result.installed_task10.matrix_receipt,
            result.installed_task10.semantic_manifest,
            result.installed_task10.audit_report,
            result.installed_task10.execution_report,
            result.installed_task10.observation,
            result.installed_task10.incremental_evidence,
            *(snapshot for _gate_id, snapshot in result.gate_output_files),
            result.ws24_aggregate,
            *(snapshot for _gate_id, snapshot in result.gate_envelopes),
        )
        return validator.Closure(
            local_ref=local_ref,
            qualification=qualification_authority,
            candidate=candidate_authority,
            installation=installation,
            qualification_run=result.qualification_run,
            transaction_result=result,
            input_files=inputs,
        )


class ValidateFinalLocalCandidateTests(unittest.TestCase):
    def _rewrite_network_report(self, payload=None):
        if payload is not None:
            self.fixture._write_bytes(self.fixture.task10_observation, payload)
            self.fixture.task10_audit_document["observer"].update(
                observation_byte_count=len(payload), observation_sha256=_sha(payload))
        self.fixture._write_document(self.fixture.task10_audit, self.fixture.task10_audit_document)
        network = self.fixture.task10_result_record["network_artifact_root"]
        network["audit_report_sha256"] = _sha(self.fixture.task10_audit.read_bytes())
        network["observation_sha256"] = _sha(self.fixture.task10_observation.read_bytes())
        artifacts = self.fixture.task10_incremental_document["evidence"][0]["proofArtifacts"]
        artifacts[2]["sha256"] = network["observation_sha256"]
        artifacts[3]["sha256"] = network["audit_report_sha256"]
        self.fixture._write_document(self.fixture.task10_incremental, self.fixture.task10_incremental_document)
        self.fixture.task10_result_record["incremental_evidence"]["sha256"] = _sha(self.fixture.task10_incremental.read_bytes())
        self.fixture.rewrite_result()

    def _foreign_network(self):
        # Synthetic retained proof, not an assertion of real process observation.
        from Scripts.tests.test_network_attribution import fixture as proof_fixture
        proofs, drains = proof_fixture()
        self.fixture.task10_audit_document["attribution"].update(proofs=proofs, drains=drains)
        self.fixture.task10_audit_document["observer"].update(
            observed_process_row_count=1, observed_foreign_row_count=1)
        self._rewrite_network_report(b",bytes_in,bytes_out,\nlaunchd.10,0,0,\n")

    def test_installed_task10_accepts_replayed_foreign_row(self):
        self._foreign_network()
        self.fixture.validate_result()

    def test_installed_task10_rejects_rehashed_unknown_row(self):
        self._foreign_network()
        self._rewrite_network_report(b",bytes_in,bytes_out,\nnew.999,0,0,\n")
        with self.assertRaises(validator.FinalLocalCandidateError):
            self.fixture.validate_result()

    def test_installed_task10_rejects_intermediate_exec_and_forged_candidate_exclusion(self):
        self._foreign_network()
        attribution = self.fixture.task10_audit_document["attribution"]
        attribution["drains"][1]["events"] = [{"watch_token": 1, "pid": 10, "filter": -5,
            "flags": 0x8075, "fflags": 0xA0000000, "data": 0}]
        self._rewrite_network_report()
        with self.assertRaises(validator.FinalLocalCandidateError):
            self.fixture.validate_result()
        attribution["drains"][1]["events"] = []
        for key in ("initial_probe", "final_probe"):
            attribution["proofs"][0][key]["executable_path"] = str(self.fixture.installed_app / "Contents/MacOS/MacScope")
        self._rewrite_network_report()
        with self.assertRaises(validator.FinalLocalCandidateError):
            self.fixture.validate_result()

    def test_installed_task10_rejects_legacy_schema_even_rehashed(self):
        self.fixture.task10_audit_document["schema_version"] = 3
        self._rewrite_network_report()
        with self.assertRaises(validator.FinalLocalCandidateError):
            self.fixture.validate_result()

    def test_installed_task10_rejects_report_candidate_path_substitution(self):
        self.fixture.task10_audit_document["executables"][0]["executable_path"] = "/tmp/foreign"
        self._rewrite_network_report()
        with self.assertRaises(validator.FinalLocalCandidateError):
            self.fixture.validate_result()

    def setUp(self) -> None:
        self.fixture = TransactionFixture()
        self.plan_contract = mock.patch.object(
            validator,
            "_validate_frozen_plan_contract",
            side_effect=self._validate_fixture_plan_contract,
        )
        self.plan_contract.start()

    def tearDown(self) -> None:
        self.plan_contract.stop()
        self.fixture.cleanup()

    def _validate_fixture_plan_contract(self, document: dict[str, object]) -> None:
        if canonical_bytes(document) != self.fixture.frozen_plan_payload:
            raise validator.FinalLocalCandidateError("literal plan argv differs")

    def test_schema_one_transaction_result_success(self) -> None:
        authority = self.fixture.validate_result()
        self.assertEqual(authority.result_file.path, self.fixture.result_path)
        self.assertEqual(
            tuple(gate_id for gate_id, _snapshot in authority.gate_envelopes),
            validator.installer.REQUIRED_ACCEPTANCE_GATES,
        )
        self.assertEqual(len(authority.gate_output_files), 8)
        self.assertEqual(
            authority.installed_task10.document,
            self.fixture.task10_result_record,
        )

    def test_ws24_aggregate_rejects_wrong_live_evidence_digest(self) -> None:
        aggregate = json.loads(self.fixture.ws24_aggregate.read_text(encoding="utf-8"))
        aggregate["liveEvidenceSHA256"] = "0" * 64
        cli_document = json.loads(
            self.fixture.cli_gui_report.read_text(encoding="utf-8")
        )
        mcp_document = json.loads(self.fixture.mcp_report.read_text(encoding="utf-8"))
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "live-evidence digest differs",
        ):
            validator._validate_ws24_aggregate(
                aggregate,
                transaction=self.fixture._transaction_document(),
                cli_gui_report=SimpleNamespace(
                    sha256=_sha(self.fixture.cli_gui_report.read_bytes())
                ),
                cli_gui_document=cli_document,
                mcp_report=SimpleNamespace(
                    sha256=_sha(self.fixture.mcp_report.read_bytes())
                ),
                mcp_document=mcp_document,
                live_evidence_manifest=SimpleNamespace(
                    sha256=_sha(
                        self.fixture.primary_outputs[
                            "shellbroker-launchagent"
                        ].read_bytes()
                    )
                ),
            )
    def test_gate_plan_authority_schema_matches_the_frozen_compiler(self) -> None:
        self.assertEqual(
            validator.GATE_PLAN_AUTHORITY_FIELDS,
            compiler.AUTHORITY_FIELDS,
        )

    def test_gate_plan_timeouts_match_the_frozen_compiler(self) -> None:
        self.assertEqual(validator.GATE_PLAN_TIMEOUTS, compiler.FIXED_TIMEOUTS)
        self.assertEqual(
            validator.GATE_PLAN_OUTPUTS,
            {
                gate_id: (
                    compiler.FIXED_OUTPUT_KINDS[gate_id],
                    str(compiler.PRIMARY_OUTPUT_RELATIVE_PATHS[gate_id]),
                )
                for gate_id in compiler.GATE_IDS
            },
        )
        self.assertEqual(
            validator.GATE_PLAN_MAXIMUM_BYTES,
            compiler.FIXED_OUTPUT_MAXIMUM_BYTES,
        )

    def test_only_governed_bash_script_file_invocations_are_admitted(self) -> None:
        for gate_id, script in validator.GOVERNED_BASH_GATE_SCRIPTS.items():
            with self.subTest(gate_id=gate_id):
                self.assertEqual(
                    validator._validate_gate_executable(
                        ["/bin/bash", str(script), "--fixture"],
                        gate_id=gate_id,
                    ),
                    Path("/bin/bash"),
                )
        rejected = (
            ("cli", ["/bin/bash", "-c", "true"]),
            ("cli", ["/bin/bash", "/tmp/arbitrary.sh"]),
            (
                "mcp",
                [
                    "/bin/bash",
                    str(validator.GOVERNED_BASH_GATE_SCRIPTS["cli"]),
                ],
            ),
            ("cli", ["/bin/sh", str(validator.GOVERNED_BASH_GATE_SCRIPTS["cli"])]),
        )
        for gate_id, argv in rejected:
            with self.subTest(gate_id=gate_id, argv=argv):
                with self.assertRaises(validator.FinalLocalCandidateError):
                    validator._validate_gate_executable(argv, gate_id=gate_id)

    def test_candidate_source_app_must_be_the_qualified_release_product(self) -> None:
        source_app = self.fixture.artifact_root / "Debug" / "MacScope.app"
        candidate = self.fixture.result_document["candidate"]
        assert isinstance(candidate, dict)
        candidate["source_app_path"] = str(source_app)
        candidate["provenance_path"] = str(
            source_app / "Contents" / "Resources" / "MacScopeBuildProvenance.json"
        )
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "source app differs from the qualified Release product",
        ):
            self.fixture.validate_result()

    def test_installed_task10_rejects_every_outer_path_and_digest_mutation(self) -> None:
        original = copy.deepcopy(self.fixture.task10_result_record)
        alternate = str(self.fixture.acceptance_receipt)
        mutations = (
            ("matrix path", lambda row: row["matrix_receipt"].__setitem__("path", alternate)),
            ("matrix digest", lambda row: row["matrix_receipt"].__setitem__("sha256", "0" * 64)),
            ("xcresult path", lambda row: row["xcresult"].__setitem__("path", str(self.fixture.result_bundle))),
            ("xcresult bundle digest", lambda row: row["xcresult"].__setitem__("bundle_sha256", "0" * 64)),
            ("xcresult tree digest", lambda row: row["xcresult"].__setitem__("closed_tree_sha256", "0" * 64)),
            ("semantic path", lambda row: row["xcresult_semantic_manifest"].__setitem__("path", alternate)),
            ("semantic digest", lambda row: row["xcresult_semantic_manifest"].__setitem__("sha256", "0" * 64)),
            ("network root path", lambda row: row["network_artifact_root"].__setitem__("path", str(self.fixture.evidence_root))),
            ("audit path", lambda row: row["network_artifact_root"].__setitem__("audit_report_path", str(self.fixture.task10_execution))),
            ("audit digest", lambda row: row["network_artifact_root"].__setitem__("audit_report_sha256", "0" * 64)),
            ("execution path", lambda row: row["network_artifact_root"].__setitem__("execution_report_path", str(self.fixture.task10_audit))),
            ("execution digest", lambda row: row["network_artifact_root"].__setitem__("execution_report_sha256", "0" * 64)),
            ("observation path", lambda row: row["network_artifact_root"].__setitem__("observation_path", str(self.fixture.task10_audit))),
            ("observation digest", lambda row: row["network_artifact_root"].__setitem__("observation_sha256", "0" * 64)),
            ("incremental path", lambda row: row["incremental_evidence"].__setitem__("path", alternate)),
            ("incremental digest", lambda row: row["incremental_evidence"].__setitem__("sha256", "0" * 64)),
        )
        for label, mutate in mutations:
            with self.subTest(label=label):
                mutated = copy.deepcopy(original)
                mutate(mutated)
                self.fixture.result_document["installed_task10"] = mutated
                self.fixture.rewrite_result()
                with self.assertRaises(validator.FinalLocalCandidateError):
                    self.fixture.validate_result()
        self.fixture.result_document["installed_task10"] = original
        self.fixture.task10_result_record = original
        self.fixture.rewrite_result()

    def test_installed_task10_rejects_extra_network_child(self) -> None:
        self.fixture._write_bytes(self.fixture.task10_network_root / "extra", b"extra")
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "exact closed child set",
        ):
            self.fixture.validate_result()

    def test_installed_task10_rejects_hardlinked_and_symlinked_files(self) -> None:
        with self.subTest(kind="hardlink"):
            os.link(
                self.fixture.task10_matrix_receipt,
                self.fixture.root / "task10-matrix-hardlink",
            )
            with self.assertRaisesRegex(
                validator.FinalLocalCandidateError,
                "single-link",
            ):
                self.fixture.validate_result()
        self.fixture.cleanup()
        self.fixture = TransactionFixture()
        with self.subTest(kind="symlink"):
            target = self.fixture.root / "semantic-target.json"
            target.write_bytes(self.fixture.task10_semantic.read_bytes())
            self.fixture.task10_semantic.unlink()
            self.fixture.task10_semantic.symlink_to(target)
            with self.assertRaisesRegex(
                validator.FinalLocalCandidateError,
                "single-link non-symlink|must not traverse symbolic links",
            ):
                self.fixture.validate_result()

    def test_installed_task10_rejects_xcresult_tree_drift(self) -> None:
        self.fixture._write_bytes(
            self.fixture.task10_xcresult / "result.json",
            b"drifted-xcresult",
        )
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "xcresult bytes/tree differ",
        ):
            self.fixture.validate_result()

    def test_installed_task10_rejects_rehashed_descriptor_substitution(self) -> None:
        artifacts = self.fixture.task10_incremental_document["evidence"][0][
            "proofArtifacts"
        ]
        artifacts[0]["kind"] = "substituted-receipt"
        self.fixture._write_document(
            self.fixture.task10_incremental,
            self.fixture.task10_incremental_document,
        )
        self.fixture.task10_result_record["incremental_evidence"]["sha256"] = _sha(
            self.fixture.task10_incremental.read_bytes()
        )
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "incremental artifact 0 is substituted",
        ):
            self.fixture.validate_result()

    def test_installed_task10_rejects_rehashed_network_receipt_binding(self) -> None:
        self.fixture.task10_audit_document["workload"]["matrix_receipt_sha256"] = (
            "0" * 64
        )
        self.fixture._write_document(
            self.fixture.task10_audit, self.fixture.task10_audit_document
        )
        audit_digest = _sha(self.fixture.task10_audit.read_bytes())
        self.fixture.task10_result_record["network_artifact_root"][
            "audit_report_sha256"
        ] = audit_digest
        self.fixture.task10_incremental_document["evidence"][0]["proofArtifacts"][3][
            "sha256"
        ] = audit_digest
        self.fixture._write_document(
            self.fixture.task10_incremental,
            self.fixture.task10_incremental_document,
        )
        self.fixture.task10_result_record["incremental_evidence"]["sha256"] = _sha(
            self.fixture.task10_incremental.read_bytes()
        )
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "exact passing workload",
        ):
            self.fixture.validate_result()

    def test_installed_task10_rejects_rehashed_run_and_predecessor_substitution(self) -> None:
        for field, value in (
            ("qualification_run", {"nonce": "0" * 64, "run_id": self.fixture.run_id}),
            ("predecessor_observations_sha256", "0" * 64),
        ):
            with self.subTest(field=field):
                document = copy.deepcopy(self.fixture.task10_execution_document)
                document[field] = value
                self.fixture._write_document(self.fixture.task10_execution, document)
                digest = _sha(self.fixture.task10_execution.read_bytes())
                self.fixture.task10_result_record["network_artifact_root"][
                    "execution_report_sha256"
                ] = digest
                descriptor = copy.deepcopy(self.fixture.task10_incremental_document)
                descriptor["evidence"][0]["proofArtifacts"][1]["sha256"] = digest
                self.fixture._write_document(self.fixture.task10_incremental, descriptor)
                self.fixture.task10_result_record["incremental_evidence"]["sha256"] = _sha(
                    self.fixture.task10_incremental.read_bytes()
                )
                self.fixture.rewrite_result()
                with self.assertRaisesRegex(
                    validator.FinalLocalCandidateError,
                    "execution report is not the bound passing authority",
                ):
                    self.fixture.validate_result()
                self.fixture._write_document(
                    self.fixture.task10_execution,
                    self.fixture.task10_execution_document,
                )

    def test_installed_task10_rejects_rehashed_network_observation_semantics(self) -> None:
        payload = b",bytes_in,bytes_out,\nMacScope.123,1,0,\n"
        self.fixture._write_bytes(self.fixture.task10_observation, payload)
        self.fixture.task10_audit_document["observer"]["observation_byte_count"] = len(
            payload
        )
        self.fixture.task10_audit_document["observer"]["observation_sha256"] = _sha(
            payload
        )
        self.fixture._write_document(
            self.fixture.task10_audit, self.fixture.task10_audit_document
        )
        observation_digest = _sha(payload)
        audit_digest = _sha(self.fixture.task10_audit.read_bytes())
        network = self.fixture.task10_result_record["network_artifact_root"]
        network["observation_sha256"] = observation_digest
        network["audit_report_sha256"] = audit_digest
        artifacts = self.fixture.task10_incremental_document["evidence"][0][
            "proofArtifacts"
        ]
        artifacts[2]["sha256"] = observation_digest
        artifacts[3]["sha256"] = audit_digest
        self.fixture._write_document(
            self.fixture.task10_incremental,
            self.fixture.task10_incremental_document,
        )
        self.fixture.task10_result_record["incremental_evidence"]["sha256"] = _sha(
            self.fixture.task10_incremental.read_bytes()
        )
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "sampled-state interval",
        ):
            self.fixture.validate_result()

    def test_reopened_candidate_run_transaction_and_plan_bindings_succeed(self) -> None:
        closure = self.fixture.closure()
        with (
            mock.patch.object(
                validator.native_preparation,
                "load_receipt",
                return_value={},
            ),
            mock.patch.object(
                validator.native_preparation,
                "validate_prepared",
                return_value=closure.transaction_result.native_preparation_receipt.sha256,
            ),
        ):
            validator._validate_result_bindings(
                closure.transaction_result,
                qualification_authority=closure.qualification,
                candidate=closure.candidate,
                installation=closure.installation,
                candidate_artifact_root=self.fixture.artifact_root,
            )

    def test_substituted_artifact_is_rejected(self) -> None:
        self.fixture.acceptance_receipt.write_bytes(b"substituted")
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "bytes differ from the transaction result",
        ):
            self.fixture.validate_result()

    def test_substituted_plan_argv_is_rejected_by_frozen_compiler_contract(self) -> None:
        gates = self.fixture.plan_document["gates"]
        assert isinstance(gates, list)
        gates[0]["argv"] = ["/usr/bin/true", "substituted"]
        self.fixture._write_document(self.fixture.plan_path, self.fixture.plan_document)
        plan_record = self.fixture.result_document["gate_plan"]
        assert isinstance(plan_record, dict)
        plan_record["sha256"] = _sha(self.fixture.plan_path.read_bytes())
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "literal plan argv differs",
        ):
            self.fixture.validate_result()

    def test_stale_primary_output_is_rejected(self) -> None:
        path = self.fixture.primary_outputs["cli"]
        stale = self.fixture.plan_path.stat().st_mtime_ns - 1
        os.utime(path, ns=(stale, stale))
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "predates its compiled plan",
        ):
            self.fixture.validate_result()

    def test_duplicate_gate_is_rejected(self) -> None:
        rows = self.fixture.result_document["gate_envelopes"]
        assert isinstance(rows, list)
        rows[1] = dict(rows[0])
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "eight distinct IDs|canonical order",
        ):
            self.fixture.validate_result()

    def test_hardlinked_input_is_rejected(self) -> None:
        source = self.fixture.gate_envelopes["cli"]
        os.link(source, self.fixture.root / "gate-hardlink")
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "single-link",
        ):
            self.fixture.validate_result()

    def test_symlinked_input_is_rejected(self) -> None:
        source = self.fixture.acceptance_receipt
        target = self.fixture.root / "acceptance-target.json"
        target.write_bytes(source.read_bytes())
        source.unlink()
        source.symlink_to(target)
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "single-link non-symlink|must not traverse symbolic links",
        ):
            self.fixture.validate_result()

    def test_noncanonical_json_is_rejected(self) -> None:
        self.fixture.rewrite_result(canonical=False)
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "not canonical JSON",
        ):
            self.fixture.validate_result()

    def test_noncanonical_path_is_rejected(self) -> None:
        candidate = self.fixture.result_document["candidate"]
        assert isinstance(candidate, dict)
        candidate["identity_path"] = str(
            self.fixture.artifact_root / "nested" / ".." / "candidate.json"
        )
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "absolute canonical path",
        ):
            self.fixture.validate_result()

    def test_local_ref_mismatch_is_rejected_before_dependent_validation(self) -> None:
        arguments = SimpleNamespace(
            transaction_result=self.fixture.result_path,
            integration_ref="refs/remotes/gitfox-local/final",
            qualification_receipt=self.fixture.qualification_receipt,
            candidate_artifact_root=self.fixture.artifact_root,
        )
        mismatched = validator.LocalRefAuthority(
            repository_root=self.fixture.root,
            integration_ref=arguments.integration_ref,
            remote_name="gitfox-local",
            branch_name="final",
            remote_url=str(self.fixture.root),
            commit="e" * 40,
            tree="f" * 40,
        )
        with mock.patch.object(validator, "_resolve_local_ref", return_value=mismatched):
            with self.assertRaisesRegex(
                validator.FinalLocalCandidateError,
                "differs from the exact local integration ref",
            ):
                validator.validate_inputs(arguments, allow_test_destination=True)

    def test_rollback_result_is_rejected(self) -> None:
        self.fixture.result_document["rolled_back"] = True
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "passing committed schema-1 authority",
        ):
            self.fixture.validate_result()

    def test_nonterminal_result_is_rejected(self) -> None:
        self.fixture.result_document["transaction_phase"] = "pending"
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "passing committed schema-1 authority",
        ):
            self.fixture.validate_result()

    def test_missing_gate_is_rejected(self) -> None:
        rows = self.fixture.result_document["gate_envelopes"]
        assert isinstance(rows, list)
        rows.pop()
        self.fixture.rewrite_result()
        with self.assertRaisesRegex(
            validator.FinalLocalCandidateError,
            "exactly eight gate envelopes",
        ):
            self.fixture.validate_result()

    def test_cli_publishes_one_create_only_canonical_receipt_path(self) -> None:
        closure = self.fixture.closure()
        output = self.fixture.root / "FinalLocalCandidate.receipt.json"
        arguments = [
            "--transaction-result",
            str(self.fixture.result_path),
            "--integration-ref",
            "refs/remotes/gitfox-local/final",
            "--qualification-receipt",
            str(self.fixture.qualification_receipt),
            "--candidate-artifact-root",
            str(self.fixture.artifact_root),
            "--output",
            str(output),
        ]
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(validator, "validate_inputs", return_value=closure),
            mock.patch.object(validator, "_revalidate_closure"),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = validator.main(
                arguments,
                _clock_ns=lambda: self.fixture.produced_at + 100,
            )
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue(), f"{output}\n")
        self.assertEqual(stderr.getvalue(), "")
        payload = output.read_bytes()
        self.assertFalse(payload.endswith(b"\n"))
        receipt = decode_canonical_bytes(payload)
        self.assertEqual(receipt["result"], "passed")
        self.assertEqual(
            receipt["transaction_result"]["installed_task10"],
            self.fixture.task10_result_record,
        )
        self.assertEqual(receipt["scope"], {
            "authority": validator.AUTHORITY_SCOPE,
            "gate_f_claimed": False,
            "online_delivery_claimed": False,
            "post_2026_09_11_proof_claimed": False,
            "public_release_claimed": False,
        })
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(validator, "validate_inputs", return_value=closure),
            mock.patch.object(validator, "_revalidate_closure"),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            repeated = validator.main(
                arguments,
                _clock_ns=lambda: self.fixture.produced_at + 200,
            )
        self.assertEqual(repeated, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("create-only publication refused", stderr.getvalue())

    def test_parser_rejects_removed_direct_artifact_flags(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            validator.parse_arguments(
                [
                    "--transaction-result",
                    str(self.fixture.result_path),
                    "--integration-ref",
                    "refs/remotes/gitfox-local/final",
                    "--qualification-receipt",
                    str(self.fixture.qualification_receipt),
                    "--candidate-artifact-root",
                    str(self.fixture.artifact_root),
                    "--output",
                    str(self.fixture.root / "receipt.json"),
                    "--acceptance-receipt",
                    str(self.fixture.acceptance_receipt),
                ]
            )
        self.assertIn("exactly once in frozen order", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
