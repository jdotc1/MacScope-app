"""Actual portable BEGIN plus captured admission; no app/native qualification.

Source Git/export, bridge/installer transactions, capture transport and receipt
replay are real. Only signing tool output, the portable destination/rename, and
the upstream signing receipt transport use the established physical fixtures.
"""
from __future__ import annotations

import contextlib
from dataclasses import replace
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import unittest
from unittest import mock

from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction_gate_f import command_execution, materialize_candidate_identity, operator_run
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes
from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile
from Scripts.reconstruction_gate_f.executor_request_adapter import (
    capture_execution_report_artifact_id,
)
from Scripts.reconstruction_gate_f.installed_capture_adapter import retained_begin_state
from Scripts.reconstruction_gate_f.receipt_validator import validate_receipt
from Scripts.reconstruction_gate_f.schema import candidate_identity_sha256, parse_candidate_identity
from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
from Scripts.reconstruction_gate_f.tests import test_begin_installed_candidate as begin_fixtures
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
from Scripts.source_export_provenance import create_export
from Scripts.tests.test_gate_f_operator_run import metadata
from Scripts.tests import test_install_release_to_applications as install_fixtures
from Scripts.tests.test_local_signing_policy import update_release_provenance
from Scripts.tests.test_source_export_provenance import SourceRepository


BEGIN = "install.release-to-applications"
AGGREGATE = "installed.emit-report"


