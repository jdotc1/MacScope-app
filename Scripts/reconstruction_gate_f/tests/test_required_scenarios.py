from __future__ import annotations

import unittest

from Scripts.reconstruction_gate_f.scenario_compiler import (
    HIGHER_ORDER_SCENARIO_IDS,
    RECONSTRUCTION_JOB_STATES,
    REQUIRED_SCENARIO_IDS,
    TASK10_COMMANDS,
    TASK10_STATE_COMMAND_SCENARIO_IDS,
    commissioned_scenarios,
    higher_order_scenarios,
)
from Scripts.reconstruction_gate_f.scenario_model import ScenarioOrigin
from Scripts.reconstruction_gate_f.schema import EvidenceLayer


class GateFRequiredScenarioTests(unittest.TestCase):
    def test_task10_state_command_matrix_is_exactly_twelve_by_five(self) -> None:
        self.assertEqual(len(RECONSTRUCTION_JOB_STATES), 12)
        self.assertEqual(
            TASK10_COMMANDS,
            ("cancel", "create", "pause", "resume", "start"),
        )
        self.assertEqual(len(TASK10_STATE_COMMAND_SCENARIO_IDS), 60)
        self.assertEqual(
            TASK10_STATE_COMMAND_SCENARIO_IDS,
            tuple(
                sorted(
                    f"task10.command.{state}.{command}"
                    for state in RECONSTRUCTION_JOB_STATES
                    for command in TASK10_COMMANDS
                )
            ),
        )
        self.assertFalse(any("retry" in item or "retire" in item for item in TASK10_STATE_COMMAND_SCENARIO_IDS))
        matrix = {
            item.scenario_id: {parameter.name: parameter.value for parameter in item.parameters}
            for item in commissioned_scenarios()
            if item.scenario_id in TASK10_STATE_COMMAND_SCENARIO_IDS
        }
        self.assertEqual(
            matrix["task10.command.created.start"]["expected_availability"],
            "available",
        )
        self.assertEqual(
            matrix["task10.command.completed.start"]["expected_availability"],
            "unavailable-job-state",
        )
        self.assertEqual(
            matrix["task10.command.paused.resume"]["expected_availability"],
            "available",
        )
        self.assertEqual(
            matrix["task10.command.retrieving.create"]["expected_availability"],
            "available",
        )
        self.assertTrue(
            all(
                matrix[f"task10.command.{state}.create"]["expected_availability"]
                == "available"
                for state in RECONSTRUCTION_JOB_STATES
            )
        )

    def test_task8_closed_request_reply_and_event_discriminators_are_present(self) -> None:
        exact = {
            "task8.request.round",
            "task8.request.final-synthesis",
            "task8.reply.accepted",
            "task8.reply.rejected",
            "task8.event.round-candidate",
            "task8.event.final-candidate",
            "task8.event.usage",
            "task8.event.completed",
        }
        self.assertTrue(exact.issubset(REQUIRED_SCENARIO_IDS))
        observed = {item.scenario_id for item in commissioned_scenarios() if item.scenario_id in exact}
        self.assertEqual(observed, exact)

    def test_native_install_and_merge_commission_is_not_reduced(self) -> None:
        exact = {
            "native.governed-package-verification",
            "native.normal",
            "native.asan",
            "native.ubsan",
            "native.golden",
            "signed-xpc.complete",
            "signed-xpc.truncated",
            "signed-xpc.error",
            "signed-xpc.cancellation",
            "release.build",
            "release.strict-signing",
            "release.embedded-service-identities",
            "installed.source-binary-equality",
            "installed.launch-log",
            "installed.no-unauthorized-network-or-acquisition",
            "installed.task10.create",
            "installed.task10.start",
            "installed.task10.pause",
            "installed.task10.resume",
            "installed.task10.cancel",
            "installed.accessibility",
            "merge.candidate-head-differs-from-receipt",
            "merge.prospective-tree-differs",
            "merge.workflow-success-wrong-sha",
            "merge.governed-files-changed",
            "postmerge.source-installed-binary-differs",
            "postmerge.stale-after-dependency-toolchain-movement",
        }
        self.assertTrue(exact.issubset(REQUIRED_SCENARIO_IDS))

    def test_named_higher_order_race_catalog_is_exact(self) -> None:
        self.assertEqual(
            HIGHER_ORDER_SCENARIO_IDS,
            (
                "race.cancel-removal-release-skip",
                "race.cancel-terminal-reset-stale-revision",
                "race.concurrent-resolution-reset-foreign-window",
                "race.merge-tool-movement-stale-evidence",
                "race.protocol-duplicate-reordered-post-terminal",
                "race.resource-memory-processor-extreme-width",
                "race.task10-old-scope-late-completion",
            ),
        )

    def test_higher_order_race_authority_shapes_are_frozen(self) -> None:
        expected_parameters = {
            "race.cancel-removal-release-skip": {
                "cancellation": "during-removal",
                "release": "concurrent",
                "removal": "delayed",
                "waiter": "cancelled",
            },
            "race.cancel-terminal-reset-stale-revision": {
                "cancellation": "after-terminal",
                "publication": "terminal",
                "revision": "stale",
                "session": "reset-race",
            },
            "race.concurrent-resolution-reset-foreign-window": {
                "authority": "foreign-window",
                "resolution": "concurrent",
                "session": "reset-race",
            },
            "race.merge-tool-movement-stale-evidence": {
                "candidate": "moved",
                "evidence": "old",
                "merge": "prospective",
                "toolchain": "moved",
            },
            "race.protocol-duplicate-reordered-post-terminal": {
                "correlation": "exact",
                "event": "duplicate",
                "ordering": "reordered",
                "publication": "post-terminal",
            },
            "race.resource-memory-processor-extreme-width": {
                "memory": "extreme",
                "policy": "bounded",
                "processor": "extreme",
            },
            "race.task10-old-scope-late-completion": {
                "completion": "late",
                "generation": "repeated",
                "revision": "repeated",
                "scope": "old",
                "window": "replacement",
            },
        }
        scenarios = {item.scenario_id: item for item in higher_order_scenarios()}
        self.assertEqual(set(scenarios), set(expected_parameters))
        for scenario_id, expected in expected_parameters.items():
            with self.subTest(scenario=scenario_id):
                scenario = scenarios[scenario_id]
                self.assertEqual(scenario.origin, ScenarioOrigin.HIGHER_ORDER)
                self.assertEqual(
                    scenario.command_groups,
                    ("reconstruction-concurrency", "stress-recovery"),
                )
                self.assertEqual(
                    scenario.evidence_layers,
                    (EvidenceLayer.STRESS_RECOVERY, EvidenceLayer.XCODE_FOCUSED),
                )
                self.assertEqual(
                    {item.name: item.value for item in scenario.parameters},
                    expected,
                )

    def test_specialized_scenarios_use_truthful_executor_layers(self) -> None:
        scenarios = {item.scenario_id: item for item in commissioned_scenarios()}
        self.assertEqual(
            scenarios["task8.request.round"].evidence_layers,
            (EvidenceLayer.XCODE_FOCUSED,),
        )
        self.assertEqual(
            scenarios["task8.signed-worker-parity"].evidence_layers,
            (EvidenceLayer.SIGNED_XPC,),
        )
        self.assertEqual(
            scenarios["installed.no-unauthorized-network-or-acquisition"].evidence_layers,
            (EvidenceLayer.INSTALLED_WORKFLOW,),
        )


if __name__ == "__main__":
    unittest.main()
