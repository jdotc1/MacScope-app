"""Fresh verifier ownership against the real synthetic physical admission fixture."""
from dataclasses import replace
import base64
import copy
import hashlib
import importlib.util
import io
import os
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace

from Scripts.reconstruction_gate_f import bootstrap_qualification as bootstrap
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes


class BootstrapVerifierTests(unittest.TestCase):
    def modules(self):
        for name in ("bootstrap_verifier", "bootstrap_verifier_adapter"):
            self.assertIsNotNone(importlib.util.find_spec("Scripts.reconstruction_gate_f." + name),
                                 "missing verifier producer/adapter: " + name)
        from Scripts.reconstruction_gate_f import bootstrap_verifier, bootstrap_verifier_adapter
        return bootstrap_verifier, bootstrap_verifier_adapter

    def fixture(self):
        from Scripts.tests.test_gate_f_bootstrap_qualification import BootstrapPhysicalAdmissionTests
        f = BootstrapPhysicalAdmissionTests(methodName="runTest")
        f.setUp()
        self.addCleanup(f.doCleanups)
        f.fixture(skipped=True)
        bootstrap.admit_bootstrap_qualification(f.retained, f.candidate, output=f.artifacts / "admission.json")
        return f

    def run_verifier(self, f, kind, output=None, predecessor="c" * 64):
        verifier, _ = self.modules()
        output = output or f.root / ("verify-" + kind)
        with redirect_stdout(io.StringIO()) as stdout:
            paths = verifier.run_bootstrap_verifier(kind=kind, candidate=f.candidate,
                expected_source=f.source, bootstrap_root=f.artifacts,
                admission_relative_path="admission.json", artifact_root=output,
                qualification_run=f.run, predecessor_observations_sha256=predecessor)
        return paths, stdout.getvalue()

    def test_verifiers_emit_fresh_command_bound_reports(self):
        self.modules()
        f = self.fixture()
        original = decode_canonical_bytes((f.artifacts / "admission.json").read_bytes())
        for kind, prefix, projection_name in (("fullsuite", "Fullsuite", "xcresult"), ("products", "Products", "app")):
            paths, stdout = self.run_verifier(f, kind)
            self.assertEqual([p.name for p in paths], ["Bootstrap" + prefix + ".execution-report.json",
                "Bootstrap" + prefix + ".semantic-report.json", "Bootstrap" + prefix + "." + projection_name + "-projection.json"])
            execution, semantic, projection = [decode_canonical_bytes(p.read_bytes()) for p in paths]
            self.assertEqual(execution["schema_version"], 2)
            self.assertEqual(execution["result"], "passed")
            self.assertEqual(execution["qualification_run"], {"run_id": f.run.run_id, "nonce": f.run.nonce})
            self.assertEqual(semantic["command_id"], "qualification.verify-bootstrap-" + kind)
            self.assertEqual(semantic["verification_interval"], {k: execution[k] for k in ("started_at_unix_ms", "ended_at_unix_ms")})
            self.assertEqual(semantic["bootstrap"]["original_execution_interval"], original["execution_interval"])
            self.assertLessEqual(original["execution_interval"]["ended_at_unix_ms"], execution["started_at_unix_ms"])
            self.assertEqual(projection["bootstrap_admission_sha256"], semantic["bootstrap"]["admission"]["sha256"])
            self.assertEqual(projection["candidate_identity_sha256"], semantic["candidate_identity_sha256"])
            markers = ["EXECUTION_REPORT", "SEMANTIC_REPORT", "XCRESULT_PROJECTION" if kind == "fullsuite" else "APP_PROJECTION"]
            self.assertEqual(stdout.splitlines(), ["MACSCOPE_BOOTSTRAP_" + kind.upper() + "_" + marker + "=" + str(path) for marker, path in zip(markers, paths)])
            if kind == "fullsuite":
                self.assertEqual(semantic["test_observations"]["skipped_selector_count"], 1)

    def test_verifier_outputs_do_not_alias_original_or_each_other(self):
        self.modules()
        f = self.fixture()
        first, _ = self.run_verifier(f, "fullsuite")
        second, _ = self.run_verifier(f, "products")
        self.assertEqual(len({(p.stat().st_dev, p.stat().st_ino) for p in (*first, *second)}), 6)
        self.assertTrue(all(p.stat().st_nlink == 1 for p in (*first, *second)))
        with self.assertRaises((ValueError, OSError)):
            self.run_verifier(f, "fullsuite")
        with self.assertRaises((ValueError, OSError)):
            self.run_verifier(f, "products", first[0].parent)
        with self.assertRaises(ValueError):
            self.run_verifier(f, "products", f.artifacts / "overlap")

    def test_verifier_rejects_changed_original_physical_evidence(self):
        self.modules()
        f = self.fixture()
        for index, path in enumerate((f.fixture_build.app / "Contents/MacOS/MacScope", f.tests_path,
                                      f.fixture_build.run / "COVERAGE.json", f.artifacts / "admission.json")):
            saved = path.read_bytes()
            path.write_bytes(saved + b"changed")
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.run_verifier(f, "products", f.root / ("invalid-" + str(index)))
            path.write_bytes(saved)

    def test_cli_uses_only_fixed_subcommands_and_exact_option_names(self):
        verifier, _ = self.modules()
        f = self.fixture()
        from Scripts.reconstruction_gate_f.schema import candidate_to_mapping
        candidate_path = f.root / "candidate.json"
        candidate_path.write_bytes(canonical_bytes(candidate_to_mapping(f.candidate)))
        args = ["products", "--candidate-identity", str(candidate_path), "--repository-root", str(f.repository),
            "--integration-ref", f.source.integration_ref, "--bootstrap-root", str(f.artifacts),
            "--bootstrap-admission", str(f.artifacts / "admission.json"), "--artifact-root", str(f.root / "cli-products"),
            "--qualification-run-id", f.run.run_id, "--qualification-run-nonce", f.run.nonce,
            "--predecessor-observations-sha256", "c" * 64]
        for bad in (["other", *args[1:]], [*args, "--mode", "full-test"],
                    [*args, "--qualification-run-id", f.run.run_id],
                    ["products", "--candidate", *args[2:]]):
            with self.subTest(argv=bad), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    verifier.main(bad)
                self.assertEqual(error.exception.code, 2)
        with redirect_stdout(io.StringIO()) as stdout:
            result = verifier.main(args)
        self.assertEqual(result, 0)
        self.assertEqual(len(stdout.getvalue().splitlines()), 3)

    def test_cli_rejects_duplicate_equals_and_mixed_form_options_before_evidence_reads(self):
        verifier, _ = self.modules()
        args = ["products", "--candidate-identity", "/missing/candidate.json", "--repository-root", "/missing/source",
            "--integration-ref", "refs/remotes/github/main", "--bootstrap-root", "/missing/bootstrap",
            "--bootstrap-admission", "/missing/bootstrap/admission.json", "--artifact-root", "/missing/products",
            "--qualification-run-nonce", "a" * 64, "--predecessor-observations-sha256", "c" * 64]
        for duplicate in (["--qualification-run-id=first", "--qualification-run-id=second"],
                          ["--qualification-run-id", "first", "--qualification-run-id=second"]):
            with self.subTest(options=duplicate), redirect_stderr(io.StringIO()) as stderr:
                with self.assertRaises(SystemExit) as error:
                    verifier.main([*args, *duplicate])
                self.assertEqual(error.exception.code, 2)
                self.assertIn("duplicate verifier options", stderr.getvalue())

    def adapter_fixture(self, f, kind):
        from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, command_templates
        from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan
        from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
        from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
        from Scripts.reconstruction_gate_f.command_execution import AdmittedCommand, ExecutionCapture
        from Scripts.reconstruction_gate_f.runtime_resolution import resolve_command_record
        from Scripts.reconstruction_gate_f.executor_request_adapter import ExecutorReceiptAdmission, OwnerArtifactSource
        from Scripts.reconstruction_gate_f.schema import ArtifactKind, QualificationPhase, ReceiptType, candidate_to_mapping
        from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation
        from Scripts.reconstruction_gate_f.command_capture import serialize_capture
        verifier, _ = self.modules()
        inputs = command_inputs(profile=CampaignProfile.BOOTSTRAP_VERIFIER, output_root=f.root)
        candidate_path = f.root / "candidate.json"
        candidate_path.write_bytes(canonical_bytes(candidate_to_mapping(f.candidate)))
        inputs.update(candidate_identity_path=str(candidate_path), integration_ref=f.source.integration_ref,
            qualification_run_id=f.run.run_id, qualification_run_nonce=f.run.nonce,
            bootstrap_artifact_root=str(f.artifacts), bootstrap_admission_path=str(f.artifacts / "admission.json"),
            bootstrap_fullsuite_artifact_root=str(f.root / "verify-fullsuite"),
            bootstrap_products_artifact_root=str(f.root / "verify-products"))
        # Compile the actual scenario obligations from the current real source.
        # The admitted local command fixture then supplies the isolated physical
        # bootstrap source; full-plan dispatch belongs to the integration tests.
        plan = compile_command_plan(f.candidate, compile_scenario_catalog(f.candidate), repository_root=ROOT,
                                    inputs=inputs, profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        record = next(r for r in plan.commands if r.command_id == "qualification.verify-bootstrap-" + kind)
        inputs["repository_root"] = str(f.repository)
        inputs["native_source_root"] = str(f.repository / "Tools/NativeDecompilerBridge")
        record = replace(record, argv=tuple(str(f.repository) if arg == str(ROOT) else arg for arg in record.argv),
                         working_directory=str(f.repository))
        predecessors = tuple(CommandPrerequisiteExpectation(key, "receipt-" + str(i), "e" * 64,
            f.run.run_id, f.run.nonce) for i, key in enumerate(record.prerequisite_ids))
        digest = canonical_sha256([vars(item) for item in predecessors])
        resolved = resolve_command_record(record, prerequisite_receipts=predecessors, qualification_run=f.run,
                                          profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        paths, stdout = self.run_verifier(f, kind, predecessor=digest)
        report = decode_canonical_bytes(paths[0].read_bytes())
        sources = tuple(OwnerArtifactSource("artifact-" + kind + "-" + str(i), path.relative_to(f.root).as_posix(),
            ArtifactKind.JSON if i < 2 else (ArtifactKind.XCRESULT if kind == "fullsuite" else ArtifactKind.APP_BUNDLE),
            "application/json", "artifact:stdout-path:" + marker)
            for i, (path, (_, marker)) in enumerate(zip(paths, verifier.output_contract(kind))))
        log_path = f.root / (kind + "-output.log")
        log_path.write_bytes(stdout.encode())
        sources += (OwnerArtifactSource("artifact-" + kind + "-log", log_path.name, ArtifactKind.LAUNCH_LOG,
            "text/plain", "log:executor-captured:bootstrap-" + kind + "-verifier-stdout-stderr"),)
        intent = dict(capture_id="verifier-capture", run_id=f.run.run_id, nonce=f.run.nonce,
            candidate_identity_sha256=record.candidate_identity_sha256, command_plan_sha256=canonical_sha256(plan),
            command_record_sha256=canonical_sha256(record), command_id=record.command_id,
            scenario_id=record.scenario_ids[0] if record.scenario_ids else record.command_id,
            producer_source_commit=f.source.commit, producer_source_tree=f.source.tree,
            argv=list(resolved.record.argv), working_directory=str(f.repository), environment=[], effective_environment=[],
            environment_policy_id="gatef-host-environment-v1",
            prerequisite_receipts=sorted([[p.command_id, p.canonical_sha256] for p in predecessors]),
            started_at_unix_ms=report["started_at_unix_ms"])
        frames = [dict(sequence=0, stream="stdout", raw_length=len(stdout.encode()),
            raw_sha256=hashlib.sha256(stdout.encode()).hexdigest(), data_base64=base64.b64encode(stdout.encode()).decode())]
        terminal = dict(intent_sha256=canonical_sha256(intent), frames_sha256=canonical_sha256(frames),
            ended_at_unix_ms=report["ended_at_unix_ms"] + 1, termination_kind="exited", exit_code=0, signal=None,
            stdout_length=len(stdout.encode()), stdout_sha256=hashlib.sha256(stdout.encode()).hexdigest(),
            stderr_length=0, stderr_sha256=hashlib.sha256(b"").hexdigest())
        document = dict(schema_version=2, intent=intent, terminal=terminal, output_frames=frames,
            runtime_resolution=vars(resolved.runtime_resolution), process_observation=dict(state="launched", pid=123,
                spawn_observed_monotonic_ns=1, os_start_time=dict(state="unavailable", reason="synthetic outer capture fixture")))
        from Scripts.reconstruction_gate_f.canonical_json import to_primitive
        document["runtime_resolution"] = to_primitive(resolved.runtime_resolution)
        captured_path = f.root / (kind + "-capture.json")
        payload = serialize_capture(document)
        captured_path.write_bytes(payload)
        execution = SimpleNamespace(candidate=f.candidate, qualification_run=f.run,
            integrated_plan_input=SimpleNamespace(inputs=inputs), admitted_predecessors=predecessors)
        capture = ExecutionCapture(execution, record.command_id, intent["scenario_id"], "verifier-capture", (),
                                   captured_path, hashlib.sha256(payload).hexdigest())
        admission = ExecutorReceiptAdmission(capture, f.root, "receipt-verifier-" + kind,
            "requirement-verifier", QualificationPhase.PREMERGE,
            ReceiptType.TEST_RESULT if kind == "fullsuite" else ReceiptType.RELEASE_BUILD,
            "root-verifier", sources[0].artifact_id, sources, {})
        admitted = AdmittedCommand(None, record, resolved)
        return admission, admitted, {"stdout": stdout.encode(), "stderr": b""}, paths

    def test_verifier_adapter_derives_scenario_authority_and_release_tuple(self):
        _, adapter = self.modules()
        f = self.fixture()
        for kind in ("fullsuite", "products"):
            admission, admitted, streams, _ = self.adapter_fixture(f, kind)
            self.assertEqual(admission.capture.capture_path.parent, f.root)
            self.assertNotEqual(admission.artifact_root, f.root / ("verify-" + kind))
            authority, constituents = adapter.validate_bootstrap_verifier_outputs(admission, admitted, streams)
            if kind == "fullsuite":
                count = len(admitted.record.scenario_ids or (admitted.record.command_id,))
                self.assertEqual(authority["expected_selector_count"], count)
                self.assertEqual(authority["skipped_selector_count"], 0)
                self.assertEqual([c["selector_id"] for c in constituents], list(admitted.record.scenario_ids or (admitted.record.command_id,)))
            else:
                self.assertEqual(authority, dict(bundle_sha256=f.candidate.application.bundle_sha256,
                    closed_tree_sha256=f.candidate.application.closed_tree_sha256,
                    executable_sha256=f.candidate.application.executable_sha256))
                self.assertEqual(constituents, ())

    def test_verifier_rejects_stale_or_forged_semantics(self):
        _, adapter = self.modules()
        f = self.fixture()
        admission, admitted, streams, paths = self.adapter_fixture(f, "fullsuite")
        def validate(a=admission, c=admitted, s=streams):
            return adapter.validate_bootstrap_verifier_outputs(a, c, s)
        validate()
        semantic = decode_canonical_bytes(paths[1].read_bytes())
        for field, value in (("command_id", "qualification.verify-bootstrap-products"),
                             ("candidate_identity_sha256", "f" * 64),
                             ("predecessor_observations_sha256", "f" * 64), ("schema_version", True)):
            forged = copy.deepcopy(semantic)
            forged[field] = value
            paths[1].write_bytes(canonical_bytes(forged))
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate()
        paths[1].write_bytes(canonical_bytes(semantic))
        saved_projection = paths[2].read_bytes()
        projected = decode_canonical_bytes(saved_projection)
        projected["artifact_kind"] = "app-bundle"
        paths[2].write_bytes(canonical_bytes(projected))
        with self.assertRaises(ValueError):
            validate()
        paths[2].write_bytes(saved_projection)
        with self.assertRaises(ValueError):
            validate(s={"stdout": b"", "stderr": b""})
        from Scripts.reconstruction_gate_f.schema import ArtifactKind
        with self.assertRaises(ValueError):
            validate(a=replace(admission, owner_artifacts=(*admission.owner_artifacts[:2],
                replace(admission.owner_artifacts[2], kind=ArtifactKind.APP_BUNDLE), admission.owner_artifacts[3])))
        saved = paths[0].read_bytes()
        execution = decode_canonical_bytes(saved)
        execution.update(semantic["bootstrap"]["original_execution_interval"])
        paths[0].write_bytes(canonical_bytes(execution))
        with self.assertRaises(ValueError):
            validate()
        paths[0].write_bytes(saved)
        # A hard link is rejected even though its bytes and digest still match.
        link = paths[1].parent / "alias.json"
        os.link(paths[1], link)
        with self.assertRaises(ValueError):
            validate()
        link.unlink()
        with self.assertRaises(ValueError):
            validate(a=replace(admission, owner_artifacts=(*admission.owner_artifacts[:2],
                replace(admission.owner_artifacts[2], artifact_id=admission.owner_artifacts[0].artifact_id),
                admission.owner_artifacts[3])))
        for path in (f.fixture_build.app / "Contents/MacOS/MacScope", f.tests_path,
                     f.fixture_build.run / "COVERAGE.json", f.artifacts / "admission.json"):
            saved = path.read_bytes()
            path.write_bytes(saved + b"changed")
            with self.subTest(path=path), self.assertRaises(ValueError):
                validate()
            path.write_bytes(saved)

    def test_verifier_adapter_rejects_escaped_aliased_or_shared_output_roots(self):
        _, adapter = self.modules()
        f = self.fixture()
        admission, admitted, streams, paths = self.adapter_fixture(f, "fullsuite")
        context = admission.capture.admission
        original_inputs = context.integrated_plan_input.inputs
        def with_root(name, value):
            inputs = dict(original_inputs, **{name: str(value)})
            changed_context = SimpleNamespace(candidate=context.candidate, qualification_run=context.qualification_run,
                admitted_predecessors=context.admitted_predecessors, integrated_plan_input=SimpleNamespace(inputs=inputs))
            changed_admission = replace(admission, capture=replace(admission.capture, admission=changed_context))
            old = original_inputs[name]
            record = replace(admitted.resolved_command.record,
                argv=tuple(str(value) if token == old else token for token in admitted.resolved_command.record.argv))
            return changed_admission, replace(admitted, resolved_command=replace(admitted.resolved_command, record=record))
        for outside in (f.root, f.root.parent):
            a, c = with_root("bootstrap_fullsuite_artifact_root", outside)
            with self.subTest(root=outside), self.assertRaisesRegex(ValueError, "strictly contained"):
                adapter.validate_bootstrap_verifier_outputs(a, c, streams)
        alias = f.root / "output-alias"
        alias.symlink_to(paths[0].parent, target_is_directory=True)
        a, c = with_root("bootstrap_fullsuite_artifact_root", alias)
        with self.assertRaisesRegex(ValueError, "canonical physical"):
            adapter.validate_bootstrap_verifier_outputs(a, c, streams)
        alias.unlink()
        a, c = with_root("bootstrap_products_artifact_root", paths[0].parent)
        with self.assertRaisesRegex(ValueError, "overlap"):
            adapter.validate_bootstrap_verifier_outputs(a, c, streams)
        changed = replace(admission, owner_artifacts=(replace(admission.owner_artifacts[0],
            relative_path=paths[0].name), *admission.owner_artifacts[1:]))
        with self.assertRaisesRegex(ValueError, "wrong kind/path/media type"):
            adapter.validate_bootstrap_verifier_outputs(changed, admitted, streams)


if __name__ == "__main__":
    unittest.main()
