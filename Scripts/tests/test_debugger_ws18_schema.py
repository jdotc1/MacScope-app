#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import importlib.util
import itertools
import json
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPOSITORY_ROOT / "Scripts" / "debugger-fixture" / "ws18_schema.py"


def load_schema_module():
    specification = importlib.util.spec_from_file_location("ws18_schema", SCHEMA_PATH)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


schema = load_schema_module()


def operation_rows(observation: str = "observed") -> list[dict[str, object]]:
    return [
        {
            "name": name,
            "advertisement": "unknown",
            "observation": observation,
        }
        for name in schema.OPERATION_ORDER
    ]


def aggregate(
    root: str,
    *,
    pid: int = 4101,
    request_id: str = "request-A",
    session_id: str = "session-A",
    timestamp: int = 1_700_000_000,
) -> dict[str, object]:
    candidates = []
    for index, candidate in enumerate(schema.CANDIDATE_ORDER):
        candidates.append(
            schema.make_candidate(
                candidate,
                "Xcode 27 candidate {0}".format(index),
                {"executablePath": root + "/Xcode.app/tool-{0}".format(index)},
                [
                    {
                        "mode": "launch",
                        "requestID": request_id + "-{0}".format(index),
                        "sessionID": session_id + "-{0}".format(index),
                        "timestamp": timestamp + index,
                        "expectedIdentity": {
                            "pid": pid + index,
                            "startTimeNS": timestamp * 1_000_000_000 + index,
                            "canonicalPath": root + "/fixture/MacScopeDebuggerFixture",
                            "machOUUID": "AAAAAAAA-BBBB-CCCC-DDDD-{0:012d}".format(index),
                        },
                        "outcome": {"state": "observed"},
                        "operations": operation_rows(),
                        "diagnostics": ["adapter ready ✓"],
                    }
                ],
            )
        )
    value = schema.make_aggregate(
        toolchain={
            "developerDirectory": root + "/Xcode.app/Contents/Developer",
            "majorVersion": 27,
        },
        fixture={
            "fixturePath": root + "/fixture/MacScopeDebuggerFixture.app",
            "machOUUID": "11111111-2222-3333-4444-555555555555",
            "signingTeam": "TEAM000000",
            "displayName": "fixture ✓",
        },
        normalization=schema.make_normalization(
            [{"alias": "$ROOT", "path": root}], diagnostic_preview_bytes=8
        ),
        candidates=candidates,
        validator=schema.make_validator_envelope(),
    )
    return schema.seal_validator_digest(value)


