#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
from pathlib import Path
import unittest
from unittest import mock

from Scripts import ws24_emit_installed_qualification_report as ws24
from Scripts.reconstruction import compile_installed_acceptance_gate_plan as compiler
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import installed_matrix_receipt
from Scripts.reconstruction import run_installed_acceptance_transaction as transaction
from Scripts.reconstruction import validate_final_local_candidate as final_validator
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority
from Scripts.tests.test_compile_installed_acceptance_gate_plan import CompilerFixture
from Scripts.tests.test_run_installed_acceptance_transaction import (
    InstalledAcceptanceTransactionTests,
)
from Scripts.tests.test_validate_final_local_candidate import TransactionFixture
from Scripts.tests.test_ws24_emit_installed_qualification_report import (
    PREDECESSOR_SHA256,
    RUN_ID,
    RUN_NONCE,
)


GATE_IDS = (
    "cli",
    "forced-legacy-grid",
    "full-surface",
    "gui",
    "mcp",
    "native-xpc",
    "shellbroker-launchagent",
    "signing",
)

PLAN_FIELDS = frozenset(
    {
        "authority",
        "authority_sha256",
        "candidate_artifact_root",
        "evidence_root",
        "gates",
        "output_path",
        "plan_kind",
        "schema_version",
    }
)
PLAN_AUTHORITY_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "artifact_root_identity_sha256",
        "artifact_root_path",
        "began_at_unix_ns",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_path",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "execution_identity_sha256",
        "exposed_at_unix_ns",
        "installed_app_path",
        "installed_task10_incremental_evidence_path",
        "installed_task10_matrix_receipt_path",
        "installed_task10_network_artifact_root",
        "installed_task10_xcresult_path",
        "installed_task10_xcresult_semantic_manifest_path",
        "installed_ui_preparation_receipt_path",
        "installed_ui_preparation_receipt_sha256",
        "installed_ui_runner_closed_tree_sha256",
        "installed_ui_runner_executable_sha256",
        "installed_ui_runner_path",
        "installed_ui_test_bundle_closed_tree_sha256",
        "installed_ui_test_bundle_executable_sha256",
        "installed_ui_test_bundle_path",
        "installed_ui_xctestrun_path",
        "installed_ui_xctestrun_sha256",
        "native_preparation_receipt_path",
        "native_preparation_receipt_sha256",
        "native_xctestrun_path",
        "native_xctestrun_sha256",
        "pending_state_path",
        "pending_state_sha256",
        "predecessor_digest",
        "predecessor_observations_sha256",
        "qualification_receipt_path",
        "qualification_receipt_sha256",
        "qualification_run_id",
        "qualification_run_nonce",
        "source_app_path",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "transaction_id",
        "transaction_nonce",
    }
)
PLAN_GATE_FIELDS = frozenset(
    {
        "argv",
        "authority_sha256",
        "depends_on",
        "environment",
        "gate_id",
        "operation_id",
        "output",
        "timeout_seconds",
    }
)
PLAN_OUTPUT_FIELDS = frozenset({"kind", "maximum_bytes", "path", "publication"})

PENDING_SNAPSHOT_FIELDS = frozenset(
    {"closed_tree_sha256", "content_sha256", "directory_identity", "root_mode"}
)
PENDING_ARTIFACT_ROOT_FIELDS = frozenset(
    {
        "directory_device",
        "directory_inode",
        "parent_device",
        "parent_inode",
        "path",
        "state_at_begin",
    }
)
PENDING_DESTINATION_FIELDS = frozenset(
    {
        "application_device",
        "application_inode",
        "application_mtime_ns",
        "closed_tree_sha256",
        "content_sha256",
        "parent_device",
        "parent_inode",
        "path",
        "root_mode",
    }
)

GATE_ENVELOPE_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "ended_at_unix_ns",
        "evidence_sha256",
        "execution_identity_sha256",
        "gate_id",
        "input_kind",
        "qualification_run_id",
        "qualification_run_nonce",
        "result",
        "rolled_back",
        "schema_version",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "started_at_unix_ns",
        "transaction_id",
        "transaction_nonce",
        "transaction_phase",
    }
)

