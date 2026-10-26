#!/usr/bin/env python3

from __future__ import annotations

import ast
import contextlib
import copy
import hashlib
import io
import inspect
from pathlib import Path
import unittest

from Scripts.reconstruction import (
    compile_installed_acceptance_gate_plan as compiler,
)
from Scripts.reconstruction import run_installed_acceptance_transaction as transaction
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.tests.test_compile_installed_acceptance_gate_plan import CompilerFixture


EXPECTED_GATE_IDS = (
    "cli",
    "forced-legacy-grid",
    "full-surface",
    "gui",
    "mcp",
    "native-xpc",
    "shellbroker-launchagent",
    "signing",
)
EXPECTED_DEPENDENCIES = {
    "cli": ("forced-legacy-grid", "full-surface", "native-xpc"),
    "forced-legacy-grid": (),
    "full-surface": (),
    "gui": ("forced-legacy-grid", "full-surface", "native-xpc"),
    "mcp": ("forced-legacy-grid", "full-surface", "native-xpc"),
    "native-xpc": (),
    "shellbroker-launchagent": (),
    "signing": EXPECTED_GATE_IDS[:-1],
}
EXPECTED_OPERATION_IDS = {
    "cli": "cli-gui-operability",
    "forced-legacy-grid": "renderer-dual",
    "full-surface": "renderer-dual",
    "gui": "cli-gui-operability",
    "mcp": "mcp-probe",
    "native-xpc": "native-xpc-probe",
    "shellbroker-launchagent": "shellbroker-launchagent-probe",
    "signing": "ws24-finalize",
}
EXPECTED_OPERATION_ORDER = (
    ("forced-legacy-grid", "full-surface"),
    ("native-xpc",),
    ("cli", "gui"),
    ("mcp",),
    ("shellbroker-launchagent",),
    ("signing",),
)
EXPECTED_TIMEOUTS = {
    "cli": 90,
    "forced-legacy-grid": 90,
    "full-surface": 90,
    "gui": 90,
    "mcp": 60,
    "native-xpc": 300,
    "shellbroker-launchagent": 1_860,
    "signing": 120,
}
EXPECTED_OUTPUTS = {
    "cli": Path("cli-gui-operability.report.json"),
    "forced-legacy-grid": Path("full-surface.legacy-grid.json"),
    "full-surface": Path("full-surface.json"),
    "gui": Path("cli-gui-operability.status.txt"),
    "mcp": Path("mcp-operability.report.json"),
    "native-xpc": Path(
        "native-xpc-artifacts/NativeDecompilerLiveXPC.execution-report.json"
    ),
    "shellbroker-launchagent": Path("live-evidence.json"),
    "signing": Path("WS24.installed-qualification.json"),
}


def _gate_specs(plan: dict[str, object]) -> tuple[transaction.GateSpec, ...]:
    specs = []
    for raw_gate in plan["gates"]:  # type: ignore[index]
        gate = raw_gate  # type: ignore[assignment]
        output = gate["output"]
        specs.append(
            transaction.GateSpec(
                gate_id=gate["gate_id"],
                operation_id=gate["operation_id"],
                argv=tuple(gate["argv"]),
                depends_on=tuple(gate["depends_on"]),
                environment=dict(gate["environment"]),
                timeout_seconds=gate["timeout_seconds"],
                output=transaction.GateOutput(
                    kind=output["kind"],
                    maximum_bytes=output["maximum_bytes"],
                    path=Path(output["path"]),
                ),
            )
        )
    return tuple(specs)