class StrictJSONLoadingTests(unittest.TestCase):
    def test_rejects_duplicate_keys_and_nonfinite_numbers(self) -> None:
        with self.assertRaisesRegex(schema.SchemaError, "duplicate"):
            schema.strict_json_loads('{"a":1,"a":2}')
        for literal in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(literal=literal):
                with self.assertRaisesRegex(schema.SchemaError, "non-finite"):
                    schema.strict_json_loads('{"value":' + literal + "}")

    def test_rejects_encoding_size_depth_integer_and_string_bounds(self) -> None:
        with self.assertRaisesRegex(schema.SchemaError, "UTF-8"):
            schema.strict_json_loads(b"\xff")
        with self.assertRaisesRegex(schema.SchemaError, "byte limit"):
            schema.strict_json_loads("{}", max_bytes=1)
        with self.assertRaisesRegex(schema.SchemaError, "64-bit"):
            schema.strict_json_loads('{"value":9223372036854775808}')
        with self.assertRaisesRegex(schema.SchemaError, "nesting"):
            schema.strict_json_loads("[" * 66 + "0" + "]" * 66)
        oversized = "x" * (schema.MAX_STRING_BYTES + 1)
        with self.assertRaisesRegex(schema.SchemaError, "string"):
            schema.strict_json_loads(json.dumps({"value": oversized}))

    def test_load_aggregate_applies_strict_parser_and_schema(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "report.json"
            report.write_text(json.dumps(aggregate(str(root))), encoding="utf-8")
            self.assertEqual(schema.load_aggregate(report)["schema"], schema.SCHEMA_ID)
            report.write_text('{"schema":1,"schema":2}', encoding="utf-8")
            with self.assertRaisesRegex(schema.SchemaError, "duplicate"):
                schema.load_aggregate(report)


class AggregateContractTests(unittest.TestCase):
    def test_helpers_emit_exact_frozen_versions_shape_and_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = aggregate(directory)
        self.assertEqual(report["schema"], "macscope.ws18.debugger-transport-report.v1")
        self.assertEqual(report["canonicalizationVersion"], 1)
        self.assertEqual(report["candidateContractVersion"], 1)
        self.assertEqual(set(report), schema.TOP_LEVEL_KEYS)
        self.assertEqual(
            [item["candidate"] for item in report["candidates"]],
            list(schema.CANDIDATE_ORDER),
        )
        self.assertEqual(
            [item["name"] for item in report["candidates"][0]["runs"][0]["operations"]],
            list(schema.OPERATION_ORDER),
        )

    def test_rejects_unknown_missing_duplicate_or_reordered_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = aggregate(directory)
        unknown_key = copy.deepcopy(base)
        unknown_key["extra"] = True
        missing = copy.deepcopy(base)
        del missing["validator"]
        reordered = copy.deepcopy(base)
        reordered["candidates"][0], reordered["candidates"][1] = (
            reordered["candidates"][1],
            reordered["candidates"][0],
        )
        duplicate = copy.deepcopy(base)
        duplicate["candidates"][1]["candidate"] = duplicate["candidates"][0]["candidate"]
        for value in (unknown_key, missing, reordered, duplicate):
            with self.subTest(value=value):
                with self.assertRaises(schema.SchemaError):
                    schema.validate_aggregate(value)

    def test_rejects_version_mismatch_and_incomplete_or_reordered_operations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = aggregate(directory)
        wrong_version = copy.deepcopy(base)
        wrong_version["candidateContractVersion"] = 2
        incomplete = copy.deepcopy(base)
        incomplete["candidates"][0]["runs"][0]["operations"].pop()
        reordered = copy.deepcopy(base)
        operations = reordered["candidates"][0]["runs"][0]["operations"]
        operations[0], operations[1] = operations[1], operations[0]
        for value in (wrong_version, incomplete, reordered):
            with self.assertRaises(schema.SchemaError):
                schema.validate_aggregate(value)

    def test_rejects_ambiguous_or_unbounded_normalization_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = aggregate(directory)
        duplicate_alias = copy.deepcopy(base)
        duplicate_alias["normalization"]["pathAliases"].append(
            copy.deepcopy(duplicate_alias["normalization"]["pathAliases"][0])
        )
        bad_alias = copy.deepcopy(base)
        bad_alias["normalization"]["pathAliases"][0]["alias"] = "ROOT"
        bad_preview = copy.deepcopy(base)
        bad_preview["normalization"]["diagnosticPreviewBytes"] = 0
        for value in (duplicate_alias, bad_alias, bad_preview):
            with self.assertRaises(schema.SchemaError):
                schema.validate_aggregate(value)

    def test_validator_envelope_is_exact_versioned_and_lowercase_sha256(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = aggregate(directory)
        self.assertTrue(schema.validator_digest_matches(base))
        cases = []
        unknown = copy.deepcopy(base)
        unknown["validator"]["pass"] = True
        cases.append(unknown)
        wrong_name = copy.deepcopy(base)
        wrong_name["validator"]["name"] = "candidate.py"
        cases.append(wrong_name)
        wrong_version = copy.deepcopy(base)
        wrong_version["validator"]["contractVersion"] = 2
        cases.append(wrong_version)
        uppercase = copy.deepcopy(base)
        uppercase["validator"]["canonicalDigest"] = "A" * 64
        cases.append(uppercase)
        short = copy.deepcopy(base)
        short["validator"]["canonicalDigest"] = "0" * 63
        cases.append(short)
        for value in cases:
            with self.subTest(value=value["validator"]):
                with self.assertRaises(schema.SchemaError):
                    schema.validate_aggregate(value)


class CanonicalReportTests(unittest.TestCase):
    def test_volatile_roots_pids_ids_sessions_and_times_have_stable_digest(self) -> None:
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            left = aggregate(
                first,
                pid=4101,
                request_id="left-request",
                session_id="left-session",
                timestamp=1_700_000_000,
            )
            right = aggregate(
                second,
                pid=9901,
                request_id="right-request",
                session_id="right-session",
                timestamp=1_900_000_000,
            )
            self.assertEqual(schema.canonical_bytes(left), schema.canonical_bytes(right))
            self.assertEqual(schema.canonical_digest(left), schema.canonical_digest(right))
            self.assertEqual(schema.validator_digest(left), schema.validator_digest(right))

    def test_validator_digest_binds_semantics_and_detects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sealed = aggregate(directory)
        self.assertTrue(schema.validator_digest_matches(sealed))
        tampered = copy.deepcopy(sealed)
        tampered["fixture"]["signingTeam"] = "OTHERTEAM"
        self.assertFalse(schema.validator_digest_matches(tampered))
        resealed = schema.seal_validator_digest(tampered)
        self.assertTrue(schema.validator_digest_matches(resealed))
        self.assertNotEqual(
            sealed["validator"]["canonicalDigest"],
            resealed["validator"]["canonicalDigest"],
        )

    def test_mapping_insertion_order_does_not_change_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            left = aggregate(directory)
        right = copy.deepcopy(left)
        right["fixture"] = dict(reversed(list(right["fixture"].items())))
        right["toolchain"] = dict(reversed(list(right["toolchain"].items())))
        self.assertEqual(schema.canonical_bytes(left), schema.canonical_bytes(right))

    def test_semantic_identity_outcome_cleanup_and_diagnostics_change_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = aggregate(directory)
        mutations = []
        uuid_change = copy.deepcopy(base)
        uuid_change["fixture"]["machOUUID"] = "99999999-2222-3333-4444-555555555555"
        mutations.append(uuid_change)
        signing_change = copy.deepcopy(base)
        signing_change["fixture"]["signingTeam"] = "OTHERTEAM"
        mutations.append(signing_change)
        outcome_change = copy.deepcopy(base)
        outcome_change["candidates"][0]["runs"][0]["outcome"]["state"] = "timedOut"
        mutations.append(outcome_change)
        cleanup_change = copy.deepcopy(base)
        cleanup_change["candidates"][0]["runs"][0]["cleanupComplete"] = False
        mutations.append(cleanup_change)
        diagnostic_change = copy.deepcopy(base)
        diagnostic_change["candidates"][0]["runs"][0]["diagnostics"] = ["adapter failed"]
        mutations.append(diagnostic_change)
        base_digest = schema.canonical_digest(base)
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertNotEqual(schema.canonical_digest(mutation), base_digest)

    def test_paths_alias_only_at_real_component_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "build"
            root.mkdir()
            report = aggregate(str(root))
            report["fixture"]["outsidePath"] = str(root) + "-other/product"
            projected = schema.canonical_document(report)
        self.assertEqual(projected["fixture"]["fixturePath"], "$ROOT/fixture/MacScopeDebuggerFixture.app")
        self.assertNotIn("$ROOT", projected["fixture"]["outsidePath"])

    def test_path_alias_declaration_permutations_have_one_canonical_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = []
            for name in ("alpha", "beta", "gamma"):
                path = root / name
                path.mkdir()
                paths.append(path)
            base = aggregate(str(root))
            aliases = [
                {"alias": "$ALPHA", "path": str(paths[0])},
                {"alias": "$BETA", "path": str(paths[1])},
                {"alias": "$GAMMA", "path": str(paths[2])},
            ]
            digests = set()
            for permutation in itertools.permutations(aliases):
                candidate = copy.deepcopy(base)
                candidate["normalization"] = schema.make_normalization(
                    list(permutation), diagnostic_preview_bytes=8
                )
                digests.add(schema.canonical_digest(candidate))
        self.assertEqual(len(digests), 1)

    def test_diagnostics_retain_bounded_preview_full_hash_and_byte_count(self) -> None:
        diagnostic = "failure-✓-full-detail"
        with tempfile.TemporaryDirectory() as directory:
            report = aggregate(directory)
        report["candidates"][0]["runs"][0]["diagnostics"] = [diagnostic]
        projected = schema.canonical_document(report)
        item = projected["candidates"][0]["runs"][0]["diagnostics"][0]
        encoded = diagnostic.encode("utf-8")
        self.assertLessEqual(len(item["preview"].encode("utf-8")), 8)
        self.assertEqual(item["sha256"], hashlib.sha256(encoded).hexdigest())
        self.assertEqual(item["byteCount"], len(encoded))

    def test_encoding_is_compact_utf8_sorted_final_newline_and_write_digest_matches(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = aggregate(directory)
            destination = Path(directory) / "canonical.json"
            digest = schema.write_canonical(destination, report)
            payload = destination.read_bytes()
        self.assertTrue(payload.endswith(b"\n"))
        self.assertNotIn(b": ", payload)
        self.assertIn("✓".encode("utf-8"), payload)
        self.assertEqual(digest, hashlib.sha256(payload).hexdigest())
        self.assertEqual(digest, schema.canonical_digest(report))


if __name__ == "__main__":
    unittest.main()
