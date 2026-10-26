#!/usr/bin/env python3
"""Static hygiene checks for the canonical installed-acceptance handoff."""

from __future__ import annotations

import ast
from pathlib import Path
import re
from typing import Iterable
import unittest

from Scripts import ws24_emit_installed_qualification_report as ws24
from Scripts.reconstruction import (
    compile_installed_acceptance_gate_plan as compiler,
)
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import run_installed_acceptance_transaction as transaction
from Scripts.reconstruction import validate_final_local_candidate as final_validator


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ENTRYPOINT = REPOSITORY_ROOT / "Scripts/install_local_private_build.sh"
RECONSTRUCTION = REPOSITORY_ROOT / "Scripts/reconstruction"
INSTALLER = RECONSTRUCTION / "install_release_to_applications.py"
COMPILER = RECONSTRUCTION / "compile_installed_acceptance_gate_plan.py"
TRANSACTION = RECONSTRUCTION / "run_installed_acceptance_transaction.py"
FINAL_VALIDATOR = RECONSTRUCTION / "validate_final_local_candidate.py"
WS24_REPORT = REPOSITORY_ROOT / "Scripts/ws24_emit_installed_qualification_report.py"
TASK10_RUNNER = RECONSTRUCTION / "run_installed_task10_matrix.py"
NETWORK_AUDITOR = RECONSTRUCTION / "audit_installed_network_acquisition.py"
INCREMENTAL_EVIDENCE = (
    RECONSTRUCTION / "emit_installed_incremental_xcuitest_evidence.py"
)

CANONICAL_PYTHON_SCRIPTS = (
    INSTALLER,
    COMPILER,
    TRANSACTION,
    FINAL_VALIDATOR,
    WS24_REPORT,
    TASK10_RUNNER,
    NETWORK_AUDITOR,
    INCREMENTAL_EVIDENCE,
)
CANONICAL_GATE_IDS = (
    "cli",
    "forced-legacy-grid",
    "full-surface",
    "gui",
    "mcp",
    "native-xpc",
    "shellbroker-launchagent",
    "signing",
)
CANONICAL_NETWORK_ROOT = "installed-task10-network"
OBSOLETE_REPORT_FLAGS = (
    "--installation-operation-report",
    "--installation-source-equality-report",
    "--installation-execution-report",
)
NETWORK_ROOT_SEGMENT = re.compile(
    r"(?<![A-Za-z0-9_])installed[._-]?task10[._-]?network(?![A-Za-z0-9_-])",
    re.IGNORECASE,
)


def _source(path: Path) -> str:
    if not path.is_file():
        raise AssertionError(f"canonical installed-acceptance script is missing: {path}")
    return path.read_text(encoding="utf-8")


def _tree(path: Path) -> ast.Module:
    return ast.parse(_source(path), filename=str(path))


def _existing(paths: Iterable[Path]) -> tuple[Path, ...]:
    """Let the completeness test own missing-file diagnostics without masking drift."""
    return tuple(path for path in paths if path.is_file())


def _assigned_value(tree: ast.Module, name: str) -> ast.expr | None:
    for statement in tree.body:
        if isinstance(statement, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == name
            for target in statement.targets
        ):
            return statement.value
        if (
            isinstance(statement, ast.AnnAssign)
            and isinstance(statement.target, ast.Name)
            and statement.target.id == name
        ):
            return statement.value
    return None


def _argparse_flags(tree: ast.Module) -> Iterable[tuple[str, bool]]:
    for node in ast.walk(tree):
        if (
            not isinstance(node, ast.Call)
            or not isinstance(node.func, ast.Attribute)
            or node.func.attr != "add_argument"
        ):
            continue
        required = next(
            (
                keyword.value.value
                for keyword in node.keywords
                if keyword.arg == "required"
                and isinstance(keyword.value, ast.Constant)
                and isinstance(keyword.value.value, bool)
            ),
            False,
        )
        for argument in node.args:
            if (
                isinstance(argument, ast.Constant)
                and isinstance(argument.value, str)
                and argument.value.startswith("--")
            ):
                yield argument.value, required


