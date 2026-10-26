#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "Scripts" / "ws24_emit_installed_qualification_report.py"


def load_module():
    specification = importlib.util.spec_from_file_location(
        "ws24_emit_installed_qualification_report_xcuitest_schema",
        SCRIPT,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load WS-24 report script")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


ws24_report = load_module()


class WS24XCUITestEvidenceSchemaTests(unittest.TestCase):
    source_commit = "1" * 40
    source_tree = "2" * 40
    installed_digest = "a" * 64

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.xcresult = Path(self.temporary_directory.name) / "Installed.xcresult"
        self.xcresult.mkdir()
        (self.xcresult / "Info.plist").write_bytes(b"fixture xcresult\n")
        self.receipt = Path(self.temporary_directory.name) / "installed-matrix.json"
        self.receipt.write_bytes(b"{}")
        self.selectors = ws24_report.load_installed_selector_catalog()
        self.sealed_receipt = {
            "candidate": {
                "source_commit": self.source_commit,
                "source_tree": self.source_tree,
            },
            "execution": {
                "result": "passed",
                "selectors": [item["testIdentifier"] for item in self.selectors],
            },
            "products": {
                "installed_app": {"executable_sha256": self.installed_digest},
                "xcresult": {"path": str(self.xcresult)},
            },
        }

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def summary(
        self,
        *,
        passed: int = ws24_report.INSTALLED_SELECTOR_COUNT,
        failed: int = 0,
        skipped: int = 0,
        expected_failures: int = 0,
        result: str = "Passed",
    ) -> dict[str, object]:
        return {
            "expectedFailures": expected_failures,
            "failedTests": failed,
            "passedTests": passed,
            "result": result,
            "skippedTests": skipped,
            "title": "Test - MacScopeInstalledAppUITests",
            "totalTestCount": passed + failed + skipped + expected_failures,
        }

    def xcresult_tree(
        self,
        *,
        identifiers: list[str] | None = None,
        case_result: str = "Passed",
        child_node_type: str = "Test Case Run",
        bundle_name: str = "MacScopeInstalledAppUITests",
        suite_name: str = "WS24InstalledAppUITests",
    ) -> dict[str, object]:
        selected_identifiers = identifiers or [
            selector["testIdentifier"] for selector in self.selectors
        ]
        cases = []
        for identifier in selected_identifiers:
            method = identifier.rsplit("/", 1)[-1]
            cases.append(
                {
                    "children": [
                        {
                            "children": [],
                            "name": method,
                            "nodeType": child_node_type,
                            "result": case_result,
                        }
                    ],
                    "name": method,
                    "nodeIdentifier": identifier,
                    "nodeType": "Test Case",
                    "result": case_result,
                }
            )
        return {
            "testNodes": [
                {
                    "children": [
                        {
                            "children": [
                                {
                                    "children": cases,
                                    "name": suite_name,
                                    "nodeType": "Test Suite",
                                    "result": case_result,
                                }
                            ],
                            "name": bundle_name,
                            "nodeType": "UI test bundle",
                            "result": case_result,
                        }
                    ],
                    "name": "MacScopeInstalledAppUITests",
                    "nodeType": "Test Plan",
                    "result": case_result,
                }
            ]
        }

    def evidence(self, **overrides: object) -> dict[str, object]:
        item: dict[str, object] = {
            "gate": "incremental-xcuitest",
            "proofArtifacts": [
                {
                    "kind": ws24_report.installed_matrix_receipt.PROOF_ARTIFACT_KIND,
                    "path": str(self.receipt),
                    "sha256": hashlib.sha256(self.receipt.read_bytes()).hexdigest(),
                },
                {
                    "kind": "xcresult",
                    "path": str(self.xcresult),
                }
            ],
        }
        item.update(overrides)
        return item

    def normalize(
        self,
        item: dict[str, object] | None = None,
        *,
        summary: dict[str, object] | None = None,
        tests: dict[str, object] | None = None,
    ) -> list[dict[str, object]]:
        with (
            mock.patch.object(
                ws24_report,
                "xcresult_test_summary",
                return_value=summary or self.summary(),
            ),
            mock.patch.object(
                ws24_report,
                "xcresult_test_nodes",
                return_value=tests or self.xcresult_tree(),
            ),
            mock.patch.object(
                ws24_report.installed_matrix_receipt,
                "load_receipt_with_sha256",
                return_value=(
                    self.sealed_receipt,
                    hashlib.sha256(self.receipt.read_bytes()).hexdigest(),
                ),
            ),
            mock.patch.object(
                ws24_report.installed_matrix_receipt,
                "validate_receipt",
                return_value="f" * 64,
            ),
        ):
            return ws24_report.normalize_input_evidence(
                [item or self.evidence()],
                expected_source_commit=self.source_commit,
                expected_source_tree=self.source_tree,
                expected_installed_executable_sha256=self.installed_digest,
                candidate_identity_path=Path(self.temporary_directory.name) / "candidate.json",
                installed_app=Path(self.temporary_directory.name) / "MacScope.app",
            )

    def test_catalog_derives_exactly_twenty_two_unique_test_identifiers(self) -> None:
        self.assertEqual(len(self.selectors), 22)
        self.assertEqual(len({item["vectorID"] for item in self.selectors}), 22)
        self.assertEqual(len({item["testIdentifier"] for item in self.selectors}), 22)
        for item in self.selectors:
            scenario = item["vectorID"].removeprefix("xcui.")
            self.assertEqual(
                item["testIdentifier"],
                "WS24InstalledAppUITests/"
                f"testTask10C{scenario[0].upper()}{scenario[1:]}()",
            )

    def test_exact_twenty_two_selector_ledger_is_accepted_and_normalized(self) -> None:
        normalized = self.normalize()

        self.assertEqual(len(normalized), 1)
        item = normalized[0]
        self.assertEqual(item["executedTestCount"], 22)
        self.assertEqual(item["skippedTestCount"], 0)
        self.assertEqual(
            item["executedSelectorIDs"],
            sorted(selector["vectorID"] for selector in self.selectors),
        )
        self.assertEqual(
            item["executedTestIdentifiers"],
            sorted(selector["testIdentifier"] for selector in self.selectors),
        )
        self.assertEqual(item["sourceTree"], self.source_tree)
        self.assertEqual(
            item["resultBundleSHA256"],
            ws24_report.result_bundle_sha256(self.xcresult),
        )

    def test_omitted_selector_ledger_entry_is_rejected(self) -> None:
        identifiers = [selector["testIdentifier"] for selector in self.selectors][:-1]
        with self.assertRaisesRegex(
            ws24_report.ReportError,
            r"exact one-to-one selector execution.*missing=",
        ):
            self.normalize(tests=self.xcresult_tree(identifiers=identifiers))

    def test_duplicate_selector_ledger_entry_is_rejected(self) -> None:
        identifiers = [selector["testIdentifier"] for selector in self.selectors]
        identifiers[-1] = identifiers[0]
        with self.assertRaisesRegex(
            ws24_report.ReportError,
            r"exact one-to-one selector execution.*duplicates=",
        ):
            self.normalize(tests=self.xcresult_tree(identifiers=identifiers))

    def test_unexpected_selector_ledger_entry_is_rejected(self) -> None:
        identifiers = [selector["testIdentifier"] for selector in self.selectors]
        identifiers[-1] = "WS24InstalledAppUITests/testUncommissionedSelector()"
        with self.assertRaisesRegex(
            ws24_report.ReportError,
            r"exact one-to-one selector execution.*unexpected=",
        ):
            self.normalize(tests=self.xcresult_tree(identifiers=identifiers))

    def test_skip_failure_and_expected_failure_are_each_rejected(self) -> None:
        cases = (
            (
                self.summary(passed=21, skipped=1, result="Passed"),
                self.xcresult_tree(case_result="Skipped", child_node_type="Skip Message"),
                self.evidence(),
            ),
            (
                self.summary(passed=21, failed=1, result="Failed"),
                self.xcresult_tree(case_result="Failed", child_node_type="Failure Message"),
                self.evidence(),
            ),
            (
                self.summary(passed=21, expected_failures=1, result="Passed"),
                self.xcresult_tree(
                    case_result="Expected Failure",
                    child_node_type="Expected Failure",
                ),
                self.evidence(),
            ),
        )
        for summary, tests, item in cases:
            with self.subTest(summary=summary):
                with self.assertRaisesRegex(
                    ws24_report.ReportError,
                    r"counts disagree|zero skipped, failed, expected-failure",
                ):
                    self.normalize(item, summary=summary, tests=tests)

    def test_wrong_bundle_or_suite_boundary_is_rejected(self) -> None:
        for tests in (
            self.xcresult_tree(bundle_name="OtherUITests"),
            self.xcresult_tree(suite_name="OtherInstalledSuite"),
        ):
            with self.subTest(tests=tests):
                with self.assertRaisesRegex(
                    ws24_report.ReportError,
                    r"wrongBoundary=",
                ):
                    self.normalize(tests=tests)

    def test_caller_authored_candidate_bindings_are_rejected(self) -> None:
        for field, value in (
            ("sourceCommit", "3" * 40),
            ("sourceTree", "4" * 40),
            ("installedExecutableSHA256", "b" * 64),
        ):
            with self.subTest(field=field):
                with self.assertRaisesRegex(ws24_report.ReportError, "unknown="):
                    self.normalize(self.evidence(**{field: value}))

    def test_caller_authored_result_bundle_digest_is_rejected(self) -> None:
        with self.assertRaisesRegex(ws24_report.ReportError, "unknown="):
            self.normalize(self.evidence(resultBundleSHA256="a" * 64))

    def test_xcuitest_evidence_requires_the_sha_bound_receipt(self) -> None:
        item = self.evidence()
        item["proofArtifacts"] = [item["proofArtifacts"][1]]
        with self.assertRaisesRegex(ws24_report.ReportError, "SHA-bound installed matrix receipt"):
            self.normalize(item)

    def test_xcuitest_evidence_counts_must_match_the_xcresult_summary(self) -> None:
        with self.assertRaisesRegex(
            ws24_report.ReportError,
            r"incremental-xcuitest counts disagree with the xcresult summary",
        ):
            self.normalize(summary=self.summary(passed=21, skipped=1))

    def test_xcuitest_proof_must_be_an_xcresult_bundle(self) -> None:
        ordinary_file = Path(self.temporary_directory.name) / "not-an-xcresult.txt"
        ordinary_file.write_text("not an xcresult\n", encoding="utf-8")
        with self.assertRaisesRegex(
            ws24_report.ReportError,
            r"non-symlink directory",
        ):
            self.normalize(
                self.evidence(
                    proofArtifacts=[
                        self.evidence()["proofArtifacts"][0],
                        {"kind": "xcresult", "path": str(ordinary_file)},
                    ]
                )
            )


if __name__ == "__main__":
    unittest.main()