TASK10_FIELDS = frozenset(
    {
        "incremental_evidence",
        "matrix_receipt",
        "network_artifact_root",
        "xcresult",
        "xcresult_semantic_manifest",
    }
)
TASK10_FILE_FIELDS = frozenset({"path", "sha256"})
TASK10_XCRESULT_FIELDS = frozenset({"bundle_sha256", "closed_tree_sha256", "path"})
TASK10_NETWORK_DESCRIPTOR_FIELDS = frozenset(
    {
        "audit_report_path",
        "audit_report_sha256",
        "execution_report_path",
        "execution_report_sha256",
        "observation_path",
        "observation_sha256",
        "path",
    }
)
TASK10_SEMANTIC_FIELDS = frozenset(
    {
        "candidate_identity_sha256",
        "executed_selector_count",
        "expected_selector_count",
        "failed_selector_count",
        "observed_selector_projection",
        "observed_selector_projection_sha256",
        "passed_selector_count",
        "result",
        "schema_version",
        "selector_catalog_sha256",
        "selector_projection",
        "selector_projection_sha256",
        "selectors",
        "skipped_selector_count",
        "source_xcresult",
    }
)
TASK10_NETWORK_REPORT_FIELDS = frozenset(
    {
        "attribution",
        "artifacts",
        "candidate",
        "command_id",
        "diagnostic",
        "ended_at_unix_ms",
        "evidence_layer",
        "executables",
        "exit_code",
        "observer",
        "result",
        "schema_version",
        "started_at_unix_ms",
        "workload",
    }
)
TASK10_NETWORK_ATTRIBUTION_FIELDS = frozenset(
    {
        "policy_id",
        "observer_spawn_ns",
        "observer_eof_ns",
        "queue_closed_ns",
        "proofs",
        "drains",
    }
)
TASK10_EXECUTION_REPORT_FIELDS = frozenset(
    {
        "ended_at_unix_ms",
        "exit_code",
        "predecessor_observations_sha256",
        "qualification_run",
        "result",
        "schema_version",
        "started_at_unix_ms",
        "stress",
    }
)

RESULT_FIELDS = frozenset(
    {
        "acceptance_receipt",
        "candidate",
        "commit_authority",
        "gate_envelopes",
        "gate_plan",
        "installed_task10",
        "pending_state",
        "produced_at_unix_ns",
        "qualification_run",
        "result",
        "result_kind",
        "rolled_back",
        "schema_version",
        "terminal_committed_state",
        "transaction",
        "transaction_phase",
    }
)
RESULT_CANDIDATE_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "artifact_root",
        "identity_file_sha256",
        "identity_path",
        "identity_sha256",
        "provenance_path",
        "provenance_sha256",
        "source_app_path",
        "source_commit",
        "source_tree",
    }
)
RESULT_TRANSACTION_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "began_at_unix_ns",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "execution_identity_sha256",
        "exposed_at_unix_ns",
        "predecessor_digest",
        "predecessor_observations_sha256",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "transaction_id",
        "transaction_nonce",
    }
)
RESULT_GATE_FIELDS = frozenset({"gate_id", "path", "sha256"})