def _call_offsets(function: ast.FunctionDef) -> dict[str, int]:
    offsets: dict[str, int] = {}
    for node in ast.walk(function):
        if not isinstance(node, ast.Call):
            continue
        if isinstance(node.func, ast.Name):
            offsets.setdefault(node.func.id, node.lineno)
        elif isinstance(node.func, ast.Attribute):
            offsets.setdefault(node.func.attr, node.lineno)
    return offsets


def _named_tuple_routes(
    tree: ast.Module, *, function_name: str, assignment_name: str
) -> dict[str, str]:
    function = next(
        (
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == function_name
        ),
        None,
    )
    if function is None:
        raise AssertionError(f"missing contract function: {function_name}")
    assignment = next(
        (
            node
            for node in ast.walk(function)
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == assignment_name
                for target in node.targets
            )
        ),
        None,
    )
    if assignment is None or not isinstance(assignment.value, (ast.List, ast.Tuple)):
        raise AssertionError(
            f"{function_name} does not define literal {assignment_name} routes"
        )
    routes: dict[str, str] = {}
    for item in assignment.value.elts:
        if (
            not isinstance(item, (ast.List, ast.Tuple))
            or len(item.elts) != 2
            or not isinstance(item.elts[0], ast.Constant)
            or not isinstance(item.elts[0].value, str)
        ):
            raise AssertionError(f"{assignment_name} contains a nonliteral route")
        gate_id = item.elts[0].value
        if gate_id in routes:
            raise AssertionError(f"{assignment_name} duplicates gate {gate_id}")
        routes[gate_id] = ast.unparse(item.elts[1])
    return routes


