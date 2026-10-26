from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TEST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TEST_ROOT.parent))

from reconstruction_task10_adjudication.core import (  # noqa: E402
    FINDING_SPECS,
    MUTATION_CASES,
    VALID_ADJUDICATION_OUTCOMES,
    _parse_ledger,
    _safe_archive_path,
    _source_identity_handoff_text,
    audit_source,
    adjudicate_findings,
    deterministic_set_cover,
    select_vectors,
    verify_mutations,
)


class T10CSourceContractTests(unittest.TestCase):
    @classmethod
    def repo_root(cls) -> Path:
        return Path(__file__).resolve().parents[3]

    def test_closed_finding_inventory_and_outcomes(self) -> None:
        self.assertEqual(len(FINDING_SPECS), 18)
        self.assertEqual(len({item.finding_id for item in FINDING_SPECS}), 18)
        self.assertTrue(all(item.outcome in VALID_ADJUDICATION_OUTCOMES for item in FINDING_SPECS))

    def test_live_source_mapping_resolves_every_symbol_anchor(self) -> None:
        result = audit_source(self.repo_root())
        self.assertTrue(result["allSymbolsResolved"])
        self.assertEqual(result["mappingCount"], 18)
        self.assertEqual(len(result["currentSource"]["worktreeInputManifestSHA256"]), 64)
        for row in result["mappings"]:
            self.assertNotEqual(row["classification"], "unchanged")
            self.assertEqual(len(row["semanticFingerprintSHA256"]), 64)

    def test_source_identity_handoff_distinguishes_clean_and_dirty_inputs(self) -> None:
        current_source = {
            "headCommit": "a" * 40,
            "worktreeInputManifestSHA256": "b" * 64,
            "dirtyInputPaths": [],
        }

        clean = _source_identity_handoff_text(current_source)
        self.assertIn(f"input manifest `{'b' * 64}`", clean)
        self.assertIn("identifies the exact inspected Task 10 source", clean)
        self.assertIn("No audited source input paths were dirty.", clean)
        self.assertNotIn("exact inspected dirty Task 10 source", clean)

        current_source["dirtyInputPaths"] = ["MacScope/Stores/WorkspaceStore.swift"]
        dirty = _source_identity_handoff_text(current_source)
        self.assertIn("identifies the exact inspected Task 10 source", dirty)
        self.assertIn(
            "Dirty audited source input paths: `MacScope/Stores/WorkspaceStore.swift`.",
            dirty,
        )
        self.assertNotIn("No audited source input paths were dirty.", dirty)


class T10CArchiveGuardTests(unittest.TestCase):
    def test_ledger_rejects_duplicate_malformed_and_traversing_rows(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate"):
            _parse_ledger(("0" * 64 + "  a\n" + "1" * 64 + "  a\n").encode())
        with self.assertRaisesRegex(ValueError, "malformed"):
            _parse_ledger(b"not-a-ledger\n")
        with self.assertRaisesRegex(ValueError, "unsafe"):
            _parse_ledger(("0" * 64 + "  ../escape\n").encode())

    def test_archive_path_guard_rejects_absolute_parent_and_backslash(self) -> None:
        for value in ("/absolute", "a/../b", "a\\b"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                _safe_archive_path(value)


class T10CSelectorTests(unittest.TestCase):
    @classmethod
    def repo_root(cls) -> Path:
        return Path(__file__).resolve().parents[3]

    def test_attached_normative_coverage_uses_the_closed_id_schema(self) -> None:
        configured = os.environ.get("MACSCOPE_T10A_ARCHIVE")
        if not configured or not Path(configured).is_file():
            self.skipTest("MACSCOPE_T10A_ARCHIVE is not available")
        archive = Path(configured)

        selection = select_vectors(archive, adjudicate_findings(archive, audit_source(self.repo_root())))
        with zipfile.ZipFile(archive) as bundle:
            report = __import__("json").loads(
                bundle.read(f"MacScope-RECON-R1-T10A/generated/state_coverage_report.json")
            )
        normative_ids = {f"rule:{row['id']}" for row in report["normativeCoverage"] if row["covered"]}

        self.assertTrue(selection["coverageComplete"])
        self.assertEqual(len(normative_ids), 57)
        self.assertTrue(normative_ids <= set(selection["coverageMatrix"]))

    def test_selector_is_deterministic_lexical_and_removal_sensitive(self) -> None:
        candidates = {
            "a": {"one", "two"},
            "b": {"two", "three"},
            "c": {"one"},
            "d": {"three"},
        }
        first, matrix = deterministic_set_cover(candidates, {"one", "two", "three"}, set())
        second, _ = deterministic_set_cover(dict(reversed(list(candidates.items()))), {"one", "two", "three"}, set())
        self.assertEqual(first, second)
        self.assertEqual(first, ["a", "b"])
        for selected in first:
            remaining = [item for item in first if item != selected]
            covered = set().union(*(candidates[item] for item in remaining)) if remaining else set()
            self.assertNotEqual(covered, {"one", "two", "three"})
        self.assertTrue(all(matrix.values()))

    def test_empty_coverage_is_not_treated_as_equivalent(self) -> None:
        with self.assertRaisesRegex(ValueError, "no candidate"):
            deterministic_set_cover({}, {"required"}, set())


class T10CMutationTests(unittest.TestCase):
    def test_all_required_mutations_are_caught(self) -> None:
        result = verify_mutations()
        self.assertEqual(len(MUTATION_CASES), 24)
        self.assertEqual(result["caughtCount"], 24)
        self.assertTrue(result["allCaught"])


if __name__ == "__main__":
    unittest.main()