class InstalledBeginHookTests(unittest.TestCase):
    def setUp(self):
        self.bridge = begin_fixtures.BeginInstalledCandidateTests(methodName="runTest")
        self.bridge.setUp()
        self.addCleanup(self.bridge.doCleanups)
        self.root = self.bridge.root
        source, _ = bootstrap_repository(self)
        # Freeze all actual compiler command inputs, plus the installed adapter's
        # checked producer closure, before deriving candidate/source authority.
        for path in tuple(source.rglob("*")):
            if path.is_file():
                shutil.copy2(ROOT / path.relative_to(source), path)
        closure = (
            "Scripts/check_local_signing_policy.py", "Scripts/ws24_check_xcuitest_host.py",
            "Scripts/ws24_emit_installed_qualification_report.py",
            "Scripts/phase2/run_installed_shell_smoke.py",
            "Scripts/reconstruction/install_release_to_applications.py",
            "Scripts/reconstruction/native_live_preparation_receipt.py",
            "Scripts/reconstruction/installed_matrix_receipt.py",
            "Scripts/reconstruction_gate_f/materialize_candidate_identity.py",
            "Scripts/reconstruction_gate_f/begin_installed_candidate.py",
            "Scripts/reconstruction_gate_f/installed_capture_adapter.py",
            "Scripts/reconstruction_gate_f/operator_run.py",
            "Scripts/reconstruction_gate_f/operator_cli.py",
        )
        for relative in closure:
            target = source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        repository = SourceRepository(source)
        repository.write("MacScope/project.yml", "name: PortableInstalledBeginFixture\n")
        repository.git("add", ".")
        repository.git("commit", "-m", "Freeze installed BEGIN source fixture")
        commit, tree = repository.git("rev-parse", "HEAD"), repository.git("rev-parse", "HEAD^{tree}")
        integration_ref = "refs/remotes/gitfox-local/feature/task11-local-premerge-current"
        repository.git("update-ref", integration_ref, commit)
        export = self.root / "source-export"
        create_export(source, export, integration_ref)
        update_release_provenance(self.bridge.source, git_head_commit=commit, git_head_tree=tree)
        writer = install_fixtures.InstallReleaseToApplicationsTests(methodName="runTest")
        writer.candidate = self.bridge.candidate
        writer._write_candidate(self.bridge.source)
        mapping = decode_canonical_bytes(self.bridge.candidate.read_bytes())
        mapping["source"].update(commit=commit, tree=tree, base_commit=commit, base_tree=tree,
            project_yml_sha256=hashlib.sha256((source / "MacScope/project.yml").read_bytes()).hexdigest())
        mapping["application"].update(materialize_candidate_identity._codesign_identity(self.bridge.source))
        self.bridge.candidate.write_bytes(canonical_bytes(mapping))
        candidate, issues = parse_candidate_identity(mapping)
        self.assertEqual(issues, ())
        inputs = command_inputs(profile=CampaignProfile.BOOTSTRAP_VERIFIER,
                                repository_root=source, output_root=self.root)
        inputs.update(candidate_identity_path=str(self.bridge.candidate),
            source_export_root=str(export), integration_ref=integration_ref,
            hosted_governance_runner=str(export / "Scripts/ci/run_hosted_governance.py"),
            source_release_app=str(self.bridge.source), installed_app=str(self.bridge.installed),
            install_release_artifact_root=str(self.bridge.artifacts),
            installed_pending_state=str(installer._pending_root(
                self.bridge.installed, candidate_identity_sha256(candidate)) / "transaction.json"),
            qualification_run_id="run-fixture", qualification_run_nonce="7" * 64)
        receipt_id = "receipt-installed-begin"
        sources = [dict(artifact_id="begin-output-" + str(index),
            relative_path=str((self.bridge.artifacts / name).relative_to(self.root)),
            kind="json", media_type="application/json",
            command_output="artifact:" + str(self.bridge.artifacts / name))
            for index, name in enumerate((self.bridge.bridge.PROJECTION_NAME, self.bridge.bridge.EQUALITY_NAME))]
        sources.append(dict(artifact_id="begin-log", relative_path="begin.log", kind="launch-log",
            media_type="text/plain", command_output="log:executor-captured:install-release-to-applications-stdout-stderr"))
        commands = {BEGIN: dict(metadata(), receipt_id=receipt_id,
            receipt_type="installed-source-equality", owner_artifacts=sources,
            execution_report_artifact_id=capture_execution_report_artifact_id(receipt_id),
            executor=dict(metadata()["executor"], host="macos-arm64-xcode27-tcc")),
            AGGREGATE: dict(metadata(), receipt_id="receipt-aggregate-transport-only",
                receipt_type="installed-workflow")}
        manifest = dict(schema_version=3, campaign_profile=CampaignProfile.BOOTSTRAP_VERIFIER.value,
            candidate_identity=mapping, repository_root=str(source), command_inputs=inputs,
            qualification_run=dict(run_id="run-fixture", nonce="7" * 64), commands=commands)
        (self.root / "run.json").write_bytes(canonical_bytes(manifest))
        self.run = operator_run.load_run(self.root)
        original_completed = operator_run.OperatorRun.completed

        def completed(run, command, *args):
            if command == "signing.strict-release":
                # Independent upstream receipt transport is isolated; BEGIN's
                # real bundle/signing observations are never replaced.
                return dict(receipt_id="prior-signing", canonical_sha256="b" * 64)
            return original_completed(run, command, *args)

        patcher = mock.patch.object(operator_run.OperatorRun, "completed", completed)
        patcher.start()
        self.addCleanup(patcher.stop)
        original_transport = command_execution._capture_owned_process

        def transport(argv, **kwargs):
            def spawn(observed_argv, **spawn_kwargs):
                self.assertEqual(tuple(observed_argv), tuple(argv))
                stdout, stderr = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    status = self.bridge.bridge.main(list(argv[3:]))
                self.assertEqual(status, 0, stderr.getvalue())
                # Actual owned child/stream capture; the actual bridge runs
                # in-process solely to retain portable external-tool fixtures.
                return subprocess.Popen([sys.executable, "-c",
                    "import sys; sys.stdout.write(" + repr(stdout.getvalue()) + "); sys.stderr.write(" +
                    repr(stderr.getvalue()) + ")"], **spawn_kwargs)
            return original_transport(argv, **kwargs, spawn=spawn)

        with mock.patch.object(command_execution, "_capture_owned_process", side_effect=transport):
            record = self.run._record(BEGIN)
            self.receipt = self.run.execute(BEGIN, record.scenario_ids[0], threading.Event())

    def test_actual_bridge_emits_and_replays_public_installed_receipt(self):
        result = self.run.completed_result(BEGIN)
        self.assertEqual(result.receipt, self.receipt)
        self.assertEqual(validate_receipt(result.receipt, context=result.context), ())
        self.assertEqual(result.receipt["receipt_type"], "installed-source-equality")
        outputs = {item["command_output"]: item for item in result.receipt["artifacts"]}
        equality_output = "artifact:" + str(self.bridge.artifacts / self.bridge.bridge.EQUALITY_NAME)
        self.assertEqual(outputs[equality_output]["kind"], "source-equality-report")
        self.assertFalse(any("INSTALL_RELEASE_OPERATION_REPORT" in key for key in outputs))
        retained = retained_begin_state(result.admission)
        self.assertEqual(installer._pending_read_stable(retained.path.parent)[1], retained)
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in self.root.rglob("*") if path.is_file()}
        restarted = operator_run.load_run(self.root)
        self.assertEqual(restarted.completed(BEGIN), self.receipt)
        self.assertEqual(before, {path: (path.read_bytes(), path.stat().st_mtime_ns)
                                 for path in self.root.rglob("*") if path.is_file()})

    def test_aggregate_transport_retains_only_replayed_begin_ancestor(self):
        result = self.run.completed_result(BEGIN)
        # Only carrier transport is exercised here; this unexecuted aggregate
        # capture is never submitted to a receipt validator as execution proof.
        capture = replace(result.admission.capture, command_id=AGGREGATE)
        admission = self.run.receipt_admission(capture)
        self.assertIsNotNone(admission.installed_begin_admission)
        self.assertEqual(admission.installed_begin_admission, result.admission)
        records = tuple(replace(record, prerequisite_ids=()) if record.command_id == AGGREGATE else record
                        for record in self.run.integrated_plan_input.plan.commands)
        changed = replace(self.run, integrated_plan_input=replace(self.run.integrated_plan_input,
            plan=replace(self.run.integrated_plan_input.plan, commands=records)))
        with self.assertRaisesRegex(operator_run.OperatorError, "ancestor"):
            changed.receipt_admission(capture)
        legacy = replace(self.run, campaign_profile=CampaignProfile.EXISTING)
        self.assertIsNone(legacy.receipt_admission(capture).installed_begin_admission)
        # A capture-shaped object from another run or plan cannot carry this
        # BEGIN authority even when the command and candidate happen to match.
        context = capture.admission
        for changed_context in (
                replace(context, qualification_run=replace(context.qualification_run, run_id="another-run")),
                replace(context, integrated_plan_input=replace(context.integrated_plan_input,
                    inputs=dict(context.integrated_plan_input.inputs, qualification_work_root=str(self.root / "other"))))):
            with self.subTest(context=changed_context), self.assertRaisesRegex(
                    operator_run.OperatorError, "candidate/run/plan"):
                self.run.receipt_admission(replace(capture, admission=changed_context))

    def test_public_begin_replay_survives_real_commit_but_rejects_missing_marker(self):
        result = self.run.completed_result(BEGIN)
        retained = retained_begin_state(result.admission)
        state = decode_canonical_bytes(retained.payload)
        projection = decode_canonical_bytes((self.bridge.artifacts / self.bridge.bridge.PROJECTION_NAME).read_bytes())
        # Synthetic eight-gate envelopes drive only the actual transaction state
        # machine. They are not offered as GUI/native qualification evidence.
        self.bridge.owner._write_acceptance_receipt(state["candidate_token"])
        argv = ["--phase", "commit", "--transaction-token", state["candidate_token"],
            "--candidate-identity", str(self.bridge.candidate), "--source-app", str(self.bridge.source),
            "--installed-app", str(self.bridge.installed), "--artifact-root", str(self.bridge.artifacts),
            "--qualification-run-id", "run-fixture", "--qualification-run-nonce", "7" * 64,
            "--predecessor-observations-sha256", projection["physical_predecessor"]["sha256"]]
        for gate in self.bridge.owner.acceptance_gate_arguments:
            argv += ["--acceptance-gate-input", gate]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = installer.main(argv)
        self.assertEqual(status, 0, stderr.getvalue())
        self.assertFalse(retained.path.exists())
        restarted = operator_run.load_run(self.root)
        self.assertEqual(restarted.completed(BEGIN), self.receipt)
        self.assertEqual(retained_begin_state(restarted.completed_result(BEGIN).admission), retained)
        committed = installer._committed_root(self.bridge.installed, state["candidate_token"], state["transaction_id"])
        (committed / installer.COMMIT_AUTHORITY_NAME).unlink()
        with self.assertRaises(ValueError):
            restarted.completed(BEGIN)

    def test_changed_begin_projection_or_capture_cannot_supply_authority(self):
        result = self.run.completed_result(BEGIN)
        projection = self.bridge.artifacts / self.bridge.bridge.PROJECTION_NAME
        original = projection.read_bytes()
        changed = decode_canonical_bytes(original)
        changed["command_predecessor_observations_sha256"] = "f" * 64
        projection.write_bytes(canonical_bytes(changed))
        self.assertTrue(validate_receipt(result.receipt, context=result.context))
        with self.assertRaises(ValueError):
            retained_begin_state(result.admission)
        projection.write_bytes(original)
        result.admission.capture.capture_path.write_bytes(b"{}")
        self.assertTrue(validate_receipt(result.receipt, context=result.context))