FINAL_FIELDS = frozenset(
    {
        "acceptance_gates",
        "candidate",
        "installation",
        "integration",
        "produced_at_unix_ns",
        "qualification",
        "receipt_kind",
        "result",
        "schema_version",
        "scope",
        "transaction_result",
    }
)
FINAL_GATE_FIELDS = frozenset(
    {
        "ended_at_unix_ns",
        "evidence_path",
        "evidence_sha256",
        "gate_id",
        "input_path",
        "input_sha256",
        "primary_output_path",
        "primary_output_sha256",
        "result",
        "started_at_unix_ns",
    }
)
FINAL_CANDIDATE_FIELDS = frozenset(
    {
        "application_bundle_sha256",
        "application_closed_tree_sha256",
        "application_executable_sha256",
        "application_root_mode",
        "identity_file_sha256",
        "identity_path",
        "identity_sha256",
        "provenance_path",
        "provenance_sha256",
        "source_app_path",
    }
)
FINAL_INSTALLATION_FIELDS = frozenset(
    {
        "acceptance_produced_at_unix_ns",
        "acceptance_receipt_path",
        "acceptance_receipt_sha256",
        "began_at_unix_ns",
        "commit_authority_path",
        "commit_authority_sha256",
        "destination_identity_sha256",
        "execution_identity_sha256",
        "exposed_at_unix_ns",
        "installed_app_path",
        "pending_state_path_at_begin",
        "predecessor_digest",
        "predecessor_observations_sha256",
        "rolled_back",
        "source_equality_sha256",
        "terminal_state_path",
        "terminal_state_sha256",
        "transaction_id",
        "transaction_nonce",
        "transaction_phase",
    }
)
FINAL_INTEGRATION_FIELDS = frozenset(
    {"branch", "commit", "ref", "remote", "remote_url", "tree"}
)
FINAL_QUALIFICATION_FIELDS = frozenset(
    {
        "coverage_path",
        "coverage_sha256",
        "dependency_network_allowed",
        "dependency_network_used",
        "mode",
        "receipt_path",
        "receipt_sha256",
        "result_bundle_path",
        "run_id",
        "run_nonce",
        "run_root",
        "source_provenance_sha256",
    }
)
FINAL_SCOPE_FIELDS = frozenset(
    {
        "authority",
        "gate_f_claimed",
        "online_delivery_claimed",
        "post_2026_09_11_proof_claimed",
        "public_release_claimed",
    }
)
FINAL_TRANSACTION_RESULT_FIELDS = frozenset(
    {
        "candidate_artifact_root",
        "gate_plan_authority_sha256",
        "gate_plan_path",
        "gate_plan_sha256",
        "installed_task10",
        "native_preparation_receipt_path",
        "native_preparation_receipt_sha256",
        "native_xctestrun_path",
        "native_xctestrun_sha256",
        "path",
        "produced_at_unix_ns",
        "sha256",
        "ws24_aggregate_path",
        "ws24_aggregate_sha256",
    }
)


def _duplicate_top_level(document: dict[str, object], field: str) -> bytes:
    payload = canonical_bytes(document)
    return payload[:-1] + b"," + canonical_bytes(field) + b":" + canonical_bytes(document[field]) + b"}"


def _assert_closed(test: unittest.TestCase, value: object, fields: frozenset[str]) -> dict[str, object]:
    test.assertIsInstance(value, dict)
    record = value
    assert isinstance(record, dict)
    test.assertEqual(set(record), fields)
    return record


