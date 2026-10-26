"""Small retained-evidence primitives, NOT an all-green campaign factory.

The physical products and xcresult are explicit portable test doubles. Only
external codesign, toolchain and xcresult tool I/O is substituted by the reused
fixture. Git/source/export, product/receipt semantics, capture transport and
public receipt validation are real. No validator is replaced with success.
Callers must supply genuine raw prerequisite inputs; this helper invents no
predecessor digest and makes no claim to native or installed qualification.
"""
from __future__ import annotations

import base64
import shutil
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

from Scripts.tests.test_gate_f_bootstrap_qualification import BootstrapPhysicalAdmissionTests
from Scripts.reconstruction_gate_f import command_execution as execution
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.reconstruction_gate_f.command_capture import parse_capture
from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, command_templates, campaign_profile_for_inputs
from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan
from Scripts.reconstruction_gate_f.evidence_model import EvidenceReceiptInput
from Scripts.reconstruction_gate_f.executor_receipt import emit_executor_receipt
from Scripts.reconstruction_gate_f.executor_request_adapter import (
    ExecutorReceiptAdmission, OwnerArtifactSource, build_executor_request,
    capture_execution_report_artifact_id, capture_derived_report_receipt_type,
    publish_capture_execution_report,
)
from Scripts.reconstruction_gate_f.prerequisite_dag import LaneCIntegratedCommandPlanInput
from Scripts.reconstruction_gate_f.qualification_artifact_validator import (
    validate_qualification_products, validate_full_coretests_xcresult,
)
from Scripts.reconstruction_gate_f.qualification_receipt_adapter import publish_qualification_artifact_projections
from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation, validate_receipt
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.schema import ArtifactKind, QualificationPhase, candidate_to_mapping
from .test_command_compiler import ROOT, command_inputs


