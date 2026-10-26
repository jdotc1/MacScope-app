from __future__ import annotations

import dataclasses
import unittest
from unittest import mock
from pathlib import Path

from Scripts.reconstruction.installed_matrix_receipt import PRESENTATION_VARIANTS
from Scripts.reconstruction_gate_f.command_catalog import (
    CampaignProfile,
    CommandExecutionMode,
    CommandHost,
    CommandMutationState,
    INDEPENDENT_REVIEW_COMMAND_LENSES,
    REQUIRED_RECEIPT_BINDING_FIELDS,
    command_templates,
)
from Scripts.reconstruction_gate_f.command_compiler import (
    RUNTIME_ARGUMENT_MARKER,
    CommandCompilationError,
    command_plan_sha256,
    compile_command_plan,
    required_command_input_names,
    validate_command_plan,
)
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.scenario_model import ScenarioOrigin, scenario_catalog_sha256
from Scripts.reconstruction_gate_f.schema import candidate_identity_sha256
from Scripts.reconstruction_gate_f.tests import candidate_mapping, parsed_candidate
from Scripts.reconstruction_gate_f.schema import parse_candidate_identity


ROOT = Path(__file__).resolve().parents[3]


def command_inputs(*, profile=CampaignProfile.EXISTING, repository_root=None,
                   output_root=None) -> dict[str, str]:
    base = Path("/private/tmp/macscope-gate-f")
    values = {
        name: str(base / name)
        for name in required_command_input_names(profile=profile)
    }
    values.update(
        {
            "repository_root": str(ROOT),
            "native_source_root": str(ROOT / "Tools" / "NativeDecompilerBridge"),
            "native_wrapper_revision": "a" * 64,
            "integration_ref": "refs/remotes/origin/main",
            "sdk_name": "macosx27.0",
            "generated_at_unix_ms": "0",
            "installed_app": "/Applications/MacScope.app",
            "source_release_app": "/private/tmp/macscope-gate-f/release/MacScope.app",
            "developer_dir": "/Applications/Xcode-beta.app/Contents/Developer",
            "qualification_run_id": "task11-local-premerge-qualification",
            "qualification_run_nonce": "b" * 64,
            "authority_stress_predecessor_observations": str(
                base / "authority-stress-predecessor-observations.json"
            ),
        }
    )
    values["hosted_governance_runner"] = (
        f"{values['source_export_root']}/Scripts/ci/run_hosted_governance.py"
    )
    if repository_root is not None:
        values["repository_root"] = str(repository_root)
        values["native_source_root"] = str(Path(repository_root) / "Tools/NativeDecompilerBridge")
    if output_root is not None:
        values["output_root"] = str(output_root)
    if profile is CampaignProfile.BOOTSTRAP_VERIFIER:
        shell_report = Path(values['installed_shell_smoke_report'])
        values.update(installed_full_surface_report=str(shell_report),
            installed_legacy_grid_report=str(shell_report.with_name(shell_report.stem + '.legacy-grid' + shell_report.suffix)))
        native_work = Path(values["output_root"]) / "native-work"
        values.update(native_build_root=str(native_work / "normal"),
            native_sanitizer_build_root=str(native_work / "sanitizers"),
            native_normal_report_dir=str(native_work / "normal/qualification"),
            native_asan_report_dir=str(native_work / "sanitizers/address/qualification"),
            native_ubsan_report_dir=str(native_work / "sanitizers/undefined/qualification"),
            native_golden_work_root=str(native_work / "golden"))
    return values


