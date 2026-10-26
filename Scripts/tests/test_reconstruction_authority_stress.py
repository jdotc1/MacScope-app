from __future__ import annotations

import dataclasses
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from Scripts.reconstruction import run_authority_stress as harness
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.scenario_model import ScenarioParameter
from Scripts.reconstruction_gate_f.tests import parsed_candidate


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/reconstruction/run_authority_stress_tests.sh"
SWIFT_TEST = (
    ROOT
    / "MacScope/Tests/CoreTests/ReconstructionAuthorityRaceStressTests.swift"
)
QUALIFICATION_RUN = harness.QualificationRunAuthority(
    run_id="gate-f-qualification-20260828",
    nonce="9" * 64,
)


class ReconstructionAuthorityStressHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.candidate = parsed_candidate()

    def test_plan_exactly_covers_compiled_stress_catalog_each_iteration(self) -> None:
        catalog = compile_scenario_catalog(self.candidate)
        expected_ids = tuple(
            item.scenario_id
            for item in catalog.scenarios
            if harness.STRESS_COMMAND_GROUP in item.command_groups
        )

        plan = harness.compile_authority_stress_plan(self.candidate, repetitions=3)

        self.assertEqual(len(expected_ids), 49)
        self.assertEqual(len(plan.invocations), 147)
        for iteration in range(3):
            self.assertEqual(
                tuple(
                    item.scenario_id
                    for item in plan.invocations
                    if item.iteration == iteration
                ),
                expected_ids,
            )

    def test_seeds_are_deterministic_unique_and_nonnegative(self) -> None:
        first = harness.compile_authority_stress_plan(
            self.candidate,
            repetitions=4,
        )
        second = harness.compile_authority_stress_plan(
            self.candidate,
            repetitions=4,
        )
        first_seeds = tuple(item.seed for item in first.invocations)
        second_seeds = tuple(item.seed for item in second.invocations)

        self.assertEqual(first_seeds, second_seeds)
        self.assertEqual(len(first_seeds), len(set(first_seeds)))
        self.assertTrue(all(0 <= seed <= harness.MAX_SEED for seed in first_seeds))

    def test_missing_compiler_scenario_is_rejected(self) -> None:
        catalog = compile_scenario_catalog(self.candidate)
        removed = next(
            item
            for item in catalog.scenarios
            if harness.STRESS_COMMAND_GROUP in item.command_groups
        )
        malformed = dataclasses.replace(
            catalog,
            scenarios=tuple(
                item
                for item in catalog.scenarios
                if item.scenario_id != removed.scenario_id
            ),
        )

        with mock.patch.object(
            harness,
            "compile_scenario_catalog",
            return_value=malformed,
        ), self.assertRaisesRegex(
            harness.StressHarnessError,
            "missing-required-scenario",
        ):
            harness.compile_authority_stress_plan(self.candidate)

    def test_duplicate_compiler_scenario_is_rejected(self) -> None:
        catalog = compile_scenario_catalog(self.candidate)
        duplicate = next(
            item
            for item in catalog.scenarios
            if harness.STRESS_COMMAND_GROUP in item.command_groups
        )
        malformed = dataclasses.replace(
            catalog,
            scenarios=tuple(
                sorted(
                    catalog.scenarios + (duplicate,),
                    key=lambda item: item.scenario_id,
                )
            ),
        )

        with mock.patch.object(
            harness,
            "compile_scenario_catalog",
            return_value=malformed,
        ), self.assertRaisesRegex(
            harness.StressHarnessError,
            "duplicate-scenario",
        ):
            harness.compile_authority_stress_plan(self.candidate)

    def test_adapter_vocabulary_is_closed_and_dispatch_is_structural(self) -> None:
        catalog = compile_scenario_catalog(self.candidate)
        scenarios = harness._stress_scenarios(catalog)
        plan = harness.compile_authority_stress_plan(self.candidate)
        allowed = {item.value for item in harness.StressAdapter}

        self.assertEqual(set(plan.adapters), allowed)
        self.assertTrue(
            all(item.adapter.value in allowed for item in plan.invocations)
        )
        python_cases = tuple(
            item
            for item in plan.invocations
            if item.adapter is harness.StressAdapter.PYTHON_EVIDENCE_MOVEMENT
        )
        self.assertEqual(len(python_cases), 1)
        self.assertEqual(
            python_cases[0].scenario_id,
            "race.merge-tool-movement-stale-evidence",
        )
        self.assertEqual(
            {name for name, _ in python_cases[0].parameters},
            {"candidate", "evidence", "merge", "toolchain"},
        )
        composite_cases = tuple(
            item
            for item in plan.invocations
            if item.adapter is harness.StressAdapter.SWIFT_PAIRWISE_COMPOSITE
        )
        self.assertEqual(len(composite_cases), 26)
        self.assertEqual(
            {item.semantic_axes for item in composite_cases},
            {("batch-scheduler-provider-pairwise-composite",)},
        )
        self.assertTrue(
            all(item.scenario_id.startswith("matrix.pairwise.") for item in composite_cases)
        )

        malformed = dataclasses.replace(
            plan,
            invocations=(
                dataclasses.replace(plan.invocations[0], adapter="shell"),
                *plan.invocations[1:],
            ),
        )
        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "unknown stress adapter",
        ):
            harness.validate_authority_stress_plan(
                malformed,
                scenarios=scenarios,
            )

    def test_pairwise_composite_rejects_an_uncovered_combination(self) -> None:
        catalog = compile_scenario_catalog(self.candidate)
        target = next(
            item
            for item in catalog.scenarios
            if item.scenario_id.startswith("matrix.pairwise.")
        )
        parameters = tuple(
            ScenarioParameter(item.name, "uncovered")
            if item.name == "authority"
            else item
            for item in target.parameters
        )
        changed = dataclasses.replace(target, parameters=parameters)

        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "pairwise composite adapter has an uncovered combination.*authority=uncovered",
        ):
            harness._semantic_contract(
                changed,
                harness.StressAdapter.SWIFT_PAIRWISE_COMPOSITE,
            )

    def test_duplicate_execution_adapter_requires_an_explicit_alias(self) -> None:
        catalog = compile_scenario_catalog(self.candidate)
        scenarios = harness._stress_scenarios(catalog)
        correct = next(
            item
            for item in scenarios
            if item.scenario_id == "durable.correct-job-bound-scheduling"
        )
        session = next(
            item
            for item in scenarios
            if item.scenario_id == "durable.concurrent-session-resolution-coalesces"
        )
        aliased = dataclasses.replace(correct, parameters=session.parameters)
        changed = tuple(
            aliased if item.scenario_id == correct.scenario_id else item
            for item in scenarios
        )

        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "duplicate stress execution adapter without explicit alias.*"
            "durable.concurrent-session-resolution-coalesces.*"
            "durable.correct-job-bound-scheduling",
        ):
            harness._validate_duplicate_execution_adapters(changed)

    def test_python_adapter_rejects_stale_evidence_after_all_identity_movement(self) -> None:
        plan = harness.compile_authority_stress_plan(
            self.candidate,
            repetitions=2,
        )

        results = harness.execute_python_adapters(
            plan,
            candidate=self.candidate,
            qualification_run=QUALIFICATION_RUN,
        )
        payload = harness.plan_mapping(plan)

        self.assertEqual(len(results), 2)
        self.assertEqual(
            len(harness.validate_python_results(payload, list(results))),
            2,
        )
        self.assertEqual({item["status"] for item in results}, {"passed"})
        for result in results:
            self.assertEqual(
                result["scenario_id"],
                "race.merge-tool-movement-stale-evidence",
            )
            self.assertIn(
                "receipt-candidate-mismatch",
                result["validator_issue_codes"],
            )

        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "results differ from compiled attempts.*missing",
        ):
            harness.validate_python_results(payload, list(results[:-1]))

        wrong_seam = [dict(item) for item in results]
        wrong_seam[0]["observed_semantic_axes"] = ["wrong-seam"]
        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "wrong production seams",
        ):
            harness.validate_python_results(payload, wrong_seam)

    def test_python_adapter_fails_closed_if_validator_accepts_old_receipt(self) -> None:
        plan = harness.compile_authority_stress_plan(self.candidate)

        with mock.patch.object(
            harness,
            "validate_receipt",
            return_value=(),
        ), self.assertRaisesRegex(
            harness.StressHarnessError,
            "receipt validator accepted old evidence",
        ):
            harness.execute_python_adapters(
                plan,
                candidate=self.candidate,
                qualification_run=QUALIFICATION_RUN,
            )

    def test_python_adapter_requires_orchestrator_issued_run_authority(self) -> None:
        plan = harness.compile_authority_stress_plan(self.candidate)

        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "must be supplied by the coordinator",
        ):
            harness.execute_python_adapters(
                plan,
                candidate=self.candidate,
                qualification_run=None,
            )

    def test_predecessor_observations_are_closed_and_same_run(self) -> None:
        observation = {
            "command_id": harness.STRESS_PREDECESSOR_COMMAND_ID,
            "receipt_id": "receipt-full-coretests",
            "canonical_sha256": "8" * 64,
            "qualification_run_id": QUALIFICATION_RUN.run_id,
            "qualification_run_nonce": QUALIFICATION_RUN.nonce,
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "predecessors.json"
            path.write_bytes(harness.canonical_bytes([observation]))
            self.assertEqual(
                harness.load_predecessor_observations(
                    path,
                    qualification_run=QUALIFICATION_RUN,
                ),
                (observation,),
            )

            observation["qualification_run_nonce"] = "7" * 64
            path.write_bytes(harness.canonical_bytes([observation]))
            with self.assertRaisesRegex(
                harness.StressHarnessError,
                "belongs to another qualification run",
            ):
                harness.load_predecessor_observations(
                    path,
                    qualification_run=QUALIFICATION_RUN,
                )

    def test_terminal_reset_stale_revision_is_one_composite_seam(self) -> None:
        catalog = compile_scenario_catalog(self.candidate)
        scenarios = harness._stress_scenarios(catalog)
        plan = harness.compile_authority_stress_plan(self.candidate)
        target_index, target = next(
            (index, item)
            for index, item in enumerate(plan.invocations)
            if item.scenario_id == "race.cancel-terminal-reset-stale-revision"
        )

        self.assertEqual(
            target.semantic_axes,
            ("terminal-reset-stale-resolution-composite",),
        )
        swift = SWIFT_TEST.read_text(encoding="utf-8")
        self.assertIn(
            'case "terminal-reset-stale-resolution-composite":',
            swift,
        )
        self.assertIn(
            "try await exerciseTerminalResetStaleResolutionComposite(",
            swift,
        )
        self.assertIn("mode: .terminalAwaitingCancellation", swift)
        weakened = dataclasses.replace(
            target,
            semantic_axes=(
                "destination-session-authority",
                "xpc-event-sequencing",
            ),
        )
        invocations = list(plan.invocations)
        invocations[target_index] = weakened
        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "differs from compiler-owned semantics",
        ):
            harness.validate_authority_stress_plan(
                dataclasses.replace(plan, invocations=tuple(invocations)),
                scenarios=scenarios,
            )

    def test_swift_invocations_carry_only_the_closed_selector_and_environment(self) -> None:
        plan = harness.compile_authority_stress_plan(self.candidate)
        payload = harness.plan_mapping(plan)
        swift_cases = [
            item
            for item in payload["invocations"]
            if item["adapter"]
            in {item.value for item in harness.SWIFT_EXECUTABLE_ADAPTERS}
        ]

        self.assertEqual(len(swift_cases), 48)
        self.assertEqual(
            {item["swift"]["selector"] for item in swift_cases},
            {harness.SWIFT_TEST_SELECTOR},
        )
        self.assertEqual(
            {
                key
                for item in swift_cases
                for key in item["swift"]["environment"]
            },
            {
                "MACSCOPE_RECONSTRUCTION_STRESS_ADAPTER",
                "MACSCOPE_RECONSTRUCTION_STRESS_PARAMETERS_JSON",
                "MACSCOPE_RECONSTRUCTION_STRESS_SCENARIO_ID",
                "MACSCOPE_RECONSTRUCTION_STRESS_SEED",
                "MACSCOPE_RECONSTRUCTION_STRESS_SEMANTIC_AXES_JSON",
            },
        )

        swift = SWIFT_TEST.read_text(encoding="utf-8")
        composite_start = swift.index(
            "    private func exerciseBatchSchedulerProviderAuthority("
        )
        composite_end = swift.index(
            "    private func exerciseBudgetBoundary(",
            composite_start,
        )
        composite = swift[composite_start:composite_end]
        self.assertIn("ReconstructionAnalysisProviderPool(", composite)
        self.assertIn("ReconstructionBatchScheduler(", composite)
        self.assertIn("AuthorityRaceStressCompositeBatchExecutor(", composite)
        self.assertIn(".jobAuthorityMismatch(", composite)
        self.assertIn("[.staleAuthority]", composite)
        self.assertIn(
            'case "batch-scheduler-job-authority":',
            swift,
        )
        self.assertIn(
            "try await exerciseBatchSchedulerJobAuthority(configuration)",
            swift,
        )

    def test_semantic_contract_is_fully_executable_and_fails_closed(self) -> None:
        plan = harness.compile_authority_stress_plan(self.candidate)
        payload = harness.plan_mapping(plan)
        statuses = [item["semantic_status"] for item in payload["invocations"]]

        self.assertEqual(statuses, ["fully-executable"] * len(statuses))
        self.assertTrue(all(not item["semantic_gaps"] for item in payload["invocations"]))
        self.assertTrue(all(item["semantic_axes"] for item in payload["invocations"]))

        pairwise = [
            item
            for item in payload["invocations"]
            if item["scenario_id"].startswith("matrix.pairwise.")
        ]
        self.assertEqual(len(pairwise), 26)
        self.assertEqual(
            {item["adapter"] for item in pairwise},
            {harness.StressAdapter.SWIFT_PAIRWISE_COMPOSITE.value},
        )
        self.assertEqual(
            {tuple(item["semantic_axes"]) for item in pairwise},
            {("batch-scheduler-provider-pairwise-composite",)},
        )

        catalog = compile_scenario_catalog(self.candidate)
        target = next(
            item
            for item in catalog.scenarios
            if item.scenario_id == "race.task10-old-scope-late-completion"
        )
        changed = dataclasses.replace(
            target,
            parameters=tuple(sorted(
                target.parameters
                + (ScenarioParameter("unhandled-axis", "new-value"),)
            )),
        )
        malformed = dataclasses.replace(
            catalog,
            scenarios=tuple(
                changed if item.scenario_id == target.scenario_id else item
                for item in catalog.scenarios
            ),
        )
        with mock.patch.object(
            harness,
            "compile_scenario_catalog",
            return_value=malformed,
        ), self.assertRaisesRegex(
            harness.StressHarnessError,
            "no closed Swift production seam.*unhandled-axis",
        ):
            harness.compile_authority_stress_plan(self.candidate)

    def test_swift_attempt_ledger_requires_every_exact_attempt_and_seam(self) -> None:
        plan = harness.plan_mapping(
            harness.compile_authority_stress_plan(self.candidate, repetitions=2)
        )
        expected = [
            {
                "iteration": item["iteration"],
                "observed_semantic_axes": item["semantic_axes"],
                "scenario_id": item["scenario_id"],
                "seed": item["seed"],
                "status": "passed",
            }
            for item in plan["invocations"]
            if item["adapter"]
            in {adapter.value for adapter in harness.SWIFT_EXECUTABLE_ADAPTERS}
        ]
        ledger = {"attempts": expected, "schema_version": 1}
        self.assertEqual(
            len(harness.validate_swift_attempt_ledger(plan, ledger)),
            len(expected),
        )

        omitted = {"attempts": expected[:-1], "schema_version": 1}
        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "ledger differs from compiled attempts.*missing",
        ):
            harness.validate_swift_attempt_ledger(plan, omitted)

        wrong_seam = {
            "attempts": [dict(item) for item in expected],
            "schema_version": 1,
        }
        wrong_seam["attempts"][0]["observed_semantic_axes"] = ["wrong-seam"]
        with self.assertRaisesRegex(
            harness.StressHarnessError,
            "wrong production seams",
        ):
            harness.validate_swift_attempt_ledger(plan, wrong_seam)

    def test_repeatable_runner_executes_one_manifest_bound_xcode_pass(self) -> None:
        runner = RUNNER.read_text(encoding="utf-8")
        swift = SWIFT_TEST.read_text(encoding="utf-8")
        self.assertTrue(RUNNER.stat().st_mode & 0o111)
        self.assertEqual(runner.count("xcodebuild test-without-building"), 1)
        self.assertIn('"MACSCOPE_RECONSTRUCTION_STRESS_PLAN": str(plan)', runner)
        self.assertIn('"MACSCOPE_RECONSTRUCTION_STRESS_LEDGER": str(ledger)', runner)
        self.assertIn('(\"EnvironmentVariables\", \"TestingEnvironmentVariables\")', runner)
        self.assertIn('-xctestrun "$execution_xctestrun"', runner)
        self.assertIn('--preparation-receipt ABSOLUTE_PATH', runner)
        self.assertIn('"$preparation_validator" validate', runner)
        self.assertLess(
            runner.index('"$preparation_validator" validate'),
            runner.index('/bin/mkdir "$artifact_root"'),
        )
        self.assertLess(
            runner.index('"$preparation_validator" validate'),
            runner.index('xcodebuild test-without-building'),
        )
        self.assertIn("MACSCOPE_AUTHORITY_STRESS_XCTESTRUN=", runner)
        self.assertNotIn("observed = len(invocations)", runner)
        self.assertIn("--execute-python", runner)
        self.assertIn('--qualification-run-id "$qualification_run_id"', runner)
        self.assertIn('--qualification-run-nonce "$qualification_run_nonce"', runner)
        self.assertIn('"predecessor_observations_sha256": predecessor_observations_sha256', runner)
        self.assertIn('"schema_version": 2', runner)
        self.assertIn("MACSCOPE_AUTHORITY_STRESS_PLAN=", runner)
        self.assertIn("MACSCOPE_AUTHORITY_STRESS_TEST_RESULTS=", runner)
        self.assertIn("MACSCOPE_AUTHORITY_STRESS_REPORT=", runner)
        self.assertIn("MACSCOPE_AUTHORITY_STRESS_ATTEMPT_LEDGER=", runner)
        self.assertIn(
            'environment["MACSCOPE_RECONSTRUCTION_STRESS_PLAN"]',
            swift,
        )
        self.assertIn("for configuration in configurations", swift)


if __name__ == "__main__":
    unittest.main()
