"""The portable helper retains evidence; it does not claim a native campaign."""
import importlib.util
import copy
import unittest


class RetainedCampaignFixtureTests(unittest.TestCase):
    def fixture(self):
        name = "Scripts.reconstruction_gate_f.tests.retained_campaign_fixture"
        self.assertIsNotNone(importlib.util.find_spec(name), "retained evidence helper is absent")
        from .retained_campaign_fixture import RetainedCampaignFixture
        return RetainedCampaignFixture(self)

    def test_real_source_capture_public_emission_and_mutation_rejection(self):
        f = self.fixture()
        raw = f.source_receipt()
        self.assertEqual(raw.receipt["evidence_status"], "passed")
        self.assertEqual(f.validate(raw), ())
        self.assertGreater(raw.context.capture_admission.capture.capture_path.stat().st_size, 0)
        verified = f.source_receipt(predecessor=raw)
        self.assertEqual(f.validate(verified), ())
        target = f.repository / "Scripts/reconstruction_gate_f/command_execution.py"
        target.write_bytes(target.read_bytes() + b"\n# changed\n")
        with self.assertRaises(ValueError):
            f.source_receipt()

    def test_full_suite_physical_proof_rejects_changed_products(self):
        f = self.fixture()
        proof = f.full_suite_proof()
        self.assertEqual(proof["executed_selector_count"], 1)
        executable = f.build.app / "Contents/MacOS/MacScope"
        executable.write_bytes(b"substituted product")
        with self.assertRaises(ValueError):
            f.full_suite_proof()

    def test_transport_double_is_observed_and_does_not_invent_full_suite_predecessors(self):
        from Scripts.reconstruction_gate_f.command_capture import parse_capture
        f = self.fixture()
        raw = f.source_receipt()
        capture = f.capture("source.verify-sealed-export", predecessors=(raw,),
            stdout=b"explicit portable transport double\n")
        document = parse_capture(capture.capture_path.read_bytes()).to_mapping()
        self.assertGreater(document["process_observation"]["pid"], 0)
        self.assertEqual(document["terminal"]["exit_code"], 0)
        self.assertEqual(document["intent"]["prerequisite_receipts"],
            [["source.create-sealed-export", raw.receipt["canonical_sha256"]]])
        with self.assertRaisesRegex(ValueError, "prerequisite set differs"):
            f.full_suite_receipt(predecessors=())

    def test_same_run_foreign_candidate_and_plan_receipts_are_not_prerequisites(self):
        from .retained_campaign_fixture import RetainedCampaignFixture
        from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan
        from Scripts.reconstruction_gate_f.prerequisite_dag import LaneCIntegratedCommandPlanInput
        f = self.fixture()
        own = f.source_receipt()
        foreign = RetainedCampaignFixture(self, source_paths=("README.md",))
        foreign_raw = foreign.source_receipt()
        self.assertEqual(foreign.run, f.run)
        self.assertNotEqual(foreign.candidate, f.candidate)
        self.assertEqual(foreign.validate(foreign_raw), ())

        alternate = copy.copy(f)
        alternate.inputs = dict(f.inputs, source_export_root=str(f.root / "alternate-export"),
            hosted_governance_runner=str(f.root / "alternate-export/Scripts/ci/run_hosted_governance.py"))
        alternate_plan = compile_command_plan(f.candidate, f.integrated.scenario_catalog,
            repository_root=f.repository, inputs=alternate.inputs, profile=f.profile)
        alternate.integrated = LaneCIntegratedCommandPlanInput(alternate_plan,
            f.integrated.scenario_catalog, f.repository, alternate.inputs, f.integrated.templates)
        alternate_raw = alternate.source_receipt()
        self.assertEqual(alternate.validate(alternate_raw), ())
        self.assertEqual(alternate_raw.context.expected_candidate, f.candidate)
        self.assertNotEqual(alternate_raw.context.expected_command_plan_sha256,
            own.context.expected_command_plan_sha256)

        for raw in (foreign_raw, alternate_raw):
            with self.subTest(receipt_id=raw.context.expected_receipt_id):
                with self.assertRaisesRegex(ValueError, "predecessor.*(candidate|plan|profile)"):
                    f.capture("source.verify-sealed-export", predecessors=(raw,),
                        stdout=b"foreign authority must never reach transport\n")


if __name__ == "__main__":
    unittest.main()
