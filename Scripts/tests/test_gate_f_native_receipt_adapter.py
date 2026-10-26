"""Synthetic retained native files; no native producer, Xcode or GUI execution."""
from __future__ import annotations

import base64
import copy
from dataclasses import replace
import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, canonical_sha256, to_primitive
from Scripts.reconstruction_gate_f import command_capture, command_execution, prerequisite_dag
from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, command_templates
from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan, command_plan_sha256
from Scripts.reconstruction_gate_f.executor_request_adapter import ExecutorReceiptAdmission, OwnerArtifactSource
from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation
from Scripts.reconstruction_gate_f.runtime_resolution import resolve_command_record
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.schema import ArtifactKind, QualificationPhase, ReceiptType
from Scripts.reconstruction_gate_f.tests import parsed_candidate
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
from Scripts.reconstruction_gate_f.tests.test_executor_receipt import QUALIFICATION_RUN
from Scripts.tests import test_native_qualification_report as native_fixture


class NativeReceiptAdapterTests(unittest.TestCase):
    def adapter(self):
        name = "Scripts.reconstruction_gate_f.native_receipt_adapter"
        self.assertIsNotNone(importlib.util.find_spec(name), "native physical admission adapter is missing")
        return __import__(name, fromlist=["validate_native_qualification"])

    def fixture(self, command_id="native.normal"):
        f = native_fixture.NativeQualificationReportTests(methodName="runTest")
        f.setUp()
        self.addCleanup(f.doCleanups)
        profile = {"native.normal": "none", "native.asan": "address", "native.ubsan": "undefined",
                   "native.golden": "none"}[command_id]
        target = f.root / "native-work" / ("normal" if profile == "none" else "sanitizers/" + profile)
        target.parent.mkdir(parents=True, exist_ok=True)
        previous = f.build
        previous.rename(target)
        f.build, f.report = target, target / "qualification"
        for name in ("CMakeCache.txt", "compile_commands.json"):
            p = target / name
            p.write_bytes(p.read_bytes().replace(str(previous).encode(), str(target).encode()))
        for row in f.inventory["tests"]:
            row["command"][0] = str(target / Path(row["command"][0]).name)
        if profile != "none":
            f.sanitizer_fixture(profile)
        # Seal a small genuine Git export containing the producer closure. No
        # repository-source or manifest validator is replaced in these tests.
        from Scripts.source_export_provenance import create_export
        # The real compiler checks only the command-owned source entrypoints
        # and selected XCTest definitions. Copy their bounded source closure.
        paths = {"Scripts/reconstruction_gate_f/command_execution.py"}
        paths.update(f.module.source_identity.profile_paths(ROOT, "golden"))
        paths.update("Scripts/native-decompiler-xpc/" + name for name in
            ("run_gatef_native_golden.py", "native_golden_evidence.py", "stage_xcode_resources.py"))
        for template in command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER):
            for i, token in enumerate(template.argv):
                if token.startswith(("Scripts/", "./Scripts/")): paths.add(token.removeprefix("./"))
                if i and template.argv[i - 1] == "-m" and token.startswith("Scripts."):
                    paths.add(token.replace(".", "/") + ".py")
            if "--only-testing" in template.argv:
                suite = template.argv[template.argv.index("--only-testing") + 1].split("/")[1]
                paths.add("MacScope/Tests/CoreTests/" + suite + ".swift")
        for relative in sorted(paths):
            target_source = f.repo / relative
            target_source.parent.mkdir(parents=True, exist_ok=True)
            if not target_source.exists(): shutil.copyfile(ROOT / relative, target_source)
        (f.repo / "THIRD_PARTY_COMPONENTS.yml").write_bytes(b'{"components":[]}\n')
        (f.repo / "THIRD_PARTY_NOTICES.md").write_bytes(b"Synthetic fixture notices\n")
        def git(*args):
            return subprocess.run(["git", *args], cwd=f.repo, check=True, capture_output=True,
                                  text=True).stdout.strip()
        git("init", "-q", "-b", "fixture")
        git("remote", "add", "github", "https://github.com/jdotc1/MacScope-app.git")
        git("add", ".")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        git("update-ref", "refs/remotes/github/fixture", "HEAD")
        f.export = f.root / "export"
        provenance = create_export(f.repo, f.export, "refs/remotes/github/fixture")
        new_digest = f.module.source_identity.profile_digest(f.repo, "wrapper")
        f.report.mkdir()
        now = time.time_ns() // 1_000_000
        toolchain = {"developer_dir": str(f.dev), "compiler": f.module._external(f.compiler),
            "sdk_root": str(f.sdk), "sdk_settings": f.module._external(f.sdk / "SDKSettings.json"),
            "cmake": f.module._external(f.cmake), "ctest": f.module._external(f.ctest),
            "compiler_version": "Apple clang version 21.0.0", "cmake_version": "cmake version 4.1.0",
            "ctest_version": "ctest version 4.1.0"}
        snapshot = f.module._snapshot(repository_root=f.repo, build_root=f.build, materialization_root=f.material,
                 profile=profile, developer_dir=f.dev, final=False, observe=False, recorded_toolchain=toolchain)
        (f.report / "native-inputs.json").write_bytes(canonical_bytes(snapshot))
        (f.report / "ctest.inventory.json").write_bytes(json.dumps(f.inventory).encode())
        (f.report / "ctest.junit.xml").write_bytes(f.xml().encode())
        for name, timestamp in (("native-inputs.json", now - 200), ("ctest.inventory.json", now - 200), ("ctest.junit.xml", now - 50)):
            os.utime(f.report / name, ns=(timestamp * 1_000_000, timestamp * 1_000_000))
        rows = f.module._inventory((f.report / "ctest.inventory.json").read_bytes(), f.build)
        for row in rows: row["status"] = "passed"
        execution = dict(schema_version=1, record_kind="macscope-native-ctest-execution", profile=profile,
            build_root=str(f.build), started_at_unix_ms=now - 100, ended_at_unix_ms=now - 25, exit_code=0,
            inventory=f.module._file_ref(f.report / "ctest.inventory.json", f.report),
            junit=f.module._file_ref(f.report / "ctest.junit.xml", f.report),
            input_snapshot=f.module._file_ref(f.report / "native-inputs.json", f.report), tests=rows)
        (f.report / "ctest.execution.json").write_bytes(canonical_bytes(execution))
        if profile == "none": f.extras()
        final = f.module._snapshot(repository_root=f.repo, build_root=f.build, materialization_root=f.material,
            profile=profile, developer_dir=f.dev, final=True, observe=False, recorded_toolchain=toolchain)
        final.update(record_kind="macscope-native-qualification", ctest=f.module._file_ref(f.report / "ctest.execution.json", f.report))
        f.result = f.report / "native-qualification.json"
        f.result.write_bytes(canonical_bytes(final))
        candidate = parsed_candidate()
        candidate = replace(candidate, source=replace(candidate.source, commit=provenance["git_head_commit"],
            tree=provenance["git_head_tree"], base_commit=provenance["git_head_commit"],
            base_tree=provenance["git_head_tree"], dirty=False))
        tools = {"clang": ("Apple clang version 21.0.0", f.compiler), "cmake": ("cmake version 4.1.0", f.cmake),
                 "sdk": ("27.2", f.sdk / "SDKSettings.json")}
        swift = f.dev / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        f.executable(swift, "raise AssertionError('must not execute Swift during replay')")
        for tool in (f.dev / "Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo", f.sdk / "usr/lib/libc++.tbd"):
            tool.parent.mkdir(parents=True, exist_ok=True); tool.write_bytes(b"synthetic selected tool")
        system_version = f.sdk / "System/Library/CoreServices/SystemVersion.plist"
        system_version.parent.mkdir(parents=True, exist_ok=True)
        system_version.write_bytes(plistlib.dumps({"ProductBuildVersion": "27C99"}))
        tools.update(xcode=("Xcode 27.2 | Build version 27C20", f.dev / "usr/bin/xcodebuild"),
            swift=("Apple Swift version 6.4 (synthetic) | Target: arm64-apple-macosx27.2.0", swift))
        candidate = replace(candidate, tools=tuple(replace(t, version=tools[t.tool_id][0],
            identity_sha256=hashlib.sha256(tools[t.tool_id][1].read_bytes()).hexdigest()) if t.tool_id in tools else t
            for t in candidate.tools))
        inputs = command_inputs(profile=CampaignProfile.BOOTSTRAP_VERIFIER, repository_root=f.repo, output_root=f.root)
        inputs.update(repository_root=str(f.repo), source_export_root=str(f.export), native_source_root=str(f.repo / "Tools/NativeDecompilerBridge"),
            native_build_root=str(f.root / "native-work/normal"), native_sanitizer_build_root=str(f.root / "native-work/sanitizers"),
            native_normal_report_dir=str(f.root / "native-work/normal/qualification"),
            native_asan_report_dir=str(f.root / "native-work/sanitizers/address/qualification"),
            native_ubsan_report_dir=str(f.root / "native-work/sanitizers/undefined/qualification"),
            native_golden_work_root=str(f.root / "native-work/golden"),
            sleigh_materialization_root=str(f.material), native_wrapper_revision=new_digest,
            developer_dir=str(f.dev), sdk_root=str(f.sdk), sdk_name="macosx27.2",
            integration_ref="refs/remotes/github/fixture", qualification_run_id=QUALIFICATION_RUN.run_id,
            qualification_run_nonce=QUALIFICATION_RUN.nonce,
            **{name: str(f.root / name) for name in ("bootstrap_artifact_root", "bootstrap_admission_path",
                "bootstrap_fullsuite_artifact_root", "bootstrap_products_artifact_root")})
        templates = command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        from Scripts.reconstruction_gate_f.command_compiler import required_command_input_names
        inputs = {k: v for k, v in inputs.items() if k in required_command_input_names(templates)}
        scenarios = compile_scenario_catalog(candidate)
        plan = compile_command_plan(candidate, scenarios, repository_root=f.repo, inputs=inputs, profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        record = next(r for r in plan.commands if r.command_id == command_id)
        predecessors = tuple(CommandPrerequisiteExpectation(key, "prior-" + str(i), "c" * 64,
            QUALIFICATION_RUN.run_id, QUALIFICATION_RUN.nonce) for i, key in enumerate(record.prerequisite_ids))
        resolved = resolve_command_record(record, prerequisite_receipts=predecessors, qualification_run=QUALIFICATION_RUN,
                                          profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        context = command_execution.ExecutionAdmission(candidate, prerequisite_dag.LaneCIntegratedCommandPlanInput(
            plan, scenarios, f.repo, inputs, {t.command_id: t for t in templates}), QUALIFICATION_RUN,
            candidate.source.commit, candidate.source.tree, predecessors)
        stdout = ("MACSCOPE_NATIVE_QUALIFICATION_REPORT=" + str(f.result) + "\n").encode()
        sources = (OwnerArtifactSource("native-report", f.result.relative_to(f.root).as_posix(), ArtifactKind.JSON,
            "application/json", "artifact:stdout-path:MACSCOPE_NATIVE_QUALIFICATION_REPORT"),)
        if command_id == "native.golden":
            from Scripts.tests.test_gatef_native_golden_producer import load, PRODUCER
            golden = load(PRODUCER)
            work = f.root / "native-work/golden"
            products, stage = work / "products", work / "metadata/stage"
            products.mkdir(parents=True); stage.mkdir(parents=True)
            golden._STAGE.stage_xcode_resources(f.material, products, golden.RESOURCE_SUBPATH, stage)
            f.golden_material = products / golden.RESOURCE_SUBPATH / golden._STAGE.DESTINATION_NAME
            f.golden_stamp = stage / golden._STAGE.STAMP_NAME
            f.golden_result = products / "NativeDecompilerBridgeGolden.json"
            golden_payload = {**golden._EVIDENCE.PINNED_IDENTITY,
                **{name: "d" * 64 for name in golden._EVIDENCE.OUTCOME_KEYS},
                "schemaVersion": 1, "passed": True, "xcodeVersion": "27.2", "xcodeBuild": "27C20",
                "swiftCompilerVersion": "6.4", "swiftTargetTriple": "arm64-apple-macosx27.2.0",
                "sdkName": "macosx27.2", "sdkVersion": "27.2", "sdkBuild": "27C99",
                "wrapperGitRevision": f.module.source_identity.profile_digest(f.repo, "wrapper"),
                "goldenSourceSHA256": f.module.source_identity.profile_digest(f.repo, "golden"),
                "contractArchiveSHA256": hashlib.sha256((f.build / "libmacscope_native_decompiler_contract.a").read_bytes()).hexdigest(),
                "contractBuildIdentitySHA256": hashlib.sha256((f.build / "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp").read_bytes()).hexdigest(),
                "stageStampSHA256": hashlib.sha256(f.golden_stamp.read_bytes()).hexdigest(),
                "materializationManifestSHA256": hashlib.sha256((f.golden_material / "MATERIALIZATION.json").read_bytes()).hexdigest(),
                "materializationTreeSHA256": json.loads((f.golden_material / "MATERIALIZATION.json").read_bytes())["package"]["treeSha256"],
                "decompilerArchiveSHA256": hashlib.sha256((f.golden_material / "package/lib/libdecomp.a").read_bytes()).hexdigest(),
                "sleighArchiveSHA256": hashlib.sha256((f.golden_material / "package/lib/libsla.a").read_bytes()).hexdigest()}
            f.golden_result.write_bytes((json.dumps(golden_payload, sort_keys=True, separators=(",", ":")) + "\n").encode())
            markers = ("MACSCOPE_NATIVE_GOLDEN_RESULT", "MACSCOPE_NATIVE_GOLDEN_STAGE_STAMP", "MACSCOPE_NATIVE_GOLDEN_MATERIALIZATION")
            paths = (f.golden_result, f.golden_stamp, f.golden_material)
            stdout = b"".join((m + "=" + str(p) + "\n").encode() for m, p in zip(markers, paths))
            sources = tuple(OwnerArtifactSource("golden-" + str(i), p.relative_to(f.root).as_posix(), ArtifactKind.JSON,
                "application/json", "artifact:stdout-path:" + m) for i, (m, p) in enumerate(zip(markers, paths)))
        log = f.root / "native-output.log"
        log.write_bytes(stdout)
        sources += (OwnerArtifactSource("native-log", log.name, ArtifactKind.LAUNCH_LOG, "text/plain",
            "log:executor-captured:" + command_id.replace(".", "-") + "-stdout-stderr"),)
        intent = dict(capture_id="native-capture", run_id=QUALIFICATION_RUN.run_id, nonce=QUALIFICATION_RUN.nonce,
            candidate_identity_sha256=record.candidate_identity_sha256, command_plan_sha256=command_plan_sha256(plan),
            command_record_sha256=canonical_sha256(record), command_id=command_id, scenario_id=record.scenario_ids[0],
            producer_source_commit=candidate.source.commit, producer_source_tree=candidate.source.tree,
            argv=list(resolved.record.argv), working_directory=record.working_directory,
            environment=[list(v) for v in record.environment], effective_environment=[list(v) for v in record.environment],
            environment_policy_id="gatef-host-environment-v1", prerequisite_receipts=sorted([[p.command_id, p.canonical_sha256] for p in predecessors]),
            started_at_unix_ms=now - 500)
        frames = [dict(sequence=0, stream="stdout", raw_length=len(stdout), raw_sha256=hashlib.sha256(stdout).hexdigest(),
                       data_base64=base64.b64encode(stdout).decode())]
        document = dict(schema_version=2, intent=intent, output_frames=frames,
            runtime_resolution=to_primitive(resolved.runtime_resolution),
            process_observation=dict(state="launched", pid=123, spawn_observed_monotonic_ns=1,
                os_start_time=dict(state="unavailable", reason="synthetic physical fixture")),
            terminal=dict(intent_sha256=canonical_sha256(intent), frames_sha256=canonical_sha256(frames),
                ended_at_unix_ms=now + 10_000, termination_kind="exited", exit_code=0, signal=None,
                stdout_length=len(stdout), stdout_sha256=hashlib.sha256(stdout).hexdigest(),
                stderr_length=0, stderr_sha256=hashlib.sha256(b"").hexdigest()))
        capture_path = f.root / "native-capture.json"
        payload = command_capture.serialize_capture(document)
        capture_path.write_bytes(payload)
        capture = command_execution.ExecutionCapture(context, command_id, record.scenario_ids[0], "native-capture",
            record.environment, capture_path, hashlib.sha256(payload).hexdigest())
        role = ReceiptType.TEST_RESULT if profile == "none" else ReceiptType.NATIVE_SANITIZER
        from Scripts.reconstruction_gate_f.executor_request_adapter import capture_execution_report_artifact_id
        admission = ExecutorReceiptAdmission(capture, f.root, "native-receipt", "native-requirement", QualificationPhase.PREMERGE,
            role, "native-root", capture_execution_report_artifact_id("native-receipt"), sources,
            dict(executor_id="synthetic-xcode", host="macos-arm64-xcode27", platform="macos",
                 architecture="arm64", os_version="macos-27"))
        f.admission, f.document = admission, document
        return f

    def test_each_native_owner_requires_capture_and_exact_physical_report(self):
        adapter = self.adapter()
        for command, count in (("native.normal", 2), ("native.asan", 1), ("native.ubsan", 1)):
            with self.subTest(command=command):
                f = self.fixture(command)
                validate = lambda admission=f.admission: adapter.validate_native_qualification(
                    command_id=command, report_path=f.result, admission=admission)
                with patch.object(adapter._REPORT, "_capture", side_effect=AssertionError("replay executed a producer")), \
                     patch.object(adapter._GOLDEN, "_tool_identity", side_effect=AssertionError("replay probed a toolchain")):
                    value = validate()
                self.assertEqual(set(value), {"authority", "constituents"})
                self.assertEqual(len(value["constituents"]), count)
                self.assertEqual([c["selector_id"] for c in value["constituents"]],
                    ["native.governed-package-verification", "native.normal"] if count == 2 else [command])
                for bad in (None, replace(f.admission, receipt_type=ReceiptType.COMMAND_EXECUTION),
                            replace(f.admission, owner_artifacts=())):
                    with self.assertRaises((ValueError, RuntimeError)): validate(bad)
                raw = f.result.read_bytes()
                document = json.loads(raw); document["profile"] = "undefined" if command != "native.ubsan" else "address"
                f.result.write_bytes(canonical_bytes(document))
                with self.assertRaises((ValueError, RuntimeError)): validate()
                f.result.write_bytes(raw)
                (f.report / "ctest.junit.xml").unlink()
                with self.assertRaises((ValueError, RuntimeError, OSError)): validate()

    def test_cancelled_native_capture_cannot_pass_even_with_complete_reports(self):
        adapter = self.adapter()
        for command in ("native.normal", "native.asan", "native.ubsan", "native.golden"):
            f = self.fixture(command)
            for kind in ("cancelled", "timed-out", "signaled", "output-limit"):
                document = copy.deepcopy(f.document)
                document["terminal"].update(termination_kind=kind, exit_code=None if kind == "signaled" else 0,
                    signal=15 if kind == "signaled" else None)
                payload = command_capture.serialize_capture(document)
                f.admission.capture.capture_path.write_bytes(payload)
                admission = replace(f.admission, capture=replace(f.admission.capture, capture_sha256=hashlib.sha256(payload).hexdigest()))
                with self.subTest(command=command, kind=kind), self.assertRaises((ValueError, RuntimeError)):
                    adapter.validate_native_outputs(admission)

    def test_native_replay_rejects_late_manifest_product_or_result_mutation(self):
        adapter = self.adapter()
        for command in ("native.normal", "native.golden"):
            f = self.fixture(command)
            from Scripts.reconstruction_gate_f.operator_run import OperatorRun
            admission = OperatorRun._projected_admission(f.admission, publish=True) if command == "native.golden" else f.admission
            targets = [f.export / "SOURCE_FILES.json", f.build / "libmacscope_native_decompiler_contract.a",
                       f.report / "ctest.junit.xml", admission.capture.capture_path,
                       *(f.root / s.relative_path for s in admission.owner_artifacts if s.command_output.startswith("log:"))]
            if command == "native.golden":
                targets += [f.golden_result, f.golden_stamp,
                    f.sdk / "System/Library/CoreServices/SystemVersion.plist", f.dev / "usr/bin/xcodebuild"]
            else: targets += [f.result]
            semantic = adapter._semantic
            for target in targets:
                original = target.read_bytes()
                def mutate(*args):
                    value = semantic(*args)
                    target.write_bytes(original + b"late physical mutation")
                    return value
                try:
                    with self.subTest(command=command, target=target.name), patch.object(adapter, "_semantic", side_effect=mutate):
                        with self.assertRaises((ValueError, RuntimeError, OSError)):
                            adapter.validate_native_outputs(admission)
                finally: target.write_bytes(original)
            target = f.golden_result if command == "native.golden" else f.result
            original = target.read_bytes()
            def replace_same_bytes(*args):
                value = semantic(*args)
                replacement = target.with_suffix(".replacement")
                replacement.write_bytes(original)
                os.replace(replacement, target)
                return value
            with self.subTest(command=command, mutation="same-bytes-replacement"), patch.object(adapter, "_semantic", side_effect=replace_same_bytes):
                with self.assertRaises((ValueError, RuntimeError, OSError)):
                    adapter.validate_native_outputs(admission)
            alias = f.root / "hardlinked-result"
            os.link(target, alias)
            with self.subTest(command=command, mutation="hardlink"), self.assertRaises((ValueError, RuntimeError, OSError)):
                adapter.validate_native_outputs(admission)

    def test_native_capture_rejects_wrong_run_source_marker_and_supplied_semantics(self):
        adapter = self.adapter(); f = self.fixture()
        admission = f.admission
        for change in ("nonce", "source"):
            context = admission.capture.admission
            if change == "nonce": context = replace(context, qualification_run=replace(QUALIFICATION_RUN, nonce="d" * 64))
            else: context = replace(context, producer_source_commit="d" * 40)
            wrong = replace(admission, capture=replace(admission.capture, admission=context))
            with self.subTest(change=change), self.assertRaises((ValueError, RuntimeError)):
                adapter.validate_native_outputs(wrong)
        with self.assertRaises((ValueError, RuntimeError)):
            adapter.validate_native_outputs(replace(admission, authority={"passed_selector_count": 21}))

    def test_executor_log_published_after_process_exit_preserves_producer_freshness(self):
        adapter = self.adapter()
        for command in ("native.normal", "native.asan", "native.ubsan"):
            f = self.fixture(command)
            producer_outputs = [f.result, *(f.report / name for name in
                ("ctest.execution.json", "native-inputs.json", "ctest.inventory.json", "ctest.junit.xml"))]
            ended = max(p.stat().st_mtime_ns // 1_000_000 for p in producer_outputs)
            document = copy.deepcopy(f.document)
            document["terminal"]["ended_at_unix_ms"] = ended
            payload = command_capture.serialize_capture(document)
            f.admission.capture.capture_path.write_bytes(payload)
            admission = replace(f.admission, capture=replace(f.admission.capture, capture_sha256=hashlib.sha256(payload).hexdigest()))
            log = f.root / "native-output.log"
            os.utime(log, ns=((ended + 1000) * 1_000_000, (ended + 1000) * 1_000_000))
            with self.subTest(command=command):
                self.assertTrue(adapter.validate_native_outputs(admission)["constituents"])
                os.utime(f.result, ns=((ended + 1000) * 1_000_000, (ended + 1000) * 1_000_000))
                with self.assertRaises((ValueError, RuntimeError)):
                    adapter.validate_native_outputs(admission)

    def test_golden_admits_declared_swift_alias_and_reobserves_target(self):
        adapter = self.adapter(); f = self.fixture("native.golden")
        from Scripts.reconstruction_gate_f.operator_run import OperatorRun
        swift = f.dev / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        frontend = swift.with_name("swift-frontend")
        swift.rename(frontend); swift.symlink_to(frontend.name)
        admission = OperatorRun._projected_admission(f.admission, publish=True)
        self.assertTrue(adapter.validate_native_outputs(admission)["constituents"])
        semantic = adapter._semantic
        def mutate_target(*args):
            value = semantic(*args)
            frontend.write_bytes(frontend.read_bytes() + b"late target mutation")
            return value
        with patch.object(adapter, "_semantic", side_effect=mutate_target), self.assertRaises((ValueError, RuntimeError, OSError)):
            adapter.validate_native_outputs(admission)

    def test_existing_gate_fixture_preserves_default_native_capture_policy(self):
        from Scripts.reconstruction_gate_f.executor_request_adapter import (
            CAPTURE_DERIVED_REPORT_COMMANDS, capture_derived_report_policy)
        from Scripts.reconstruction_gate_f.tests.test_gate_evaluator import GateFixture, GateEvaluatorTests
        from Scripts.reconstruction_gate_f.schema import CandidateSubjectKind
        from Scripts.reconstruction_gate_f.receipt_validator import validate_receipt
        f = self.fixture()
        # Reuse the legacy fixture's established synthetic repository/native
        # observation boundaries. This case tests historical policy, not fresh
        # qualification; new-profile tests above retain real Git admission.
        support = GateEvaluatorTests(methodName="runTest")
        support.setUp(); self.addCleanup(support.doCleanups)
        fixture = GateFixture(f.root / "existing-profile", CandidateSubjectKind.PROSPECTIVE_MERGE)
        for command in ("native.normal", "native.asan", "native.ubsan", "native.golden"):
            with self.subTest(command=command):
                self.assertNotIn(command, CAPTURE_DERIVED_REPORT_COMMANDS)
                self.assertFalse(capture_derived_report_policy(command))
                self.assertTrue(capture_derived_report_policy(command, profile=CampaignProfile.BOOTSTRAP_VERIFIER))
                physical = fixture._catalog_input(fixture.prospective, command)
                self.assertIsNone(physical.context.capture_admission)
                self.assertEqual(validate_receipt(physical.receipt, context=physical.context), ())

    def test_golden_projection_is_created_once_and_rederived_from_physical_stage(self):
        adapter = self.adapter(); f = self.fixture("native.golden")
        from Scripts.reconstruction_gate_f.operator_run import OperatorRun
        admission = OperatorRun._projected_admission(f.admission, publish=True)
        expected_sources = to_primitive(admission.owner_artifacts)
        self.assertEqual(OperatorRun._projected_admission(f.admission, expected_sources), admission)
        with self.assertRaises(FileExistsError): OperatorRun._projected_admission(f.admission, publish=True)
        with patch.object(adapter._REPORT, "_capture", side_effect=AssertionError("replay executed a producer")), \
             patch.object(adapter._GOLDEN, "_tool_identity", side_effect=AssertionError("replay probed a toolchain")):
            value = adapter.validate_native_golden(result_path=f.golden_result, stage_stamp_path=f.golden_stamp,
                materialization_root=f.golden_material, admission=admission)
        self.assertEqual(value["authority"]["passed_selector_count"], 1)
        self.assertEqual([c["selector_id"] for c in value["constituents"]], ["native.golden"])
        # SDKSettings deliberately omits ProductBuildVersion. Physical SDK
        # SystemVersion.plist is the independent source, not the report string.
        original = f.golden_result.read_bytes(); result = json.loads(original)
        result["sdkBuild"] = "forged"
        f.golden_result.write_bytes((json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n").encode())
        with self.assertRaises((ValueError, RuntimeError)):
            adapter.validate_native_golden(result_path=f.golden_result, stage_stamp_path=f.golden_stamp,
                materialization_root=f.golden_material, admission=admission)
        f.golden_result.write_bytes(original)
        f.golden_stamp.unlink()
        with self.assertRaises((ValueError, RuntimeError, OSError)):
            adapter.validate_native_golden(result_path=f.golden_result, stage_stamp_path=f.golden_stamp,
                materialization_root=f.golden_material, admission=admission)

    def test_native_receipts_emit_and_replay_with_layer_kinds_after_physical_derivation(self):
        self.adapter()
        from Scripts.reconstruction_gate_f.executor_request_adapter import (build_executor_request,
            publish_capture_execution_report, emit_captured_receipt)
        from Scripts.reconstruction_gate_f.operator_run import OperatorRun
        from Scripts.reconstruction_gate_f.receipt_validator import validate_receipt
        for command in ("native.normal", "native.asan", "native.ubsan", "native.golden"):
            with self.subTest(command=command):
                f = self.fixture(command)
                admission = OperatorRun._projected_admission(f.admission, publish=True) if command == "native.golden" else f.admission
                publish_capture_execution_report(admission)
                request = build_executor_request(admission)
                kind = "sanitizer-report" if command in {"native.asan", "native.ubsan"} else "test-results"
                self.assertEqual(sum(a["kind"] == kind for a in request["artifacts"]), 1)
                receipt, context = emit_captured_receipt(request, artifact_root=f.root,
                    qualification_run_authority=QUALIFICATION_RUN, admission=admission)
                self.assertEqual(validate_receipt(receipt, context=context), ())
                self.assertEqual([i.code for i in validate_receipt(receipt,
                    context=replace(context, capture_admission=None))], ["capture-admission-required"])
                target = f.golden_result if command == "native.golden" else f.report / "ctest.junit.xml"
                target.unlink()
                self.assertTrue(validate_receipt(receipt, context=context))
