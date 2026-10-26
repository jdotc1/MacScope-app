#!/usr/bin/env python3
"""Guard the installed-acceptance surface against system-Python drift."""

from __future__ import annotations

import ast
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SYSTEM_PYTHON = Path("/usr/bin/python3")
WRAPPER = REPOSITORY_ROOT / "Scripts/install_local_private_build.sh"
PYTHON_SURFACE = (
    REPOSITORY_ROOT / "Scripts/reconstruction/compile_installed_acceptance_gate_plan.py",
    REPOSITORY_ROOT / "Scripts/reconstruction/run_installed_acceptance_transaction.py",
    REPOSITORY_ROOT / "Scripts/reconstruction/installed_matrix_receipt.py",
    REPOSITORY_ROOT / "Scripts/reconstruction/run_installed_task10_matrix.py",
    REPOSITORY_ROOT / "Scripts/reconstruction/emit_installed_live_evidence.py",
    REPOSITORY_ROOT / "Scripts/reconstruction/run_ws24_installed_live_gates.py",
    REPOSITORY_ROOT / "Scripts/ws24_emit_installed_qualification_report.py",
    REPOSITORY_ROOT / "Scripts/native-decompiler-xpc/run_installed_native_xpc_gate.py",
    REPOSITORY_ROOT / "Scripts/reconstruction/validate_final_local_candidate.py",
    REPOSITORY_ROOT / "Scripts/reconstruction/integration_remote_authority.py",
)

COMPILE_DRIVER = "compile(__import__('sys').stdin.read(), __import__('sys').argv[1], 'exec')"
IMPORT_DRIVER = r"""
import importlib.util
from pathlib import Path
import sys

path = Path(sys.argv[1])
name = "_macscope_python_compatibility_" + str(abs(hash(str(path))))
specification = importlib.util.spec_from_file_location(name, path)
if specification is None or specification.loader is None:
    raise RuntimeError("could not create an import specification for " + str(path))
module = importlib.util.module_from_spec(specification)
sys.modules[name] = module
specification.loader.exec_module(module)
"""

LATE_MODULE_MEMBERS = {
    "asyncio": {"TaskGroup", "timeout", "timeout_at"},
    "contextlib": {"aclosing", "chdir"},
    "hashlib": {"file_digest"},
    "itertools": {"batched", "pairwise"},
    "os": {"process_cpu_count"},
    "sys": {"exception"},
}
LATE_TYPING_MEMBERS = {
    "Concatenate",
    "LiteralString",
    "Never",
    "NotRequired",
    "ParamSpec",
    "ParamSpecArgs",
    "ParamSpecKwargs",
    "ReadOnly",
    "Required",
    "Self",
    "TypeAlias",
    "TypeGuard",
    "TypeVarTuple",
    "Unpack",
    "assert_never",
    "clear_overloads",
    "dataclass_transform",
    "get_overloads",
    "is_typeddict",
    "override",
    "reveal_type",
}


def _has_postponed_annotations(tree: ast.Module) -> bool:
    return any(
        isinstance(node, ast.ImportFrom)
        and node.module == "__future__"
        and any(alias.name == "annotations" for alias in node.names)
        for node in tree.body
    )


def _annotation_nodes(tree: ast.AST):
    for node in ast.walk(tree):
        if isinstance(node, ast.arg) and node.annotation is not None:
            yield node.annotation
        elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)):
            annotation = getattr(node, "annotation", None)
            if annotation is not None:
                yield annotation
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.returns is not None:
                yield node.returns


def _import_bindings(tree: ast.Module):
    modules = {}
    members = {}
    for node in tree.body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                modules[alias.asname or alias.name] = alias.name
        elif isinstance(node, ast.ImportFrom) and node.module is not None:
            for alias in node.names:
                members[alias.asname or alias.name] = (node.module, alias.name)
    return modules, members


