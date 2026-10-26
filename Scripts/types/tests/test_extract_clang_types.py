import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("extract_clang_types", ROOT / "Scripts/types/extract_clang_types.py")
extractor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(extractor)
FIXTURES = ROOT / "Scripts/types/fixtures"


class ExtractClangTypesTests(unittest.TestCase):
    def test_layout_smoke_matches_pinned_compiler_facts(self):
        evidence = Path(os.environ.get("DP06_EVIDENCE_ROOT", str(ROOT.parent / "DP06Evidence.noindex")))
        evidence.mkdir(exist_ok=True)
        output = evidence / "layout-smoke.archive.json"
        expected = json.loads((FIXTURES / "layout-smoke.expected.json").read_text())
        profile = extractor.configuration.load_profile(ROOT / "Scripts/types/profiles/minimal-darwin.json")
        doc = extractor.extract(profile, FIXTURES / "layout-smoke.h", output)
        by_name = {node["spelling"]: node for node in doc["types"]}
        by_id = {node["id"]: node for node in doc["types"]}
        for name, facts in expected["records"].items():
            with self.subTest(record=name):
                node = by_name[name]
                self.assertEqual(node["layout"], {"status": "known", "sizeBytes": facts["sizeBytes"], "alignmentBytes": facts["alignmentBytes"]})
                self.assertEqual([field.get("bitOffset") for field in node["fields"]], facts["bitOffsets"])
                self.assertEqual([field.get("bitWidth") for field in node["fields"]], facts["bitWidths"])
        flexible = by_name["struct Flexible"]["fields"][-1]
        self.assertTrue(flexible["flexibleArray"])
        self.assertEqual(by_id[flexible["typeID"]]["layout"]["status"], "unknown")
        anonymous = by_name["struct Anonymous"]["fields"][-1]
        self.assertTrue(anonymous["anonymous"])
        nested = by_id[anonymous["typeID"]]
        self.assertEqual(nested["recordKind"], "union")
        self.assertEqual([f["bitOffset"] for f in nested["fields"]], [0, 0])
        self.assertEqual(by_name["struct Opaque"]["layout"]["status"], "unknown")
        self.assertEqual(by_name["Count"]["kind"], "typedef")
        self.assertEqual(by_id[by_name["Count"]["underlyingTypeID"]]["spelling"], "unsigned long")
        wide = by_name["enum Wide"]
        self.assertEqual(wide["enumValues"][-1]["value"], expected["unsignedMaximum"])
        self.assertFalse(by_id[wide["underlyingTypeID"]]["signed"])
        callback = by_id[by_name["struct Callbacks"]["fields"][0]["typeID"]]
        self.assertEqual(callback["kind"], "pointer")
        self.assertEqual(by_id[callback["pointeeTypeID"]]["kind"], "opaque")
        self.assertEqual(doc["provenance"]["targetTriple"], expected["target"])
        self.assertTrue(doc["provenance"]["compilerVersion"])
        self.assertTrue(doc["provenance"]["libclangVersion"])
        self.assertEqual(json.loads(output.read_bytes()), doc)
        corrupt = copy.deepcopy(doc)
        padded = next(n for n in corrupt["types"] if n["spelling"] == "struct Padded")
        padded["fields"][1]["bitOffset"] *= 8
        with self.assertRaises(extractor.ExtractionError):
            extractor.validate_archive(corrupt)
        (evidence / "layout-smoke.compiler.json").write_text(json.dumps(doc["provenance"], sort_keys=True, indent=2) + "\n")
        print("DP06_LIBCLANG_WITNESS " + json.dumps({"types": len(doc["types"]), "records": len(expected["records"]),
              "compiler": doc["provenance"]["compilerVersion"], "libclang": doc["provenance"]["libclangVersion"],
              "configurationID": doc["configurationID"], "archive": str(output)}, sort_keys=True))

    def test_failure_publishes_no_archive_and_source_scope_is_bounded(self):
        with tempfile.TemporaryDirectory(prefix="dp06-failure-", dir=ROOT.parent) as temporary:
            directory = Path(temporary)
            output = directory / "previous.json"
            output.write_bytes(b"previous accepted archive")
            def failed_worker(config, source, directory):
                raise extractor.ExtractionError("clang error diagnostics: simulated malformed declaration")
            with self.assertRaisesRegex(extractor.ExtractionError, "clang error diagnostics"):
                extractor.extract({}, FIXTURES / "layout-smoke.h", output,
                                  resolve=lambda profile, root: {}, worker=failed_worker)
            self.assertEqual(output.read_bytes(), b"previous accepted archive")
            self.assertEqual(sorted(p.name for p in directory.iterdir()), ["previous.json"])
            header = directory / "include.h"
            header.write_text('#include "other.h"\n')
            with self.assertRaisesRegex(extractor.ExtractionError, "includes"):
                extractor.checked_source(header)
            header.write_bytes(b" " * (extractor.MAX_SOURCE + 1))
            with self.assertRaisesRegex(extractor.ExtractionError, "bounded"):
                extractor.checked_source(header)


if __name__ == "__main__":
    unittest.main()