class InstalledAcceptanceContractHygieneTests(unittest.TestCase):
    def test_canonical_script_set_is_complete_and_python_is_parseable(self) -> None:
        self.assertTrue(ENTRYPOINT.is_file(), f"missing entrypoint: {ENTRYPOINT}")
        for path in CANONICAL_PYTHON_SCRIPTS:
            with self.subTest(path=path.relative_to(REPOSITORY_ROOT)):
                _tree(path)

    def test_network_root_has_one_lowercase_hyphenated_spelling(self) -> None:
        sources = {
            path: _source(path)
            for path in _existing((*CANONICAL_PYTHON_SCRIPTS, ENTRYPOINT))
        }
        for path, source in sources.items():
            with self.subTest(path=path.relative_to(REPOSITORY_ROOT)):
                self.assertNotIn("InstalledTask10.network", source)
                for match in NETWORK_ROOT_SEGMENT.finditer(source):
                    self.assertEqual(
                        match.group(0),
                        CANONICAL_NETWORK_ROOT,
                        f"{path.name} contains a noncanonical Task10 network-root segment",
                    )

        for path, assignment_name in (
            (TRANSACTION, "TASK10_NETWORK_ROOT_NAME"),
            (INCREMENTAL_EVIDENCE, "NETWORK_ROOT_NAME"),
        ):
            value = _assigned_value(_tree(path), assignment_name)
            self.assertIsInstance(value, ast.Constant)
            self.assertEqual(value.value, CANONICAL_NETWORK_ROOT)

    def test_obsolete_installer_report_flags_are_absent(self) -> None:
        source = "\n".join(
            _source(path)
            for path in _existing((*CANONICAL_PYTHON_SCRIPTS, ENTRYPOINT))
        )
        for flag in OBSOLETE_REPORT_FLAGS:
            self.assertNotIn(flag, source, f"obsolete installed-report flag survived: {flag}")

    def test_stdout_status_is_never_selected_as_governed_gate_evidence(self) -> None:
        captured = {
            gate_id
            for gate_id, kind in compiler.FIXED_OUTPUT_KINDS.items()
            if kind == "captured-stdout"
        }
        self.assertEqual(captured, {"gui"})
        self.assertEqual(
            compiler.PRIMARY_OUTPUT_RELATIVE_PATHS["gui"],
            Path("cli-gui-operability.status.txt"),
        )
        self.assertEqual(
            compiler.FIXED_OUTPUT_KINDS["cli"],
            "command-file",
        )
        self.assertEqual(
            compiler.PRIMARY_OUTPUT_RELATIVE_PATHS["cli"],
            Path("cli-gui-operability.report.json"),
        )

        evidence_root = Path("/private/tmp/macscope-contract-hygiene")
        snapshots = {
            gate_id: transaction.FileSnapshot(
                path=(
                    evidence_root
                    / compiler.PRIMARY_OUTPUT_RELATIVE_PATHS[gate_id]
                ),
                metadata=(0, 0, 0o600, 1, 1, 1, 1),
                payload=b"x",
                sha256="0" * 64,
            )
            for gate_id in compiler.GATE_IDS
        }
        inputs = transaction._ws24_inputs(
            tuple((gate_id, snapshots[gate_id]) for gate_id in compiler.GATE_IDS)
        )
        self.assertIs(inputs.cli_gui, snapshots["cli"])
        self.assertIsNot(inputs.cli_gui, snapshots["gui"])

        evidence_routes = _named_tuple_routes(
            _tree(FINAL_VALIDATOR),
            function_name="_validate_transaction_result",
            assignment_name="gate_evidence_files",
        )
        self.assertEqual(tuple(evidence_routes), CANONICAL_GATE_IDS)
        self.assertEqual(evidence_routes["cli"], "cli_gui_report")
        self.assertEqual(evidence_routes["gui"], "cli_gui_report")
        self.assertEqual(evidence_routes["signing"], "ws24_aggregate")
        self.assertNotEqual(evidence_routes["gui"], "outputs_by_gate['gui']")
        self.assertNotEqual(evidence_routes["signing"], "outputs_by_gate['signing']")

    def test_authority_bearing_arguments_cannot_be_optional(self) -> None:
        sensitive = re.compile(
            r"^--(?:source-app$|signing(?:-|$)|gate-timeout(?:-|$))"
        )
        observed: list[tuple[Path, str]] = []
        for path in _existing(CANONICAL_PYTHON_SCRIPTS):
            for flag, required in _argparse_flags(_tree(path)):
                if sensitive.match(flag):
                    observed.append((path, flag))
                    self.assertTrue(
                        required,
                        f"{path.name} leaves authority-bearing {flag} optional",
                    )
        self.assertIn((WS24_REPORT, "--source-app"), observed)

        entrypoint = _source(ENTRYPOINT)
        for seen_name in (
            "SEEN_SIGNING",
            "SEEN_BEGIN_TIMEOUT",
            "SEEN_COMPILER_TIMEOUT",
            "SEEN_REPORT_TIMEOUT",
            "SEEN_COMMIT_TIMEOUT",
            "SEEN_ROLLBACK_TIMEOUT",
        ):
            self.assertRegex(
                entrypoint,
                rf"\(\({seen_name}\s*==\s*1\)\)\s*\|\|\s*usage_error",
                f"installed-acceptance entrypoint does not require {seen_name}",
            )

    def test_every_gate_id_authority_is_the_exact_canonical_eight(self) -> None:
        gate_sequences = {
            "installer": installer.REQUIRED_ACCEPTANCE_GATES,
            "compiler": compiler.GATE_IDS,
            "transaction": transaction.REQUIRED_ACCEPTANCE_GATES,
            "WS24": ws24.REQUIRED_ACCEPTANCE_GATES,
        }
        for authority, gate_ids in gate_sequences.items():
            with self.subTest(authority=authority):
                self.assertEqual(tuple(gate_ids), CANONICAL_GATE_IDS)
                self.assertEqual(len(set(gate_ids)), 8)

        gate_mappings = {
            "compiler timeouts": compiler.FIXED_TIMEOUTS,
            "compiler dependencies": compiler.FIXED_DEPENDENCIES,
            "compiler operations": compiler.FIXED_OPERATION_IDS,
            "compiler output kinds": compiler.FIXED_OUTPUT_KINDS,
            "compiler output bounds": compiler.FIXED_OUTPUT_MAXIMUM_BYTES,
            "compiler output paths": compiler.PRIMARY_OUTPUT_RELATIVE_PATHS,
            "transaction output bounds": transaction.GATE_OUTPUT_MAXIMUM_BYTES,
            "final-validator timeouts": final_validator.GATE_PLAN_TIMEOUTS,
            "final-validator outputs": final_validator.GATE_PLAN_OUTPUTS,
            "final-validator output bounds": final_validator.GATE_PLAN_MAXIMUM_BYTES,
        }
        for authority, mapping in gate_mappings.items():
            with self.subTest(authority=authority):
                self.assertEqual(tuple(mapping), CANONICAL_GATE_IDS)

        # The shell entrypoint delegates the closed gate schema to the
        # transaction/final-validator owners and must not duplicate it.
        self.assertNotRegex(_source(ENTRYPOINT), r"\bGATE_IDS\s*=")

    def test_task10_is_owned_and_ordered_by_the_transaction(self) -> None:
        owners = [
            path
            for path in _existing(CANONICAL_PYTHON_SCRIPTS)
            if _assigned_value(_tree(path), "TASK10_MATRIX_SCRIPT") is not None
        ]
        self.assertEqual(owners, [TRANSACTION])
        self.assertNotIn("TASK10_MATRIX_SCRIPT", _source(ENTRYPOINT))

        execute = next(
            (
                node
                for node in _tree(TRANSACTION).body
                if isinstance(node, ast.FunctionDef)
                and node.name == "execute_transaction"
            ),
            None,
        )
        self.assertIsNotNone(execute, "transaction lacks execute_transaction")
        offsets = _call_offsets(execute)
        self.assertLess(
            offsets["_run_task10_prerequisite"],
            offsets["_execute_gate_plan"],
            "Task10 must be transaction-owned and complete before gate execution",
        )
        self.assertIn('"installed_task10"', _source(TRANSACTION))

    def test_entrypoint_hands_exact_remote_result_to_final_validator(self) -> None:
        entrypoint = _source(ENTRYPOINT)
        self.assertIn(
            'FINAL_VALIDATOR="$ROOT_DIR/reconstruction/validate_final_local_candidate.py"',
            entrypoint,
        )
        self.assertIn("refs/remotes/<remote>/<branch>", entrypoint)
        self.assertIn("from Scripts.reconstruction.integration_remote_authority import validate_integration_remote_url", entrypoint)
        self.assertIn("validate_integration_remote_url(remote_url)", entrypoint)
        driver_call = entrypoint.index('"${DRIVER_ARGUMENTS[@]}"')
        validator_call = entrypoint.index('"${VALIDATOR_ARGUMENTS[@]}"')
        self.assertLess(driver_call, validator_call)
        validator_argv = entrypoint[
            entrypoint.index("VALIDATOR_ARGUMENTS=(") : validator_call
        ]
        for binding in (
            '--transaction-result "$RESULT_OUTPUT"',
            '--integration-ref "$INTEGRATION_REF"',
            '--qualification-receipt "$QUALIFICATION_RECEIPT"',
            '--candidate-artifact-root "$CANDIDATE_ARTIFACT_ROOT"',
            '--output "$FINAL_OUTPUT"',
        ):
            self.assertIn(binding, validator_argv)

        validator_source = _source(FINAL_VALIDATOR)
        self.assertNotIn("GITFOX_REMOTE", validator_source)
        self.assertIn('"remote": closure.local_ref.remote_name', validator_source)
        validator_tree = _tree(FINAL_VALIDATOR)
        validator_flags = dict(_argparse_flags(validator_tree))
        for flag in (
            "--transaction-result",
            "--integration-ref",
            "--qualification-receipt",
            "--candidate-artifact-root",
            "--output",
        ):
            self.assertTrue(
                validator_flags.get(flag),
                f"final validator does not require handoff flag {flag}",
            )


if __name__ == "__main__":
    unittest.main()