def compatibility_hazards(source: str, label: str):
    """Return line-specific constructs that are not executable on Python 3.9."""

    hazards = []
    try:
        tree = ast.parse(source, filename=label, feature_version=(3, 9))
    except SyntaxError as error:
        hazards.append("%s:%s: syntax is not accepted by Python 3.9: %s" % (
            label,
            error.lineno or 0,
            error.msg,
        ))
        return hazards

    if not _has_postponed_annotations(tree):
        for annotation in _annotation_nodes(tree):
            for node in ast.walk(annotation):
                if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
                    hazards.append(
                        "%s:%s: PEP 604 annotation is evaluated on Python 3.9"
                        % (label, node.lineno)
                    )

    modules, members = _import_bindings(tree)
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            function_name = node.func.id if isinstance(node.func, ast.Name) else None
            keyword_names = {keyword.arg for keyword in node.keywords}
            if function_name == "zip" and "strict" in keyword_names:
                hazards.append(
                    "%s:%s: zip(strict=...) requires Python 3.10"
                    % (label, node.lineno)
                )
            if function_name == "map" and "strict" in keyword_names:
                hazards.append(
                    "%s:%s: map(strict=...) requires Python 3.14"
                    % (label, node.lineno)
                )
            if function_name in {"aiter", "anext"}:
                hazards.append(
                    "%s:%s: built-in %s() requires Python 3.10"
                    % (label, node.lineno, function_name)
                )
            if function_name in {"dataclass", "make_dataclass"} and (
                {"kw_only", "slots", "weakref_slot"} & keyword_names
            ):
                hazards.append(
                    "%s:%s: dataclass layout keywords require Python 3.10+"
                    % (label, node.lineno)
                )
            if isinstance(node.func, ast.Attribute):
                attribute = node.func.attr
                if attribute == "hardlink_to":
                    hazards.append(
                        "%s:%s: pathlib.%s() requires Python 3.10+"
                        % (label, node.lineno, attribute)
                    )
                if attribute == "glob" and (
                    {"case_sensitive", "recurse_symlinks"} & keyword_names
                ):
                    hazards.append(
                        "%s:%s: pathlib glob compatibility keywords require Python 3.12+"
                        % (label, node.lineno)
                    )
                if attribute == "realpath" and "strict" in keyword_names:
                    hazards.append(
                        "%s:%s: os.path.realpath(strict=...) requires Python 3.10"
                        % (label, node.lineno)
                    )
                if attribute in {"Popen", "run"} and (
                    {"pipesize", "process_group"} & keyword_names
                ):
                    hazards.append(
                        "%s:%s: subprocess process-control keyword requires Python 3.10+"
                        % (label, node.lineno)
                    )

        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            module = modules.get(node.value.id, node.value.id)
            if node.attr in LATE_MODULE_MEMBERS.get(module, set()):
                hazards.append(
                    "%s:%s: %s.%s is newer than Python 3.9"
                    % (label, node.lineno, module, node.attr)
                )
            if module == "typing" and node.attr in LATE_TYPING_MEMBERS:
                hazards.append(
                    "%s:%s: typing.%s is newer than Python 3.9"
                    % (label, node.lineno, node.attr)
                )

        if isinstance(node, ast.Name) and node.id in members:
            module, member = members[node.id]
            if member in LATE_MODULE_MEMBERS.get(module, set()):
                hazards.append(
                    "%s:%s: %s.%s is newer than Python 3.9"
                    % (label, node.lineno, module, member)
                )
            if module == "typing" and member in LATE_TYPING_MEMBERS:
                hazards.append(
                    "%s:%s: typing.%s is newer than Python 3.9"
                    % (label, node.lineno, member)
                )
    return sorted(set(hazards))


def _wrapper_python_programs(source: str):
    programs = []
    for match in re.finditer(r"<<'PY'\n(.*?)\nPY$", source, re.MULTILINE | re.DOTALL):
        programs.append(("heredoc at line %s" % source[:match.start()].count("\n"), match.group(1)))
    inline = re.search(r"/usr/bin/python3 -B -c '\n(.*?)\n' \"\$1\"", source, re.DOTALL)
    if inline is not None:
        programs.append(("classify_helper_stdout inline program", inline.group(1)))
    return programs


