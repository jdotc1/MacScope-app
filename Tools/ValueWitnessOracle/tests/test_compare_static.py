import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("compare_static", ROOT / "compare_static.py")
compare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compare)


class CompareStaticTests(unittest.TestCase):
    def setUp(self):
        fixtures = ROOT / "tests" / "fixtures"
        self.oracle = json.loads((fixtures / "compare_oracle.json").read_text())
        self.census = json.loads((fixtures / "compare_census.json").read_text())

    def test_fixed_fixture_counts_and_size_difference(self):
        result = compare.compare_static(self.oracle, self.census)
        self.assertEqual({key: result[key] for key in
                          ("joined", "agree", "disagree", "oracleOnly", "staticOnly")},
                         {"joined": 2, "agree": 1, "disagree": 1, "oracleOnly": 1, "staticOnly": 1})
        self.assertEqual(result["types"][0]["status"], "agree")
        self.assertEqual(result["types"][1]["differences"], {"size": {"oracle": 16, "static": 15}})

    def test_missing_census_is_pending(self):
        self.assertEqual(compare.compare_static(self.oracle, None),
                         {"status": "pending", "reason": "no census receipt"})

    def test_hex_address_join_and_missing_value_is_disagreement(self):
        self.census["valueWitnesses"][0]["metadataAddress"] = "0x1000"
        del self.census["valueWitnesses"][0]["flags"]
        result = compare.compare_static(self.oracle, self.census)
        self.assertEqual(result["joined"], 2)
        self.assertEqual(result["types"][0]["differences"], {"flags": {"oracle": 7, "static": None}})

    def test_external_and_unanswered_metadata_are_not_joined(self):
        self.oracle["types"].append({"metadataVA": 16384, "external": True, "vwt": {"size": 4}})
        self.oracle["types"].append({"metadataVA": 16384, "reason": "nil-from-runtime"})
        self.assertEqual(compare.compare_static(self.oracle, self.census)["staticOnly"], 1)

    def test_conflicting_duplicate_is_error(self):
        duplicate = copy.deepcopy(self.oracle["types"][0])
        duplicate["vwt"]["size"] = 9
        self.oracle["types"].append(duplicate)
        with self.assertRaisesRegex(ValueError, "conflicting duplicate"):
            compare.compare_static(self.oracle, self.census)

    def test_memorylayout_joins_names_and_compares_available_facts(self):
        result = compare.compare_memorylayout(self.oracle, {"layouts": [
            {"qualifiedName": "Fixture.Mismatch", "size": 16, "stride": 16, "alignment": 8},
            {"qualifiedName": "Fixture.Agree", "size": 8, "stride": 8, "alignment": 8}]})
        self.assertEqual((result["joined"], result["agree"], result["disagree"]), (2, 2, 0))
        self.assertEqual(result["oracleOnly"], 1)

    def test_cli_writes_pending_and_continues(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            root = Path(directory)
            oracle = root / "oracle.json"
            oracle.write_text(json.dumps(self.oracle))
            output = root / "compare.json"
            self.assertEqual(compare.main([str(oracle), str(root / "absent.json"), "--out", str(output)]), 0)
            self.assertEqual(json.loads(output.read_text()),
                             {"status": "pending", "reason": "no census receipt"})


if __name__ == "__main__":
    unittest.main()
