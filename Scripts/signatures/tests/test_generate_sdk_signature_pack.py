#!/usr/bin/env python3
"""Focused tests for the HOP-5 offline SDK signature-pack generator."""

import importlib.util
import json
import tempfile
from unittest.mock import patch
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "generate_sdk_signature_pack.py"
SPEC = importlib.util.spec_from_file_location("generate_sdk_signature_pack", SCRIPT)
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


class SpellingTests(unittest.TestCase):
    def test_return_type_handles_plain_and_function_pointer_returns(self) -> None:
        self.assertEqual(generator.return_type("int (const char *, ...)"), "int")
        self.assertEqual(generator.return_type("void (int) __attribute__((noreturn))"), "void")
        self.assertEqual(generator.return_type("void (*(int, void (*)(int)))(int)"), "void (*)(int)")
        self.assertEqual(generator.return_type("const char *(void)"), "const char *")

    def test_clean_type_strips_nullability_and_restrict(self) -> None:
        self.assertEqual(generator.clean_type("const char *_Nonnull __restrict"), "const char *")
        self.assertEqual(generator.clean_type("char *_Nullable *_Nullable"), "char **")

    def test_abi_type_resolves_floating_typedefs_and_drops_aggregates(self) -> None:
        typedefs = {"CFAbsoluteTime": "CFTimeInterval", "CFTimeInterval": "double",
                    "CFRange": "struct CFRange", "CFIndex": "long"}
        self.assertEqual(generator.abi_type("CFAbsoluteTime", typedefs), "double")
        self.assertEqual(generator.abi_type("CFIndex", typedefs), "CFIndex")
        self.assertIsNone(generator.abi_type("CFRange", typedefs))
        self.assertEqual(generator.abi_type("CFRange *", typedefs), "CFRange *")

    def test_format_attributes_come_from_the_text_dump(self) -> None:
        dump = [
            "|-FunctionDecl 0x1 <line:1:1, col:9> col:5 implicit printf 'int (const char *, ...)' extern",
            "| |-ParmVarDecl 0x2 <<invalid sloc>> <invalid sloc> 'const char *'",
            "| `-FormatAttr 0x3 <col:5> Implicit printf 1 2",
            "|-FunctionDecl 0x4 <line:2:1, col:9> col:6 abort 'void (void) __attribute__((noreturn))'",
            "| `-NoThrowAttr 0x5 <col:6> Implicit",
        ]
        self.assertEqual(generator.format_attributes(dump), {"printf": ("printf", 1, 2)})