class InstalledAcceptanceClosedSchemaTests(unittest.TestCase):
    maxDiff = None

    def _assert_plan_rejected(self, plan: dict[str, object]) -> None:
        with self.assertRaises(compiler.PlanCompilationError):
            compiler.validate_plan_document(plan)

    def test_plan_schema_v1_is_exact_and_every_record_is_closed(self) -> None:
        with CompilerFixture() as fixture:
            plan = fixture.plan()
            self.assertEqual(compiler.validate_plan_document(copy.deepcopy(plan)), plan)
            _assert_closed(self, plan, PLAN_FIELDS)
            _assert_closed(self, plan["authority"], PLAN_AUTHORITY_FIELDS)
            self.assertEqual(plan["schema_version"], 1)
            self.assertEqual(plan["plan_kind"], "macscope-installed-acceptance-gate-plan")
            self.assertEqual(tuple(gate["gate_id"] for gate in plan["gates"]), GATE_IDS)
            for gate in plan["gates"]:
                _assert_closed(self, gate, PLAN_GATE_FIELDS)
                output = _assert_closed(self, gate["output"], PLAN_OUTPUT_FIELDS)
                self.assertEqual(output["publication"], "create-only")

            mutations = []
            for record_path in ((), ("authority",), ("gates", 0), ("gates", 0, "output")):
                for operation in ("unknown", "missing"):
                    candidate = copy.deepcopy(plan)
                    record: dict[str, object] = candidate
                    for component in record_path:
                        record = record[component]  # type: ignore[index,assignment]
                    if operation == "unknown":
                        record["unexpected"] = None
                    else:
                        record.pop(next(iter(record)))
                    mutations.append((f"{record_path}-{operation}", candidate))
            wrong_types = (
                ("top schema", lambda value: value.__setitem__("schema_version", "1")),
                (
                    "authority timestamp",
                    lambda value: value["authority"].__setitem__("began_at_unix_ns", "1"),
                ),
                (
                    "gate timeout",
                    lambda value: value["gates"][0].__setitem__("timeout_seconds", "90"),
                ),
                (
                    "output maximum",
                    lambda value: value["gates"][0]["output"].__setitem__(
                        "maximum_bytes", "65536"
                    ),
                ),
                (
                    "plan kind",
                    lambda value: value.__setitem__("plan_kind", "historical-plan"),
                ),
                (
                    "output publication",
                    lambda value: value["gates"][0]["output"].__setitem__(
                        "publication", "replace"
                    ),
                ),
            )
            for label, mutate in wrong_types:
                candidate = copy.deepcopy(plan)
                mutate(candidate)
                mutations.append((label, candidate))
            for label, candidate in mutations:
                with self.subTest(label=label):
                    self._assert_plan_rejected(candidate)

            fixture.output.write_bytes(_duplicate_top_level(plan, "schema_version"))
            fixture.output.chmod(0o600)
            with self.assertRaises(compiler.PlanCompilationError):
                compiler.load_plan(fixture.output)

    def _validate_pending(self, fixture: CompilerFixture, state: dict[str, object]) -> None:
        authority = installer._load_source_authority(
            fixture.bridge.candidate_identity, fixture.bridge.source_app
        )
        installer._pending_validate_state(
            state,
            authority=authority,
            token=fixture.bridge.candidate_digest,
            installed_app=fixture.bridge.installed_app,
            source_app=fixture.bridge.source_app,
            artifact_root=fixture.bridge.artifact_root,
            qualification_run=QualificationRunAuthority(run_id=RUN_ID, nonce=RUN_NONCE),
            predecessor_observations_sha256=PREDECESSOR_SHA256,
        )

    def test_pending_state_schema_v3_and_nested_identities_are_closed(self) -> None:
        with CompilerFixture() as fixture:
            state = copy.deepcopy(fixture.bridge.state)
            self._validate_pending(fixture, state)
            _assert_closed(self, state, installer.PENDING_TRANSACTION_FIELDS)
            _assert_closed(self, state["artifact_root_identity"], PENDING_ARTIFACT_ROOT_FIELDS)
            _assert_closed(self, state["candidate_identity"], PENDING_SNAPSHOT_FIELDS)
            _assert_closed(self, state["destination_identity"], PENDING_DESTINATION_FIELDS)
            self.assertEqual(state["schema_version"], 3)
            self.assertEqual(state["phase"], "pending")

            mutations = []
            for operation in ("unknown", "missing"):
                candidate = copy.deepcopy(state)
                if operation == "unknown":
                    candidate["unexpected"] = None
                else:
                    candidate.pop("transaction_nonce")
                mutations.append((operation, candidate))
            for label, mutate in (
                ("schema type", lambda value: value.__setitem__("schema_version", "3")),
                ("phase literal", lambda value: value.__setitem__("phase", "committed")),
                (
                    "nested unknown",
                    lambda value: value["candidate_identity"].__setitem__("unexpected", 1),
                ),
                (
                    "nested missing",
                    lambda value: value["destination_identity"].pop("root_mode"),
                ),
                (
                    "nested wrong type",
                    lambda value: value["candidate_identity"].__setitem__("root_mode", "493"),
                ),
            ):
                candidate = copy.deepcopy(state)
                mutate(candidate)
                mutations.append((label, candidate))
            for label, candidate in mutations:
                with self.subTest(label=label):
                    with self.assertRaises(installer.InstallationError):
                        self._validate_pending(fixture, candidate)

            original = fixture.bridge.pending_state.read_bytes()
            fixture.bridge.pending_state.write_bytes(
                _duplicate_top_level(state, "schema_version")
            )
            with self.assertRaises(installer.InstallationError):
                installer._pending_read_stable(fixture.bridge.pending_state.parent)
            fixture.bridge.pending_state.write_bytes(original)

    def _write_gate_set(
        self, fixture: CompilerFixture
    ) -> tuple[dict[str, dict[str, object]], tuple[str, ...]]:
        root = fixture.root / "closed-gate-envelopes"
        root.mkdir(mode=0o700)
        documents: dict[str, dict[str, object]] = {}
        arguments = []
        exposure = int(fixture.bridge.state["exposed_at_unix_ns"])
        for offset, gate_id in enumerate(GATE_IDS, start=1):
            document = ws24.acceptance_gate_document(
                gate_id=gate_id,
                state=fixture.bridge.state,
                evidence_sha256=hashlib.sha256(gate_id.encode("utf-8")).hexdigest(),
                started_at_unix_ns=exposure + offset,
                ended_at_unix_ns=exposure + offset + 1,
            )
            path = root / f"{gate_id}.json"
            path.write_bytes(canonical_bytes(document))
            path.chmod(0o600)
            documents[gate_id] = document
            arguments.append(f"{gate_id}={path}")
        return documents, tuple(arguments)

    def test_all_eight_gate_envelopes_have_one_exact_schema_and_parser(self) -> None:
        with CompilerFixture() as fixture:
            documents, arguments = self._write_gate_set(fixture)
            records, _latest = installer._acceptance_gate_records(
                state=fixture.bridge.state, gate_arguments=arguments
            )
            self.assertEqual(tuple(records), GATE_IDS)
            for gate_id, document in documents.items():
                _assert_closed(self, document, GATE_ENVELOPE_FIELDS)
                self.assertEqual(document["gate_id"], gate_id)
                self.assertEqual(document["schema_version"], 1)
                self.assertEqual(
                    document["input_kind"], "macscope-installer-acceptance-gate"
                )
                self.assertEqual(document["result"], "passed")
                self.assertIs(document["rolled_back"], False)
                self.assertEqual(document["transaction_phase"], "pending")

            cli_path = Path(arguments[0].partition("=")[2])
            original = documents["cli"]
            mutations = (
                ("unknown", lambda value: value.__setitem__("unexpected", None)),
                ("missing", lambda value: value.pop("transaction_nonce")),
                ("wrong type", lambda value: value.__setitem__("started_at_unix_ns", True)),
                ("wrong literal", lambda value: value.__setitem__("result", "failed")),
            )
            for label, mutate in mutations:
                candidate = copy.deepcopy(original)
                mutate(candidate)
                cli_path.write_bytes(canonical_bytes(candidate))
                with self.subTest(label=label), self.assertRaises(installer.InstallationError):
                    installer._acceptance_gate_records(
                        state=fixture.bridge.state, gate_arguments=arguments
                    )
            cli_path.write_bytes(_duplicate_top_level(original, "schema_version"))
            with self.assertRaises(installer.InstallationError):
                installer._acceptance_gate_records(
                    state=fixture.bridge.state, gate_arguments=arguments
                )

    def _with_final_fixture(self) -> tuple[TransactionFixture, mock._patch]:
        fixture = TransactionFixture()
        patcher = mock.patch.object(
            final_validator, "_validate_frozen_plan_contract", return_value=None
        )
        patcher.start()
        return fixture, patcher

    def test_task10_reports_and_result_descriptors_are_exact_closed_records(self) -> None:
        fixture, patcher = self._with_final_fixture()
        try:
            authority = fixture.validate_result()
            self.assertEqual(authority.installed_task10.document, fixture.task10_result_record)
            installed_matrix_receipt.parse_document(fixture.task10_matrix_document)

            record = _assert_closed(self, fixture.task10_result_record, TASK10_FIELDS)
            _assert_closed(self, record["matrix_receipt"], TASK10_FILE_FIELDS)
            _assert_closed(self, record["incremental_evidence"], TASK10_FILE_FIELDS)
            _assert_closed(self, record["xcresult_semantic_manifest"], TASK10_FILE_FIELDS)
            _assert_closed(self, record["xcresult"], TASK10_XCRESULT_FIELDS)
            _assert_closed(
                self, record["network_artifact_root"], TASK10_NETWORK_DESCRIPTOR_FIELDS
            )
            _assert_closed(self, fixture.task10_semantic_document, TASK10_SEMANTIC_FIELDS)
            _assert_closed(
                self, fixture.task10_audit_document, TASK10_NETWORK_REPORT_FIELDS
            )
            _assert_closed(
                self,
                fixture.task10_audit_document["attribution"],
                TASK10_NETWORK_ATTRIBUTION_FIELDS,
            )
            _assert_closed(
                self, fixture.task10_execution_document, TASK10_EXECUTION_REPORT_FIELDS
            )
            incremental = _assert_closed(
                self, fixture.task10_incremental_document, frozenset({"evidence"})
            )
            self.assertEqual(len(incremental["evidence"]), 1)
            entry = _assert_closed(
                self,
                incremental["evidence"][0],
                frozenset({"gate", "proofArtifacts"}),
            )
            self.assertEqual(entry["gate"], "incremental-xcuitest")
            self.assertEqual(len(entry["proofArtifacts"]), 6)
            self.assertEqual(fixture.task10_semantic_document["schema_version"], 3)
            self.assertEqual(fixture.task10_semantic_document["result"], "passed")
            self.assertEqual(fixture.task10_audit_document["schema_version"], 4)
            self.assertEqual(
                fixture.task10_audit_document["command_id"],
                "installed.network-acquisition-audit",
            )
            self.assertEqual(fixture.task10_execution_document["schema_version"], 2)
            self.assertEqual(fixture.task10_execution_document["result"], "passed")
        finally:
            patcher.stop()
            fixture.cleanup()

    def _reject_task10_artifact_mutation(
        self,
        *,
        path_attribute: str,
        document_attribute: str,
        digest_container: str,
        digest_field: str,
        mutate,
        duplicate_field: str | None = None,
    ) -> None:
        fixture, patcher = self._with_final_fixture()
        try:
            document = copy.deepcopy(getattr(fixture, document_attribute))
            mutate(document)
            path = getattr(fixture, path_attribute)
            payload = (
                _duplicate_top_level(document, duplicate_field)
                if duplicate_field is not None
                else canonical_bytes(document)
            )
            fixture._write_bytes(path, payload)
            fixture.task10_result_record[digest_container][digest_field] = hashlib.sha256(
                payload
            ).hexdigest()
            fixture.result_document["installed_task10"] = fixture.task10_result_record
            fixture.rewrite_result()
            with self.assertRaises(final_validator.FinalLocalCandidateError):
                fixture.validate_result()
        finally:
            patcher.stop()
            fixture.cleanup()

    def test_task10_parser_rejects_unknown_missing_duplicate_and_wrong_type_fields(self) -> None:
        cases = (
            (
                "matrix unknown",
                dict(
                    path_attribute="task10_matrix_receipt",
                    document_attribute="task10_matrix_document",
                    digest_container="matrix_receipt",
                    digest_field="sha256",
                    mutate=lambda value: value.__setitem__("unexpected", None),
                ),
            ),
            (
                "semantic missing",
                dict(
                    path_attribute="task10_semantic",
                    document_attribute="task10_semantic_document",
                    digest_container="xcresult_semantic_manifest",
                    digest_field="sha256",
                    mutate=lambda value: value.pop("result"),
                ),
            ),
            (
                "audit wrong type",
                dict(
                    path_attribute="task10_audit",
                    document_attribute="task10_audit_document",
                    digest_container="network_artifact_root",
                    digest_field="audit_report_sha256",
                    mutate=lambda value: value.__setitem__("schema_version", "4"),
                ),
            ),
            (
                "execution unknown",
                dict(
                    path_attribute="task10_execution",
                    document_attribute="task10_execution_document",
                    digest_container="network_artifact_root",
                    digest_field="execution_report_sha256",
                    mutate=lambda value: value.__setitem__("unexpected", False),
                ),
            ),
            (
                "incremental missing",
                dict(
                    path_attribute="task10_incremental",
                    document_attribute="task10_incremental_document",
                    digest_container="incremental_evidence",
                    digest_field="sha256",
                    mutate=lambda value: value.pop("evidence"),
                ),
            ),
            (
                "semantic duplicate",
                dict(
                    path_attribute="task10_semantic",
                    document_attribute="task10_semantic_document",
                    digest_container="xcresult_semantic_manifest",
                    digest_field="sha256",
                    mutate=lambda _value: None,
                    duplicate_field="schema_version",
                ),
            ),
        )
        for label, arguments in cases:
            with self.subTest(label=label):
                self._reject_task10_artifact_mutation(**arguments)

    def test_transaction_result_schema_v1_comes_from_builder_and_is_parser_closed(self) -> None:
        builder_fixture = InstalledAcceptanceTransactionTests(methodName="runTest")
        builder_fixture.setUp()
        try:
            document = transaction._result_document(
                builder_fixture.request,
                builder_fixture.pending,
                builder_fixture.task10,
                builder_fixture.plan,
                builder_fixture.publication,
                builder_fixture.terminal,
                produced_at_unix_ns=2,
            )
            _assert_closed(self, document, RESULT_FIELDS)
            _assert_closed(self, document["candidate"], RESULT_CANDIDATE_FIELDS)
            _assert_closed(self, document["qualification_run"], frozenset({"nonce", "run_id"}))
            _assert_closed(self, document["transaction"], RESULT_TRANSACTION_FIELDS)
            _assert_closed(
                self,
                document["pending_state"],
                frozenset({"path_at_begin", "sha256", "terminal_path"}),
            )
            _assert_closed(self, document["gate_plan"], TASK10_FILE_FIELDS)
            self.assertEqual(len(document["gate_envelopes"]), 8)
            for envelope in document["gate_envelopes"]:
                _assert_closed(self, envelope, RESULT_GATE_FIELDS)
            task10 = _assert_closed(self, document["installed_task10"], TASK10_FIELDS)
            _assert_closed(self, task10["matrix_receipt"], TASK10_FILE_FIELDS)
            _assert_closed(self, task10["xcresult"], TASK10_XCRESULT_FIELDS)
            _assert_closed(
                self, task10["network_artifact_root"], TASK10_NETWORK_DESCRIPTOR_FIELDS
            )
            self.assertEqual(document["schema_version"], 1)
            self.assertEqual(
                document["result_kind"], "macscope-installed-acceptance-transaction"
            )
            self.assertEqual(document["result"], "passed")
            self.assertIs(document["rolled_back"], False)
            self.assertEqual(document["transaction_phase"], "committed")
        finally:
            builder_fixture.tearDown()

        for label, mutate in (
            ("unknown", lambda value: value.__setitem__("unexpected", None)),
            ("missing", lambda value: value.pop("commit_authority")),
            ("wrong type", lambda value: value.__setitem__("schema_version", "1")),
            (
                "task10 unknown",
                lambda value: value["installed_task10"].__setitem__("unexpected", None),
            ),
            (
                "task10 descriptor missing",
                lambda value: value["installed_task10"]["network_artifact_root"].pop(
                    "observation_sha256"
                ),
            ),
            (
                "task10 descriptor wrong type",
                lambda value: value["installed_task10"].__setitem__("xcresult", []),
            ),
        ):
            fixture, patcher = self._with_final_fixture()
            try:
                mutate(fixture.result_document)
                fixture.rewrite_result()
                with self.subTest(label=label), self.assertRaises(
                    final_validator.FinalLocalCandidateError
                ):
                    fixture.validate_result()
            finally:
                patcher.stop()
                fixture.cleanup()

        fixture, patcher = self._with_final_fixture()
        try:
            fixture._write_bytes(
                fixture.result_path,
                _duplicate_top_level(fixture.result_document, "schema_version"),
            )
            with self.assertRaises(final_validator.FinalLocalCandidateError):
                fixture.validate_result()
        finally:
            patcher.stop()
            fixture.cleanup()

    def _validate_final_receipt_contract(self, value: object) -> None:
        document = final_validator._closed_mapping(
            value, FINAL_FIELDS, label="final local receipt"
        )
        if (
            document["schema_version"] != 1
            or document["receipt_kind"] != "macscope-final-local-candidate"
            or document["result"] != "passed"
            or type(document["produced_at_unix_ns"]) is not int
        ):
            final_validator.fail("final local receipt literals differ")
        gates = document["acceptance_gates"]
        if not isinstance(gates, list) or len(gates) != 8:
            final_validator.fail("final local receipt gate count differs")
        for index, (gate_id, value) in enumerate(zip(GATE_IDS, gates)):
            gate = final_validator._closed_mapping(
                value, FINAL_GATE_FIELDS, label=f"final gate {index}"
            )
            if gate["gate_id"] != gate_id or gate["result"] != "passed":
                final_validator.fail("final local receipt gate literals differ")
        final_validator._closed_mapping(
            document["candidate"], FINAL_CANDIDATE_FIELDS, label="final candidate"
        )
        installation = final_validator._closed_mapping(
            document["installation"],
            FINAL_INSTALLATION_FIELDS,
            label="final installation",
        )
        if (
            installation["rolled_back"] is not False
            or installation["transaction_phase"] != "committed"
        ):
            final_validator.fail("final installation literals differ")
        integration = final_validator._closed_mapping(
            document["integration"], FINAL_INTEGRATION_FIELDS, label="final integration"
        )
        match = final_validator.LOCAL_REMOTE_REF_RE.fullmatch(integration["ref"])
        if match is None or integration["remote"] != match.group(1):
            final_validator.fail("final integration remote differs")
        qualification = final_validator._closed_mapping(
            document["qualification"],
            FINAL_QUALIFICATION_FIELDS,
            label="final qualification",
        )
        if (
            qualification["mode"] != "full-test"
            or qualification["dependency_network_used"] is not False
        ):
            final_validator.fail("final qualification literals differ")
        scope = final_validator._closed_mapping(
            document["scope"], FINAL_SCOPE_FIELDS, label="final scope"
        )
        if scope != {
            "authority": "local-private-candidate-only",
            "gate_f_claimed": False,
            "online_delivery_claimed": False,
            "post_2026_09_11_proof_claimed": False,
            "public_release_claimed": False,
        }:
            final_validator.fail("final scope literals differ")
        result = final_validator._closed_mapping(
            document["transaction_result"],
            FINAL_TRANSACTION_RESULT_FIELDS,
            label="final transaction result",
        )
        final_validator._closed_mapping(
            result["installed_task10"], TASK10_FIELDS, label="final installed Task10"
        )

    def test_final_local_receipt_schema_v1_is_exact_closed_output(self) -> None:
        fixture, patcher = self._with_final_fixture()
        try:
            receipt = final_validator._receipt_document(
                fixture.closure(), produced_at_unix_ns=fixture.produced_at + 100
            )
            self._validate_final_receipt_contract(receipt)
            _assert_closed(self, receipt, FINAL_FIELDS)
            _assert_closed(self, receipt["candidate"], FINAL_CANDIDATE_FIELDS)
            _assert_closed(self, receipt["installation"], FINAL_INSTALLATION_FIELDS)
            _assert_closed(self, receipt["integration"], FINAL_INTEGRATION_FIELDS)
            _assert_closed(self, receipt["qualification"], FINAL_QUALIFICATION_FIELDS)
            _assert_closed(self, receipt["scope"], FINAL_SCOPE_FIELDS)
            _assert_closed(
                self, receipt["transaction_result"], FINAL_TRANSACTION_RESULT_FIELDS
            )

            mutations = (
                ("unknown", lambda value: value.__setitem__("unexpected", None)),
                ("missing", lambda value: value.pop("scope")),
                ("wrong type", lambda value: value.__setitem__("schema_version", "1")),
                (
                    "nested unknown",
                    lambda value: value["qualification"].__setitem__("unexpected", None),
                ),
                (
                    "nested missing",
                    lambda value: value["transaction_result"].pop("installed_task10"),
                ),
                (
                    "nested wrong type",
                    lambda value: value["installation"].__setitem__("rolled_back", 0),
                ),
            )
            for label, mutate in mutations:
                candidate = copy.deepcopy(receipt)
                mutate(candidate)
                with self.subTest(label=label), self.assertRaises(
                    final_validator.FinalLocalCandidateError
                ):
                    self._validate_final_receipt_contract(candidate)

            with self.assertRaises(Exception):
                decode_canonical_bytes(_duplicate_top_level(receipt, "schema_version"))
        finally:
            patcher.stop()
            fixture.cleanup()


if __name__ == "__main__":
    unittest.main()