def _call_names_in_order(function: object) -> tuple[str, ...]:
    tree = ast.parse(inspect.getsource(function))
    calls: list[tuple[int, int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            calls.append((node.lineno, node.col_offset, node.func.id))
    return tuple(name for _line, _column, name in sorted(calls))


class InstalledAcceptancePlanDAGTests(unittest.TestCase):
    maxDiff = None

    def _compile_and_load(
        self, fixture: CompilerFixture
    ) -> tuple[dict[str, object], str]:
        inputs = fixture.inputs()
        first = compiler.compile_plan_document(inputs)
        second = compiler.compile_plan_document(inputs)
        self.assertEqual(canonical_bytes(first), canonical_bytes(second))

        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = compiler.main(fixture.arguments())
        self.assertEqual(result, 0, stderr.getvalue())
        self.assertEqual(stdout.getvalue(), f"{fixture.output}\n")
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(fixture.output.read_bytes(), canonical_bytes(first))
        loaded, digest = compiler.load_plan(fixture.output)
        self.assertEqual(loaded, first)
        self.assertEqual(
            digest,
            hashlib.sha256(fixture.output.read_bytes()).hexdigest(),
        )
        return loaded, digest

    def test_real_compiler_emits_exact_transaction_plan_dag(self) -> None:
        with CompilerFixture() as fixture:
            plan, _digest = self._compile_and_load(fixture)
            gates = {
                gate["gate_id"]: gate for gate in plan["gates"]  # type: ignore[index]
            }
            self.assertEqual(tuple(gates), EXPECTED_GATE_IDS)
            self.assertEqual(compiler.GATE_IDS, EXPECTED_GATE_IDS)
            self.assertEqual(transaction.REQUIRED_ACCEPTANCE_GATES, EXPECTED_GATE_IDS)

            authority_sha256 = plan["authority_sha256"]
            fixed_environment = {
                "LANG": "C",
                "LC_ALL": "C",
                "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256": authority_sha256,
                "NO_PROXY": "*",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "no_proxy": "*",
            }
            output_paths: set[Path] = set()
            for gate_id in EXPECTED_GATE_IDS:
                gate = gates[gate_id]
                self.assertEqual(gate["operation_id"], EXPECTED_OPERATION_IDS[gate_id])
                self.assertEqual(tuple(gate["depends_on"]), EXPECTED_DEPENDENCIES[gate_id])
                self.assertEqual(gate["timeout_seconds"], EXPECTED_TIMEOUTS[gate_id])
                self.assertEqual(gate["environment"], fixed_environment)
                self.assertEqual(gate["output"]["publication"], "create-only")
                output = Path(gate["output"]["path"])
                governed_root = (
                    fixture.qualification_output_root
                    if gate_id == "signing"
                    else fixture.evidence_root
                )
                self.assertEqual(
                    output.relative_to(governed_root), EXPECTED_OUTPUTS[gate_id]
                )
                self.assertNotIn(output, output_paths)
                output_paths.add(output)

            self.assertEqual(gates["forced-legacy-grid"]["argv"], gates["full-surface"]["argv"])
            self.assertEqual(gates["cli"]["argv"], gates["gui"]["argv"])
            operation_order = tuple(
                tuple(gate.gate_id for gate in members)
                for members in transaction._operation_order(_gate_specs(plan))
            )
            self.assertEqual(operation_order, EXPECTED_OPERATION_ORDER)

    def test_task10_is_transaction_prerequisite_and_shellbroker_live_input(self) -> None:
        with CompilerFixture() as fixture:
            plan, _digest = self._compile_and_load(fixture)
            gates = {
                gate["gate_id"]: gate for gate in plan["gates"]  # type: ignore[index]
            }
            authority = plan["authority"]
            network_root = fixture.evidence_root / "installed-task10-network"
            self.assertEqual(
                authority["installed_task10_network_artifact_root"],
                str(network_root),
            )
            self.assertEqual(network_root.name, "installed-task10-network")
            self.assertNotIn("InstalledTask10.network", str(network_root))
            self.assertFalse(
                any(
                    "task10" in gate["gate_id"].lower()
                    or "task10" in gate["operation_id"].lower()
                    for gate in gates.values()
                )
            )

            calls = _call_names_in_order(transaction.execute_transaction)
            self.assertLess(
                calls.index("_run_task10_prerequisite"),
                calls.index("_execute_gate_plan"),
            )
            shellbroker = gates["shellbroker-launchagent"]
            self.assertEqual(
                shellbroker["operation_id"], "shellbroker-launchagent-probe"
            )
            self.assertEqual(
                Path(shellbroker["argv"][2]),
                compiler.REPOSITORY_ROOT
                / "Scripts/reconstruction/emit_installed_live_evidence.py",
            )
            self.assertEqual(
                Path(shellbroker["output"]["path"]),
                fixture.evidence_root / "live-evidence.json",
            )
            argv = shellbroker["argv"]
            expected_task10_inputs = {
                "--matrix-receipt": authority[
                    "installed_task10_matrix_receipt_path"
                ],
                "--xcresult-semantic-manifest": authority[
                    "installed_task10_xcresult_semantic_manifest_path"
                ],
                "--network-artifact-root": str(network_root),
            }
            for flag, expected in expected_task10_inputs.items():
                self.assertEqual(argv[argv.index(flag) + 1], expected)

    def test_signing_is_final_ws24_aggregate_and_envelope_publisher(self) -> None:
        with CompilerFixture() as fixture:
            plan, _digest = self._compile_and_load(fixture)
            gates = {
                gate["gate_id"]: gate for gate in plan["gates"]  # type: ignore[index]
            }
            signing = gates["signing"]
            self.assertEqual(tuple(signing["depends_on"]), EXPECTED_GATE_IDS[:-1])
            self.assertEqual(signing["operation_id"], "ws24-finalize")
            self.assertEqual(
                Path(signing["argv"][2]),
                compiler.REPOSITORY_ROOT
                / "Scripts/ws24_emit_installed_qualification_report.py",
            )
            self.assertEqual(
                Path(signing["output"]["path"]),
                fixture.qualification_output_root
                / "WS24.installed-qualification.json",
            )
            argv = signing["argv"]
            envelope_values = [
                argv[index + 1]
                for index, token in enumerate(argv[:-1])
                if token == "--acceptance-gate-output"
            ]
            self.assertEqual(
                envelope_values,
                [
                    f"{gate_id}={fixture.qualification_output_root / (gate_id + '.acceptance-gate.json')}"
                    for gate_id in EXPECTED_GATE_IDS
                ],
            )
            self.assertEqual(
                tuple(
                    tuple(gate.gate_id for gate in members)
                    for members in transaction._operation_order(_gate_specs(plan))
                )[-1],
                ("signing",),
            )

    def test_real_loader_rejects_cycle_missing_dependency_and_duplicate_operation(self) -> None:
        def cycle(plan: dict[str, object]) -> None:
            gates = {
                gate["gate_id"]: gate for gate in plan["gates"]  # type: ignore[index]
            }
            gates["forced-legacy-grid"]["depends_on"] = ["signing"]
            gates["full-surface"]["depends_on"] = ["signing"]
            with self.assertRaisesRegex(transaction.TransactionError, "cycle"):
                transaction._operation_order(_gate_specs(plan))

        def missing_dependency(plan: dict[str, object]) -> None:
            gates = {
                gate["gate_id"]: gate for gate in plan["gates"]  # type: ignore[index]
            }
            for gate_id in ("cli", "gui"):
                gates[gate_id]["depends_on"] = [
                    "forced-legacy-grid",
                    "full-surface",
                    "missing-gate",
                    "native-xpc",
                ]

        def duplicate_operation(plan: dict[str, object]) -> None:
            gates = {
                gate["gate_id"]: gate for gate in plan["gates"]  # type: ignore[index]
            }
            gates["native-xpc"]["operation_id"] = "mcp-probe"

        for label, mutate in (
            ("cycle", cycle),
            ("missing dependency", missing_dependency),
            ("duplicate operation", duplicate_operation),
        ):
            with self.subTest(label=label), CompilerFixture() as fixture:
                plan, _digest = self._compile_and_load(fixture)
                mutated = copy.deepcopy(plan)
                mutate(mutated)
                fixture.output.write_bytes(canonical_bytes(mutated))
                with self.assertRaises(compiler.PlanCompilationError):
                    compiler.load_plan(fixture.output)


if __name__ == "__main__":
    unittest.main()
