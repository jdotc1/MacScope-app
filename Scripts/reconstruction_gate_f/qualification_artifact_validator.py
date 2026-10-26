"""Physical qualification semantics; successful invocation is never test proof.

These functions do not emit receipts or confer dispatch authority. The caller must
obtain expected selectors/skips from its admitted catalogue, and bind returned
observations to a separate semantic receipt and the captured command/run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import tempfile
from pathlib import Path
from typing import Mapping, Sequence

from Scripts.source_export_provenance import load_verified_export
from Scripts.check_test_skip_allowlist import report as skip_allowlist_report
from Scripts.reconstruction.validate_qualification_product_identity import (
    validate_qualification_build,
)
from Scripts.reconstruction.installed_matrix_receipt import _bundle_identity
from Scripts.ws24_emit_installed_qualification_report import (
    exclusively_passed_case, result_bundle_sha256, xcresult_test_nodes,
    xcresult_test_summary,
)


class QualificationArtifactError(ValueError):
    pass


# Reviewed retained-evidence supplement, 2026-10-04. The lexical skip audit
# deliberately cannot resolve same-name sections() methods: these package
# helpers can skip while the same-file synthetic helpers cannot. Pin the exact
# source and observed reason rather than admitting all overloads or all skips.
# These remain uncovered, skipped observations; no installed/native control is
# included and none gains passing credit from full-suite admission.
_DWARF_OVERLOAD_SKIP_SOURCES = (
    ("DWARFCFITests", "testPackage05FixtureRecoversFDEProgramsInSectionOrder",
     "0100c4705fa37d3631de42b94fa814f5cf4e1d474d4ab12cac6a974345ad4253"),
    ("DWARFGlobalTests", "testPackage03FixtureRecoversNamedFileScopeGlobals",
     "1a32cb41e32ee6a4f6ac5f0d73a6594f928da332062687285ad312164c7298c9"),
    ("DWARFLocationTests", "testPackage02FixtureRecoversNormalizedLocations",
     "12b192eb4439d1ede37f70062045b5b51268fa071d7976f5609b6f3662b132be"),
    ("DWARFLoclistTests", "testPackage04FixtureRecoversNormalizedLoclists",
     "9beb9513068e68602457eb14d9c5f0ecbc19905a30fc61a07762d57d5adf3b9e"),
    ("DWARFRnglistTests", "testPackage06FixtureRecoversLexicalBlockRanges",
     "e7315753d58a695d765bd882fc1b4b76cc2cf225660c557d5fd7c49f5cc58adc"),
)
_DWARF_OVERLOAD_SKIP_REASON = "Test skipped - handoff_package/sections fixture is unavailable"


def validate_source_export(candidate, source_root: Path, integration_ref: str) -> dict:
    provenance, _ = load_verified_export(source_root, require_closed_tree=True)
    expected = {
        "git_head_commit": candidate.source.commit,
        "git_head_tree": candidate.source.tree,
        "canonical_integration_commit": candidate.source.commit,
        "canonical_integration_ref": integration_ref,
        "repository_clean": True,
    }
    if candidate.source.dirty or any(provenance.get(k) != v for k, v in expected.items()):
        raise QualificationArtifactError("export differs from the admitted candidate source")
    return provenance


def validate_qualification_products(candidate, qualification_receipt: Path, *,
                                    integration_ref: str, dependency_cache_root: Path,
                                    mode: str) -> dict:
    if mode not in {"smoke", "focused-test", "full-test", "release"}:
        raise QualificationArtifactError("unsupported qualification mode")
    run = qualification_receipt.parent
    configuration = "Release" if mode in {"full-test", "release"} else "Debug"
    app = run / "DerivedData/Build/Products" / configuration / "MacScope.app"
    arguments = argparse.Namespace(
        receipt=qualification_receipt, run_root=run,
        derived_data_root=run / "DerivedData", build_source_root=run / "source",
        dependency_cache_root=dependency_cache_root, expected_mode=mode,
        expected_integration_ref=integration_ref,
        expected_integration_commit=candidate.source.commit,
        expected_integration_tree=candidate.source.tree,
        dependency_network_authorized=False, app_bundle=app,
    )
    observed = validate_qualification_build(arguments)
    # Only completed qualification is semantic evidence. The qualifier retains
    # generated-project-evidence outside source, removes its three governed
    # scaffold entries, and strictly verifies the restored source before its
    # final success marker. Input/build validation alone checks manifest bytes,
    # not every source file; retain this independent content/closure check.
    validate_source_export(candidate, run / "source", integration_ref)
    if mode in {"full-test", "release"}:
        # qualification_executables["app"] describes the separate Debug product.
        # validate_qualification_build above already preserves the generic product
        # checks: canonical contained ordinary paths, executable permission, exact
        # Info.plist executable/identifier, bounded stable leaf reads and final
        # revalidation. Bind that observation to the Release authority, then check
        # the full closed signed tree rather than comparing it to Debug bytes.
        if observed.get("app_executable_sha256") != candidate.application.executable_sha256:
            raise QualificationArtifactError("Release build executable is not the candidate executable")
        physical = _bundle_identity(app, app / "Contents/MacOS/MacScope")
        expected = {
            "content_sha256": candidate.application.bundle_sha256,
            "closed_tree_sha256": candidate.application.closed_tree_sha256,
            "executable_sha256": candidate.application.executable_sha256,
            "bundle_identifier": candidate.application.bundle_identifier,
        }
        if any(physical.get(k) != value for k, value in expected.items()):
            raise QualificationArtifactError("Release app is not the physical candidate tree")
        observed = {**observed, "bundle_sha256": physical["content_sha256"],
                    "closed_tree_sha256": physical["closed_tree_sha256"]}
    return observed


def project_xcresult(summary: object, tests: object, *,
                     expected_selectors: Sequence[str] = (),
                     allowed_skips: Mapping[str, str], selected_scope: str | None = None,
                     _reviewed_full_suite_skips: Mapping[str, str] | None = None) -> dict:
    """Project exact CoreTests cases, including explicitly expected skip reasons.

    Selectors are full CoreTests/Suite/test names, not suite prefixes. No empty,
    duplicate, missing, unexpected, retried-failing or expected-failure case passes.
    """
    expected = tuple(expected_selectors)
    reviewed = _reviewed_full_suite_skips or {}
    if reviewed and (selected_scope != "CoreTests" or expected
                     or not set(allowed_skips).issubset(reviewed)):
        raise QualificationArtifactError("governed skips apply only to the full CoreTests run")
    if selected_scope is not None and (expected or not isinstance(selected_scope, str)
            or selected_scope.split("/")[0] != "CoreTests"
            or len(selected_scope.split("/")) not in {1, 2, 3}
            or any(not part for part in selected_scope.split("/"))):
        raise QualificationArtifactError("selected scope must be one admitted CoreTests selector")
    if ((not expected and selected_scope is None) or len(set(expected)) != len(expected)
            or any(not isinstance(s, str) or not s.startswith("CoreTests/")
                   or len(s.split("/")) != 3 for s in expected)
            or (selected_scope is None and not set(allowed_skips).issubset(expected))
            or any(not isinstance(v, str) or not v for v in allowed_skips.values())):
        raise QualificationArtifactError("expected selector/skip catalogue is invalid")
    if not isinstance(summary, dict) or not isinstance(tests, dict):
        raise QualificationArtifactError("xcresult documents must be objects")
    rows = {}
    skip_observations = []

    def visit(node, bundle=None, suite=None):
        if not isinstance(node, dict) or not isinstance(node.get("nodeType"), str):
            raise QualificationArtifactError("malformed xcresult node")
        kind, name = node["nodeType"], node.get("name")
        if kind in {"Unit test bundle", "Test Bundle"}:
            bundle = name
        if kind == "Test Suite":
            suite = name
        if kind == "Test Case":
            identifier = node.get("nodeIdentifier")
            if not isinstance(identifier, str):
                raise QualificationArtifactError("test identifier missing")
            if not identifier.startswith("CoreTests/"):
                identifier = "CoreTests/" + identifier
            identifier = identifier.removesuffix("()")
            selected = identifier in expected if selected_scope is None else (
                identifier == selected_scope or identifier.startswith(selected_scope + "/")
            )
            if (bundle != "CoreTests" or not selected or identifier in rows
                    or len(identifier.split("/")) != 3):
                raise QualificationArtifactError("unexpected, duplicate or wrong-bundle test")
            if identifier.split("/")[1] != suite:
                raise QualificationArtifactError("test suite ancestry differs")
            status = node.get("result")
            if status == "Passed":
                exclusively_passed_case(node, 0)
                rows[identifier] = "passed"
            elif status == "Skipped" and (identifier in allowed_skips or identifier in reviewed):
                children = node.get("children", [])
                if (not isinstance(children, list) or len(children) != 1
                        or not isinstance(children[0], dict)
                        or children[0].get("nodeType") != "Skip Message"
                        or not isinstance(children[0].get("name"), str)
                        or not children[0]["name"].strip()
                        or (identifier in allowed_skips and children[0]["name"] != allowed_skips[identifier])
                        or children[0].get("children", []) != []):
                    raise QualificationArtifactError("skip is not the exact admitted reason")
                rows[identifier] = "skipped"
                skip_observations.append({"test_identifier": identifier,
                    "observed_reason": children[0]["name"],
                    "reviewed_reason": reviewed.get(identifier, allowed_skips.get(identifier))})
            else:
                raise QualificationArtifactError("test did not pass or match an allowed skip")
            return
        children = node.get("children", [])
        if not isinstance(children, list):
            raise QualificationArtifactError("malformed xcresult children")
        for child in children:
            visit(child, bundle, suite)

    roots = tests.get("testNodes")
    if not isinstance(roots, list):
        raise QualificationArtifactError("testNodes missing")
    for root in roots:
        visit(root)
    if not rows or (selected_scope is None and set(rows) != set(expected)):
        raise QualificationArtifactError("xcresult omitted expected tests")
    skipped = sum(value == "skipped" for value in rows.values())
    counts = {"totalTestCount": len(rows), "passedTests": len(rows) - skipped,
              "failedTests": 0, "skippedTests": skipped, "expectedFailures": 0}
    if summary.get("result") != "Passed" or any(
        type(summary.get(k)) is not int or summary[k] != v for k, v in counts.items()
    ):
        raise QualificationArtifactError("xcresult summary differs from physical cases")
    scope_evidence = ({"expected_selector_count": len(expected)} if selected_scope is None else {
        "selected_scope": selected_scope,
        "coverage_claim": "all-recorded-cases-in-selected-scope-not-source-enumeration",
    })
    return {**scope_evidence, "executed_selector_count": len(rows),
            "passed_selector_count": len(rows) - skipped, "failed_selector_count": 0,
            "skipped_selector_count": skipped,
            "skips": sorted(skip_observations, key=lambda item: item["test_identifier"]),
            "selectors": [{"test_identifier": key, "status": rows[key]}
                          for key in sorted(rows)]}


def _inspect_xcresult(path: Path, *, scratch_root: Path | None = None) -> tuple[object, object, str]:
    # Xcode 27.2's xcresulttool may create database.sqlite3 even for read
    # commands. Never permit that derived cache to mutate retained evidence.
    before = result_bundle_sha256(path)
    if scratch_root is not None and (not scratch_root.is_absolute()
            or scratch_root.is_symlink() or not scratch_root.is_dir()
            or path.resolve() == scratch_root.resolve()
            or path.resolve() in scratch_root.resolve().parents):
        raise QualificationArtifactError("inspection scratch must be an external ordinary directory")
    with tempfile.TemporaryDirectory(prefix="macscope-xcresult-", dir=scratch_root) as temporary:
        copied = Path(temporary) / "Inspection.xcresult"
        shutil.copytree(path, copied, symlinks=True)
        if result_bundle_sha256(copied) != before or result_bundle_sha256(path) != before:
            raise QualificationArtifactError("xcresult changed while copying inspection evidence")
        summary = xcresult_test_summary(copied, 0)
        tests = xcresult_test_nodes(copied, 0)
    if result_bundle_sha256(path) != before:
        raise QualificationArtifactError("xcresult changed during semantic observation")
    return summary, tests, before


def validate_xcresult(path: Path, *, expected_selectors: Sequence[str],
                      allowed_skips: Mapping[str, str], scratch_root: Path | None = None) -> dict:
    summary, tests, before = _inspect_xcresult(path, scratch_root=scratch_root)
    result = project_xcresult(summary, tests,
                             expected_selectors=expected_selectors, allowed_skips=allowed_skips)
    return {**result, "xcresult_bundle_sha256": before}


def validate_selected_xcresult(path: Path, *, selected_scope: str,
                              allowed_skips: Mapping[str, str], scratch_root: Path | None = None) -> dict:
    """Actual run outcomes only; caller binds scope to admitted argv/test configuration.

    This deliberately does not synthesize an expected per-case catalogue from
    observed cases or claim that every source-defined test was discovered.
    """
    summary, tests, before = _inspect_xcresult(path, scratch_root=scratch_root)
    result = project_xcresult(summary, tests,
                             selected_scope=selected_scope, allowed_skips=allowed_skips)
    return {**result, "xcresult_bundle_sha256": before}


def validate_full_coretests_xcresult(path: Path, *, candidate, source_root: Path,
                                   integration_ref: str, scratch_root: Path | None = None) -> dict:
    """Apply only the reviewed, candidate-source-bound full-suite skip policy."""
    before = validate_source_export(candidate, source_root, integration_ref)
    allowlist = source_root / "docs/qualification/skip-allowlist.json"
    payload = allowlist.read_bytes() if allowlist.exists() else None
    if payload is None:
        audit = {"countingRule": None, "knownGap": "skip allowlist absent; no reviewed skip authority"}
        entries = []
    else:
        audit, errors = skip_allowlist_report(source_root / "MacScope/Tests", allowlist)
        if errors or audit.get("accepted") is not True:
            raise QualificationArtifactError("candidate skip allowlist differs from reviewed source")
        entries = json.loads(payload)["entries"]
    reviewed = {}
    for entry in entries:
        relative = Path(entry["file"])
        if relative.parts[0] != "CoreTests":
            continue
        # The existing review catalogue is file/method based. Admit its mapping
        # only when that source explicitly declares the filename-named test class.
        suite = relative.stem
        source = (source_root / "MacScope/Tests" / relative).read_text(encoding="utf-8")
        if not re.search(r"\bclass\s+" + re.escape(suite) + r"\s*:", source):
            raise QualificationArtifactError("reviewed skip file has no unambiguous named suite")
        selector = f"CoreTests/{suite}/{entry['method']}"
        if selector in reviewed:
            raise QualificationArtifactError("reviewed skip selector is duplicated")
        reviewed[selector] = entry["reason"]
    exact_skips = {}
    for suite, method, source_sha256 in _DWARF_OVERLOAD_SKIP_SOURCES:
        source_path = source_root / "MacScope/Tests/CoreTests" / (suite + ".swift")
        if not source_path.is_file() or hashlib.sha256(source_path.read_bytes()).hexdigest() != source_sha256:
            continue
        selector = f"CoreTests/{suite}/{method}"
        reviewed[selector] = (
            "Reviewed same-file overload-resolution gap: the source-pinned package "
            "sections() helper requires handoff_package/sections. Remains skipped, "
            "not passing coverage; dedicated native controls remain separate."
        )
        exact_skips[selector] = _DWARF_OVERLOAD_SKIP_REASON
    summary, tests, digest = _inspect_xcresult(path, scratch_root=scratch_root)
    result = project_xcresult(summary, tests, selected_scope="CoreTests", allowed_skips=exact_skips,
                             _reviewed_full_suite_skips=reviewed)
    if ((allowlist.read_bytes() if allowlist.exists() else None) != payload
            or validate_source_export(candidate, source_root, integration_ref) != before):
        raise QualificationArtifactError("candidate skip authority changed during observation")
    return {**result, "xcresult_bundle_sha256": digest,
            "skip_policy": {"source_commit": candidate.source.commit,
                "source_tree": candidate.source.tree,
                "allowlist_sha256": hashlib.sha256(payload).hexdigest() if payload is not None else None,
                "allowlist_present": payload is not None,
                "counting_rule": audit["countingRule"], "known_gap": audit["knownGap"]}}
