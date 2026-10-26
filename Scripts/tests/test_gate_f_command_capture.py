"""Synthetic transport tests; no fixture is production execution evidence."""
import base64
from dataclasses import replace
import hashlib
import unittest
from unittest.mock import patch

from Scripts.reconstruction_gate_f import command_capture as capture
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, canonical_sha256, to_primitive
from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile
from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan, command_plan_sha256, EXTERNAL_PREREQUISITE_IDS
from Scripts.reconstruction_gate_f.runtime_resolution import resolve_command_record
from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation, QualificationRunAuthority
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.tests import parsed_candidate
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs


class CommandCaptureTests(unittest.TestCase):
    def test_bootstrap_verifier_capture_uses_unchanged_wire_and_independent_profile(self):
        import inspect
        self.assertIn("profile", inspect.signature(capture.compare_bindings).parameters,
                      "capture comparison must accept independently selected profile")
        candidate = parsed_candidate()
        from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
        root, inputs = bootstrap_repository(self)
        profile = CampaignProfile.BOOTSTRAP_VERIFIER
        self.plan = compile_command_plan(candidate, compile_scenario_catalog(candidate),
            repository_root=root, inputs=inputs, profile=profile)
        for command_id in ("qualification.verify-bootstrap-fullsuite", "qualification.verify-bootstrap-products"):
            self.record = next(record for record in self.plan.commands if record.command_id == command_id)
            document = self.document(profile=profile)
            envelope = capture.parse_capture(capture.serialize_capture(document))
            self.assertEqual(document["schema_version"], 2)
            self.assertEqual(document["runtime_resolution"]["schema_version"], 1)
            self.assertEqual(capture.compare_bindings(envelope, **self.expected(), profile=profile), ())
            with self.assertRaises(capture.CaptureError):
                capture.compare_bindings(envelope, **self.expected())
            expected = self.expected()
            expected["expected_source_commit"] = "0" * 40
            self.assertIn("producer_source_commit", capture.compare_bindings(envelope, **expected, profile=profile))
            for key in ("campaign_profile", "bootstrap_role", "bootstrap_completion"):
                changed = dict(document, **{key: "bootstrap-verifier-campaign-v1"})
                with self.assertRaises(capture.CaptureError):
                    capture.serialize_capture(changed)

    @classmethod
    def setUpClass(cls):
        candidate = parsed_candidate()
        cls.plan = compile_command_plan(candidate, compile_scenario_catalog(candidate), repository_root=ROOT, inputs=command_inputs())
        cls.record = next(record for record in cls.plan.commands if record.argv and record.scenario_ids)
        cls.qualification_run = QualificationRunAuthority("run-1", "b" * 64)

    def predecessors(self, record=None):
        record = record or self.record
        return tuple(CommandPrerequisiteExpectation(key, "receipt-" + str(index), "c" * 64,
            self.qualification_run.run_id, self.qualification_run.nonce) for index, key in enumerate(record.prerequisite_ids)
            if key not in EXTERNAL_PREREQUISITE_IDS)

    def document(self, chunks=(b'\0\xff{"terminal":true}\n', b"stderr"), *, profile=CampaignProfile.EXISTING):
        record = self.record
        predecessors = self.predecessors()
        resolved = resolve_command_record(record, prerequisite_receipts=predecessors,
                                          qualification_run=self.qualification_run, profile=profile)
        intent = dict(capture_id="capture-1", run_id=self.qualification_run.run_id, nonce=self.qualification_run.nonce,
                      candidate_identity_sha256=record.candidate_identity_sha256,
                      command_plan_sha256=command_plan_sha256(self.plan),
                      command_record_sha256=canonical_sha256(record), command_id=record.command_id,
                      scenario_id=record.scenario_ids[0] if record.scenario_ids else record.command_id, producer_source_commit="a" * 40,
                      producer_source_tree="b" * 40, argv=list(resolved.record.argv),
                      working_directory=record.working_directory,
                      environment=[list(pair) for pair in record.environment],
                      environment_policy_id="gatef-host-environment-v1", effective_environment=[["PATH", "/usr/bin"]],
                      prerequisite_receipts=[[item.command_id, item.canonical_sha256] for item in predecessors],
                      started_at_unix_ms=1)
        frames = [dict(sequence=index, stream=("stdout", "stderr")[index % 2],
                       data_base64=base64.b64encode(raw).decode(), raw_length=len(raw),
                       raw_sha256=hashlib.sha256(raw).hexdigest()) for index, raw in enumerate(chunks)]
        terminal = dict(intent_sha256=canonical_sha256(intent), frames_sha256=canonical_sha256(frames),
                        ended_at_unix_ms=2, termination_kind="exited", exit_code=0, signal=None)
        for stream in ("stdout", "stderr"):
            raw = b"".join(chunks[index] for index, frame in enumerate(frames) if frame["stream"] == stream)
            terminal[stream + "_length"] = len(raw)
            terminal[stream + "_sha256"] = hashlib.sha256(raw).hexdigest()
        return dict(schema_version=2, intent=intent, output_frames=frames, terminal=terminal,
                    runtime_resolution=to_primitive(resolved.runtime_resolution),
                    process_observation=dict(state="launched", pid=123,
                        spawn_observed_monotonic_ns=100,
                        os_start_time=dict(state="unavailable", reason="synthetic query unavailable")))

    def expected(self):
        return dict(expected_record=self.record, expected_plan_sha256=command_plan_sha256(self.plan),
                    expected_run_id=self.qualification_run.run_id, expected_nonce=self.qualification_run.nonce, expected_source_commit="a" * 40,
                    expected_source_tree="b" * 40, expected_capture_id="capture-1",
                    expected_scenario_id=self.record.scenario_ids[0] if self.record.scenario_ids else self.record.command_id,
                    expected_effective_environment=(("PATH", "/usr/bin"),),
                    expected_prerequisite_receipts=self.predecessors())

    def test_round_trip_binary_and_binding_comparison(self):
        document = self.document()
        envelope = capture.parse_capture(capture.serialize_capture(document))
        self.assertEqual(envelope.to_mapping(), document)
        self.assertEqual(capture.compare_bindings(envelope, **self.expected()), ())
        document["intent"]["run_id"] = "changed"
        self.assertEqual(envelope.to_mapping()["intent"]["run_id"], "run-1")

    def test_compiled_scenario_less_supervision_binding_is_command_scoped_only(self):
        record = next(item for item in self.plan.commands if item.command_id == "signed-xpc.supervision")
        self.assertEqual(record.scenario_ids, ())
        self.record = record
        document = self.document()
        expected = self.expected()
        envelope = capture.parse_capture(capture.serialize_capture(document))
        self.assertEqual(capture.compare_bindings(envelope, **expected), ())
        document["intent"]["scenario_id"] = "arbitrary-scenario"
        document["terminal"]["intent_sha256"] = canonical_sha256(document["intent"])
        expected["expected_scenario_id"] = "arbitrary-scenario"
        self.assertIn("scenario_id", capture.compare_bindings(capture.parse_capture(capture.serialize_capture(document)), **expected))

    def test_durable_prefix_exactly_precedes_frames_and_never_proves_completion(self):
        for chunks in ((), (b"x",), (b"x", b"y")):
            document = self.document(chunks)
            prefix = capture.intent_prefix(document["intent"])
            self.assertTrue(capture.serialize_capture(document).startswith(prefix))
            with self.assertRaises(capture.CaptureError):
                capture.parse_capture(prefix)

    def test_runtime_identity_uses_fixed_static_plan_and_real_predecessor_mapping(self):
        self.record = next(item for item in self.plan.commands if item.command_id == "signed-xpc.supervision")
        document = self.document()
        before_p = document["intent"]["command_plan_sha256"]
        before_s = document["intent"]["command_record_sha256"]
        predecessors = self.predecessors()
        changed = tuple(replace(item, canonical_sha256="e" * 64) for item in predecessors)
        resolved = resolve_command_record(self.record, prerequisite_receipts=changed, qualification_run=self.qualification_run)
        self.assertEqual(before_s, resolved.static_record_sha256)
        self.assertEqual(before_p, command_plan_sha256(self.plan))
        self.assertNotEqual(document["runtime_resolution"]["resolved_command_record_sha256"], resolved.runtime_resolution.resolved_command_record_sha256)
        self.assertNotEqual(document["intent"]["argv"], list(resolved.record.argv))
        self.assertTrue(capture.serialize_capture(document).startswith(capture.intent_prefix(document["intent"])))
        self.assertEqual(capture.compare_bindings(capture.parse_capture(capture.serialize_capture(document)), **self.expected()), ())

    def test_runtime_resolution_is_closed_and_not_caller_asserted_authority(self):
        self.record = next(item for item in self.plan.commands if item.command_id == "signed-xpc.supervision")
        mutations = (
            lambda d: d.update(schema_version=1),
            lambda d: d.pop("runtime_resolution"),
            lambda d: d["runtime_resolution"].update(extra=True),
            lambda d: d["runtime_resolution"].update(schema_version=True),
            lambda d: d["runtime_resolution"]["bindings"][0].update(argv_index=True),
            lambda d: d["runtime_resolution"]["bindings"][0].update(argv_index=999),
            lambda d: d["runtime_resolution"]["bindings"][0].update(kind="arbitrary"),
            lambda d: d["runtime_resolution"]["bindings"].append(dict(d["runtime_resolution"]["bindings"][0])),
            lambda d: d["runtime_resolution"]["bindings"][0].update(value="e" * 64),
        )
        for mutation in mutations:
            document = self.document()
            mutation(document)
            with self.subTest(mutation=mutation), self.assertRaises(capture.CaptureError):
                capture.serialize_capture(document)
        # A self-consistent false resolution is structurally valid but fails
        # independent re-resolution from the expected full predecessor DTOs.
        document = self.document()
        binding = document["runtime_resolution"]["bindings"][0]
        binding["value"] = "e" * 64
        document["intent"]["argv"][binding["argv_index"]] = binding["value"]
        document["runtime_resolution"]["resolved_command_record_sha256"] = "f" * 64
        document["terminal"]["intent_sha256"] = canonical_sha256(document["intent"])
        issues = capture.compare_bindings(capture.parse_capture(capture.serialize_capture(document)), **self.expected())
        self.assertIn("argv", issues)
        self.assertIn("runtime_resolution", issues)

    def test_unresolved_runtime_marker_cannot_form_completed_capture(self):
        self.record = next(item for item in self.plan.commands if item.command_id == "signed-xpc.supervision")
        document = self.document()
        document["intent"]["argv"] = list(self.record.argv)
        document["runtime_resolution"]["bindings"] = []
        document["terminal"]["intent_sha256"] = canonical_sha256(document["intent"])
        with self.assertRaises(capture.CaptureError):
            capture.serialize_capture(document)

    def test_foreign_reordered_or_shortened_expected_predecessors_fail(self):
        self.record = next(item for item in self.plan.commands if item.command_id == "installed.task10-workflow")
        document = self.document()
        envelope = capture.parse_capture(capture.serialize_capture(document))
        predecessors = self.predecessors()
        variants = (predecessors[:-1], tuple(reversed(predecessors)),
                    tuple(replace(item, qualification_run_nonce="f" * 64) for item in predecessors),
                    tuple((item.command_id, item.canonical_sha256) for item in predecessors))
        for variant in variants:
            expected = self.expected()
            expected["expected_prerequisite_receipts"] = variant
            with self.subTest(variant=variant), self.assertRaises(capture.CaptureError):
                capture.compare_bindings(envelope, **expected)

    def test_partial_trailing_duplicate_noncanonical_and_deep_json(self):
        payload = capture.serialize_capture(self.document())
        for invalid in (payload[:-1], payload + b"x", payload + b"\n", b'{"x":1,"x":2}', b"[" * 1500 + b"]" * 1500):
            with self.subTest(payload=invalid[:30]), self.assertRaises(capture.CaptureError):
                capture.parse_capture(invalid)

    def test_prefix_invalid_unicode_is_capture_error(self):
        document = self.document()
        document["intent"]["run_id"] = "\ud800"
        with self.assertRaises(capture.CaptureError):
            capture.intent_prefix(document["intent"])

    def test_closed_schema_and_tampering(self):
        mutations = [lambda d: d.update(extra=1), lambda d: d.pop("terminal"),
                     lambda d: d.update(schema_version=True),
                     lambda d: d["intent"].update(run_id="forged"),
                     lambda d: d["output_frames"][0].update(sequence=1),
                     lambda d: d["output_frames"][0].update(raw_length=1),
                     lambda d: d["output_frames"][0].update(raw_sha256="0" * 64),
                     lambda d: d["output_frames"][0].update(data_base64="!!!!"),
                     lambda d: d["output_frames"][0].update(data_base64="Zh=="),
                     lambda d: d["output_frames"][0].update(stream="other"),
                     lambda d: d["terminal"].update(stdout_length=True),
                     lambda d: d["terminal"].update(ended_at_unix_ms=0),
                     lambda d: d["terminal"].update(signal=9),
                     lambda d: d["terminal"].update(exit_code=True),
                     lambda d: d["intent"].update(environment=[["A", "1"], ["A", "2"]])]
        for mutate in mutations:
            document = self.document()
            mutate(document)
            with self.subTest(mutation=mutate), self.assertRaises(capture.CaptureError):
                capture.serialize_capture(document)

    def test_encoded_decoded_frame_and_count_limits(self):
        document = self.document()
        for name, limit in (("MAX_ENCODED_BYTES", 1), ("MAX_DECODED_BYTES", 1), ("MAX_FRAME_BYTES", 1), ("MAX_FRAMES", 1)):
            with patch.object(capture, name, limit), self.subTest(limit=name), self.assertRaises(capture.CaptureError):
                capture.serialize_capture(document)
        capture.serialize_capture(self.document((b"x" * capture.MAX_FRAME_BYTES,)))
        with self.assertRaises(capture.CaptureError):
            capture.serialize_capture(self.document((b"x" * (capture.MAX_FRAME_BYTES + 1),)))

    def test_environment_and_prerequisite_context_are_separate_comparisons(self):
        document = self.document()
        document["intent"]["effective_environment"] = [["PATH", "/other"]]
        document["terminal"]["intent_sha256"] = canonical_sha256(document["intent"])
        envelope = capture.parse_capture(capture.serialize_capture(document))
        self.assertIn("effective_environment", capture.compare_bindings(envelope, **self.expected()))
        document["intent"]["effective_environment"] = [["PYTHONPATH", "/other"]]
        with self.assertRaises(capture.CaptureError):
            capture.serialize_capture(document)
        expected = self.expected()
        expected["expected_prerequisite_receipts"] = (("different", "a" * 64),)
        with self.assertRaises(capture.CaptureError):
            capture.compare_bindings(envelope, **expected)

    def test_terminal_commitments_and_non_success_outcomes(self):
        for kind in ("signaled", "timed-out", "cancelled", "output-limit", "launch-failed"):
            document = self.document()
            document["terminal"].update(termination_kind=kind, exit_code=None, signal=9 if kind == "signaled" else None)
            if kind == "launch-failed":
                document["process_observation"] = {"state": "not-launched"}
            capture.serialize_capture(document)
        for key in ("intent_sha256", "frames_sha256", "stdout_sha256", "stderr_sha256"):
            document = self.document()
            document["terminal"][key] = "0" * 64
            with self.subTest(key=key), self.assertRaises(capture.CaptureError):
                capture.serialize_capture(document)
        document = self.document()
        document["output_frames"].reverse()
        document["terminal"]["frames_sha256"] = canonical_sha256(document["output_frames"])
        with self.assertRaises(capture.CaptureError):
            capture.serialize_capture(document)

    def test_stop_cause_preserves_observed_process_status(self):
        accepted = (("timed-out", None, 15), ("output-limit", None, 9),
                    ("cancelled", 0, None), ("timed-out", None, None),
                    ("cancelled", None, None), ("output-limit", None, None))
        for kind, code, signal in accepted:
            document = self.document()
            document["terminal"].update(termination_kind=kind, exit_code=code, signal=signal)
            with self.subTest(kind=kind, code=code, signal=signal):
                self.assertEqual(capture.parse_capture(capture.serialize_capture(document)).to_mapping()["terminal"], document["terminal"])

    def test_invalid_or_conflicting_observed_status_fails_closed(self):
        invalid = [(kind, 0, 9) for kind in ("exited", "signaled", "timed-out", "cancelled", "output-limit", "launch-failed")]
        invalid += [("timed-out", None, signal) for signal in (0, -1, 128, True, "15")]
        invalid += [("cancelled", code, None) for code in (-1, 256, True, "0")]
        invalid += [("launch-failed", 0, None), ("launch-failed", None, 9),
                    ("exited", None, None), ("exited", None, 9),
                    ("signaled", None, None), ("signaled", 0, None)]
        for kind, code, signal in invalid:
            document = self.document()
            document["terminal"].update(termination_kind=kind, exit_code=code, signal=signal)
            with self.subTest(kind=kind, code=code, signal=signal), self.assertRaises(capture.CaptureError):
                capture.serialize_capture(document)

    def test_process_observation_available_unavailable_and_prefix(self):
        document = self.document()
        unavailable = document["process_observation"]["os_start_time"]
        self.assertEqual(set(unavailable), {"state", "reason"})
        for observation in (unavailable, dict(state="available", unix_time_ns=123456789, source="synthetic OS query")):
            document["process_observation"]["os_start_time"] = observation
            payload = capture.serialize_capture(document)
            self.assertTrue(payload.startswith(capture.intent_prefix(document["intent"])))
        document["terminal"].update(termination_kind="launch-failed", exit_code=None)
        document["process_observation"] = {"state": "not-launched"}
        payload = capture.serialize_capture(document)
        self.assertTrue(payload.startswith(capture.intent_prefix(document["intent"])))

    def test_process_observation_rejects_bad_types_tags_times_and_terminal(self):
        mutations = [lambda d: d.pop("process_observation"),
                     lambda d: d.update(process_observation=None),
                     lambda d: d.update(process_observation={"state": "not-launched"}),
                     lambda d: d["process_observation"].update(state="unknown"),
                     lambda d: d["terminal"].update(termination_kind="launch-failed", exit_code=None)]
        for key, values in (("pid", (0, -1, 2**31, True, "123")),
                            ("spawn_observed_monotonic_ns", (0, -1, True, "100"))):
            mutations.extend(lambda d, key=key, value=value: d["process_observation"].update({key: value}) for value in values)
        for observation in (None, {"state": "unknown"}, {"state": "unavailable", "reason": ""},
                            {"state": "unavailable", "reason": "absent", "unix_time_ns": 0},
                            {"state": "available", "unix_time_ns": 0, "source": "query"},
                            {"state": "available", "unix_time_ns": True, "source": "query"},
                            {"state": "available", "unix_time_ns": 123, "source": ""}):
            mutations.append(lambda d, value=observation: d["process_observation"].update(os_start_time=value))
        for mutate in mutations:
            document = self.document()
            mutate(document)
            with self.subTest(mutation=mutate), self.assertRaises(capture.CaptureError):
                capture.serialize_capture(document)

    def test_self_consistent_forgery_is_structural_only_and_context_rejects(self):
        for field in ("run_id", "nonce", "producer_source_commit", "producer_source_tree", "command_plan_sha256", "command_record_sha256", "candidate_identity_sha256", "capture_id", "command_id", "scenario_id"):
            document = self.document()
            old = document["intent"][field]
            document["intent"][field] = "d" * len(old)
            document["terminal"]["intent_sha256"] = canonical_sha256(document["intent"])
            envelope = capture.parse_capture(capture.serialize_capture(document))
            self.assertIn(field, capture.compare_bindings(envelope, **self.expected()))
        # Self-asserted expected context can match a forged capture: not authority.
        expected = self.expected()
        document = self.document()
        document["intent"]["capture_id"] = expected["expected_capture_id"] = "forged"
        document["terminal"]["intent_sha256"] = canonical_sha256(document["intent"])
        self.assertEqual(capture.compare_bindings(capture.parse_capture(capture.serialize_capture(document)), **expected), ())


if __name__ == "__main__":
    unittest.main()
