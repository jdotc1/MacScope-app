from __future__ import annotations

import copy
import hashlib
from pathlib import Path
from types import SimpleNamespace
import unittest

from Scripts.reconstruction import compile_installed_acceptance_gate_plan as compiler
from Scripts.reconstruction import emit_installed_live_evidence as live
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import installed_matrix_receipt as matrix
from Scripts.reconstruction import run_installed_acceptance_transaction as transaction
from Scripts.reconstruction import validate_final_local_candidate as final_validator
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority
from Scripts.tests.test_compile_installed_acceptance_gate_plan import CompilerFixture
from Scripts.tests.test_ws24_emit_installed_qualification_report import (
    PREDECESSOR_SHA256,
    RUN_ID,
    RUN_NONCE,
    SOURCE_COMMIT,
    SOURCE_TREE,
)
from Scripts import ws24_emit_installed_qualification_report as ws24


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class LineageError(AssertionError):
    pass


def require(condition: object, message: str) -> None:
    if not condition:
        raise LineageError(message)


class DigestLineageFixture:
    """One deterministic, build-free installed-acceptance authority chain."""

    def __init__(self) -> None:
        self.compiler_fixture = CompilerFixture()
        fixture = self.compiler_fixture
        self.root = fixture.root
        self.state = fixture.bridge.state
        self.pending_path = fixture.bridge.pending_state
        self.source_authority = fixture.inputs().source_authority
        self.plan_path = compiler.compile_and_publish(fixture.namespace())
        self.plan, self.plan_sha256 = compiler.load_plan(self.plan_path)
        self.authority = self.plan["authority"]

        self.task10_xcresult = Path(self.authority["installed_task10_xcresult_path"])
        self.task10_xcresult.mkdir(mode=0o700)
        self._write(self.task10_xcresult / "Info.plist", b"deterministic-xcresult")
        self.task10_matrix = Path(
            self.authority["installed_task10_matrix_receipt_path"]
        )
        self.task10_execution = (
            Path(self.authority["installed_task10_network_artifact_root"])
            / transaction.NETWORK_EXECUTION_REPORT_NAME
        )
        self.task10_semantic = Path(
            self.authority["installed_task10_xcresult_semantic_manifest_path"]
        )
        self.task10_incremental = Path(
            self.authority["installed_task10_incremental_evidence_path"]
        )
        self.task10_network_root = Path(
            self.authority["installed_task10_network_artifact_root"]
        )
        self.task10_network_root.mkdir(mode=0o700)
        self.task10_audit = (
            self.task10_network_root / transaction.NETWORK_AUDIT_REPORT_NAME
        )
        self.task10_observation = (
            self.task10_network_root / transaction.NETWORK_OBSERVATION_NAME
        )
        self._write_document(self.task10_matrix, self._matrix_document())
        self._write_document(self.task10_semantic, {"result": "passed"})
        self._write_document(self.task10_audit, {"result": "passed"})
        self._write(self.task10_observation, b"deterministic-network-observation\n")
        self._write_document(
            self.task10_execution,
            {
                "ended_at_unix_ms": 4_100,
                "exit_code": 0,
                "predecessor_observations_sha256": PREDECESSOR_SHA256,
                "qualification_run": {"nonce": RUN_NONCE, "run_id": RUN_ID},
                "result": "passed",
                "schema_version": 1,
                "started_at_unix_ms": 4_000,
                "stress": None,
            },
        )
        self._write_document(
            self.task10_incremental,
            {
                "evidence": [
                    {
                        "gate": "incremental-xcuitest",
                        "proofArtifacts": [
                            self._artifact("installed-task10-matrix-receipt-v1", self.task10_matrix),
                            self._artifact(
                                "installed-task10-network-audit-execution-report-v1",
                                self.task10_execution,
                            ),
                        ],
                    }
                ]
            },
        )

        self.live_path = next(
            Path(gate["output"]["path"])
            for gate in self.plan["gates"]
            if gate["gate_id"] == "shellbroker-launchagent"
        )
        self._write_document(self.live_path, self._live_document())
        self.primary_outputs: dict[str, Path] = {}
        for gate in self.plan["gates"]:
            gate_id = gate["gate_id"]
            path = Path(gate["output"]["path"])
            self.primary_outputs[gate_id] = path
            if path == self.live_path:
                continue
            self._write_document(
                path,
                {
                    "authority_sha256": self.plan["authority_sha256"],
                    "gate_id": gate_id,
                    "result": "passed",
                    "source_commit": SOURCE_COMMIT,
                    "source_tree": SOURCE_TREE,
                    "transaction_id": self.state["transaction_id"],
                },
            )

        self.envelope_paths: dict[str, Path] = {}
        for offset, gate_id in enumerate(installer.REQUIRED_ACCEPTANCE_GATES):
            path = fixture.qualification_output_root / f"{gate_id}.acceptance-gate.json"
            document = ws24.acceptance_gate_document(
                gate_id=gate_id,
                state=self.state,
                evidence_sha256=sha256(self.primary_outputs[gate_id].read_bytes()),
                started_at_unix_ns=self.state["exposed_at_unix_ns"] + 100 + offset,
                ended_at_unix_ns=self.state["exposed_at_unix_ns"] + 200 + offset,
            )
            self._write_document(path, document)
            self.envelope_paths[gate_id] = path

        self.pending_state, self.pending_snapshot = installer._pending_read_stable(
            self.pending_path.parent
        )
        gate_arguments = tuple(
            f"{gate_id}={self.envelope_paths[gate_id]}"
            for gate_id in installer.REQUIRED_ACCEPTANCE_GATES
        )
        self.gate_records, latest = installer._acceptance_gate_records(
            state=self.pending_state,
            gate_arguments=gate_arguments,
        )
        self.acceptance_path = Path(self.state["acceptance_receipt_path"])
        self._write_document(
            self.acceptance_path,
            installer._acceptance_receipt_document(
                state=self.pending_state,
                state_file=self.pending_snapshot,
                gates=self.gate_records,
                produced_at_unix_ns=latest + 100,
            ),
        )
        self.commit_root = installer._committed_root(
            fixture.bridge.installed_app,
            self.state["candidate_identity_sha256"],
            self.state["transaction_id"],
        )
        self.commit_root.mkdir(mode=0o700)
        self.terminal_state_path = self.commit_root / "transaction.json"
        self._write(self.terminal_state_path, self.pending_path.read_bytes())
        self.commit_authority_path = self.commit_root / installer.COMMIT_AUTHORITY_NAME
        self._write_document(
            self.commit_authority_path,
            {
                "acceptance_receipt_sha256": sha256(self.acceptance_path.read_bytes()),
                "authority_kind": installer.COMMIT_AUTHORITY_KIND,
                "candidate_identity_sha256": self.state["candidate_identity_sha256"],
                "destination_identity": self.state["destination_identity"],
                "pending_state_sha256": sha256(self.pending_path.read_bytes()),
                "schema_version": installer.COMMIT_AUTHORITY_SCHEMA_VERSION,
                "transaction_id": self.state["transaction_id"],
                "transaction_nonce": self.state["transaction_nonce"],
            },
        )

        self.result_path = fixture.work_root / transaction.RESULT_NAME
        self.result_document = self._result_document(latest + 200)
        self._write_document(self.result_path, self.result_document)
        self.final_path = fixture.work_root / "FinalLocalCandidate.receipt.json"
        self.final_document = self._final_document(latest + 300)
        self._write_document(self.final_path, self.final_document)

    def close(self) -> None:
        self.compiler_fixture.close()

    def __enter__(self) -> DigestLineageFixture:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    @staticmethod
    def _write(path: Path, payload: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(payload)
        path.chmod(0o600)

    def _write_document(self, path: Path, document: object) -> None:
        self._write(path, canonical_bytes(document))

    def rewrite_document(self, path: Path, mutate) -> None:
        if path == self.compiler_fixture.qualification_receipt:
            document = compiler._decode_canonical(
                path.read_bytes(), label="qualification mutation", one_trailing_lf=True
            )
            mutate(document)
            self._write(path, canonical_bytes(document) + b"\n")
            return
        document = final_validator._decode_canonical(
            path.read_bytes(), label=f"mutation {path.name}"
        )
        mutate(document)
        self._write_document(path, document)

    @staticmethod
    def _artifact(kind: str, path: Path) -> dict[str, str]:
        return {"kind": kind, "path": str(path), "sha256": sha256(path.read_bytes())}

    def _matrix_document(self) -> dict[str, object]:
        projection = [
            {
                "required_identifiers": ["macscope.task10.fixture"],
                "test_identifier": "WS24InstalledAppUITests/testTask10CFixture()",
                "vector_id": "fixture",
            }
        ]
        snapshot = {key: {} for key in matrix.SNAPSHOT_FIELDS_V3}
        bundle = lambda path, identifier: {
            "bundle_identifier": identifier,
            "closed_tree_sha256": "1" * 64,
            "content_sha256": "2" * 64,
            "executable_path": str(path / "Contents/MacOS/fixture"),
            "executable_sha256": "3" * 64,
            "path": str(path),
        }
        root = self.root / "task10-products"
        return {
            "accessibility_observations": {"state": "absent"},
            "candidate": {
                "identity_path": self.authority["candidate_identity_path"],
                "identity_sha256": self.state["candidate_identity_sha256"],
                "preparation_receipt_path": self.authority[
                    "installed_ui_preparation_receipt_path"
                ],
                "preparation_receipt_sha256": self.authority[
                    "installed_ui_preparation_receipt_sha256"
                ],
                "source_commit": SOURCE_COMMIT,
                "source_tree": SOURCE_TREE,
            },
            "execution": {
                "argv": ["/usr/bin/true"],
                "duration_ms": 100,
                "ended_at_unix_ms": 4_100,
                "environment": {
                    "DEVELOPER_DIR": str(self.compiler_fixture.xcode_developer_dir),
                    "HOME": str(self.root / "task10-home"),
                    matrix.INSTALLED_APP_KEY: str(self.compiler_fixture.bridge.installed_app),
                    matrix.OPT_IN_KEY: "1",
                    "LOGNAME": "macscope",
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": str(self.root / "task10-tmp"),
                    "USER": "macscope",
                },
                "exit_code": 0,
                "failure": None,
                "input_snapshot_after": copy.deepcopy(snapshot),
                "input_snapshot_before": copy.deepcopy(snapshot),
                "result": "passed",
                "selector_projection": projection,
                "selector_projection_sha256": sha256(canonical_bytes(projection)),
                "selectors": [projection[0]["test_identifier"]],
                "started_at_unix_ms": 4_000,
            },
            "presentation_screenshots": {"state": "absent"},
            "products": {
                "execution_xctestrun": {
                    "path": self.authority["installed_ui_xctestrun_path"],
                    "sha256": self.authority["installed_ui_xctestrun_sha256"],
                },
                "installed_app": bundle(
                    self.compiler_fixture.bridge.installed_app, "org.macscope.app"
                ),
                "prepared_xctestrun": {
                    "path": self.authority["installed_ui_xctestrun_path"],
                    "sha256": self.authority["installed_ui_xctestrun_sha256"],
                },
                "test_bundle": bundle(root / "Tests.xctest", "tests"),
                "ui_runner": bundle(root / "Runner.app", "runner"),
                "xcresult": {
                    "closed_tree_sha256": "4" * 64,
                    "path": str(self.task10_xcresult),
                },
            },
            "receipt_kind": matrix.RECEIPT_KIND,
            "schema_version": matrix.SCHEMA_VERSION,
        }

    def _live_document(self) -> dict[str, object]:
        live_entries: dict[str, dict[str, object]] = {}
        for gate in live.MANIFEST_GATE_ORDER:
            if gate == "incremental-xcuitest":
                continue
            report = self.compiler_fixture.evidence_root / "live-reports" / f"{gate}.json"
            self._write_document(report, {"gate": gate, "result": "passed"})
            live_entries[gate] = {
                "gate": gate,
                "proofArtifacts": [self._artifact(ws24.LIVE_EXECUTION_REPORT_KIND, report)],
            }
        incremental = {
            "gate": "incremental-xcuitest",
            "proofArtifacts": [self._artifact(matrix.PROOF_ARTIFACT_KIND, self.task10_matrix)],
        }
        return live._manifest_document(live_entries, incremental)

    def _transaction_snapshot(self, path: Path, label: str) -> transaction.FileSnapshot:
        return transaction._read_stable_file(
            path, label=label, maximum_bytes=16 * 1024 * 1024
        )

    def _result_document(self, produced_at: int) -> dict[str, object]:
        provenance_path = (
            self.compiler_fixture.bridge.source_app
            / installer.BUILD_PROVENANCE_RELATIVE_PATH
        )
        request = SimpleNamespace(
            candidate_artifact_root=self.compiler_fixture.candidate_root,
            candidate_identity=self.compiler_fixture.bridge.candidate_identity,
            candidate_token=self.state["candidate_identity_sha256"],
            candidate_identity_snapshot=self._transaction_snapshot(
                self.compiler_fixture.bridge.candidate_identity, "candidate"
            ),
            provenance_snapshot=self._transaction_snapshot(
                provenance_path, "provenance"
            ),
            source_app=self.compiler_fixture.bridge.source_app,
            qualification_run=QualificationRunAuthority(RUN_ID, RUN_NONCE),
        )
        pending = transaction.PendingBinding(
            state=self.pending_state,
            state_file=self.pending_snapshot,
            state_sha256=sha256(self.pending_path.read_bytes()),
            transaction_id=self.state["transaction_id"],
            transaction_nonce=self.state["transaction_nonce"],
            acceptance_receipt=self.acceptance_path,
        )
        task10 = transaction.Task10Publication(
            paths=transaction.Task10Paths(
                xcresult=self.task10_xcresult,
                semantic_manifest=SimpleNamespace(path=self.task10_semantic),
                matrix_receipt=SimpleNamespace(path=self.task10_matrix),
                network_root=self.task10_network_root,
                incremental_evidence=self.task10_incremental,
            ),
            matrix_receipt=self._transaction_snapshot(self.task10_matrix, "Task10 matrix"),
            semantic_manifest=self._transaction_snapshot(self.task10_semantic, "Task10 semantic"),
            incremental_evidence=self._transaction_snapshot(self.task10_incremental, "Task10 incremental"),
            xcresult=transaction._directory_identity(self.task10_xcresult, label="Task10 xcresult"),
            network_root=transaction._directory_identity(self.task10_network_root, label="Task10 network"),
            xcresult_bundle_sha256="5" * 64,
            xcresult_closed_tree_sha256="4" * 64,
            network_audit_report=self._transaction_snapshot(self.task10_audit, "Task10 audit"),
            network_execution_report=self._transaction_snapshot(self.task10_execution, "Task10 execution"),
            network_observation=self._transaction_snapshot(self.task10_observation, "Task10 observation"),
        )
        plan = SimpleNamespace(snapshot=self._transaction_snapshot(self.plan_path, "plan"))
        publication = transaction.WS24Publication(
            report=self._transaction_snapshot(self.primary_outputs["signing"], "WS24"),
            gate_envelopes=tuple(
                (gate_id, self._transaction_snapshot(path, f"envelope {gate_id}"))
                for gate_id, path in self.envelope_paths.items()
            ),
        )
        terminal = transaction.TerminalBinding(
            committed_root=self.commit_root,
            state=self._transaction_snapshot(self.terminal_state_path, "terminal state"),
            acceptance_receipt=self._transaction_snapshot(self.acceptance_path, "acceptance"),
            commit_authority=self._transaction_snapshot(self.commit_authority_path, "commit"),
        )
        return dict(
            transaction._result_document(
                request,
                pending,
                task10,
                plan,
                publication,
                terminal,
                produced_at_unix_ns=produced_at,
            )
        )

    def _final_snapshot(self, path: Path, label: str):
        return final_validator._read_stable_file(
            path, maximum_bytes=16 * 1024 * 1024, label=label
        )

    def _final_document(self, produced_at: int) -> dict[str, object]:
        candidate = self.source_authority.candidate
        provenance_path = (
            self.compiler_fixture.bridge.source_app
            / installer.BUILD_PROVENANCE_RELATIVE_PATH
        )
        candidate_authority = SimpleNamespace(
            candidate=candidate,
            identity=self._final_snapshot(
                self.compiler_fixture.bridge.candidate_identity, "candidate"
            ),
            provenance=self._final_snapshot(
                provenance_path, "provenance"
            ),
            source_app=self.compiler_fixture.bridge.source_app,
        )
        coverage = self.compiler_fixture.qualification_run_root / "COVERAGE.json"
        self._write_document(coverage, {"result": "passed"})
        result_bundle = self.compiler_fixture.qualification_run_root / "TestResults.xcresult"
        result_bundle.mkdir()
        qualification = SimpleNamespace(
            document={"dependency_network_allowed": False},
            receipt=self._final_snapshot(
                self.compiler_fixture.qualification_receipt, "qualification"
            ),
            coverage=self._final_snapshot(coverage, "coverage"),
            result_bundle=result_bundle,
            validated=SimpleNamespace(run_root=self.compiler_fixture.qualification_run_root),
            source_provenance_sha256="6" * 64,
        )
        gate_files = tuple(
            (gate_id, self._final_snapshot(path, f"envelope {gate_id}"))
            for gate_id, path in self.envelope_paths.items()
        )
        gate_outputs = tuple(
            (gate_id, self._final_snapshot(path, f"output {gate_id}"))
            for gate_id, path in self.primary_outputs.items()
        )
        result_file = self._final_snapshot(self.result_path, "transaction result")
        installed_task10 = SimpleNamespace(document=self.result_document["installed_task10"])
        transaction_result = SimpleNamespace(
            candidate=self.result_document["candidate"],
            document=self.result_document,
            result_file=result_file,
            pending_state=self.result_document["pending_state"],
            gate_plan=self._final_snapshot(self.plan_path, "gate plan"),
            gate_plan_document=self.plan,
            native_preparation_receipt=self._final_snapshot(
                self.compiler_fixture.native_preparation_receipt, "native preparation"
            ),
            native_xctestrun=self._final_snapshot(
                self.compiler_fixture.native_xctestrun, "native xctestrun"
            ),
            installed_task10=installed_task10,
            ws24_aggregate=self._final_snapshot(
                self.primary_outputs["signing"], "WS24 aggregate"
            ),
            gate_output_files=gate_outputs,
            gate_evidence_files=gate_outputs,
        )
        acceptance_document = final_validator._decode_canonical(
            self.acceptance_path.read_bytes(), label="acceptance"
        )
        installation = SimpleNamespace(
            state=self.state,
            acceptance_receipt=self._final_snapshot(self.acceptance_path, "acceptance"),
            acceptance_document=acceptance_document,
            commit_authority=self._final_snapshot(
                self.commit_authority_path, "commit authority"
            ),
            installed_app=self.compiler_fixture.bridge.installed_app,
            state_file=self._final_snapshot(self.terminal_state_path, "terminal state"),
            gate_files=gate_files,
            gate_records=self.gate_records,
        )
        closure = SimpleNamespace(
            candidate=candidate_authority,
            qualification=qualification,
            installation=installation,
            qualification_run=QualificationRunAuthority(RUN_ID, RUN_NONCE),
            local_ref=final_validator.LocalRefAuthority(
                repository_root=self.root,
                integration_ref="refs/remotes/gitfox-local/digest-lineage",
                remote_name="gitfox-local",
                branch_name="digest-lineage",
                remote_url=str(self.root / "MacScope.git"),
                commit=SOURCE_COMMIT,
                tree=SOURCE_TREE,
            ),
            transaction_result=transaction_result,
        )
        return final_validator._receipt_document(
            closure, produced_at_unix_ns=produced_at
        )


def verify_lineage(fixture: DigestLineageFixture) -> None:
    try:
        qualification_snapshot = compiler._stable_file(
            fixture.compiler_fixture.qualification_receipt,
            maximum_bytes=compiler.MAXIMUM_INPUT_BYTES,
            label="qualification receipt",
        )
        qualification = compiler._validate_qualification_receipt(
            qualification_snapshot
        )
        pending, pending_snapshot = installer._pending_read_stable(
            fixture.pending_path.parent
        )
        plan, plan_sha = compiler.load_plan(fixture.plan_path)
        matrix_document, matrix_sha = matrix.load_receipt_with_sha256(
            fixture.task10_matrix
        )
        execution_snapshot = final_validator._read_stable_file(
            fixture.task10_execution,
            maximum_bytes=final_validator.MAX_TASK10_EXECUTION_REPORT_BYTES,
            label="Task10 execution",
        )
        task10_execution = final_validator._closed_mapping(
            final_validator._decode_canonical(
                execution_snapshot.payload, label="Task10 execution"
            ),
            final_validator.TASK10_EXECUTION_REPORT_FIELDS,
            label="Task10 execution",
        )
        live_snapshot, live_document = live._stable_canonical_object(
            fixture.live_path,
            label="live evidence",
            maximum_bytes=live.MAXIMUM_MANIFEST_BYTES,
            require_private_mode=True,
        )
        gate_records, _latest = installer._acceptance_gate_records(
            state=pending,
            gate_arguments=tuple(
                f"{gate_id}={fixture.envelope_paths[gate_id]}"
                for gate_id in installer.REQUIRED_ACCEPTANCE_GATES
            ),
        )
        result_snapshot = final_validator._read_stable_file(
            fixture.result_path,
            maximum_bytes=final_validator.MAX_TRANSACTION_RESULT_BYTES,
            label="transaction result",
        )
        result = final_validator._closed_mapping(
            final_validator._decode_canonical(
                result_snapshot.payload, label="transaction result"
            ),
            final_validator.TRANSACTION_RESULT_FIELDS,
            label="transaction result",
        )
        final_snapshot = final_validator._read_stable_file(
            fixture.final_path,
            maximum_bytes=final_validator.MAX_FINAL_RECEIPT_BYTES,
            label="final local receipt",
        )
        final = final_validator._decode_canonical(
            final_snapshot.payload, label="final local receipt"
        )
    except Exception as error:
        if isinstance(error, LineageError):
            raise
        raise LineageError(str(error)) from error

    source = qualification["source_identity"]
    authority = plan["authority"]
    run = (pending["qualification_run_id"], pending["qualification_run_nonce"])
    predecessor = (
        pending["predecessor_digest"],
        pending["predecessor_observations_sha256"],
    )
    transaction_identity = (pending["transaction_id"], pending["transaction_nonce"])
    source_identity = (source["git_head_commit"], source["git_head_tree"])
    pending_sha = sha256(pending_snapshot.payload)

    require(source_identity == (SOURCE_COMMIT, SOURCE_TREE), "qualification source differs")
    require(
        authority["qualification_receipt_path"]
        == str(fixture.compiler_fixture.qualification_receipt)
        and authority["qualification_receipt_sha256"]
        == sha256(qualification_snapshot.payload),
        "qualification receipt bytes/path differ in plan authority",
    )
    require(
        authority["pending_state_path"] == str(fixture.pending_path)
        and authority["pending_state_sha256"] == pending_sha,
        "pending bytes/path differ in plan authority",
    )
    require(plan["authority_sha256"] == sha256(canonical_bytes(authority)), "plan authority SHA differs")
    require(plan_sha == sha256(fixture.plan_path.read_bytes()), "compiled plan bytes differ")
    require(
        (authority["qualification_run_id"], authority["qualification_run_nonce"])
        == run,
        "plan qualification run differs",
    )
    require(
        (authority["predecessor_digest"], authority["predecessor_observations_sha256"])
        == predecessor,
        "plan predecessor lineage differs",
    )
    require(
        (authority["transaction_id"], authority["transaction_nonce"])
        == transaction_identity,
        "plan transaction differs",
    )
    require(
        (authority["source_commit"], authority["source_tree"]) == source_identity,
        "plan source differs",
    )

    matrix_candidate = matrix_document["candidate"]
    require(matrix_sha == sha256(fixture.task10_matrix.read_bytes()), "Task10 receipt SHA differs")
    require(
        fixture.task10_matrix == Path(authority["installed_task10_matrix_receipt_path"]),
        "Task10 receipt path differs",
    )
    require(
        (matrix_candidate["source_commit"], matrix_candidate["source_tree"])
        == source_identity,
        "Task10 source differs",
    )
    require(
        (
            task10_execution["qualification_run"]["run_id"],
            task10_execution["qualification_run"]["nonce"],
        )
        == run,
        "Task10 run differs",
    )
    require(
        task10_execution["predecessor_observations_sha256"] == predecessor[1],
        "Task10 predecessor observations differ",
    )

    require(set(live_document) == {"evidence"}, "live manifest root differs")
    require(
        tuple(item["gate"] for item in live_document["evidence"])
        == live.MANIFEST_GATE_ORDER,
        "live gate order differs",
    )
    for item in live_document["evidence"]:
        for artifact in item["proofArtifacts"]:
            artifact_path = Path(artifact["path"])
            require(artifact_path.is_file(), "live artifact path differs")
            require(
                artifact["sha256"] == sha256(artifact_path.read_bytes()),
                "live artifact digest differs",
            )
    require(live_snapshot.sha256 == sha256(fixture.live_path.read_bytes()), "live manifest SHA differs")

    require(tuple(gate_records) == installer.REQUIRED_ACCEPTANCE_GATES, "WS24 envelope set differs")
    for gate_id, record in gate_records.items():
        envelope = final_validator._decode_canonical(
            fixture.envelope_paths[gate_id].read_bytes(),
            label=f"envelope {gate_id}",
        )
        require(
            (envelope["qualification_run_id"], envelope["qualification_run_nonce"])
            == run,
            "WS24 envelope run differs",
        )
        require(
            (envelope["transaction_id"], envelope["transaction_nonce"])
            == transaction_identity,
            "WS24 envelope transaction differs",
        )
        require(
            (envelope["source_commit"], envelope["source_tree"]) == source_identity,
            "WS24 envelope source differs",
        )
        require(
            envelope["evidence_sha256"]
            == sha256(fixture.primary_outputs[gate_id].read_bytes()),
            "WS24 envelope evidence differs",
        )
        require(record["input_sha256"] == sha256(fixture.envelope_paths[gate_id].read_bytes()), "WS24 input digest differs")

    require(
        result["qualification_run"] == {"run_id": run[0], "nonce": run[1]},
        "transaction-result run differs",
    )
    result_transaction = result["transaction"]
    require(
        (result_transaction["predecessor_digest"], result_transaction["predecessor_observations_sha256"])
        == predecessor,
        "transaction-result predecessor differs",
    )
    require(
        (result_transaction["transaction_id"], result_transaction["transaction_nonce"])
        == transaction_identity,
        "transaction-result transaction differs",
    )
    require(
        (result_transaction["source_commit"], result_transaction["source_tree"])
        == source_identity,
        "transaction-result source differs",
    )
    require(
        result["gate_plan"]
        == {"path": str(fixture.plan_path), "sha256": plan_sha},
        "transaction-result plan path/digest differs",
    )
    require(
        result["pending_state"]["sha256"] == pending_sha,
        "transaction-result pending digest differs",
    )
    require(
        result["installed_task10"]["matrix_receipt"]
        == {"path": str(fixture.task10_matrix), "sha256": matrix_sha},
        "transaction-result Task10 path/digest differs",
    )
    require(len(result["gate_envelopes"]) == 8, "transaction-result envelope count differs")
    for record in result["gate_envelopes"]:
        gate_id = record["gate_id"]
        require(record["path"] == str(fixture.envelope_paths[gate_id]), "transaction-result envelope path differs")
        require(record["sha256"] == sha256(fixture.envelope_paths[gate_id].read_bytes()), "transaction-result envelope digest differs")

    require(final["receipt_kind"] == final_validator.RECEIPT_KIND, "final receipt kind differs")
    require(
        (final["qualification"]["run_id"], final["qualification"]["run_nonce"])
        == run,
        "final receipt run differs",
    )
    require(
        (
            final["installation"]["predecessor_digest"],
            final["installation"]["predecessor_observations_sha256"],
        )
        == predecessor,
        "final receipt predecessor differs",
    )
    require(
        (
            final["installation"]["transaction_id"],
            final["installation"]["transaction_nonce"],
        )
        == transaction_identity,
        "final receipt transaction differs",
    )
    require(
        (final["integration"]["commit"], final["integration"]["tree"])
        == source_identity,
        "final receipt source differs",
    )
    require(
        final["transaction_result"]["path"] == str(fixture.result_path)
        and final["transaction_result"]["sha256"] == sha256(result_snapshot.payload),
        "final receipt transaction-result path/digest differs",
    )
    require(
        final["transaction_result"]["gate_plan_authority_sha256"]
        == plan["authority_sha256"],
        "final receipt plan authority SHA differs",
    )


class InstalledAcceptanceDigestLineageTests(unittest.TestCase):
    def test_one_canonical_chain_reopens_byte_for_byte(self) -> None:
        with DigestLineageFixture() as fixture:
            verify_lineage(fixture)

    def test_each_lineage_class_fails_closed_on_mismatch(self) -> None:
        mutations = (
            (
                "qualification source tree",
                lambda fixture: fixture.rewrite_document(
                    fixture.compiler_fixture.qualification_receipt,
                    lambda document: document["source_identity"].__setitem__(
                        "git_head_tree", "f" * 40
                    ),
                ),
            ),
            (
                "pending transaction",
                lambda fixture: fixture.rewrite_document(
                    fixture.pending_path,
                    lambda document: document.__setitem__("transaction_id", "f" * 64),
                ),
            ),
            (
                "compiled authority digest",
                lambda fixture: fixture.rewrite_document(
                    fixture.plan_path,
                    lambda document: document.__setitem__("authority_sha256", "f" * 64),
                ),
            ),
            (
                "Task10 source tree",
                lambda fixture: fixture.rewrite_document(
                    fixture.task10_matrix,
                    lambda document: document["candidate"].__setitem__(
                        "source_tree", "f" * 40
                    ),
                ),
            ),
            (
                "Task10 run nonce",
                lambda fixture: fixture.rewrite_document(
                    fixture.task10_execution,
                    lambda document: document["qualification_run"].__setitem__(
                        "nonce", "f" * 64
                    ),
                ),
            ),
            (
                "live artifact digest",
                lambda fixture: fixture.rewrite_document(
                    fixture.live_path,
                    lambda document: document["evidence"][0]["proofArtifacts"][0].__setitem__(
                        "sha256", "f" * 64
                    ),
                ),
            ),
            (
                "WS24 envelope source",
                lambda fixture: fixture.rewrite_document(
                    fixture.envelope_paths["cli"],
                    lambda document: document.__setitem__("source_commit", "f" * 40),
                ),
            ),
            (
                "transaction-result plan path",
                lambda fixture: fixture.rewrite_document(
                    fixture.result_path,
                    lambda document: document["gate_plan"].__setitem__(
                        "path", str(fixture.task10_matrix)
                    ),
                ),
            ),
            (
                "transaction-result Task10 digest",
                lambda fixture: fixture.rewrite_document(
                    fixture.result_path,
                    lambda document: document["installed_task10"]["matrix_receipt"].__setitem__(
                        "sha256", "f" * 64
                    ),
                ),
            ),
            (
                "transaction-result predecessor",
                lambda fixture: fixture.rewrite_document(
                    fixture.result_path,
                    lambda document: document["transaction"].__setitem__(
                        "predecessor_digest", "f" * 64
                    ),
                ),
            ),
            (
                "final receipt run",
                lambda fixture: fixture.rewrite_document(
                    fixture.final_path,
                    lambda document: document["qualification"].__setitem__(
                        "run_nonce", "f" * 64
                    ),
                ),
            ),
            (
                "final receipt transaction result digest",
                lambda fixture: fixture.rewrite_document(
                    fixture.final_path,
                    lambda document: document["transaction_result"].__setitem__(
                        "sha256", "f" * 64
                    ),
                ),
            ),
        )
        for label, mutate in mutations:
            with self.subTest(label=label), DigestLineageFixture() as fixture:
                mutate(fixture)
                with self.assertRaises(LineageError):
                    verify_lineage(fixture)


if __name__ == "__main__":
    unittest.main()
