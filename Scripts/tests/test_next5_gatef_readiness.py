#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import replace
import base64
import hashlib
import io
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from Scripts.reconstruction_gate_f.canonical_json import write_canonical_json, canonical_bytes, canonical_sha256, load_canonical_json, to_primitive
from Scripts.reconstruction_gate_f.runtime_resolution import resolve_command_record
from Scripts.reconstruction_gate_f import next5_gatef_readiness as readiness
from Scripts.reconstruction_gate_f import command_capture, command_execution, prerequisite_dag
from Scripts.reconstruction_gate_f.command_catalog import command_templates
from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan, command_plan_sha256
from Scripts.reconstruction_gate_f.executor_request_adapter import ExecutorReceiptAdmission, OwnerArtifactSource, build_executor_request
from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.schema import candidate_to_mapping, ArtifactKind, QualificationPhase, ReceiptType
from Scripts.reconstruction_gate_f.tests.test_command_compiler import command_inputs
from Scripts.reconstruction_gate_f.tests import test_executor_receipt as owner_fixture
from Scripts.reconstruction_gate_f.tests.test_executor_receipt import QUALIFICATION_RUN


class Next5GateFReadinessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.fixtures: list[owner_fixture.GateFExecutorReceiptTests] = []
        self.executor_admissions = {}
        # Synthetic identity isolation only; compiler, capture, emitter and
        # physical owner validation run without bypasses.
        patcher = mock.patch.object(prerequisite_dag, "_repository_source_issues", return_value=())
        patcher.start()
        self.addCleanup(patcher.stop)
        # Unit evidence needs a real successor, independent of the checkout's
        # ancestry. The isolated object database reads existing objects without
        # writing to the developer repository or changing any branch.
        self.repository = self.root / "repository"
        subprocess.run(["git", "init", "--quiet", str(self.repository)], check=True)
        objects = subprocess.check_output(
            ["git", "-C", str(readiness.REPOSITORY_ROOT), "rev-parse", "--path-format=absolute", "--git-path", "objects"],
            text=True,
        ).strip()
        (self.repository / ".git/objects/info/alternates").write_text(objects + "\n")
        self.tree = readiness.PRESERVED_TREE
        self.head = subprocess.check_output(
            ["git", "-C", str(self.repository), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "commit-tree", self.tree, "-p", readiness.PRESERVED_COMMIT, "-m", "Synthetic successor for owner evidence tests"],
            text=True,
        ).strip()
        subprocess.run(["git", "-C", str(self.repository), "update-ref", "HEAD", self.head], check=True)
        seed = self._new_fixture()
        candidate = replace(
            seed.candidate,
            source=replace(
                seed.candidate.source,
                commit=self.head,
                tree=self.tree,
                dirty=False,
            ),
        )
        signed_digest = hashlib.sha256(seed.signed_worker_payload).hexdigest()
        self.candidate = replace(
            candidate,
            application=replace(
                candidate.application,
                qualification_executables=tuple(
                    replace(item, sha256=signed_digest)
                    if item.identity_id == "native-decompiler"
                    else item
                    for item in candidate.application.qualification_executables
                ),
            ),
        )
        self.candidate_path = self.root / "explicit-candidate.json"
        write_canonical_json(self.candidate_path, candidate_to_mapping(self.candidate))

    def tearDown(self) -> None:
        for fixture in reversed(self.fixtures):
            fixture.tearDown()
        self.temporary.cleanup()

    def _new_fixture(self) -> owner_fixture.GateFExecutorReceiptTests:
        fixture = owner_fixture.GateFExecutorReceiptTests(methodName="runTest")
        fixture.setUp()
        self.fixtures.append(fixture)
        return fixture

    def _request(
        self,
        method: str,
        *,
        method_arguments: dict[str, object] | None = None,
    ) -> tuple[dict[str, object], Path, Path]:
        fixture = self._new_fixture()
        fixture.candidate = self.candidate
        request = getattr(fixture, method)(**(method_arguments or {}))
        admission = self._captured_admission(fixture, request)
        self.executor_admissions[request["command_id"]] = admission
        request = build_executor_request(admission)
        request_path = fixture.root / "executor-request.json"
        write_canonical_json(request_path, request)
        return request, request_path, fixture.root

    def _one_request_report(
        self,
        command_id: str,
        request_path: Path,
        artifact_root: Path,
    ) -> dict[str, object]:
        return readiness.build_readiness(
            repository_root=self.repository,
            candidate_identity_path=self.candidate_path,
            executor_requests={command_id: request_path},
            artifact_roots={command_id: artifact_root},
            qualification_run_authority=QUALIFICATION_RUN,
            executor_admissions=self.executor_admissions,
        )

    def _captured_admission(self, fixture, old, *, shared_inputs=None):
        """Seven-owner extension of CapturedReceiptTests' synthetic recipe.

        These explicit synthetic bytes never claim real process execution.
        Recompilation and physical receipt validation remain production paths.
        """
        inputs = dict(shared_inputs) if shared_inputs is not None else command_inputs()
        inputs.update(repository_root=str(readiness.REPOSITORY_ROOT), qualification_run_id=QUALIFICATION_RUN.run_id,
                      qualification_run_nonce=QUALIFICATION_RUN.nonce)
        for artifact in old["artifacts"]:
            declaration = artifact["command_output"].split(":", 1)[1]
            match = re.match(r"^@([a-z0-9_]+)@(.*)$", declaration)
            if match:
                actual = str(fixture.root / artifact["relative_path"])
                suffix = match[2]
                self.assertTrue(actual.endswith(suffix))
                inputs[match[1]] = actual[:-len(suffix)] if suffix else actual
        scenarios = compile_scenario_catalog(self.candidate)
        plan = compile_command_plan(self.candidate, scenarios, repository_root=readiness.REPOSITORY_ROOT, inputs=inputs)
        record = next(item for item in plan.commands if item.command_id == old["command_id"])
        predecessors = tuple(CommandPrerequisiteExpectation(key, "prerequisite-" + str(index), "c" * 64,
                             QUALIFICATION_RUN.run_id, QUALIFICATION_RUN.nonce)
                             for index, key in enumerate(record.prerequisite_ids))
        resolved = resolve_command_record(record, prerequisite_receipts=predecessors,
                                          qualification_run=QUALIFICATION_RUN)
        report_source = next(item for item in old["artifacts"] if item["artifact_id"] == old["execution_report_artifact_id"])
        report_path = fixture.root / report_source["relative_path"]
        report = load_canonical_json(report_path)
        report["predecessor_observations_sha256"] = canonical_sha256([vars(item) for item in predecessors])
        write_canonical_json(report_path, report)
        def resolve(declaration):
            return re.sub(r"@([a-z0-9_]+)@", lambda match: inputs[match[1]], declaration)
        sources = tuple(OwnerArtifactSource(item["artifact_id"], item["relative_path"], ArtifactKind(item["kind"]),
                        item["media_type"], resolve(item["command_output"])) for item in old["artifacts"])
        stdout_json = [source for source in sources if source.command_output.startswith("artifact:stdout-json:")]
        stdout = ((fixture.root / stdout_json[0].relative_path).read_bytes() if stdout_json else
                  b"".join((source.command_output.removeprefix("artifact:stdout-path:") + "=" + str(fixture.root / source.relative_path) + "\n").encode()
                            for source in sources if source.command_output.startswith("artifact:stdout-path:")))
        for source in sources:
            if source.command_output.startswith("log:executor-captured:"):
                (fixture.root / source.relative_path).write_bytes(stdout)
        execution = command_execution.ExecutionAdmission(self.candidate,
            prerequisite_dag.LaneCIntegratedCommandPlanInput(plan, scenarios, readiness.REPOSITORY_ROOT, inputs,
                {item.command_id: item for item in command_templates()}), QUALIFICATION_RUN,
            self.candidate.source.commit, self.candidate.source.tree, predecessors)
        capture_id = "synthetic-" + record.command_id
        intent = dict(capture_id=capture_id, run_id=QUALIFICATION_RUN.run_id, nonce=QUALIFICATION_RUN.nonce,
            candidate_identity_sha256=record.candidate_identity_sha256, command_plan_sha256=command_plan_sha256(plan),
            command_record_sha256=canonical_sha256(record), command_id=record.command_id,
            scenario_id=record.scenario_ids[0] if record.scenario_ids else record.command_id,
            producer_source_commit=self.candidate.source.commit, producer_source_tree=self.candidate.source.tree,
            argv=list(resolved.record.argv), working_directory=record.working_directory,
            environment=[list(item) for item in record.environment], effective_environment=[list(item) for item in record.environment],
            environment_policy_id="gatef-host-environment-v1",
            prerequisite_receipts=sorted([[item.command_id, item.canonical_sha256] for item in predecessors]), started_at_unix_ms=0)
        frames = [dict(sequence=0, stream="stdout", data_base64=base64.b64encode(stdout).decode(),
                       raw_length=len(stdout), raw_sha256=hashlib.sha256(stdout).hexdigest())]
        terminal = dict(intent_sha256=canonical_sha256(intent), frames_sha256=canonical_sha256(frames),
            ended_at_unix_ms=max(3000, report["ended_at_unix_ms"]), termination_kind="exited", exit_code=0, signal=None,
            stdout_length=len(stdout), stdout_sha256=hashlib.sha256(stdout).hexdigest(), stderr_length=0,
            stderr_sha256=hashlib.sha256(b"").hexdigest())
        payload = command_capture.serialize_capture(dict(schema_version=2, intent=intent, output_frames=frames, terminal=terminal,
            runtime_resolution=to_primitive(resolved.runtime_resolution),
            process_observation=dict(state="launched", pid=123, spawn_observed_monotonic_ns=1,
                os_start_time=dict(state="unavailable", reason="synthetic readiness unit fixture"))))
        capture_path = fixture.root / "capture.json"
        capture_path.write_bytes(payload)
        captured = command_execution.ExecutionCapture(execution, record.command_id, intent["scenario_id"], capture_id,
            record.environment, capture_path, hashlib.sha256(payload).hexdigest())
        constituents = tuple(old["constituents"])
        authority = old["authority"]
        semantic_ids = record.scenario_ids or (record.command_id,)
        if old["receipt_type"] in {ReceiptType.SIGNED_XPC.value, ReceiptType.INSTALLED_WORKFLOW.value}:
            # The physical owner fixture still contains its original selected
            # tests. Receipt constituents cover the compiled semantic scenarios,
            # which need not be one-to-one with those physical test cases.
            constituents = tuple(dict(constituents[0], selector_id=value) for value in semantic_ids)
            authority = dict(authority, selector_count=len(semantic_ids))
        elif record.command_id == "reconstruction.deterministic-evidence":
            constituents = tuple(dict(constituents[0], selector_id=value) for value in semantic_ids)
            authority = dict(authority, expected_selector_count=len(semantic_ids),
                             executed_selector_count=len(semantic_ids), passed_selector_count=len(semantic_ids))
        return ExecutorReceiptAdmission(captured, fixture.root, old["receipt_id"], old["requirement_id"],
            QualificationPhase(old["qualification_phase"]), ReceiptType(old["receipt_type"]), old["artifact_root_id"],
            old["execution_report_artifact_id"], sources, old["executor"], constituents, authority)

    def _stress_report(self, gate: str, *, attempt_count: int = 10) -> Path:
        attempts = [
            {
                "attemptIndex": index,
                "endedAtUnixMilliseconds": index * 10,
                "exitCode": 0,
                "failure": None,
                "peakResidentMemoryMegabytes": None,
                "scenario": gate,
                "seed": index,
                "startedAtUnixMilliseconds": (index - 1) * 10,
                "timedOut": False,
            }
            for index in range(1, attempt_count + 1)
        ]
        path = self.root / f"{gate}-{attempt_count}.json"
        write_canonical_json(
            path,
            {
                "attempts": attempts,
                "gate": gate,
                "installedExecutableSHA256": self.candidate.application.executable_sha256,
                "schemaVersion": 1,
                "sourceCommit": self.candidate.source.commit,
                "sourceTree": self.candidate.source.tree,
            },
        )
        return path

    def _complete_inputs(
        self,
        shared_run_root: Path | None = None,
    ) -> tuple[dict[str, Path], dict[str, Path], dict[str, Path]]:
        requests: dict[str, Path] = {}
        roots: dict[str, Path] = {}
        specifications = (
            ("installed.task10-workflow", "_installed_workflow_request", {}),
            ("installed.accessibility-semantics", "_installed_accessibility_request", {}),
            (
                "reconstruction.deterministic-evidence",
                "_deterministic_evidence_request",
                {},
            ),
            (
                "signed-xpc.complete-truncated-content",
                "_signed_xpc_request",
                {"command_id": "signed-xpc.complete-truncated-content"},
            ),
            (
                "signed-xpc.error-cancellation",
                "_signed_xpc_request",
                {"command_id": "signed-xpc.error-cancellation"},
            ),
            (
                "signed-xpc.supervision",
                "_signed_xpc_request",
                {"command_id": "signed-xpc.supervision"},
            ),
            ("stress.reconstruction-authority-races", "_stress_request", {}),
        )
        # Materialize synthetic owner artifacts first, then bind ONE full plan
        # input map for every capture in this qualification run.
        prepared = []
        shared_inputs = command_inputs()
        for command_id, method, arguments in specifications:
            fixture = self._new_fixture()
            if shared_run_root is not None:
                fixture.root = shared_run_root / command_id
                fixture.root.mkdir(parents=True)
            fixture.candidate = self.candidate
            old = getattr(fixture, method)(**arguments)
            prepared.append((command_id, fixture, old))
            for artifact in old["artifacts"]:
                declaration = artifact["command_output"].split(":", 1)[1]
                match = re.match(r"^@([a-z0-9_]+)@(.*)$", declaration)
                if match:
                    actual = str(fixture.root / artifact["relative_path"])
                    suffix = match[2]
                    self.assertTrue(actual.endswith(suffix))
                    shared_inputs[match[1]] = actual[:-len(suffix)] if suffix else actual
        for command_id, fixture, old in prepared:
            admission = self._captured_admission(fixture, old, shared_inputs=shared_inputs)
            if shared_run_root is not None:
                admission = replace(admission, artifact_root=shared_run_root, receipt_id="receipt-" + command_id,
                    owner_artifacts=tuple(replace(item, relative_path=command_id + "/" + item.relative_path)
                                          for item in admission.owner_artifacts))
            self.executor_admissions[command_id] = admission
            request = build_executor_request(admission)
            path = fixture.root / "executor-request.json"
            write_canonical_json(path, request)
            requests[command_id] = path
            roots[command_id] = fixture.root
        self.assertEqual(len({command_plan_sha256(item.capture.admission.integrated_plan_input.plan)
                              for item in self.executor_admissions.values()}), 1)
        stress_reports = {
            gate: self._stress_report(gate) for gate in sorted(readiness.STRESS_GATES)
        }
        return requests, roots, stress_reports

    def _persisted_run(self):
        from Scripts.reconstruction_gate_f import operator_run
        from Scripts.reconstruction_gate_f.executor_request_adapter import emit_captured_receipt
        root = self.root / "persisted-run"
        _, _, stress = self._complete_inputs(shared_run_root=root)
        seed = next(iter(self.executor_admissions.values())).capture.admission
        metadata = {}
        for command, admission in self.executor_admissions.items():
            metadata[command] = dict(receipt_id=admission.receipt_id, requirement_id=admission.requirement_id,
                qualification_phase=admission.qualification_phase.value, receipt_type=admission.receipt_type.value,
                artifact_root_id=admission.artifact_root_id, execution_report_artifact_id=admission.execution_report_artifact_id,
                owner_artifacts=to_primitive(admission.owner_artifacts), executor=dict(admission.executor),
                constituents=list(admission.constituents), authority=admission.authority,
                qualified_premerge_authority_sha256=admission.qualified_premerge_authority_sha256)
        manifest = dict(schema_version=1, candidate_identity=candidate_to_mapping(self.candidate),
            repository_root=str(readiness.REPOSITORY_ROOT), command_inputs=dict(seed.integrated_plan_input.inputs),
            qualification_run=to_primitive(QUALIFICATION_RUN), commands=metadata)
        write_canonical_json(root / "run.json", manifest)
        for command, admission in self.executor_admissions.items():
            receipt, _ = emit_captured_receipt(build_executor_request(admission), artifact_root=root,
                qualification_run_authority=QUALIFICATION_RUN, admission=admission)
            write_canonical_json(root / (command + ".completed.json"), dict(schema_version=1,
                manifest_sha256=canonical_sha256(manifest),
                capture_path=admission.capture.capture_path.relative_to(root).as_posix(), receipt=receipt))
        return root, stress

    def test_persisted_run_bridge_replays_all_owners_in_one_container_without_writes(self):
        from Scripts.reconstruction_gate_f import operator_run
        root, stress = self._persisted_run()
        before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
        # The synthetic fixture omits predecessor captures; only that transport
        # is isolated. Real manifest loading, completion replay, owner validation,
        # shared-container handling and CLI publication run unchanged.
        def admission(run, command, *args):
            run._unchanged()
            return self.executor_admissions[command].capture.admission
        output = self.root / "readiness.json"
        argv = ["--repository-root", str(self.repository), "--candidate-identity", str(self.candidate_path),
                "--operator-run-root", str(root), "--output", str(output), "--expect-status", "complete-readiness"]
        for gate, path in stress.items():
            argv += ["--stress-report", gate + "=" + str(path)]
        with mock.patch.object(operator_run.OperatorRun, "admission", admission):
            self.assertEqual(readiness.main(argv), 0)
        report = load_canonical_json(output)
        self.assertEqual(len(report["validated_executor_receipts"]), 7)
        self.assertFalse(report["gate_f_completion_claimed"])
        self.assertEqual(before, {p: p.read_bytes() for p in root.rglob("*") if p.is_file()})

    def test_persisted_run_bridge_fails_closed_on_changed_or_missing_inputs(self):
        from Scripts.reconstruction_gate_f import operator_run
        root, stress = self._persisted_run()
        arguments = dict(repository_root=self.repository, candidate_identity_path=self.candidate_path,
                         operator_run_root=root, stress_reports=stress)
        with self.assertRaisesRegex(readiness.ReadinessError, "cannot be mixed"):
            readiness.build_readiness(**arguments, executor_requests={"irrelevant": root})
        with self.assertRaisesRegex(readiness.ReadinessError, "explicit validated"):
            readiness.build_readiness(**dict(arguments, candidate_identity_path=None))
        # Real predecessor traversal cannot promote an incomplete synthetic run.
        with self.assertRaises(readiness.ReadinessError):
            readiness.build_readiness(**arguments)
        manifest_path = root / "run.json"
        manifest = load_canonical_json(manifest_path)
        changed = dict(manifest, qualification_run=dict(manifest["qualification_run"], nonce="f" * 64))
        write_canonical_json(manifest_path, changed)
        with self.assertRaisesRegex(readiness.ReadinessError, "compiled run"):
            readiness.build_readiness(**arguments)
        changed = dict(manifest, candidate_identity=candidate_to_mapping(replace(self.candidate,
            application=replace(self.candidate.application, executable_sha256="f" * 64))))
        write_canonical_json(manifest_path, changed)
        with self.assertRaises(ValueError):
            readiness.build_readiness(**arguments)
        write_canonical_json(manifest_path, manifest)
        def admission(run, command, *args):
            run._unchanged()
            return self.executor_admissions[command].capture.admission
        command = "signed-xpc.supervision"
        path = root / (command + ".completed.json")
        completion = load_canonical_json(path)
        with mock.patch.object(operator_run.OperatorRun, "admission", admission):
            path.unlink()
            with self.assertRaises(readiness.ReadinessError):
                readiness.build_readiness(**arguments)

            write_canonical_json(path, dict(completion, receipt=dict(completion["receipt"], receipt_id="forged")))
            with self.assertRaisesRegex(readiness.ReadinessError, "fresh physical"):
                readiness.build_readiness(**arguments)
            write_canonical_json(path, completion)
            capture = self.executor_admissions[command].capture.capture_path
            original = capture.read_bytes()
            capture.write_bytes(b"{}")
            with self.assertRaises(readiness.ReadinessError):
                readiness.build_readiness(**arguments)
            capture.write_bytes(original)
            # Byte-identical owner files still cannot alias across commands.
            worker = root / command / "signed-worker"
            worker.unlink()
            os.link(root / "signed-xpc.error-cancellation" / "signed-worker", worker)
            with self.assertRaises(ValueError):
                readiness.build_readiness(**arguments)

    def test_persisted_run_manifest_mutated_during_stress_validation_is_rejected(self):
        from Scripts.reconstruction_gate_f import operator_run
        root, stress = self._persisted_run()
        manifest_path = root / "run.json"
        manifest = load_canonical_json(manifest_path)
        original_validate = readiness._validate_stress_report

        def admission(run, command, *args):
            run._unchanged()
            return self.executor_admissions[command].capture.admission

        def validate_then_mutate(**kwargs):
            result = original_validate(**kwargs)
            if kwargs["evidence_index"] == 1:
                write_canonical_json(manifest_path, dict(manifest,
                    qualification_run=dict(manifest["qualification_run"], nonce="f" * 64)))
            return result

        # Preserve real stress validation and mutate its physical run authority
        # after the first report passes, beyond the earlier manifest fence.
        with mock.patch.object(operator_run.OperatorRun, "admission", admission), \
             mock.patch.object(readiness, "_validate_stress_report", validate_then_mutate):
            with self.assertRaisesRegex(readiness.ReadinessError, "manifest changed"):
                readiness.build_readiness(repository_root=self.repository,
                    candidate_identity_path=self.candidate_path, operator_run_root=root, stress_reports=stress)
        with self.assertRaisesRegex(operator_run.OperatorError, "compiled run"):
            operator_run.load_run(root)

    def test_script_entrypoint_reports_missing_persisted_run_without_import_failure(self):
        import sys
        result = subprocess.run([sys.executable, str(Path(readiness.__file__)),
            "--repository-root", str(self.repository), "--candidate-identity", str(self.candidate_path),
            "--operator-run-root", str(self.root / "missing-run")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("persisted run validation failed", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_default_is_immutable_preserved_candidate_not_checkout_head(self) -> None:
        report = readiness.build_readiness(repository_root=self.repository)

        subject = report["residual_evidence_subject"]
        self.assertEqual(subject["selection"], "preserved-candidate-default")
        self.assertEqual(subject["source_commit"], readiness.PRESERVED_COMMIT)
        self.assertEqual(subject["source_tree"], readiness.PRESERVED_TREE)
        self.assertNotEqual(subject["source_commit"], self.head)
        self.assertFalse(subject["validated"])
        self.assertEqual(report["live_catalog"]["ws24_required_gate_count"], 14)
        self.assertEqual(report["live_catalog"]["installer_transaction_gate_count"], 8)
        self.assertEqual(report["live_catalog"]["installed_selector_count"], 22)
        self.assertEqual(report["live_catalog"]["governed_screenshot_count"], 28)
        self.assertEqual(report["live_catalog"]["stress_family_count"], 3)
        self.assertFalse(report["gate_f_completion_claimed"])
        self.assertFalse(report["step_8"]["authorized"])
        self.assertIsNone(report["step_8"]["earliest_calendar_date"])
        self.assertTrue(all(not item["complete"] for item in report["residual_families"]))

    def test_canonical_anchor_reconstructs_historical_tree_without_historical_objects(self) -> None:
        canonical_successor = subprocess.check_output(
            ["git", "-C", str(self.repository), "-c", "user.name=Fixture",
             "-c", "user.email=fixture@example.invalid", "commit-tree", self.tree,
             "-p", readiness.CANONICAL_PRESERVED_COMMIT,
             "-m", "Canonical-only successor fixture"], text=True,
        ).strip()
        write_canonical_json(self.candidate_path, candidate_to_mapping(replace(
            self.candidate, source=replace(self.candidate.source, commit=canonical_successor)
        )))
        real_exists = readiness._object_exists
        def canonical_only(root: Path, name: str) -> bool:
            return name != readiness.PRESERVED_COMMIT and real_exists(root, name)
        with mock.patch.object(readiness, "_object_exists", side_effect=canonical_only):
            self.assertEqual(
                readiness._verify_preserved_authority(self.repository),
                (readiness.CANONICAL_PRESERVED_COMMIT,),
            )
            report = readiness.build_readiness(
                repository_root=self.repository,
                candidate_identity_path=self.candidate_path,
            )
        self.assertTrue(report["residual_evidence_subject"]["validated"])
        self.assertFalse(report["gate_f_completion_claimed"])

    def test_canonical_mapping_rejects_changed_attributes_and_snapshot(self) -> None:
        real_bytes = readiness._git_bytes
        for target in ("attributes", "tree"):
            def changed(root: Path, *arguments: str) -> bytes:
                data = real_bytes(root, *arguments)
                if target == "attributes" and arguments[0] == "show":
                    return data + b"*.swift -text\n"
                if target == "tree" and arguments[0] == "cat-file":
                    return data[:-1] + bytes([data[-1] ^ 1])
                return data
            with self.subTest(target=target), mock.patch.object(
                readiness, "_git_bytes", side_effect=changed
            ), self.assertRaises(readiness.ReadinessError):
                readiness._verify_canonical_mapping(readiness.REPOSITORY_ROOT)

    def test_missing_both_anchors_fails_closed(self) -> None:
        with mock.patch.object(readiness, "_object_exists", return_value=False), \
                self.assertRaisesRegex(readiness.ReadinessError, "neither preserved"):
            readiness._verify_preserved_authority(readiness.REPOSITORY_ROOT)

    def test_unrelated_ancestor_is_not_admitted_by_mapping(self) -> None:
        root_commit = readiness._git(
            self.repository, "rev-list", "--max-parents=0", self.head
        ).splitlines()[0]
        candidate = replace(self.candidate, source=replace(
            self.candidate.source, commit=root_commit,
            tree=readiness._git(self.repository, "rev-parse", f"{root_commit}^{{tree}}"),
        ))
        write_canonical_json(self.candidate_path, candidate_to_mapping(candidate))
        with self.assertRaisesRegex(readiness.ReadinessError, "not the preserved"):
            readiness.build_readiness(repository_root=self.repository,
                                      candidate_identity_path=self.candidate_path)

    def test_historical_candidate_still_requires_original_identity_digests(self) -> None:
        if not readiness._object_exists(readiness.REPOSITORY_ROOT, readiness.PRESERVED_COMMIT):
            self.skipTest("historical object intentionally absent in a canonical-only clone")
        candidate = replace(self.candidate, source=replace(
            self.candidate.source, commit=readiness.PRESERVED_COMMIT,
            tree=readiness.PRESERVED_TREE,
        ))
        write_canonical_json(self.candidate_path, candidate_to_mapping(candidate))
        with self.assertRaisesRegex(readiness.ReadinessError, "immutable recorded identity"):
            readiness.build_readiness(repository_root=readiness.REPOSITORY_ROOT,
                                      candidate_identity_path=self.candidate_path)
    def test_unrelated_source_is_rejected_before_owner_evidence(self) -> None:
        unrelated = subprocess.check_output(
            ["git", "-C", str(self.repository), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "commit-tree", self.tree, "-m", "Unrelated source negative control"],
            text=True,
        ).strip()
        document = candidate_to_mapping(replace(
            self.candidate, source=replace(self.candidate.source, commit=unrelated)
        ))
        unrelated_path = self.root / "unrelated-candidate.json"
        write_canonical_json(unrelated_path, document)
        with self.assertRaisesRegex(readiness.ReadinessError, "not the preserved Steps 1-7 authority or its successor"):
            readiness.build_readiness(
                repository_root=self.repository,
                candidate_identity_path=unrelated_path,
            )

    def test_physical_evidence_without_explicit_candidate_fails_closed(self) -> None:
        with self.assertRaisesRegex(
            readiness.ReadinessError, "explicit validated CandidateIdentity"
        ):
            readiness.build_readiness(
                repository_root=self.repository,
                stress_reports={
                    "repeated-restart-stress": Path("/private/tmp/arbitrary.json")
                },
            )

    def test_wrong_scope_owner_schema_layer_and_report_kind_are_rejected(self) -> None:
        with self.assertRaisesRegex(readiness.ReadinessError, "not an exact Gate F"):
            readiness.build_readiness(
                repository_root=self.repository,
                candidate_identity_path=self.candidate_path,
                executor_requests={"next5.generic-json": self.candidate_path},
                artifact_roots={"next5.generic-json": self.root},
            )

        cases = (
            ("schema_version", 999, "owner validation failed"),
            ("evidence_layer", "installed-workflow", "wrong Gate F evidence layer"),
            ("receipt_type", "installed-workflow", "wrong Gate F report kind"),
            ("command_id", "installed.task10-workflow", "wrong Gate F owner command ID"),
        )
        for field, replacement, message in cases:
            with self.subTest(field=field):
                request, path, artifact_root = self._request(
                    "_installed_accessibility_request"
                )
                request[field] = replacement
                write_canonical_json(path, request)
                with self.assertRaisesRegex(readiness.ReadinessError, message):
                    self._one_request_report(
                        "installed.accessibility-semantics", path, artifact_root
                    )

    def test_missing_item_binding_is_rejected(self) -> None:
        request, path, artifact_root = self._request(
            "_deterministic_evidence_request"
        )
        del request["artifacts"][0]["root_id"]
        write_canonical_json(path, request)
        with self.assertRaisesRegex(readiness.ReadinessError, "owner validation failed"):
            self._one_request_report(
                "reconstruction.deterministic-evidence", path, artifact_root
            )

    def test_request_cannot_supply_independent_capture_or_run_admission(self) -> None:
        request, path, root = self._request("_signed_xpc_request", method_arguments={"command_id": "signed-xpc.supervision"})
        command = request["command_id"]
        arguments = dict(repository_root=self.repository, candidate_identity_path=self.candidate_path,
                         executor_requests={command: path}, artifact_roots={command: root})
        for additions in ({}, {"qualification_run_authority": QUALIFICATION_RUN},
                          {"qualification_run_authority": replace(QUALIFICATION_RUN, nonce="0" * 64),
                           "executor_admissions": self.executor_admissions}):
            with self.subTest(additions=additions), self.assertRaises(readiness.ReadinessError):
                readiness.build_readiness(**arguments, **additions)
        report = readiness.build_readiness(**arguments, qualification_run_authority=QUALIFICATION_RUN,
                                          executor_admissions=self.executor_admissions)
        self.assertEqual(len(report["validated_executor_receipts"]), 1)

    def test_incomplete_capture_cannot_borrow_a_passing_owner_report(self) -> None:
        request, path, root = self._request("_signed_xpc_request", method_arguments={"command_id": "signed-xpc.supervision"})
        admission = self.executor_admissions[request["command_id"]]
        capture_path = admission.capture.capture_path
        capture_path.write_bytes(capture_path.read_bytes()[:-1])
        with self.assertRaisesRegex(readiness.ReadinessError, "owner validation failed"):
            self._one_request_report(request["command_id"], path, root)

    def test_individually_valid_captures_cannot_mix_full_command_plans(self) -> None:
        signed, signed_path, signed_root = self._request("_signed_xpc_request", method_arguments={"command_id": "signed-xpc.supervision"})
        fixture = self._new_fixture()
        fixture.candidate = self.candidate
        old = fixture._deterministic_evidence_request()
        inputs = command_inputs()
        inputs["generated_at_unix_ms"] = "1"
        admission = self._captured_admission(fixture, old, shared_inputs=inputs)
        request = build_executor_request(admission)
        path = fixture.root / "executor-request.json"
        write_canonical_json(path, request)
        self.executor_admissions[request["command_id"]] = admission
        # Prove both owner receipts independently before testing plan mixing;
        # an unrelated invalid fixture must not satisfy the rejection assertion.
        for command, request_path, root in (
            (signed["command_id"], signed_path, signed_root),
            (request["command_id"], path, fixture.root),
        ):
            report = self._one_request_report(command, request_path, root)
            self.assertEqual(len(report["validated_executor_receipts"]), 1)
        with self.assertRaisesRegex(readiness.ReadinessError, "command plan"):
            readiness.build_readiness(repository_root=self.repository,
                candidate_identity_path=self.candidate_path,
                executor_requests={signed["command_id"]: signed_path, request["command_id"]: path},
                artifact_roots={signed["command_id"]: signed_root, request["command_id"]: fixture.root},
                qualification_run_authority=QUALIFICATION_RUN, executor_admissions=self.executor_admissions)

    def test_tampered_physical_hash_is_rejected(self) -> None:
        request, path, artifact_root = self._request(
            "_deterministic_evidence_request"
        )
        artifact_path = artifact_root / request["artifacts"][0]["relative_path"]
        artifact_path.write_bytes(artifact_path.read_bytes() + b"tampered")
        with self.assertRaisesRegex(readiness.ReadinessError, "owner validation failed"):
            self._one_request_report(
                "reconstruction.deterministic-evidence", path, artifact_root
            )

    def test_duplicate_or_hardlinked_evidence_inode_is_rejected(self) -> None:
        first, second = sorted(readiness.STRESS_GATES)[:2]
        first_path = self._stress_report(first)
        second_path = self.root / "duplicate-stress-inode.json"
        os.link(first_path, second_path)
        with self.assertRaisesRegex(readiness.ReadinessError, "singly-linked regular file"):
            readiness.build_readiness(
                repository_root=self.repository,
                candidate_identity_path=self.candidate_path,
                stress_reports={first: first_path, second: second_path},
            )

    def test_screenshot_closure_rejects_invalid_png(self) -> None:
        # Exact selector/image-count/content-uniqueness mutations live in
        # test_executor_receipt. Retain a physical PNG failure through the
        # readiness wrapper, which invokes that same production emitter.
        request, path, artifact_root = self._request(
            "_installed_accessibility_request"
        )
        screenshot = next(
            artifact
            for artifact in request["artifacts"]
            if artifact["media_type"] == "image/png"
        )
        screenshot_path = artifact_root / screenshot["relative_path"]
        screenshot_path.write_bytes(b"not-a-decodable-png")
        screenshot["byte_count"] = screenshot_path.stat().st_size
        screenshot["sha256"] = hashlib.sha256(screenshot_path.read_bytes()).hexdigest()
        write_canonical_json(path, request)
        with self.assertRaisesRegex(readiness.ReadinessError, "owner validation failed"):
            self._one_request_report(
                "installed.accessibility-semantics", path, artifact_root
            )

    def test_each_stress_family_requires_ten_consecutive_passing_attempts(self) -> None:
        gate = "repeated-restart-stress"
        with self.assertRaisesRegex(
            readiness.ReadinessError, "minimum attempts|owner validation failed"
        ):
            readiness.build_readiness(
                repository_root=self.repository,
                candidate_identity_path=self.candidate_path,
                stress_reports={gate: self._stress_report(gate, attempt_count=9)},
            )

    def test_fully_valid_owner_evidence_reaches_readiness_without_completion_claim(self) -> None:
        requests, roots, stress_reports = self._complete_inputs()

        report = readiness.build_readiness(
            repository_root=self.repository,
            candidate_identity_path=self.candidate_path,
            executor_requests=requests,
            artifact_roots=roots,
            stress_reports=stress_reports,
            qualification_run_authority=QUALIFICATION_RUN,
            executor_admissions=self.executor_admissions,
        )

        self.assertEqual(
            report["readiness_status"], "physical-evidence-validated-readiness-only"
        )
        self.assertEqual(len(report["validated_executor_receipts"]), 7)
        self.assertEqual(len(report["validated_live_stress_reports"]), 3)
        self.assertTrue(all(item["complete"] for item in report["residual_families"]))
        self.assertFalse(report["gate_f_completion_claimed"])
        self.assertFalse(report["step_8"]["authorized"])
        deterministic = next(
            item
            for item in report["residual_families"]
            if item["family_id"] == readiness.DETERMINISTIC
        )
        self.assertEqual(
            set(deterministic["validated_executor_commands"]),
            {
                "installed.task10-workflow",
                "reconstruction.deterministic-evidence",
            },
        )
        installed = next(
            item
            for item in report["validated_executor_receipts"]
            if item["command_id"] == "installed.accessibility-semantics"
        )
        self.assertEqual(
            len(
                [
                    artifact
                    for artifact in installed["artifacts"]
                    if artifact["media_type"] == "image/png"
                ]
            ),
            28,
        )

    def test_negative_control_publication_is_create_only_and_default_still_blocks(self) -> None:
        output = self.root / "negative.json"
        self.assertEqual(
            readiness.main(
                [
                    "--repository-root",
                    str(self.repository),
                    "--output",
                    str(output),
                    "--expect-status",
                    "blocked-negative-control",
                ]
            ),
            0,
        )
        payload = json.loads(output.read_text())
        self.assertEqual(
            payload["readiness_status"], "blocked-missing-physical-owner-evidence"
        )
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(output.stat().st_nlink, 1)
        self.assertEqual(readiness.main(["--repository-root", str(self.repository)]), 1)
        self.assertEqual(
            readiness.main(
                [
                    "--repository-root",
                    str(self.repository),
                    "--output",
                    str(output),
                    "--expect-status",
                    "blocked-negative-control",
                ]
            ),
            2,
        )

    def test_negative_control_forbids_physical_evidence_and_publishes_nothing(self) -> None:
        output = self.root / "forbidden.json"
        result = readiness.main(
            [
                "--repository-root",
                str(self.repository),
                "--candidate-identity",
                str(self.candidate_path),
                "--output",
                str(output),
                "--expect-status",
                "blocked-negative-control",
            ]
        )
        self.assertEqual(result, 2)
        self.assertFalse(output.exists())

    def test_request_only_cli_cannot_reconstruct_producer_admission(self) -> None:
        request, path, artifact_root = self._request(
            "_installed_accessibility_request"
        )
        command_id = request["command_id"]
        self.assertEqual(command_id, min(readiness.EXECUTOR_REQUIREMENTS))
        output = self.root / "complete.json"
        arguments = [
            "--repository-root",
            str(self.repository),
            "--candidate-identity",
            str(self.candidate_path),
            "--output",
            str(output),
            "--expect-status",
            "complete-readiness",
        ]
        # Publication requires every declared key before it inspects evidence.
        # Only the first sorted owner is materialized: its valid request must
        # fail for absent independent admission before any later path is read.
        for key in sorted(readiness.EXECUTOR_REQUIREMENTS):
            request_path = path if key == command_id else self.root / f"unread-{key}.json"
            owner_root = artifact_root if key == command_id else self.root / f"unread-{key}"
            arguments.extend(("--executor-request", f"{key}={request_path}"))
            arguments.extend(("--artifact-root", f"{key}={owner_root}"))
        for key in sorted(readiness.STRESS_GATES):
            arguments.extend(("--stress-report", f"{key}={self.root / ('unread-' + key + '.json')}"))
        with mock.patch.object(readiness.sys, "stderr", new_callable=io.StringIO) as error:
            self.assertEqual(readiness.main(arguments), 2)
        self.assertIn("independent persisted-run capture admission", error.getvalue())
        self.assertFalse(output.exists())

    def test_publication_refuses_input_change_between_validation_passes(self) -> None:
        output = self.root / "changed.json"
        original = readiness.build_readiness
        calls = 0

        def changing(**arguments: object) -> dict[str, object]:
            nonlocal calls
            calls += 1
            report = original(**arguments)
            if calls == 2:
                report["readiness_status"] = "changed"
            return report

        with mock.patch.object(readiness, "build_readiness", side_effect=changing):
            result = readiness.main(
                [
                    "--repository-root",
                    str(self.repository),
                    "--output",
                    str(output),
                    "--expect-status",
                    "blocked-negative-control",
                ]
            )
        self.assertEqual(result, 2)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