class InstalledAcceptancePythonCompatibilityTests(unittest.TestCase):
    maxDiff = None

    @staticmethod
    def _environment():
        return {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}

    def _run_python(self, arguments, *, source=None):
        return subprocess.run(
            [str(SYSTEM_PYTHON), "-B", *arguments],
            cwd=REPOSITORY_ROOT,
            env=self._environment(),
            input=source,
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )

    def test_canonical_python_surface_compiles_and_imports(self) -> None:
        self.assertEqual(len(PYTHON_SURFACE), 10)
        for path in PYTHON_SURFACE:
            with self.subTest(path=path.relative_to(REPOSITORY_ROOT)):
                self.assertTrue(path.is_file(), path)
                source = path.read_text(encoding="utf-8")
                compiled = self._run_python(
                    ["-c", COMPILE_DRIVER, str(path)], source=source
                )
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                imported = self._run_python(["-c", IMPORT_DRIVER, str(path)])
                self.assertEqual(imported.returncode, 0, imported.stderr)

    def test_canonical_surface_has_no_concrete_post_3_9_hazards(self) -> None:
        hazards = []
        for path in PYTHON_SURFACE:
            relative = str(path.relative_to(REPOSITORY_ROOT))
            hazards.extend(
                compatibility_hazards(path.read_text(encoding="utf-8"), relative)
            )
        self.assertEqual(hazards, [])

    def test_wrapper_uses_governed_python_and_embedded_programs_compile(self) -> None:
        source = WRAPPER.read_text(encoding="utf-8")
        invocations = re.findall(r"(?<![/A-Za-z0-9_])(?:/usr/bin/)?python3\b[^\n]*", source)
        # Transaction result decoding has one owner (the final validator), not
        # a fourth embedded copy in the wrapper. Two more are the ordinary
        # mode's source-signing receipt admit/compare calls (76b5de75b).
        self.assertEqual(len(invocations), 7)
        for invocation in invocations:
            self.assertTrue(
                invocation.startswith("/usr/bin/python3 -B"),
                "ungoverned Python invocation: " + invocation,
            )

        programs = _wrapper_python_programs(source)
        self.assertEqual(len(programs), 3)
        hazards = []
        for label, program in programs:
            with self.subTest(program=label):
                compiled = self._run_python(
                    ["-c", COMPILE_DRIVER, str(WRAPPER) + " (" + label + ")"],
                    source=program,
                )
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                hazards.extend(compatibility_hazards(program, label))
        self.assertEqual(hazards, [])

    def test_hazard_scanner_distinguishes_runtime_from_postponed_annotations(self) -> None:
        unsafe = """
import itertools
from dataclasses import dataclass

@dataclass(slots=True)
class Record:
    value: int | None

list(zip([1], [2], strict=True))
itertools.pairwise([1, 2])
"""
        hazards = compatibility_hazards(unsafe, "unsafe.py")
        self.assertTrue(any("PEP 604" in item for item in hazards), hazards)
        self.assertTrue(any("zip(strict" in item for item in hazards), hazards)
        self.assertTrue(any("dataclass layout" in item for item in hazards), hazards)
        self.assertTrue(any("itertools.pairwise" in item for item in hazards), hazards)

        postponed = """
from __future__ import annotations

def parse(value: list[str] | None) -> dict[str, object]:
    return {} if value is None else {"value": value}
"""
        self.assertEqual(compatibility_hazards(postponed, "postponed.py"), [])

        match_case = "match value:\n    case 1:\n        pass\n"
        syntax_hazards = compatibility_hazards(match_case, "match_case.py")
        self.assertTrue(any("syntax is not accepted" in item for item in syntax_hazards))


if __name__ == "__main__":
    unittest.main()