class RetainedCampaignFixture:
    def __init__(self, test, *, profile=CampaignProfile.EXISTING, source_paths=()):
        self.test, self.profile = test, profile
        physical = BootstrapPhysicalAdmissionTests()
        physical.setUp()
        test.addCleanup(physical.doCleanups)
        self.physical = physical
        # Copy current production Python bytes before the fixture commits and
        # seals them, including newly integrated adapters in the caller's tree.
        for source in (ROOT / "Scripts").rglob("*.py"):
            relative = source.relative_to(ROOT)
            if "tests" in relative.parts or source.name.startswith("test_"):
                continue
            target = physical.repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        for template in command_templates(profile=profile):
            for token in template.argv:
                if token.startswith(("Scripts/", "./Scripts/")) and "@" not in token:
                    relative = token[2:] if token.startswith("./") else token
                    target = physical.repository / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / relative, target)
            if "--only-testing" in template.argv:
                suite = template.argv[template.argv.index("--only-testing") + 1].split("/")[1]
                target = physical.repository / "MacScope/Tests/CoreTests" / (suite + ".swift")
                target.parent.mkdir(parents=True, exist_ok=True)
                # Static selector-existence fixture, not execution evidence.
                target.write_text("class " + suite + ": XCTestCase {}\n")
        # Adjudication callers may retain their precise current-source closure
        # before commit/export, rather than mutate a validated fixture later.
        # This overrides static selector scaffolds with real source when needed.
        for value in source_paths:
            relative = Path(value)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("extra source must be repository-relative")
            source = ROOT / relative
            if source.is_symlink() or not source.is_file():
                raise ValueError("extra source must be an ordinary current-source file")
            target = physical.repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        self.build = physical.fixture()
        self.root, self.repository = physical.root, physical.repository
        self.candidate, self.run = physical.candidate, physical.run
        candidate_path = self.root / "candidate.json"
        candidate_path.write_bytes(canonical_bytes(candidate_to_mapping(self.candidate)))
        self.inputs = command_inputs(profile=profile, repository_root=self.repository, output_root=self.root)
        self.inputs.update(candidate_identity_path=str(candidate_path),
            integration_ref=physical.source.integration_ref,
            qualification_run_id=self.run.run_id, qualification_run_nonce=self.run.nonce,
            source_export_root=str(self.root / "command-export"),
            qualification_work_root=str(physical.work), dependency_cache_root=str(physical.cache),
            developer_dir=str(physical.developer))
        self.inputs["hosted_governance_runner"] = self.inputs["source_export_root"] + "/Scripts/ci/run_hosted_governance.py"
        scenarios = compile_scenario_catalog(self.candidate)
        plan = compile_command_plan(self.candidate, scenarios, repository_root=self.repository,
            inputs=self.inputs, profile=profile)
        self.integrated = LaneCIntegratedCommandPlanInput(plan, scenarios, self.repository, self.inputs,
            {t.command_id: t for t in command_templates(profile=profile)})

    def full_suite_proof(self):
        """Real product + full-suite semantic proof, not a Gate F receipt."""
        validate_qualification_products(self.candidate, self.build.receipt,
            integration_ref=self.physical.source.integration_ref,
            dependency_cache_root=self.physical.cache, mode="full-test")
        return validate_full_coretests_xcresult(self.physical.xcresult,
            candidate=self.candidate, source_root=self.build.source,
            integration_ref=self.physical.source.integration_ref, scratch_root=self.root)

    @staticmethod
    def validate(raw):
        return validate_receipt(raw.receipt, context=raw.context)

    def capture(self, command_id, *, predecessors=(), stdout=None):
        """Observe a real process. stdout selects an explicit transport double.

        The double substitutes only Popen's executable. The complete intended
        argv/plan is still independently recompiled and captured by production.
        Use only for external resources not under test, never to qualify native
        execution. Owner artifacts must independently pass their real validator.
        """
        expectations = []
        for raw in predecessors:
            if (not isinstance(raw, EvidenceReceiptInput) or self.validate(raw)
                    or raw.receipt.get("evidence_status") != "passed"):
                raise ValueError("a predecessor must be a publicly accepted retained raw receipt")
            if raw.context.expected_qualification_run != self.run:
                raise ValueError("predecessor belongs to another run")
            retained = raw.context.capture_admission
            if (not isinstance(retained, ExecutorReceiptAdmission)
                    or not isinstance(retained.capture, execution.ExecutionCapture)
                    or not isinstance(retained.capture.admission, execution.ExecutionAdmission)):
                raise ValueError("predecessor lacks retained capture plan authority")
            retained_execution = retained.capture.admission
            if (raw.context.expected_candidate != self.candidate
                    or retained_execution.candidate != self.candidate):
                raise ValueError("predecessor belongs to another candidate")
            retained_plan = retained_execution.integrated_plan_input
            if campaign_profile_for_inputs(retained_plan.inputs) is not self.profile:
                raise ValueError("predecessor belongs to another profile")
            if retained_plan != self.integrated:
                raise ValueError("predecessor belongs to another integrated plan")
            expectations.append(CommandPrerequisiteExpectation(raw.receipt["command_id"],
                raw.context.expected_receipt_id, raw.receipt["canonical_sha256"],
                self.run.run_id, self.run.nonce))
        admission = execution.ExecutionAdmission(self.candidate, self.integrated, self.run,
            self.candidate.source.commit, self.candidate.source.tree, tuple(expectations))
        record = next(r for r in self.integrated.plan.commands if r.command_id == command_id)
        scenario = record.scenario_ids[0] if record.scenario_ids else command_id
        if stdout is None:
            return execution.execute_admitted_command(admission, command_id, scenario,
                capture_root=self.root, profile=self.profile)
        admitted = execution.admit_command(admission, command_id, scenario, profile=self.profile)
        original = subprocess.Popen
        def spawn(argv, **kwargs):
            if tuple(argv) != admitted.resolved_command.record.argv:
                raise AssertionError("transport double received unexpected argv")
            return original([sys.executable, "-B", "-c", "import os; os.write(1," + repr(stdout) + ")"], **kwargs)
        transport = execution._capture_owned_process
        def observe(*args, **kwargs):
            return transport(*args, **kwargs, spawn=spawn)
        with patch.object(execution, "_capture_owned_process", side_effect=observe):
            return execution.execute_admitted_command(admission, command_id, scenario,
                capture_root=self.root, profile=self.profile)

    def emit(self, capture, owner_artifacts, *, receipt_id, requirement_id="retained-fixture"):
        """Public emission/replay inputs; no private physical acceptance seam."""
        command_id = capture.command_id
        record = next(r for r in self.integrated.plan.commands if r.command_id == command_id)
        admission = ExecutorReceiptAdmission(capture, self.root, receipt_id, requirement_id,
            QualificationPhase.PREMERGE,
            capture_derived_report_receipt_type(command_id, profile=self.profile),
            "retained-fixture-root", capture_execution_report_artifact_id(receipt_id),
            tuple(owner_artifacts), dict(executor_id="portable-retained-observer",
                host=record.host.value,
                platform="linux" if command_id.startswith("source.") else "macos",
                architecture="x86_64" if command_id.startswith("source.") else "arm64", os_version="portable-fixture"))
        publish_capture_execution_report(admission)
        if any(s.kind in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT} for s in owner_artifacts):
            admission = publish_qualification_artifact_projections(admission)
        receipt, context = emit_executor_receipt(build_executor_request(admission), artifact_root=self.root,
            qualification_run_authority=self.run, admission=admission)
        return EvidenceReceiptInput(receipt, context)

    def full_suite_receipt(self, *, predecessors):
        """Emit only with actual retained focused predecessors supplied by caller.

        Does not fabricate the fourteen-command predecessor chain. The Python
        marker child is a transport double, not a native test invocation; all
        qualification products and xcresult semantics are independently read.
        """
        if self.profile is not CampaignProfile.EXISTING:
            raise ValueError("bootstrap full-suite uses its independently retained verifier admission")
        command_id = "xcode.full-coretests"
        outputs = {"MACSCOPE_QUALIFICATION_RECEIPT": self.build.receipt,
            "MACSCOPE_TEST_RESULTS": self.physical.xcresult,
            "MACSCOPE_COVERAGE_JSON": self.build.run / "COVERAGE.json"}
        stdout = b"".join((key + "=" + str(value) + "\n").encode() for key, value in outputs.items())
        capture = self.capture(command_id, predecessors=predecessors, stdout=stdout)
        record = next(r for r in self.integrated.plan.commands if r.command_id == command_id)
        receipt_id = "receipt-" + capture.capture_id
        sources = tuple(OwnerArtifactSource("qualification-" + str(index) + "-" + capture.capture_id,
            path.relative_to(self.root).as_posix(),
            ArtifactKind.XCRESULT if key == "MACSCOPE_TEST_RESULTS" else ArtifactKind.JSON,
            "application/octet-stream" if key == "MACSCOPE_TEST_RESULTS" else "application/json",
            "artifact:stdout-path:" + key) for index, (key, path) in enumerate(outputs.items()))
        log = self.root / (capture.capture_id + ".log")
        log.write_bytes(stdout)
        sources += tuple(OwnerArtifactSource("qualification-log-" + str(index) + "-" + capture.capture_id,
            log.name, ArtifactKind.LAUNCH_LOG, "text/plain", "log:" + output)
            for index, output in enumerate(record.generated_logs))
        return self.emit(capture, sources, receipt_id=receipt_id)

    def source_receipt(self, *, predecessor=None):
        command_id = "source.create-sealed-export" if predecessor is None else "source.verify-sealed-export"
        capture = self.capture(command_id, predecessors=() if predecessor is None else (predecessor,))
        record = next(r for r in self.integrated.plan.commands if r.command_id == command_id)
        document = parse_capture(capture.capture_path.read_bytes()).to_mapping()
        streams = {name: b"".join(base64.b64decode(frame["data_base64"], validate=True)
            for frame in document["output_frames"] if frame["stream"] == name)
            for name in ("stdout", "stderr")}
        log = self.root / (capture.capture_id + ".log")
        log.write_bytes(streams["stdout"] + streams["stderr"])
        sources = tuple(OwnerArtifactSource("source-" + str(i) + "-" + capture.capture_id,
            Path(path).relative_to(self.root).as_posix(), ArtifactKind.JSON, "application/json", "artifact:" + path)
            for i, path in enumerate(record.generated_artifacts))
        sources += (OwnerArtifactSource("log-" + capture.capture_id, log.name, ArtifactKind.LAUNCH_LOG,
            "text/plain", "log:" + record.generated_logs[0]),)
        return self.emit(capture, sources, receipt_id="receipt-" + capture.capture_id)