class ExpansionTests(unittest.TestCase):
    def test_integer_typedefs_have_proven_carriers_and_unknowns_reject(self):
        typedefs = {"OSStatus": "SInt32", "SInt32": "int", "CGFloat": "double",
                    "io_object_t": "unsigned int", "WideEnum": "enum WideEnum",
                    "enum WideEnum": "unsigned long"}
        self.assertEqual(generator.abi_scalar("OSStatus", typedefs), "int")
        self.assertEqual(generator.abi_scalar("CGFloat", typedefs), "double")
        self.assertEqual(generator.abi_scalar("io_object_t", typedefs), "unsigned int")
        self.assertEqual(generator.abi_scalar("WideEnum", typedefs), "unsigned long")
        for spelling in ["unknown_t", "enum Unfixed", "struct Pair", "float __attribute__((ext_vector_type(4)))",
                         "double _Complex", "__int128"]:
            self.assertIsNone(generator.abi_scalar(spelling, typedefs), spelling)
        self.assertEqual(generator.abi_scalar("const struct Pair *", typedefs), "const struct Pair *")

    def test_typedef_cycles_fail_closed(self):
        self.assertIsNone(generator.abi_scalar("A", {"A": "B", "B": "A"}))

    def test_semantic_annotations_deduplicate_without_macro_guessing(self):
        lines = ["|-FunctionDecl 0x1 <line:1:1, col:9> col:5 copy 'Ref (void)'",
                 "| |-CFReturnsRetainedAttr 0x2 <col:1> Inherited",
                 '| |-AvailabilityAttr 0x3 <col:1> macos 13.0 0 0 "" "" 0',
                 "| `-CFReturnsRetainedAttr 0x4 <col:1>",
                 "|-FunctionDecl 0x5 <line:2:1> other 'void (void)'"]
        result = generator.declaration_annotations(lines)
        self.assertEqual(result["copy"]["ownership"], ["CFReturnsRetained"])
        self.assertEqual(result["copy"]["availability"], ['macos 13.0 0 0 "" "" 0'])
        self.assertNotIn("other", result)

    def test_serialization_is_deterministic_for_input_order(self):
        header = {"format": generator.FORMAT_IDENTIFIER, "formatVersion": 1,
                  "generator": {"sdk": "fixture"}, "families": []}
        entries = [{"name": "z", "returns": "int"}, {"name": "a", "returns": "void"}]
        self.assertEqual(generator.encode_pack(header, entries),
                         generator.encode_pack(header, reversed(entries)))

    def test_committed_pack_budget_provenance_and_rejections_without_sdk_access(self):
        path = generator.DEFAULT_OUTPUT
        data = path.read_bytes()
        pack = json.loads(data)
        manifest = json.loads((SCRIPT.parent / "sdk_signature_manifest.json").read_text())
        ledger = json.loads((SCRIPT.parent / "sdk_signature_rejections.json").read_text())
        self.assertGreater(len(pack["entries"]), 4000)
        self.assertLess(len(data), 8 * 1024 * 1024)
        self.assertEqual(manifest["statistics"]["entries"], len(pack["entries"]))
        self.assertEqual(manifest["statistics"]["bytes"], len(data))
        self.assertEqual(manifest["statistics"]["rejections"], len(ledger["rejections"]))
        names = [e["name"] for e in pack["entries"]]
        self.assertEqual(names, sorted(set(names)))
        headers = {h["path"]: h for f in manifest["families"].values() for h in f["headers"]}
        for entry in pack["entries"]:
            self.assertTrue(entry["headers"])
            self.assertIn("abiReturns", entry)
            for header in entry["headers"]:
                self.assertIn(header, headers)
                self.assertRegex(headers[header]["sha256"], r"^[0-9a-f]{64}$")
        self.assertTrue(any(r["reason"] == "unsupported-parameter-ABI" for r in ledger["rejections"]))

    def test_anonymous_fixed_enum_resolves_through_declaration_id(self):
        root = {"inner": [
            {"kind": "EnumDecl", "id": "enum-1", "fixedUnderlyingType": {"qualType": "unsigned char"}},
            {"kind": "TypedefDecl", "name": "os_log_type_t",
             "type": {"qualType": "enum os_log_type_t", "desugaredQualType": "os_log_type_t"},
             "inner": [{"kind": "ElaboratedType", "inner": [
                 {"kind": "EnumType", "decl": {"id": "enum-1"}}]}]},
        ]}
        typedefs = {}
        generator.walk(root, generator.LocationTracker(), [], typedefs)
        self.assertEqual(generator.abi_scalar("os_log_type_t", typedefs), "uint8_t")

    def test_conflicting_redeclarations_are_rejected(self):
        family = {"name": "fixture", "files": [r"usr/include/.+\.h"], "exclude": []}
        def declaration(type_name):
            return {"kind": "FunctionDecl", "name": "probe", "mangledName": "_probe",
                    "loc": {"file": "/SDK/usr/include/fixture.h"},
                    "type": {"qualType": "int (" + type_name + ")"},
                    "inner": [{"kind": "ParmVarDecl", "name": "value", "type": {"qualType": type_name}}]}
        root = {"kind": "TranslationUnitDecl", "inner": [declaration("int"), declaration("double")]}
        rejections = []
        with patch.object(generator, "ast_inputs", return_value=(root, "", {})):
            entries = generator.collect_family(Path("/SDK"), family, Path("/unused"), rejections)
        self.assertEqual(entries, {})
        self.assertEqual(rejections[0]["reason"], "conflicting-redeclarations")

    def test_conflicting_symbol_cannot_be_reintroduced_by_third_alias(self):
        family = {"name": "fixture", "files": [r"usr/include/.+\.h"], "exclude": []}
        nodes = [{"kind": "FunctionDecl", "name": name, "mangledName": "_same",
                  "loc": {"file": "/SDK/usr/include/fixture.h"},
                  "type": {"qualType": returns + " (void)"}}
                 for name, returns in [("one", "int"), ("two", "double"), ("three", "int")]]
        rejections = []
        with patch.object(generator, "ast_inputs", return_value=({"inner": nodes}, "", {})):
            entries = generator.collect_family(Path("/SDK"), family, Path("/unused"), rejections)
        self.assertEqual(entries, {})
        self.assertEqual([r["reason"] for r in rejections], ["conflicting-symbol-declarations"] * 2)

    def test_ast_cache_reuses_recorded_provenance_without_header_reads(self):
        with tempfile.TemporaryDirectory() as folder:
            scratch = Path(folder)
            family = {"name": "fixture", "includes": [], "language": "c", "defines": []}
            identity = {"sdk": "/SDK", "sdkVersion": "fixture", "clang": "fixture", "family": family}
            key = generator.hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:20]
            cache = scratch / ("fixture-" + key)
            cache.mkdir()
            (cache / "ast.json").write_text('{"kind":"TranslationUnitDecl"}')
            (cache / "ast.txt").write_text("fixture")
            (cache / "provenance.json").write_text('{"headers":[]}')
            with patch.object(generator, "run", return_value="fixture"), \
                    patch.object(generator.subprocess, "run", side_effect=AssertionError("clang must not rerun")):
                root, text, provenance = generator.ast_inputs(Path("/SDK"), family, scratch)
            self.assertEqual(root["kind"], "TranslationUnitDecl")
            self.assertEqual(text, "fixture")
            self.assertEqual(provenance, {"headers": []})


if __name__ == "__main__":
    unittest.main()