class GateFCommandCompilerTests(unittest.TestCase):
    def bootstrap_profile(self):
        from Scripts.reconstruction_gate_f import command_catalog
        profile = getattr(command_catalog, "CampaignProfile", None)
        self.assertIsNotNone(profile, "the explicit ordinary verifier profile is missing")
        return profile.BOOTSTRAP_VERIFIER

    def bootstrap_plan(self):
        from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
        profile = self.bootstrap_profile()
        self.bootstrap_root, values = bootstrap_repository(self)
        return compile_command_plan(self.candidate, self.scenarios,
            repository_root=self.bootstrap_root, inputs=values, profile=profile)

    def test_verifier_module_must_exist(self):
        from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
        root, inputs = bootstrap_repository(self)
        (root / "Scripts/reconstruction_gate_f/bootstrap_verifier.py").unlink()
        with self.assertRaisesRegex(CommandCompilationError, "invented-entrypoint"):
            compile_command_plan(self.candidate, self.scenarios, repository_root=root,
                                 inputs=inputs, profile=self.bootstrap_profile())

    def test_bootstrap_input_selection_is_complete_and_independently_consistent(self):
        from Scripts.reconstruction_gate_f.command_catalog import campaign_profile_for_inputs, CampaignProfile
        profile = self.bootstrap_profile()
        new = dict(self.bootstrap_plan().command_inputs)
        self.assertIs(campaign_profile_for_inputs(new), profile)
        self.assertIs(campaign_profile_for_inputs(command_inputs()), CampaignProfile.EXISTING)
        for name in ("bootstrap_artifact_root", "bootstrap_admission_path",
                     "bootstrap_fullsuite_artifact_root", "bootstrap_products_artifact_root"):
            partial = dict(new)
            partial.pop(name)
            with self.assertRaisesRegex(ValueError, "complete four-path set"):
                campaign_profile_for_inputs(partial)
            with self.assertRaises(CommandCompilationError):
                compile_command_plan(self.candidate, self.scenarios, repository_root=self.bootstrap_root,
                                     inputs=partial, profile=profile)
        for runtime in ("bootstrap_fullsuite_predecessor_observations_sha256",
                        "bootstrap_products_predecessor_observations_sha256"):
            with self.assertRaisesRegex(CommandCompilationError, "runtime predecessor"):
                compile_command_plan(self.candidate, self.scenarios, repository_root=self.bootstrap_root,
                                     inputs=dict(new, **{runtime: "a" * 64}), profile=profile)

    def test_default_campaign_is_byte_identical(self):
        from Scripts.reconstruction_gate_f import command_catalog
        from Scripts.reconstruction_gate_f.tests.bootstrap_profile_fixture import existing_snapshot, frozen_snapshot
        self.assertEqual(existing_snapshot(), frozen_snapshot())
        profile = getattr(command_catalog, "CampaignProfile", None)
        self.assertIsNotNone(profile, "the explicit existing profile is missing")
        self.assertEqual(existing_snapshot(profile=profile.EXISTING), frozen_snapshot())

    def test_verifier_profile_substitutes_only_two_command_ids(self):
        new = self.bootstrap_plan()
        old_inputs = command_inputs(repository_root=self.bootstrap_root)
        old_inputs.update({key: value for key, value in new.command_inputs if key in old_inputs})
        old = compile_command_plan(self.candidate, self.scenarios, repository_root=self.bootstrap_root, inputs=old_inputs)
        substitutions = {"xcode.full-coretests": "qualification.verify-bootstrap-fullsuite",
                         "release.build": "qualification.verify-bootstrap-products"}
        records = {item.command_id: item for item in new.commands}
        self.assertEqual(set(records), {substitutions.get(item.command_id, item.command_id) for item in old.commands})
        for record in old.commands:
            replacement = records[substitutions.get(record.command_id, record.command_id)]
            installed = ("installed.task10-workflow", "installed.accessibility-semantics", "installed.source-equality", "installed.shell-smoke", "installed.emit-report") if record.command_id == "evidence.t10c-current-source-adjudication" else ()
            self.assertEqual(replacement.prerequisite_ids, tuple(sorted(substitutions.get(value, value) for value in record.prerequisite_ids + installed)))
            for field in ("scenario_ids", "command_groups", "evidence_layer", "receipt_fields"):
                self.assertEqual(getattr(replacement, field), getattr(record, field))
            if record.command_id not in substitutions and not record.command_id.startswith("native.") and record.command_id not in {
                "install.release-to-applications", "signing.strict-release", "installed.source-equality", "installed.shell-smoke", "installed.xcuitest-preflight", "installed.emit-report", "source.hosted-governance"}:
                self.assertEqual(dataclasses.replace(replacement, prerequisite_ids=record.prerequisite_ids), record)
        self.assertEqual(len(records["qualification.verify-bootstrap-fullsuite"].prerequisite_ids), 14)
        self.assertEqual(records["qualification.verify-bootstrap-products"].prerequisite_ids, (
            "native.golden", "qualification.verify-bootstrap-fullsuite",
            "signed-xpc.complete-truncated-content", "signed-xpc.error-cancellation",
            "signed-xpc.supervision", "task8.signed-worker-parity"))
        self.assertEqual(new.scenario_bindings, tuple(dataclasses.replace(binding,
            command_ids=tuple(sorted(substitutions.get(value, value) for value in binding.command_ids)))
            for binding in old.scenario_bindings))
        self.assertEqual(new.schema_version, 3)
        self.assertEqual(sum(len(record.runtime_argument_slots) for record in new.commands), 11)

    def test_native_bootstrap_vectors_require_owned_reports_and_capture(self):
        templates = {item.command_id: item for item in command_templates(profile=self.bootstrap_profile())}
        self.assertEqual(templates["native.normal"].generated_artifacts,
                         ("stdout-path:MACSCOPE_NATIVE_QUALIFICATION_REPORT",))
        plan = self.bootstrap_plan()
        records = {item.command_id: item for item in plan.commands}
        values = dict(plan.command_inputs)
        old_inputs = command_inputs(repository_root=self.bootstrap_root)
        old_inputs.update({key: value for key, value in values.items() if key in old_inputs})
        old = {item.command_id: item for item in compile_command_plan(self.candidate, self.scenarios,
            repository_root=self.bootstrap_root, inputs=old_inputs).commands}
        for suffix in ("normal", "asan", "ubsan"):
            record = records["native." + suffix]
            self.assertEqual(record.argv, old[record.command_id].argv + (
                "--qualification-report-dir", values["native_" + suffix + "_report_dir"]))
            self.assertEqual(record.generated_artifacts,
                             ("stdout-path:MACSCOPE_NATIVE_QUALIFICATION_REPORT",))
        golden = records["native.golden"]
        self.assertEqual(golden.argv, ("/usr/bin/python3", "-B",
            "./Scripts/native-decompiler-xpc/run_gatef_native_golden.py",
            "--source-materialization-root", values["sleigh_materialization_root"],
            "--native-archive-root", values["native_build_root"],
            "--work-root", values["native_golden_work_root"],
            "--developer-dir", values["developer_dir"], "--sdk-root", values["sdk_root"],
            "--sdk-name", values["sdk_name"]))
        self.assertEqual(golden.generated_artifacts, (
            "stdout-path:MACSCOPE_NATIVE_GOLDEN_MATERIALIZATION",
            "stdout-path:MACSCOPE_NATIVE_GOLDEN_RESULT",
            "stdout-path:MACSCOPE_NATIVE_GOLDEN_STAGE_STAMP"))
        for suffix in ("normal", "asan", "ubsan", "golden"):
            record = records["native." + suffix]
            original = old[record.command_id]
            self.assertEqual(record.generated_logs,
                             ("executor-captured:native-" + suffix + "-stdout-stderr",))
            self.assertEqual(record.execution_mode, CommandExecutionMode.RUNNABLE)
            self.assertEqual(dict(record.environment),
                             dict(original.environment, DEVELOPER_DIR=values["developer_dir"]))
            for field in ("timeout_seconds", "expected_exits", "command_groups", "evidence_layer",
                          "prerequisite_ids", "receipt_fields", "mutation_state"):
                self.assertEqual(getattr(record, field), getattr(original, field))

    def test_native_bootstrap_inputs_have_exact_fixed_layout_and_closed_admission(self):
        self.assertTrue({"native_normal_report_dir", "native_asan_report_dir", "native_ubsan_report_dir",
                         "native_golden_work_root"} <= set(required_command_input_names(profile=self.bootstrap_profile())))
        plan = self.bootstrap_plan()
        values = dict(plan.command_inputs)
        root = Path(values["output_root"])
        expected = {
            "native_build_root": root / "native-work/normal",
            "native_sanitizer_build_root": root / "native-work/sanitizers",
            "native_normal_report_dir": root / "native-work/normal/qualification",
            "native_asan_report_dir": root / "native-work/sanitizers/address/qualification",
            "native_ubsan_report_dir": root / "native-work/sanitizers/undefined/qualification",
            "native_golden_work_root": root / "native-work/golden",
            "native_source_root": self.bootstrap_root / "Tools/NativeDecompilerBridge",
        }
        for name, path in expected.items():
            self.assertEqual(values[name], str(path))
            for bad in (str(root / "foreign"), str(path.parent / "elsewhere" / ".." / path.name)):
                with self.subTest(name=name, bad=bad):
                    changed = dict(values, **{name: bad})
                    with self.assertRaisesRegex(CommandCompilationError, name):
                        compile_command_plan(self.candidate, self.scenarios, repository_root=self.bootstrap_root,
                            inputs=changed, profile=self.bootstrap_profile())
                    mutated = dataclasses.replace(plan, command_inputs=tuple(sorted(changed.items())))
                    self.assertIn("command-input-binding", {issue.code for issue in validate_command_plan(
                        mutated, candidate=self.candidate, scenario_catalog=self.scenarios,
                        repository_root=self.bootstrap_root, profile=self.bootstrap_profile(),
                        templates={item.command_id: item for item in command_templates(profile=self.bootstrap_profile())})})
        self.assertNotEqual(values["source_export_root"], values["repository_root"])
        for obsolete in ("native_stage_stamp", "native_golden_result", "native_golden_build_root",
                         "target_build_dir", "project_temp_dir"):
            self.assertNotIn(obsolete, values)
            with self.assertRaisesRegex(CommandCompilationError, "unknown command inputs"):
                compile_command_plan(self.candidate, self.scenarios, repository_root=self.bootstrap_root,
                    inputs=dict(values, **{obsolete: str(root / "obsolete")}), profile=self.bootstrap_profile())

    def test_verifier_vectors_and_outputs_are_frozen(self):
        templates = {item.command_id: item for item in command_templates(profile=self.bootstrap_profile())}
        for kind, prefix in (("fullsuite", "FULLSUITE"), ("products", "PRODUCTS")):
            template = templates["qualification.verify-bootstrap-" + kind]
            self.assertEqual(template.argv, ("/usr/bin/python3", "-B", "-m",
                "Scripts.reconstruction_gate_f.bootstrap_verifier", kind,
                "--candidate-identity", "@candidate_identity_path@",
                "--repository-root", "@repository_root@", "--integration-ref", "@integration_ref@",
                "--bootstrap-root", "@bootstrap_artifact_root@",
                "--bootstrap-admission", "@bootstrap_admission_path@",
                "--artifact-root", "@bootstrap_" + kind + "_artifact_root@",
                "--qualification-run-id", "@qualification_run_id@",
                "--qualification-run-nonce", "@qualification_run_nonce@",
                "--predecessor-observations-sha256", "@bootstrap_" + kind + "_predecessor_observations_sha256@"))
            projection = "XCRESULT" if kind == "fullsuite" else "APP"
            self.assertEqual(template.generated_artifacts, tuple(sorted((
                "stdout-path:MACSCOPE_BOOTSTRAP_" + prefix + "_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_BOOTSTRAP_" + prefix + "_SEMANTIC_REPORT",
                "stdout-path:MACSCOPE_BOOTSTRAP_" + prefix + "_" + projection + "_PROJECTION"))))
            self.assertEqual(template.generated_logs, ("executor-captured:bootstrap-" + kind + "-verifier-stdout-stderr",))
            self.assertEqual(template.timeout_seconds, 900)
            self.assertEqual(template.execution_mode, CommandExecutionMode.RUNNABLE)
            self.assertEqual(template.mutation_state, CommandMutationState.READ_ONLY)
            self.assertEqual({item.code for item in template.expected_exits}, {0, 1, 2})

    def test_profile_downgrade_rejected(self):
        plan = self.bootstrap_plan()
        self.assertTrue(validate_command_plan(plan, candidate=self.candidate, scenario_catalog=self.scenarios,
            repository_root=self.bootstrap_root, templates={item.command_id: item for item in command_templates()}))
        with self.assertRaises(CommandCompilationError):
            compile_command_plan(self.candidate, self.scenarios, repository_root=self.bootstrap_root,
                inputs=dict(plan.command_inputs), templates=command_templates(profile=self.bootstrap_profile()))
        with self.assertRaises(ValueError):
            command_templates(profile="bootstrap-verifier-campaign-v1")

    def test_resolved_output_order_is_canonical_for_receipt_parser(self) -> None:
        from Scripts.reconstruction_gate_f import executor_receipt
        inputs = command_inputs()
        inputs.update(installed_matrix_receipt="/private/tmp/z-receipt.json",
                      installed_matrix_xcresult_semantic_manifest="/private/tmp/a-semantic.json",
                      installed_network_audit_artifact_root="/private/tmp/m-network")
        real_plan = compile_command_plan(self.candidate, self.scenarios, repository_root=ROOT, inputs=inputs)
        real_record = next(item for item in real_plan.commands if item.command_id == "installed.task10-workflow")
        self.assertEqual(real_record.generated_artifacts[0], inputs["installed_matrix_xcresult_semantic_manifest"])
        self.assertEqual(real_record.generated_artifacts, tuple(sorted(real_record.generated_artifacts)))
        templates = tuple(dataclasses.replace(template, generated_logs=(
            "@installed_matrix_receipt@", "@installed_matrix_xcresult_semantic_manifest@"
        )) if template.command_id == "installed.task10-workflow" else template
            for template in command_templates())
        # The live catalog currently has no multi-log command. Freeze this
        # synthetic catalog in both compiler and validator for that projection.
        with mock.patch("Scripts.reconstruction_gate_f.command_compiler.command_templates", return_value=templates):
            plan = compile_command_plan(self.candidate, self.scenarios, repository_root=ROOT,
                                        inputs=inputs, templates=templates)
            reversed_plan = compile_command_plan(self.candidate, self.scenarios, repository_root=ROOT,
                inputs=inputs, templates=tuple(reversed(templates)))
        record = next(item for item in plan.commands if item.command_id == "installed.task10-workflow")
        self.assertEqual(record.generated_artifacts, tuple(sorted(record.generated_artifacts)))
        self.assertEqual(record.generated_artifacts[0], inputs["installed_matrix_xcresult_semantic_manifest"])
        self.assertEqual(record.generated_logs, (inputs["installed_matrix_xcresult_semantic_manifest"],
                                                inputs["installed_matrix_receipt"]))
        template = next(item for item in templates if item.command_id == record.command_id)
        self.assertEqual(record.argv[template.argv.index("@installed_matrix_receipt@")],
                         inputs["installed_matrix_receipt"])
        authority = dict(host=record.host.value, execution_mode=record.execution_mode.value,
            argv_sha256="a" * 64, environment_sha256="b" * 64, working_directory_sha256="c" * 64,
            generated_artifacts=list(record.generated_artifacts), generated_logs=list(record.generated_logs),
            prerequisite_receipts=[])
        run = executor_receipt.QualificationRunAuthority("test-run", "d" * 64)
        parsed = executor_receipt._parse_command_authority(authority, expected_qualification_run=run)
        self.assertEqual(parsed.generated_artifacts, record.generated_artifacts)
        self.assertEqual(plan, reversed_plan)
        for field in ("generated_artifacts", "generated_logs"):
            changed = dict(authority, **{field: list(reversed(authority[field]))})
            with self.subTest(field=field), self.assertRaises(executor_receipt.ReceiptEmissionError):
                executor_receipt._parse_command_authority(changed, expected_qualification_run=run)

    def test_resolved_output_collisions_are_rejected_not_deduplicated(self) -> None:
        inputs = command_inputs()
        inputs["installed_matrix_receipt"] = inputs["installed_matrix_xcresult_semantic_manifest"] = "/private/tmp/collision"
        with self.assertRaisesRegex(CommandCompilationError, "generated_artifacts"):
            compile_command_plan(self.candidate, self.scenarios, repository_root=ROOT, inputs=inputs)
        # Isolate the log collision using distinct output templates; the resolver
        # must reject the two retained equal values rather than hide one with set().
        templates = tuple(dataclasses.replace(template,
            generated_artifacts=("@installed_matrix_receipt@",), generated_logs=(
                "@installed_matrix_receipt@", "@installed_matrix_xcresult_semantic_manifest@"))
            if template.command_id == "installed.task10-workflow" else template
            for template in command_templates())
        with mock.patch("Scripts.reconstruction_gate_f.command_compiler.command_templates", return_value=templates):
            with self.assertRaisesRegex(CommandCompilationError, "generated_logs"):
                compile_command_plan(self.candidate, self.scenarios, repository_root=ROOT,
                                     inputs=inputs, templates=templates)

    def setUp(self) -> None:
        self.candidate = parsed_candidate()
        self.scenarios = compile_scenario_catalog(self.candidate)

    def compile(self, *, templates=None):
        inputs = command_inputs()
        if templates is not None:
            required = set(required_command_input_names(templates))
            inputs = {name: value for name, value in inputs.items() if name in required}
        return compile_command_plan(
            self.candidate,
            self.scenarios,
            repository_root=ROOT,
            inputs=inputs,
            templates=templates,
        )

    def test_plan_is_complete_identity_bound_and_every_scenario_has_commands(self) -> None:
        plan = self.compile()
        template_map = {item.command_id: item for item in command_templates()}
        self.assertEqual(
            validate_command_plan(
                plan,
                candidate=self.candidate,
                scenario_catalog=self.scenarios,
                repository_root=ROOT,
                templates=template_map,
            ),
            (),
        )
        self.assertEqual(plan.candidate_identity_sha256, candidate_identity_sha256(self.candidate))
        self.assertEqual(len(plan.scenario_bindings), len(self.scenarios.scenarios))
        self.assertTrue(all(item.command_ids for item in plan.scenario_bindings))

    def test_every_command_declares_the_universal_plan_and_record_receipt_binding(self) -> None:
        plan = self.compile()
        self.assertEqual(
            {record.receipt_fields for record in plan.commands},
            {REQUIRED_RECEIPT_BINDING_FIELDS},
        )
        templates = list(command_templates())
        templates[0] = dataclasses.replace(
            templates[0],
            receipt_fields=tuple(
                field
                for field in templates[0].receipt_fields
                if field != "command_record_sha256"
            ),
        )
        with self.assertRaisesRegex(CommandCompilationError, "command-template-drift"):
            self.compile(templates=templates)

    def test_exact_live_entrypoints_and_no_stale_roadmap_script(self) -> None:
        plan = self.compile()
        argv_by_id = {item.command_id: item.argv for item in plan.commands}
        values = command_inputs()
        self.assertEqual(
            argv_by_id["source.create-sealed-export"],
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/source_export_provenance.py",
                "create",
                "--repository-root",
                str(ROOT),
                "--destination",
                values["source_export_root"],
                "--integration-ref",
                values["integration_ref"],
            ),
        )
        self.assertEqual(
            argv_by_id["source.hosted-governance"],
            (
                "/usr/bin/python3",
                "-B",
                values["hosted_governance_runner"],
                "--candidate-identity",
                values["candidate_identity_path"],
                "--source-root",
                values["source_export_root"],
                "--test-results-output",
                values["hosted_governance_test_results"],
                "--execution-report-output",
                values["hosted_governance_execution_report"],
                "--qualification-run-id",
                values["qualification_run_id"],
                "--qualification-run-nonce",
                values["qualification_run_nonce"],
                "--predecessor-observations-sha256",
                RUNTIME_ARGUMENT_MARKER,
            ),
        )
        self.assertEqual(
            argv_by_id["source.verify-sealed-export"],
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/source_export_provenance.py",
                "verify",
                "--source-root",
                values["source_export_root"],
            ),
        )
        focused = argv_by_id["xcode.focused.provider-cancellation-race"]
        self.assertEqual(focused[0], "./Scripts/qualify_local_private_build.sh")
        self.assertEqual(
            focused[focused.index("--only-testing") + 1],
            "CoreTests/ReconstructionProviderPoolCancellationRaceTests",
        )
        flattened = [token for item in plan.commands for token in item.argv]
        self.assertFalse(any("sync_roadmap_status.py" in token for token in flattened))
        self.assertIn("./Scripts/native-decompiler-xpc/run_native_bridge_sanitizers.sh", flattened)
        self.assertIn("./Scripts/native-decompiler-xpc/run_native_bridge_golden.sh", flattened)
        self.assertIn("Scripts/check_local_signing_policy.py", flattened)

    def test_source_predecessor_vectors_dispatch_to_real_parser(self) -> None:
        import io
        from Scripts import source_export_provenance

        records = {item.command_id: item for item in self.compile().commands}
        inputs = command_inputs()
        for command_id, function, arguments in (
            ("source.create-sealed-export", "create_export", (
                ROOT, Path(inputs["source_export_root"]), inputs["integration_ref"])),
            ("source.verify-sealed-export", "verify_export", (
                Path(inputs["source_export_root"]),)),
        ):
            with self.subTest(command=command_id):
                record = records[command_id]
                self.assertEqual(record.execution_mode, CommandExecutionMode.RUNNABLE)
                self.assertEqual(record.argv[:3], (
                    "/usr/bin/python3", "-B", "Scripts/source_export_provenance.py"))
                stdout = mock.Mock(buffer=io.BytesIO())
                with mock.patch.object(source_export_provenance, function, return_value={}) as operation, \
                     mock.patch.object(source_export_provenance.sys, "stdout", stdout):
                    self.assertEqual(source_export_provenance.main(record.argv[3:]), 0)
                operation.assert_called_once_with(*arguments)
                self.assertEqual(record.generated_artifacts, tuple(sorted((
                    inputs["source_export_root"] + "/SOURCE_FILES.json",
                    inputs["source_export_root"] + "/SOURCE_PROVENANCE.json",
                ))))

    def test_ordinary_qualifiers_are_explicitly_runnable_without_network_authority(self) -> None:
        records = {item.command_id: item for item in self.compile().commands}
        qualifiers = [record for record in records.values()
                      if record.argv and record.argv[0] == "./Scripts/qualify_local_private_build.sh"]
        self.assertEqual(len(qualifiers), 17)
        inputs = command_inputs()
        for record in qualifiers:
            with self.subTest(command=record.command_id):
                self.assertEqual(record.execution_mode, CommandExecutionMode.RUNNABLE)
                self.assertEqual(record.host, CommandHost.MACOS_ARM64_XCODE27)
                self.assertEqual(record.mutation_state, CommandMutationState.BUILD_OUTPUT)
                self.assertNotIn("--materialize-dependencies", record.argv)
                flags = dict(zip(record.argv[1::2], record.argv[2::2]))
                self.assertEqual(flags["--source-root"], str(ROOT))
                self.assertEqual(flags["--work-root"], inputs["qualification_work_root"])
                self.assertEqual(flags["--dependency-cache-root"], inputs["dependency_cache_root"])
                self.assertEqual(flags["--integration-ref"], inputs["integration_ref"])
                self.assertEqual(flags["--signing"], "development")
                expected_mode = ("focused-test" if record.command_id.startswith("xcode.focused.")
                                 else {"xcode.smoke": "smoke", "xcode.full-coretests": "full-test",
                                       "release.build": "release"}[record.command_id])
                self.assertEqual(flags["--mode"], expected_mode)
                self.assertEqual("--only-testing" in flags, expected_mode == "focused-test")
                if expected_mode == "focused-test":
                    self.assertTrue(flags["--only-testing"].startswith("CoreTests/"))
                self.assertIn("stdout-path:MACSCOPE_QUALIFICATION_RECEIPT", record.generated_artifacts)
                self.assertEqual("stdout-path:MACSCOPE_TEST_RESULTS" in record.generated_artifacts,
                                 expected_mode in {"focused-test", "full-test"})

    def test_unreviewed_vectors_do_not_inherit_runnable_mode(self) -> None:
        from Scripts.reconstruction_gate_f.command_catalog import _template
        from Scripts.reconstruction_gate_f.schema import EvidenceLayer
        self.assertEqual(_template("test.future", (), ("/usr/bin/true",),
            layer=EvidenceLayer.SOURCE_GOVERNANCE).execution_mode, CommandExecutionMode.VECTOR_ONLY)
        records = {item.command_id: item for item in self.compile().commands}
        for command_id in ("native.normal", "native.asan", "native.ubsan", "native.golden",
                           "signing.strict-release", "installed.source-equality", "installed.shell-smoke"):
            with self.subTest(command=command_id):
                self.assertEqual(records[command_id].execution_mode, CommandExecutionMode.VECTOR_ONLY)

    def test_external_review_and_merge_operations_remain_executor_required(self) -> None:
        plan = self.compile()
        records = {item.command_id: item for item in plan.commands}
        expected = {
            "evidence.t10c-current-source-adjudication",
            "review.independent",
            *INDEPENDENT_REVIEW_COMMAND_LENSES,
            "merge.prospective-tree",
            "postmerge.exact-tree-proof",
        }
        for command_id in expected:
            with self.subTest(command=command_id):
                record = records[command_id]
                self.assertEqual(record.execution_mode, CommandExecutionMode.EXECUTOR_REQUIRED)
                self.assertEqual(record.argv, ())
                self.assertTrue(record.unavailability_reason)
        t10c = records["evidence.t10c-current-source-adjudication"]
        self.assertEqual(t10c.host, CommandHost.INDEPENDENT_REVIEWER)
        self.assertEqual(
            t10c.generated_artifacts,
            (
                "executor-output:t10c/FINDING_ADJUDICATION.json",
                "executor-output:t10c/SOURCE_DRIFT.json",
                "executor-output:t10c/bundle.sha256",
                "executor-output:t10c/current-source-independent-review.json",
                "executor-output:t10c/current-source-review-execution-report.json",
            ),
        )
        self.assertEqual(t10c.generated_logs, ())
        independent_review = records["review.independent"]
        self.assertEqual(
            independent_review.generated_artifacts,
            (
                "executor-output:review/ai-protocol-signed-xpc-review-receipt.json",
                "executor-output:review/corpus-package-persistence-review-receipt.json",
                "executor-output:review/evidence-retrieval-scheduling-review-receipt.json",
                "executor-output:review/independent-review-execution-report.json",
                "executor-output:review/scope-installed-ui-governance-review-receipt.json",
            ),
        )
        self.assertEqual(independent_review.generated_logs, ())
        for command_id, lens_id in INDEPENDENT_REVIEW_COMMAND_LENSES.items():
            self.assertEqual(
                records[command_id].generated_artifacts,
                (
                    f"executor-output:review/{lens_id}-review-execution-report.json",
                    f"executor-output:review/{lens_id}-review-report.json",
                ),
            )

    def test_signed_and_stress_executor_gaps_are_now_exact_runnable_commands(self) -> None:
        records = {item.command_id: item for item in self.compile().commands}
        hosted = records["source.hosted-governance"]
        self.assertEqual(hosted.execution_mode, CommandExecutionMode.RUNNABLE)
        self.assertEqual(hosted.mutation_state, CommandMutationState.READ_ONLY)
        self.assertEqual(
            hosted.generated_artifacts,
            (
                "stdout-path:MACSCOPE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_TEST_RESULTS",
            ),
        )
        installer = records["install.release-to-applications"]
        self.assertEqual(installer.execution_mode, CommandExecutionMode.RUNNABLE)
        self.assertEqual(installer.mutation_state, CommandMutationState.INSTALL_STATE)
        self.assertEqual(
            installer.argv,
            (
                "/usr/bin/python3", "-B",
                "Scripts/reconstruction/install_release_to_applications.py",
                "--candidate-identity", command_inputs()["candidate_identity_path"],
                "--source-app", command_inputs()["source_release_app"],
                "--installed-app", "/Applications/MacScope.app",
                "--artifact-root", command_inputs()["install_release_artifact_root"],
                "--qualification-run-id", command_inputs()["qualification_run_id"],
                "--qualification-run-nonce", command_inputs()["qualification_run_nonce"],
                "--predecessor-observations-sha256",
                RUNTIME_ARGUMENT_MARKER,
            ),
        )
        self.assertEqual(
            installer.generated_artifacts,
            (
                "stdout-path:MACSCOPE_INSTALL_RELEASE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_INSTALL_RELEASE_OPERATION_REPORT",
                "stdout-path:MACSCOPE_INSTALL_RELEASE_SOURCE_EQUALITY_REPORT",
            ),
        )
        accessibility = records["installed.accessibility-semantics"]
        self.assertEqual(accessibility.execution_mode, CommandExecutionMode.RUNNABLE)
        self.assertEqual(accessibility.mutation_state, CommandMutationState.READ_ONLY)
        self.assertEqual(
            accessibility.prerequisite_ids,
            ("installed.task10-workflow",),
        )
        self.assertEqual(
            accessibility.argv,
            (
                "/usr/bin/python3", "-B",
                "Scripts/reconstruction/emit_installed_accessibility_report.py",
                "--candidate-identity", command_inputs()["candidate_identity_path"],
                "--matrix-receipt", command_inputs()["installed_matrix_receipt"],
                "--xcresult-semantic-manifest",
                command_inputs()["installed_matrix_xcresult_semantic_manifest"],
                "--artifact-root", command_inputs()["installed_accessibility_artifact_root"],
                "--qualification-run-id", command_inputs()["qualification_run_id"],
                "--qualification-run-nonce", command_inputs()["qualification_run_nonce"],
                "--predecessor-observations-sha256",
                RUNTIME_ARGUMENT_MARKER,
            ),
        )
        self.assertEqual(
            accessibility.generated_artifacts,
            tuple(sorted((
                "stdout-path:MACSCOPE_INSTALLED_ACCESSIBILITY_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_INSTALLED_ACCESSIBILITY_PRESENTATION_MANIFEST",
                "stdout-path:MACSCOPE_INSTALLED_ACCESSIBILITY_REPORT",
                *tuple(
                    "stdout-path:MACSCOPE_INSTALLED_ACCESSIBILITY_SCREENSHOT_"
                    + "_".join(
                        part.upper().replace("-", "_")
                        for part in (presentation_state, appearance, window_size)
                    )
                    for presentation_state, appearance, window_size, _width, _height
                    in PRESENTATION_VARIANTS
                ),
            ))),
        )
        installed_source_equality = records["installed.source-equality"]
        self.assertEqual(
            installed_source_equality.generated_artifacts,
            ("stdout-json:source-equality-report",),
        )
        deterministic = records["reconstruction.deterministic-evidence"]
        self.assertEqual(deterministic.execution_mode, CommandExecutionMode.RUNNABLE)
        self.assertEqual(
            deterministic.command_groups,
            ("reconstruction-persistence", "reconstruction-rounds"),
        )
        self.assertEqual(
            deterministic.argv,
            (
                "./Scripts/reconstruction/run_deterministic_evidence_tests.sh",
                "--candidate-identity",
                command_inputs()["candidate_identity_path"],
                "--preparation-receipt",
                command_inputs()["native_live_preparation_receipt"],
                "--xctestrun",
                command_inputs()["native_live_xctestrun"],
                "--candidate-app",
                command_inputs()["native_live_app"],
                "--result-bundle-root",
                command_inputs()["deterministic_evidence_result_bundle_root"],
                "--artifact-root",
                command_inputs()["deterministic_evidence_artifact_root"],
                "--qualification-run-id",
                command_inputs()["qualification_run_id"],
                "--qualification-run-nonce",
                command_inputs()["qualification_run_nonce"],
                "--predecessor-observations-sha256",
                RUNTIME_ARGUMENT_MARKER,
            ),
        )
        self.assertEqual(
            set(deterministic.generated_artifacts),
            {
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_CHECKPOINT",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_CHECKPOINT_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_COMPARISON",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_CORPUS",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_CORPUS_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_FRONTIER",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_FRONTIER_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_RECEIPT",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_RECEIPT_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_RETRIEVAL_PACKET",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_RETRIEVAL_PACKET_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_ONE",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_TWO",
            },
        )
        signed_worker = records["task8.signed-worker-parity"]
        self.assertEqual(signed_worker.execution_mode, CommandExecutionMode.RUNNABLE)
        self.assertEqual(
            signed_worker.argv,
            (
                "./Scripts/reconstruction/run_signed_reconstruction_worker_tests.sh",
                "--candidate-identity",
                command_inputs()["candidate_identity_path"],
                "--preparation-receipt",
                command_inputs()["native_live_preparation_receipt"],
                "--xctestrun",
                command_inputs()["native_live_xctestrun"],
                "--candidate-app",
                command_inputs()["native_live_app"],
                "--result-bundle-path",
                command_inputs()["signed_reconstruction_result_bundle"],
                "--artifact-root",
                command_inputs()["signed_reconstruction_artifact_root"],
                "--qualification-run-id",
                command_inputs()["qualification_run_id"],
                "--qualification-run-nonce",
                command_inputs()["qualification_run_nonce"],
                "--predecessor-observations-sha256",
                RUNTIME_ARGUMENT_MARKER,
            ),
        )
        installed_matrix = records["installed.task10-workflow"]
        self.assertEqual(installed_matrix.execution_mode, CommandExecutionMode.RUNNABLE)
        self.assertEqual(
            installed_matrix.argv,
            (
                "/usr/bin/python3", "-B", "Scripts/reconstruction/run_installed_task10_matrix.py",
                "--candidate-identity", command_inputs()["candidate_identity_path"],
                "--preparation-receipt", command_inputs()["installed_ui_preparation_receipt"],
                "--installed-app", command_inputs()["installed_app"],
                "--xctestrun", command_inputs()["installed_ui_xctestrun"],
                "--test-bundle", command_inputs()["installed_ui_test_bundle"],
                "--ui-runner", command_inputs()["installed_ui_runner_app"],
                "--xcresult", command_inputs()["installed_matrix_xcresult"],
                "--xcresult-semantic-manifest",
                command_inputs()["installed_matrix_xcresult_semantic_manifest"],
                "--receipt-output", command_inputs()["installed_matrix_receipt"],
                "--network-artifact-root", command_inputs()["installed_network_audit_artifact_root"],
                "--qualification-run-id", command_inputs()["qualification_run_id"],
                "--qualification-run-nonce", command_inputs()["qualification_run_nonce"],
                "--predecessor-observations-sha256",
                RUNTIME_ARGUMENT_MARKER,
                "--developer-dir", command_inputs()["developer_dir"],
            ),
        )
        self.assertNotIn(
            "installed.network-acquisition-audit",
            set(records),
        )
        self.assertEqual(
            set(installed_matrix.command_groups),
            {"installed-network-audit", "installed-task10"},
        )
        report = records["installed.emit-report"]
        self.assertEqual(
            report.argv[report.argv.index("--candidate-identity") + 1],
            command_inputs()["candidate_identity_path"],
        )
        native_command_ids = (
            "signed-xpc.supervision",
            "signed-xpc.complete-truncated-content",
            "signed-xpc.error-cancellation",
        )
        predecessor_input_by_command = {
            "source.hosted-governance": "hosted_governance_predecessor_observations_sha256",
            "reconstruction.deterministic-evidence": "deterministic_evidence_predecessor_observations_sha256",
            "task8.signed-worker-parity": "signed_reconstruction_predecessor_observations_sha256",
            "signed-xpc.supervision": "signed_xpc_supervision_predecessor_observations_sha256",
            "signed-xpc.complete-truncated-content": "signed_xpc_content_predecessor_observations_sha256",
            "signed-xpc.error-cancellation": "signed_xpc_error_cancellation_predecessor_observations_sha256",
            "install.release-to-applications": "install_release_predecessor_observations_sha256",
            "installed.task10-workflow": "installed_task10_predecessor_observations_sha256",
            "installed.accessibility-semantics": "installed_accessibility_predecessor_observations_sha256",
        }
        self.assertEqual(
            {
                command_id
                for command_id, record in records.items()
                if "--qualification-run-id" in record.argv
            },
            {*predecessor_input_by_command, "stress.reconstruction-authority-races"},
        )
        for command_id, predecessor_input in predecessor_input_by_command.items():
            with self.subTest(run_authority=command_id):
                argv = records[command_id].argv
                self.assertEqual(
                    argv[argv.index("--qualification-run-id") + 1],
                    command_inputs()["qualification_run_id"],
                )
                self.assertEqual(
                    argv[argv.index("--qualification-run-nonce") + 1],
                    command_inputs()["qualification_run_nonce"],
                )
                self.assertEqual(
                    argv[argv.index("--predecessor-observations-sha256") + 1],
                    RUNTIME_ARGUMENT_MARKER,
                )
        for command_id in native_command_ids:
            with self.subTest(command=command_id):
                record = records[command_id]
                self.assertEqual(record.execution_mode, CommandExecutionMode.RUNNABLE)
                self.assertEqual(
                    record.argv[0],
                    "./Scripts/native-decompiler-xpc/run_live_xpc_tests.sh",
                )
                self.assertIn("--execute-prepared", record.argv)
                self.assertIn(command_inputs()["native_live_preparation_receipt"], record.argv)
                self.assertIn(command_inputs()["native_live_xctestrun"], record.argv)
                self.assertIn(command_inputs()["native_live_app"], record.argv)
                self.assertNotIn("--materialization-root", record.argv)
                self.assertNotIn("--ghostty-source-dir", record.argv)
                self.assertEqual(
                    set(record.generated_artifacts),
                    {
                        "stdout-path:MACSCOPE_SIGNED_NATIVE_EXECUTABLE",
                        "stdout-path:MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT",
                        "stdout-path:MACSCOPE_SIGNED_NATIVE_TEST_RESULTS",
                    },
                )
        self.assertIn(
            "CoreTests/NativeDecompilerLiveXPCTests/"
            "testSignedServiceReturnsMalformedFailureAndHonorsCooperativeCancellation",
            records["signed-xpc.error-cancellation"].argv,
        )
        stress = records["stress.reconstruction-authority-races"]
        self.assertEqual(stress.execution_mode, CommandExecutionMode.RUNNABLE)
        self.assertEqual(
            stress.argv,
            (
                "./Scripts/reconstruction/run_authority_stress_tests.sh",
                "--candidate-identity",
                command_inputs()["candidate_identity_path"],
                "--preparation-receipt",
                command_inputs()["native_live_preparation_receipt"],
                "--xctestrun",
                command_inputs()["native_live_xctestrun"],
                "--candidate-app",
                command_inputs()["native_live_app"],
                "--result-bundle-path",
                command_inputs()["authority_stress_result_bundle"],
                "--artifact-root",
                command_inputs()["authority_stress_artifact_root"],
                "--qualification-run-id",
                command_inputs()["qualification_run_id"],
                "--qualification-run-nonce",
                command_inputs()["qualification_run_nonce"],
                "--predecessor-observations",
                command_inputs()["authority_stress_predecessor_observations"],
            ),
        )
        self.assertEqual(
            set(stress.generated_artifacts),
            {
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_ATTEMPT_LEDGER",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_PLAN",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_PREPARATION_RECEIPT",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_PREPARED_XCTESTRUN",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_REPORT",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_TEST_RESULTS",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_XCTESTRUN",
            },
        )

    def test_template_iteration_order_cannot_change_plan(self) -> None:
        first = self.compile()
        second = self.compile(templates=tuple(reversed(command_templates())))
        self.assertEqual(first, second)
        self.assertEqual(command_plan_sha256(first), command_plan_sha256(second))

    def test_invented_repository_command_is_rejected(self) -> None:
        templates = list(command_templates())
        index = next(i for i, item in enumerate(templates) if item.command_id == "source.hosted-governance")
        templates[index] = dataclasses.replace(
            templates[index],
            argv=("/usr/bin/python3", "-B", "Scripts/invented_gate_f_runner.py"),
        )
        with self.assertRaisesRegex(CommandCompilationError, "invented-entrypoint"):
            self.compile(templates=templates)

    def test_existing_entrypoint_cannot_substitute_for_a_frozen_command(self) -> None:
        templates = list(command_templates())
        index = next(i for i, item in enumerate(templates) if item.command_id == "source.hosted-governance")
        templates[index] = dataclasses.replace(
            templates[index],
            argv=(
                "/usr/bin/python3",
                "-B",
                "Scripts/source_export_provenance.py",
                "--help",
            ),
        )
        with self.assertRaisesRegex(CommandCompilationError, "command-template-drift"):
            self.compile(templates=templates)

    def test_plan_binds_the_exact_scenario_catalog_digest(self) -> None:
        plan = dataclasses.replace(self.compile(), scenario_catalog_sha256="0" * 64)
        issues = validate_command_plan(
            plan,
            candidate=self.candidate,
            scenario_catalog=self.scenarios,
            repository_root=ROOT,
            templates={item.command_id: item for item in command_templates()},
        )
        self.assertIn("scenario-catalog-mismatch", {item.code for item in issues})

    def test_candidate_derived_argv_token_cannot_drift_from_the_bound_identity(self) -> None:
        plan = self.compile()
        records = list(plan.commands)
        index = next(i for i, item in enumerate(records) if item.command_id == "installed.emit-report")
        argv = list(records[index].argv)
        commit_index = argv.index("--expected-source-commit") + 1
        argv[commit_index] = "f" * 40
        records[index] = dataclasses.replace(records[index], argv=tuple(argv))
        changed = dataclasses.replace(plan, commands=tuple(records))
        issues = validate_command_plan(
            changed,
            candidate=self.candidate,
            scenario_catalog=self.scenarios,
            repository_root=ROOT,
            templates={item.command_id: item for item in command_templates()},
        )
        self.assertIn("command-template-drift", {item.code for item in issues})

    def test_validator_rejects_a_self_consistently_rebound_dirty_candidate(self) -> None:
        dirty_candidate = dataclasses.replace(
            self.candidate,
            source=dataclasses.replace(self.candidate.source, dirty=True),
        )
        digest = candidate_identity_sha256(dirty_candidate)
        scenarios = dataclasses.replace(
            self.scenarios,
            candidate_identity_sha256=digest,
        )
        clean_plan = self.compile()
        changed_plan = dataclasses.replace(
            clean_plan,
            candidate_identity_sha256=digest,
            scenario_catalog_sha256=scenario_catalog_sha256(scenarios),
            commands=tuple(
                dataclasses.replace(item, candidate_identity_sha256=digest)
                for item in clean_plan.commands
            ),
        )
        issues = validate_command_plan(
            changed_plan,
            candidate=dirty_candidate,
            scenario_catalog=scenarios,
            repository_root=ROOT,
            templates={item.command_id: item for item in command_templates()},
        )
        self.assertIn("candidate-dirty", {item.code for item in issues})

    def test_command_partial_order_and_family_exit_classes_are_explicit(self) -> None:
        records = {item.command_id: item for item in self.compile().commands}
        self.assertEqual(
            records["source.verify-sealed-export"].prerequisite_ids,
            ("source.create-sealed-export",),
        )
        self.assertIn(
            "xcode.focused.task10-projection",
            records["xcode.full-coretests"].prerequisite_ids,
        )
        self.assertEqual(
            records["signing.strict-release"].prerequisite_ids,
            ("release.build",),
        )
        self.assertEqual(
            records["install.release-to-applications"].prerequisite_ids,
            ("signing.strict-release",),
        )
        self.assertEqual(
            records["review.independent"].prerequisite_ids,
            tuple(INDEPENDENT_REVIEW_COMMAND_LENSES),
        )
        for command_id in INDEPENDENT_REVIEW_COMMAND_LENSES:
            self.assertIn("installed.emit-report", records[command_id].prerequisite_ids)
        self.assertEqual(
            records["postmerge.exact-tree-proof"].prerequisite_ids,
            ("merge.prospective-tree",),
        )
        self.assertIn(65, {item.code for item in records["xcode.full-coretests"].expected_exits})
        self.assertIn(65, {item.code for item in records["signed-xpc.supervision"].expected_exits})
        self.assertIn(8, {item.code for item in records["native.normal"].expected_exits})
        self.assertIn(8, {item.code for item in records["native.asan"].expected_exits})

    def test_candidate_identity_is_an_input_not_a_catalog_constant(self) -> None:
        value = candidate_mapping()
        value["source"]["commit"] = "e" * 40
        changed, issues = parse_candidate_identity(value)
        self.assertEqual(issues, ())
        changed_scenarios = compile_scenario_catalog(changed)
        changed_plan = compile_command_plan(
            changed,
            changed_scenarios,
            repository_root=ROOT,
            inputs=command_inputs(),
        )
        self.assertNotEqual(
            changed_plan.candidate_identity_sha256,
            self.compile().candidate_identity_sha256,
        )
        self.assertTrue(
            all(
                item.candidate_identity_sha256 == candidate_identity_sha256(changed)
                for item in changed_plan.commands
            )
        )

    def test_command_inputs_are_closed_and_candidate_fields_cannot_be_overridden(self) -> None:
        values = command_inputs()
        values["invented"] = "value"
        with self.assertRaisesRegex(CommandCompilationError, "unknown command inputs"):
            compile_command_plan(
                self.candidate,
                self.scenarios,
                repository_root=ROOT,
                inputs=values,
            )
        values = command_inputs()
        values["candidate_commit"] = "f" * 40
        with self.assertRaisesRegex(CommandCompilationError, "cannot be overridden"):
            compile_command_plan(
                self.candidate,
                self.scenarios,
                repository_root=ROOT,
                inputs=values,
            )
        values = command_inputs()
        values["repository_root"] = "/private/tmp"
        with self.assertRaisesRegex(CommandCompilationError, "audited repository root"):
            compile_command_plan(
                self.candidate,
                self.scenarios,
                repository_root=ROOT,
                inputs=values,
            )
        values = command_inputs()
        values["qualification_run_id"] = "Task 11"
        with self.assertRaisesRegex(CommandCompilationError, "canonical lowercase stable ID"):
            compile_command_plan(
                self.candidate,
                self.scenarios,
                repository_root=ROOT,
                inputs=values,
            )
        values = command_inputs()
        values["qualification_run_nonce"] = "f" * 63
        with self.assertRaisesRegex(CommandCompilationError, "lowercase SHA-256"):
            compile_command_plan(
                self.candidate,
                self.scenarios,
                repository_root=ROOT,
                inputs=values,
            )
        values = command_inputs()
        values["signed_xpc_content_predecessor_observations_sha256"] = "not-a-digest"
        with self.assertRaisesRegex(CommandCompilationError, "runtime predecessor hashes"):
            compile_command_plan(
                self.candidate,
                self.scenarios,
                repository_root=ROOT,
                inputs=values,
            )

    def test_every_resolved_input_is_sealed_against_authority_command_redirection(self) -> None:
        plan = self.compile()
        self.assertEqual(plan.command_inputs, tuple(sorted(command_inputs().items())))
        records = list(plan.commands)
        index = next(
            i
            for i, item in enumerate(records)
            if item.command_id == "signing.strict-release"
        )
        argv = list(records[index].argv)
        app_index = argv.index("--app-bundle") + 1
        argv[app_index] = "/private/tmp/unrelated/MacScope.app"
        records[index] = dataclasses.replace(records[index], argv=tuple(argv))
        redirected = dataclasses.replace(plan, commands=tuple(records))
        issues = validate_command_plan(
            redirected,
            candidate=self.candidate,
            scenario_catalog=self.scenarios,
            repository_root=ROOT,
            templates={item.command_id: item for item in command_templates()},
        )
        self.assertIn("command-template-drift", {item.code for item in issues})

    def test_empty_self_declared_scenario_catalog_cannot_compile_commands(self) -> None:
        empty = dataclasses.replace(
            self.scenarios,
            scenarios=(),
            pairwise_factors=(),
            pairwise_coverage=(),
            required_scenario_ids=(),
        )
        with self.assertRaisesRegex(CommandCompilationError, "empty-scenario-catalog"):
            compile_command_plan(
                self.candidate,
                empty,
                repository_root=ROOT,
                inputs=command_inputs(),
            )

    def test_reclassified_required_scenario_cannot_compile_commands(self) -> None:
        scenarios = list(self.scenarios.scenarios)
        index = next(
            i
            for i, item in enumerate(scenarios)
            if item.scenario_id == "race.cancel-removal-release-skip"
        )
        scenarios[index] = dataclasses.replace(
            scenarios[index],
            origin=ScenarioOrigin.COMMISSIONED,
            higher_order_rationale=None,
        )
        changed = dataclasses.replace(self.scenarios, scenarios=tuple(scenarios))
        with self.assertRaisesRegex(CommandCompilationError, "required-scenario-shape"):
            compile_command_plan(
                self.candidate,
                changed,
                repository_root=ROOT,
                inputs=command_inputs(),
            )

    def test_rebound_pairwise_coverage_cannot_compile_commands(self) -> None:
        changed = dataclasses.replace(
            self.scenarios,
            scenarios=tuple(
                item
                for item in self.scenarios.scenarios
                if item.origin is not ScenarioOrigin.PAIRWISE
            ),
            pairwise_coverage=tuple(
                dataclasses.replace(
                    item,
                    scenario_id="durable.correct-job-bound-scheduling",
                )
                for item in self.scenarios.pairwise_coverage
            ),
        )
        with self.assertRaisesRegex(CommandCompilationError, "pairwise-coverage-owner"):
            compile_command_plan(
                self.candidate,
                changed,
                repository_root=ROOT,
                inputs=command_inputs(),
            )


if __name__ == "__main__":
    unittest.main()
