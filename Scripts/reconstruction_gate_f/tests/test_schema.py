from __future__ import annotations

import unittest

from Scripts.reconstruction_gate_f.canonical_json import (
    CanonicalJSONError,
    canonical_bytes,
    canonical_sha256,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.schema import (
    DECISION_STATUSES,
    EVIDENCE_LAYER_IDS,
    CandidateSubjectKind,
    candidate_identity_sha256,
    parse_candidate_identity,
    validate_candidate_identity,
)
from Scripts.reconstruction_gate_f.tests import candidate_mapping, clone, parsed_candidate


class GateFSchemaTests(unittest.TestCase):
    def test_decision_and_evidence_vocabularies_are_exact(self) -> None:
        self.assertEqual(
            DECISION_STATUSES,
            (
                "blocked-prerequisite",
                "not-run",
                "running-receipts-incomplete",
                "failed",
                "invalid-evidence",
                "qualified-premerge",
                "merged-postmerge-pending",
                "complete",
            ),
        )
        self.assertEqual(len(EVIDENCE_LAYER_IDS), 18)
        self.assertEqual(len(set(EVIDENCE_LAYER_IDS)), 18)
        self.assertIn("installed-source-equality", EVIDENCE_LAYER_IDS)
        self.assertIn("installed-launch-log", EVIDENCE_LAYER_IDS)

    def test_candidate_parses_and_normalizes_catalog_order(self) -> None:
        value = candidate_mapping()
        value["tools"].reverse()
        candidate, issues = parse_candidate_identity(value)
        self.assertEqual(issues, ())
        self.assertIsNotNone(candidate)
        self.assertEqual([item.tool_id for item in candidate.tools], sorted(item["tool_id"] for item in value["tools"]))

    def test_every_candidate_authority_axis_changes_the_digest(self) -> None:
        base = candidate_mapping()
        base_candidate, issues = parse_candidate_identity(base)
        self.assertEqual(issues, ())
        base_digest = candidate_identity_sha256(base_candidate)
        mutations = (
            ("source", lambda value: value["source"].__setitem__("tree", "e" * 40)),
            ("prerequisite", lambda value: value["source"]["semantic_prerequisites"][0].__setitem__("evidence_sha256", "e" * 64)),
            ("tool", lambda value: value["tools"][0].__setitem__("identity_sha256", "e" * 64)),
            ("dependency", lambda value: value["dependencies"][0].__setitem__("artifact_sha256", "e" * 64)),
            (
                "dependency-source-tree",
                lambda value: value["dependencies"][0].__setitem__(
                    "source_tree_sha256", "f" * 64
                ),
            ),
            ("application", lambda value: value["application"].__setitem__("entitlements_sha256", "e" * 64)),
            ("application-root-mode", lambda value: value["application"].__setitem__("root_mode", 0o700)),
            (
                "qualification-executable",
                lambda value: value["application"]["qualification_executables"][0].__setitem__(
                    "sha256", "e" * 64
                ),
            ),
            ("protocol", lambda value: value["protocols"][0].__setitem__("manifest_sha256", "e" * 64)),
            ("package", lambda value: value["packages"][0].__setitem__("tree_sha256", "e" * 64)),
            ("schema", lambda value: value["schemas"][0].__setitem__("content_sha256", "e" * 64)),
            ("selector", lambda value: value.__setitem__("selector_catalog_sha256", "e" * 64)),
        )
        for name, mutate in mutations:
            with self.subTest(name=name):
                changed = clone(base)
                mutate(changed)
                candidate, nested = parse_candidate_identity(changed)
                self.assertEqual(nested, ())
                self.assertNotEqual(candidate_identity_sha256(candidate), base_digest)

    def test_branch_label_is_navigation_only(self) -> None:
        first = parsed_candidate()
        value = candidate_mapping()
        value["source"]["branch_label"] = "main"
        second, issues = parse_candidate_identity(value)
        self.assertEqual(issues, ())
        self.assertEqual(candidate_identity_sha256(first), candidate_identity_sha256(second))

    def test_phase_identity_is_closed(self) -> None:
        value = candidate_mapping()
        value["prospective_merge_commit"] = "a" * 40
        value["prospective_merge_tree"] = "b" * 40
        self.assertIn("subject-phase-identity", {issue.code for issue in validate_candidate_identity(value)})
        for subject in CandidateSubjectKind:
            self.assertEqual(validate_candidate_identity(candidate_mapping(subject)), ())

    def test_rejects_dirty_uppercase_short_boolean_and_missing_tool(self) -> None:
        mutations = (
            lambda value: value["source"].__setitem__("dirty", True),
            lambda value: value["source"].__setitem__("commit", "A" * 40),
            lambda value: value["application"].__setitem__("bundle_sha256", "a" * 63),
            lambda value: value["application"].__setitem__("root_mode", 0o10000),
            lambda value: value["application"].__setitem__(
                "qualification_executables",
                value["application"]["qualification_executables"][:-1],
            ),
            lambda value: value["application"].__setitem__(
                "embedded_executables",
                value["application"]["embedded_executables"][:-1],
            ),
            lambda value: value.__setitem__("dependencies", value["dependencies"][:-1]),
            lambda value: value.__setitem__("protocols", []),
            lambda value: value.__setitem__("packages", []),
            lambda value: value.__setitem__("schemas", []),
            lambda value: value.__setitem__("schema_version", True),
            lambda value: value.__setitem__("tools", value["tools"][:-1]),
        )
        for mutate in mutations:
            value = candidate_mapping()
            mutate(value)
            self.assertTrue(validate_candidate_identity(value))

    def test_closed_nested_records_and_wrong_types_fail_without_crashing(self) -> None:
        value = candidate_mapping()
        value["application"]["extra"] = "not-authority"
        self.assertIn("unknown-field", {issue.code for issue in validate_candidate_identity(value)})
        value = candidate_mapping()
        value["tools"] = {}
        self.assertIn("array-type", {issue.code for issue in validate_candidate_identity(value)})

    def test_canonical_json_is_sorted_utf8_integer_only_and_exact(self) -> None:
        payload = canonical_bytes({"z": 1, "a": "café"})
        self.assertEqual(payload, b'{"a":"caf\xc3\xa9","z":1}')
        self.assertEqual(decode_canonical_bytes(payload), {"a": "café", "z": 1})
        self.assertEqual(canonical_sha256({"a": 1, "b": 2}), canonical_sha256({"b": 2, "a": 1}))

    def test_canonical_decoder_rejects_float_duplicate_noncanonical_and_bounds(self) -> None:
        invalid = (
            b'{"value":1.0}',
            b'{"value":NaN}',
            b'{"a":1,"a":2}',
            b'{ "a":1}',
            b'{"value":9223372036854775808}',
        )
        for payload in invalid:
            with self.subTest(payload=payload), self.assertRaises(CanonicalJSONError):
                decode_canonical_bytes(payload)
        with self.assertRaises(CanonicalJSONError):
            canonical_bytes({"value": 1.0})


if __name__ == "__main__":
    unittest.main()
