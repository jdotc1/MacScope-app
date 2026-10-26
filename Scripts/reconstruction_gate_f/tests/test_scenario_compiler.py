from __future__ import annotations

import dataclasses
import unittest

from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256
from Scripts.reconstruction_gate_f.scenario_compiler import (
    PAIRWISE_FACTORS,
    REQUIRED_SCENARIO_IDS,
    ScenarioCompilationError,
    commissioned_scenarios,
    compile_pairwise_rows,
    compile_scenario_catalog,
    higher_order_scenarios,
    selector_catalog_identity_sha256,
)
from Scripts.reconstruction_gate_f.scenario_model import (
    SCENARIO_SCHEMA_VERSION,
    PairwiseFactor,
    ScenarioCatalog,
    ScenarioOrigin,
    scenario_catalog_sha256,
    validate_scenario_catalog,
)
from Scripts.reconstruction_gate_f.schema import EvidenceLayer, candidate_identity_sha256
from Scripts.reconstruction_gate_f.tests import parsed_candidate


EXPECTED_SELECTOR_CATALOG_IDENTITY_SHA256 = (
    "afa8cc8c58a099938ae1d7415431330ae0c6f9cca6add6f8033cc52d06dd757a"
)


class GateFScenarioCompilerTests(unittest.TestCase):
    def test_normalized_solver_reuses_immutable_rows(self) -> None:
        factors = (
            PairwiseFactor("memo-reuse-a", ("one", "two")),
            PairwiseFactor("memo-reuse-b", ("three", "four")),
        )
        normalized, rows = compile_pairwise_rows(factors)
        equivalent = (
            PairwiseFactor("memo-reuse-b", ("four", "three", "four")),
            PairwiseFactor("memo-reuse-a", ("two", "one", "two")),
        )
        repeated_normalized, repeated_rows = compile_pairwise_rows(iter(equivalent))
        self.assertEqual(normalized, repeated_normalized)
        self.assertIs(rows, repeated_rows)
        self.assertEqual(rows, (("one", "four"), ("one", "three"),
                                ("two", "four"), ("two", "three")))

    def test_solver_retention_is_bounded_to_eight_normalized_inputs(self) -> None:
        inputs = tuple(
            (PairwiseFactor(f"memo-bound-{index}-a", ("one", "two")),
             PairwiseFactor(f"memo-bound-{index}-b", ("three",)))
            for index in range(9)
        )
        rows_by_input = tuple(compile_pairwise_rows(factors)[1] for factors in inputs)
        first_rows = rows_by_input[0]
        for factors, retained_rows in zip(inputs[1:], rows_by_input[1:]):
            self.assertIs(retained_rows, compile_pairwise_rows(factors)[1])
        _, recomputed_rows = compile_pairwise_rows(inputs[0])
        self.assertEqual(first_rows, recomputed_rows)
        self.assertIsNot(first_rows, recomputed_rows)

    def test_warm_solver_does_not_bypass_input_normalization_or_rejection(self) -> None:
        factors = [PairwiseFactor("memo-validation-a", ("one",)),
                   PairwiseFactor("memo-validation-b", ("two",))]
        compile_pairwise_rows(factors)
        factors[1] = PairwiseFactor("memo-validation-a", ("two",))
        with self.assertRaisesRegex(ScenarioCompilationError, "at least two unique IDs"):
            compile_pairwise_rows(factors)
        factors[1] = PairwiseFactor("memo-validation-b", ())
        with self.assertRaisesRegex(ScenarioCompilationError, "must not be empty"):
            compile_pairwise_rows(factors)
        with self.assertRaisesRegex(ScenarioCompilationError, "at least two unique IDs"):
            compile_pairwise_rows(factors[:1])

    def test_solver_and_catalog_preserve_prechange_canonical_bytes(self) -> None:
        # Captured from the uncached solver before this performance correction.
        altered = tuple(
            dataclasses.replace(factor, values=factor.values + ("additional",))
            if index == 0 else factor
            for index, factor in enumerate(PAIRWISE_FACTORS)
        )
        duplicate_values = tuple(
            dataclasses.replace(factor, values=tuple(reversed(factor.values)) + factor.values[:1])
            for factor in reversed(PAIRWISE_FACTORS)
        )
        cases = (
            (PAIRWISE_FACTORS, "494cbd66a07ec4a53ba7308135faf166d8998d04c10eacfa3103479ddb119ee1"),
            (tuple(reversed(PAIRWISE_FACTORS)), "494cbd66a07ec4a53ba7308135faf166d8998d04c10eacfa3103479ddb119ee1"),
            (duplicate_values, "494cbd66a07ec4a53ba7308135faf166d8998d04c10eacfa3103479ddb119ee1"),
            (altered, "e957b2a6e03d911bc2502b67271e7bfcf528c3d585a2af2ba27bbb8d8dc05664"),
        )
        for factors, expected_digest in cases:
            for _ in range(2):
                with self.subTest(factors=factors):
                    self.assertEqual(canonical_sha256(compile_pairwise_rows(factors)), expected_digest)
        for factors in (PAIRWISE_FACTORS, tuple(reversed(PAIRWISE_FACTORS)), duplicate_values):
            self.assertEqual(
                canonical_sha256(compile_scenario_catalog(parsed_candidate(), factors=factors)),
                "c1a3310d9a8c49309839ebae8aa785d1c7f1b84553e8f5348d1667105716c16c",
            )
        with self.assertRaisesRegex(ScenarioCompilationError, "factors differ from the commissioned closed model"):
            compile_scenario_catalog(parsed_candidate(), factors=altered)

    def test_catalog_is_identity_bound_complete_and_valid(self) -> None:
        catalog = compile_scenario_catalog(parsed_candidate())
        self.assertEqual(validate_scenario_catalog(catalog), ())
        self.assertEqual(
            {item.scenario_id for item in catalog.scenarios}.issuperset(REQUIRED_SCENARIO_IDS),
            True,
        )
        self.assertEqual(len(catalog.required_scenario_ids), 183)
        self.assertGreater(len(catalog.scenarios), len(catalog.required_scenario_ids))
        self.assertEqual(len(catalog.pairwise_factors), 5)
        self.assertTrue(catalog.pairwise_coverage)

    def test_selector_catalog_identity_is_candidate_independent_but_shape_bound(self) -> None:
        first = selector_catalog_identity_sha256()
        self.assertEqual(first, EXPECTED_SELECTOR_CATALOG_IDENTITY_SHA256)
        self.assertEqual(first, selector_catalog_identity_sha256())
        self.assertNotEqual(first, scenario_catalog_sha256(compile_scenario_catalog(parsed_candidate())))

    def test_pairwise_rows_cover_every_value_pair(self) -> None:
        factors, rows = compile_pairwise_rows()
        observed = set()
        for row in rows:
            for left in range(len(factors)):
                for right in range(left + 1, len(factors)):
                    observed.add(
                        (
                            factors[left].factor_id,
                            row[left],
                            factors[right].factor_id,
                            row[right],
                        )
                    )
        expected = {
            (left.factor_id, left_value, right.factor_id, right_value)
            for index, left in enumerate(factors)
            for right in factors[index + 1 :]
            for left_value in left.values
            for right_value in right.values
        }
        self.assertEqual(observed, expected)

    def test_job_bound_scheduling_has_a_distinct_batch_scheduler_shape(self) -> None:
        scenarios = {
            item.scenario_id: item
            for item in commissioned_scenarios()
        }
        exact = scenarios["durable.correct-job-bound-scheduling"]
        foreign = scenarios["durable.foreign-job-authority-rejected"]
        session = scenarios["durable.concurrent-session-resolution-coalesces"]

        self.assertEqual(
            {(item.name, item.value) for item in exact.parameters},
            {("authority", "exact-job"), ("scheduler", "batch")},
        )
        self.assertEqual(
            {(item.name, item.value) for item in foreign.parameters},
            {("authority", "foreign-job"), ("scheduler", "batch")},
        )
        self.assertNotEqual(exact.parameters, session.parameters)

    def test_input_iteration_order_cannot_change_compiler_output(self) -> None:
        candidate = parsed_candidate()
        normal = compile_scenario_catalog(candidate)
        reversed_inputs = compile_scenario_catalog(
            candidate,
            factors=tuple(reversed(PAIRWISE_FACTORS)),
            commissioned=tuple(reversed(commissioned_scenarios())),
            higher_order=tuple(reversed(higher_order_scenarios())),
        )
        self.assertEqual(normal, reversed_inputs)
        self.assertEqual(scenario_catalog_sha256(normal), scenario_catalog_sha256(reversed_inputs))

    def test_higher_order_races_have_nonreducible_explanations(self) -> None:
        scenarios = higher_order_scenarios()
        self.assertEqual(len(scenarios), 7)
        for scenario in scenarios:
            with self.subTest(scenario=scenario.scenario_id):
                self.assertEqual(scenario.origin, ScenarioOrigin.HIGHER_ORDER)
                self.assertIsNotNone(scenario.higher_order_rationale)
                self.assertIn("Pairwise", scenario.higher_order_rationale)
                self.assertGreaterEqual(len(scenario.parameters), 3)

    def test_missing_commissioned_scenario_is_a_compilation_failure(self) -> None:
        reduced = tuple(
            item
            for item in commissioned_scenarios()
            if item.scenario_id != "durable.foreign-job-authority-rejected"
        )
        with self.assertRaisesRegex(
            ScenarioCompilationError,
            "missing-required-scenario.*durable.foreign-job-authority-rejected",
        ):
            compile_scenario_catalog(parsed_candidate(), commissioned=reduced)

    def test_required_higher_order_shape_cannot_be_reclassified_or_weakened(self) -> None:
        scenarios = list(higher_order_scenarios())
        scenarios[0] = dataclasses.replace(
            scenarios[0],
            origin=ScenarioOrigin.COMMISSIONED,
            higher_order_rationale=None,
            evidence_layers=(EvidenceLayer.HOSTED_PURE,),
            command_groups=("source-governance",),
        )
        with self.assertRaisesRegex(
            ScenarioCompilationError,
            "required-scenario-shape.*race.cancel-removal-release-skip",
        ):
            compile_scenario_catalog(parsed_candidate(), higher_order=scenarios)

    def test_empty_self_declared_catalog_is_invalid(self) -> None:
        empty = ScenarioCatalog(
            schema_version=SCENARIO_SCHEMA_VERSION,
            candidate_identity_sha256=candidate_identity_sha256(parsed_candidate()),
            scenarios=(),
            pairwise_factors=(),
            pairwise_coverage=(),
            required_scenario_ids=(),
        )
        self.assertTrue(
            {
                "empty-scenario-catalog",
                "empty-required-scenarios",
                "missing-pairwise-factors",
                "empty-pairwise-coverage",
            }.issubset({item.code for item in validate_scenario_catalog(empty)})
        )

    def test_pairwise_coverage_cannot_be_rebound_to_a_commissioned_scenario(self) -> None:
        catalog = compile_scenario_catalog(parsed_candidate())
        changed = dataclasses.replace(
            catalog,
            scenarios=tuple(
                item
                for item in catalog.scenarios
                if item.origin is not ScenarioOrigin.PAIRWISE
            ),
            pairwise_coverage=tuple(
                dataclasses.replace(
                    item,
                    scenario_id="durable.correct-job-bound-scheduling",
                )
                for item in catalog.pairwise_coverage
            ),
        )
        issues = validate_scenario_catalog(changed)
        self.assertIn("pairwise-coverage-owner", {item.code for item in issues})


if __name__ == "__main__":
    unittest.main()
