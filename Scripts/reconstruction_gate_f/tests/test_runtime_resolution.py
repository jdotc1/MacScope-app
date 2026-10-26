"""Static/runtime identity algebra; synthetic DTOs are not execution proof."""
from dataclasses import replace
import unittest

from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256, to_primitive
from Scripts.reconstruction_gate_f.command_compiler import (
    CommandCompilationError, EXTERNAL_PREREQUISITE_IDS, RUNTIME_ARGUMENT_KIND,
    RUNTIME_ARGUMENT_MARKER, RUNTIME_INPUT_NAMES, RuntimeArgumentSlot,
    command_plan_sha256, command_templates, compile_command_plan, required_command_input_names,
    validate_command_plan,
)
from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation, QualificationRunAuthority
from Scripts.reconstruction_gate_f.runtime_resolution import resolve_command_record, RuntimeResolutionError
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.tests import parsed_candidate
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs


class RuntimeResolutionTests(unittest.TestCase):
    def test_verifier_prerequisites_use_ordinary_v1_binding(self):
        from Scripts.reconstruction_gate_f import command_catalog
        profile_type = getattr(command_catalog, "CampaignProfile", None)
        self.assertIsNotNone(profile_type, "ordinary verifier profile is missing")
        profile = profile_type.BOOTSTRAP_VERIFIER
        from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
        root, inputs = bootstrap_repository(self)
        plan = compile_command_plan(self.candidate, self.scenarios, repository_root=root,
                                    inputs=inputs, profile=profile)
        for record in plan.commands:
            predecessors = tuple(CommandPrerequisiteExpectation(command_id, "receipt-" + str(index),
                canonical_sha256({"command_id": command_id}), self.qualification_run.run_id, self.qualification_run.nonce)
                for index, command_id in enumerate(record.prerequisite_ids)
                if command_id not in EXTERNAL_PREREQUISITE_IDS)
            resolved = resolve_command_record(record, prerequisite_receipts=predecessors,
                qualification_run=self.qualification_run, profile=profile)
            self.assertEqual(resolved.runtime_resolution.schema_version, 1)
            digest = canonical_sha256([to_primitive(item) for item in predecessors])
            for binding in resolved.runtime_resolution.bindings:
                self.assertEqual(binding.kind, "prerequisite-receipt-set-sha256-v1")
                self.assertEqual(binding.value, digest)
            if not record.command_id.startswith("qualification.verify-bootstrap-"):
                continue
            with self.assertRaises(RuntimeResolutionError):
                resolve_command_record(record, prerequisite_receipts=predecessors, qualification_run=self.qualification_run)
            bad_cases = (predecessors[1:], predecessors[::-1],
                (replace(predecessors[0], receipt_id=predecessors[1].receipt_id), *predecessors[1:]),
                (replace(predecessors[0], qualification_run_id="stale-run"), *predecessors[1:]),
                (replace(predecessors[0], qualification_run_nonce="b" * 64), *predecessors[1:]),
                (replace(predecessors[0], command_id="bootstrap-qualification-proof"), *predecessors[1:]),
                tuple(to_primitive(item) for item in predecessors))
            for bad in bad_cases:
                with self.subTest(command=record.command_id, bad=bad), self.assertRaises(RuntimeResolutionError):
                    resolve_command_record(record, prerequisite_receipts=bad,
                        qualification_run=self.qualification_run, profile=profile)

    @classmethod
    def setUpClass(cls):
        cls.candidate = parsed_candidate()
        cls.scenarios = compile_scenario_catalog(cls.candidate)
        cls.plan = compile_command_plan(cls.candidate, cls.scenarios, repository_root=ROOT, inputs=command_inputs())
        cls.records = {record.command_id: record for record in cls.plan.commands}
        cls.qualification_run = QualificationRunAuthority("test-run", "a" * 64)

    def predecessors(self, record, variant="one"):
        return tuple(CommandPrerequisiteExpectation(command_id, "receipt-" + str(index),
            canonical_sha256({"command_plan_sha256": command_plan_sha256(self.plan),
                              "command_record_sha256": canonical_sha256(self.records[command_id]),
                              "observation": variant}), self.qualification_run.run_id, self.qualification_run.nonce)
            for index, command_id in enumerate(record.prerequisite_ids)
            if command_id not in EXTERNAL_PREREQUISITE_IDS)

    def resolve(self, record, predecessors=None, run=None):
        return resolve_command_record(record,
            prerequisite_receipts=self.predecessors(record) if predecessors is None else predecessors,
            qualification_run=self.qualification_run if run is None else run)

    def test_static_plan_has_exact_nine_slots_and_no_runtime_hash_inputs(self):
        self.assertEqual(self.plan.schema_version, 3)
        self.assertFalse(RUNTIME_INPUT_NAMES & set(dict(self.plan.command_inputs)))
        self.assertFalse(RUNTIME_INPUT_NAMES & set(required_command_input_names()))
        self.assertIn("authority_stress_predecessor_observations", dict(self.plan.command_inputs))
        self.assertEqual(sum(len(record.runtime_argument_slots) for record in self.plan.commands), 9)
        for record in self.plan.commands:
            self.assertEqual(record.schema_version, 3)
            self.resolve(record)

    def test_every_former_hash_input_is_rejected(self):
        for name in RUNTIME_INPUT_NAMES:
            with self.subTest(name=name), self.assertRaisesRegex(CommandCompilationError, "runtime predecessor"):
                compile_command_plan(self.candidate, self.scenarios, repository_root=ROOT,
                                     inputs=dict(command_inputs(), **{name: "b" * 64}))
        with self.assertRaisesRegex(CommandCompilationError, "unknown command inputs"):
            compile_command_plan(self.candidate, self.scenarios, repository_root=ROOT,
                inputs=dict(command_inputs(), unapproved_predecessor_observations_sha256="b" * 64))

    def test_exact_full_mapping_digest_and_unchanged_nonruntime_fields(self):
        record = self.records["installed.task10-workflow"]
        predecessors = self.predecessors(record)
        resolved = self.resolve(record, predecessors)
        expected_digest = canonical_sha256([to_primitive(item) for item in predecessors])
        self.assertEqual(resolved.static_record_sha256, canonical_sha256(record))
        self.assertEqual(resolved.runtime_resolution.resolved_command_record_sha256, canonical_sha256(resolved.record))
        before, after = to_primitive(record), to_primitive(resolved.record)
        before.pop("argv"); after.pop("argv")
        self.assertEqual(before, after)
        indexes = {slot.argv_index for slot in record.runtime_argument_slots}
        for index, value in enumerate(resolved.record.argv):
            self.assertEqual(value, expected_digest if index in indexes else record.argv[index])
        self.assertEqual(resolved.runtime_resolution.bindings[0].value, expected_digest)

    def test_two_sequential_records_keep_one_plan_without_future_receipt_cycle(self):
        first, second = self.records["installed.task10-workflow"], self.records["installed.accessibility-semantics"]
        plan_hash, first_static, second_static = command_plan_sha256(self.plan), canonical_sha256(first), canonical_sha256(second)
        results = []
        for variant in ("one", "two"):
            first_result = self.resolve(first, self.predecessors(first, variant))
            # This receipt-shaped identity contains already known P/S/R only;
            # it never requires the later accessibility receipt's hash.
            first_receipt_hash = canonical_sha256({"command_plan_sha256": plan_hash,
                "command_record_sha256": first_static, "runtime_resolution": to_primitive(first_result.runtime_resolution)})
            second_result = self.resolve(second, (CommandPrerequisiteExpectation(first.command_id, "task10-receipt",
                first_receipt_hash, self.qualification_run.run_id, self.qualification_run.nonce),))
            self.assertEqual(second_result.static_record_sha256, second_static)
            self.assertEqual(first_result.static_record_sha256, first_static)
            results.append((first_result.runtime_resolution, second_result.runtime_resolution))
        self.assertNotEqual(results[0][0], results[1][0])
        self.assertNotEqual(results[0][1], results[1][1])
        self.assertEqual(command_plan_sha256(self.plan), plan_hash)

    def test_no_slot_record_and_external_candidate_are_not_fabricated_receipts(self):
        record = next(record for record in self.plan.commands if not record.runtime_argument_slots
                      and EXTERNAL_PREREQUISITE_IDS.intersection(record.prerequisite_ids))
        result = self.resolve(record)
        self.assertEqual(result.record, record)
        self.assertEqual(result.runtime_resolution.bindings, ())
        self.assertEqual(result.static_record_sha256, result.runtime_resolution.resolved_command_record_sha256)
        extra = CommandPrerequisiteExpectation("candidate-identity-accepted", "fabricated", "a" * 64,
                                               self.qualification_run.run_id, self.qualification_run.nonce)
        with self.assertRaises(RuntimeResolutionError): self.resolve(record, self.predecessors(record) + (extra,))

    def test_predecessor_closure_order_identity_and_run_are_strict(self):
        record = self.records["installed.task10-workflow"]
        predecessors = self.predecessors(record)
        bad_cases = ((), predecessors[::-1], predecessors + predecessors[:1],
                     (replace(predecessors[0], command_id="foreign"), *predecessors[1:]),
                     (replace(predecessors[0], receipt_id=predecessors[1].receipt_id), *predecessors[1:]),
                     (replace(predecessors[0], canonical_sha256="z" * 64), *predecessors[1:]),
                     (replace(predecessors[0], qualification_run_id="other-run"), *predecessors[1:]),
                     (replace(predecessors[0], qualification_run_nonce="b" * 64), *predecessors[1:]),
                     list(predecessors), tuple(to_primitive(item) for item in predecessors))
        for bad in bad_cases:
            with self.subTest(bad=bad), self.assertRaises(RuntimeResolutionError): self.resolve(record, bad)
        with self.assertRaises(RuntimeResolutionError): self.resolve(record, run=QualificationRunAuthority("bad run", "a" * 64))

    def test_slots_reject_unknown_duplicate_boolean_out_of_bounds_and_marker_drift(self):
        record = self.records["installed.task10-workflow"]
        slot = record.runtime_argument_slots[0]
        cases = ((), (slot, slot), (RuntimeArgumentSlot(True, slot.kind),),
                 (RuntimeArgumentSlot(-1, slot.kind),), (RuntimeArgumentSlot(len(record.argv), slot.kind),),
                 (RuntimeArgumentSlot(slot.argv_index, "unknown"),), [slot])
        for slots in cases:
            with self.subTest(slots=slots), self.assertRaises(RuntimeResolutionError):
                self.resolve(replace(record, runtime_argument_slots=slots))
        argv = list(record.argv); argv[slot.argv_index] = "a" * 64
        with self.assertRaises(RuntimeResolutionError): self.resolve(replace(record, argv=tuple(argv)))
        with self.assertRaises(RuntimeResolutionError): self.resolve(replace(record, prerequisite_ids=()))
        with self.assertRaises(RuntimeResolutionError): self.resolve(replace(record, schema_version=2))

    def test_static_validator_rejects_nonruntime_mutation(self):
        original = self.records["installed.task10-workflow"]
        for changed in (replace(original, working_directory="/tmp/substitution"),
                        replace(original, environment=(("FOREIGN", "1"),)),
                        replace(original, generated_artifacts=("/tmp/substitution",)),
                        replace(original, argv=("/bin/false",) + original.argv[1:])):
            plan = replace(self.plan, commands=tuple(changed if item.command_id == changed.command_id else item for item in self.plan.commands))
            self.assertTrue(validate_command_plan(plan, candidate=self.candidate, scenario_catalog=self.scenarios,
                repository_root=ROOT, templates={item.command_id: item for item in command_templates()}))

    def test_runtime_placeholders_cannot_be_embedded_or_move_to_nonargv_fields(self):
        template = next(item for item in command_templates() if item.command_id == "installed.task10-workflow")
        marker = "@installed_task10_predecessor_observations_sha256@"
        for changed in (replace(template, argv=("prefix" + marker,)),
                        replace(template, working_directory=marker),
                        replace(template, environment=(("X", marker),)),
                        replace(template, generated_artifacts=(marker,)),
                        replace(template, generated_logs=(marker,))):
            with self.assertRaises(CommandCompilationError): required_command_input_names((changed,))


if __name__ == "__main__": unittest.main()
