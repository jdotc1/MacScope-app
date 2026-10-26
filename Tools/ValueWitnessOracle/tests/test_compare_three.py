import copy
import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("compare_three", ROOT / "compare_three.py")
three = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(three)
FIXTURES = ROOT / "tests" / "fixtures"


def fixture(name):
    return json.loads((FIXTURES / name).read_text())


def second_build(oracle):
    other = copy.deepcopy(oracle)
    other["types"][1]["vwt"]["size"] = 24
    other["types"][1]["vwt"]["stride"] = 24
    return other


class CompareThreeTests(unittest.TestCase):
    def setUp(self):
        self.oracle = fixture("three_oracle.json")
        self.run = {"name": "sample-app-O-SampleApp", "image": "sample-app", "opt": "O",
                    "product": "SampleApp", "path": "/images/sample"}
        self.pair = (fixture("three_census_unstripped.json"), fixture("three_census_stripped.json"))
        self.dwarf = fixture("three_dwarf.json")

    def test_counts_reach_and_listed_disagreement(self):
        result = three.compare_image(self.run, self.oracle, self.pair, self.dwarf)
        runtime = result["runtime"]
        self.assertEqual((runtime["askable"], runtime["answered"], runtime["answeredTypeRows"],
                          runtime["concreteTypes"], runtime["externalRows"]), (8, 7, 6, 5, 1))
        self.assertEqual(runtime["unanswered"], {"generic": 1})
        unstripped, stripped = result["staticUnstripped"], result["staticStripped"]
        self.assertEqual([unstripped[k] for k in ("joined", "agree", "disagree", "runtimeOnly", "staticOnly")],
                         [5, 3, 1, 0, 1])
        self.assertEqual([stripped[k] for k in ("joined", "agree", "disagree", "runtimeOnly", "staticOnly")],
                         [3, 1, 1, 2, 0])
        self.assertEqual((stripped["incomplete"], stripped["diagnosticCountsValueWitness"]), (1, 1))
        for section in (unstripped, stripped):
            self.assertEqual(section["incompleteJoined"], 1)
            incomplete = next(row for row in section["types"] if row["metadataVA"] == 12288)
            self.assertEqual(incomplete["status"], "incomplete")
            self.assertNotIn(incomplete, section["disagreements"])
        self.assertAlmostEqual(result["symbolFreeReach"], 0.6)
        self.assertEqual(unstripped["disagreements"][0]["metadataVA"], 8192)
        self.assertEqual(unstripped["disagreements"][0]["differences"], {"size": {"oracle": 16, "static": 15}})
        dwarf = result["dwarf"]
        self.assertEqual((dwarf["joined"], dwarf["agree"], dwarf["disagree"]), (4, 3, 1))
        self.assertEqual(dwarf["byKind"]["enum"], {"joined": 1, "agree": 1, "disagree": 0})
        self.assertEqual(dwarf["disagreements"], [{"mangled": "6Sample1DV", "kind": "struct",
                                                   "runtime": 8, "dwarf": [4]}])
        engine = result["engine"]
        self.assertEqual((engine["computable"], engine["agree"], engine["disagree"],
                          engine["unsupported"], engine["unresolved"]), (2, 2, 0, 1, 3))

    def test_incomplete_excludes_matching_values_and_unjoined_rows_from_agreement(self):
        census = copy.deepcopy(self.pair[0])
        for row in census["valueWitnesses"]:
            row["isIncomplete"] = True
        result = three.compare_image(self.run, self.oracle, (census, census), None)
        for label in ("Unstripped", "Stripped"):
            section = result["static" + label]
            self.assertEqual((section["joined"], section["agree"], section["disagree"],
                              section["incompleteJoined"], section["incomplete"]), (5, 0, 0, 5, 6))
            self.assertEqual(section["disagreements"], [])
            self.assertEqual({row["status"] for row in section["types"]}, {"incomplete"})
        board = three.scoreboard_rows({self.run["name"]: result}, [])
        self.assertIn(["sample-app/SampleApp", "O", "static_agree_stripped", 0, 0], board)
        self.assertIn(["sample-app/SampleApp", "O", "static_incomplete_joined_stripped", 5, 5], board)
        self.assertIn(["sample-app/SampleApp", "O", "static_incomplete_stripped", 6, 6], board)

    def test_failed_oracle_is_reported_without_comparisons(self):
        failed = {"status": "failed", "summary": {}, "types": [],
                  "unanswered": [{"detail": "child crashed"}]}
        result = three.compare_image(self.run, failed, (None, None), None)
        self.assertEqual(result["runtime"]["status"], "failed")
        self.assertNotIn("staticStripped", result)

    def test_pending_census_is_not_a_zero(self):
        result = three.compare_image(self.run, self.oracle, (self.pair[0], None), None)
        self.assertEqual(result["staticStripped"]["status"], "pending")
        self.assertEqual(result["dwarf"]["status"], "no-debug-info")
        self.assertAlmostEqual(result["symbolFreeReach"], 0.0)

    def test_cross_build_lists_the_difference(self):
        oracles = {"sample-app-O-SampleApp": self.oracle,
                   "sample-app-Osize-SampleApp": second_build(self.oracle)}
        reports = three.cross_build({}, oracles)
        hidden = next(r for r in reports if r["image"] == "sample-app")
        self.assertEqual((hidden["joined"], hidden["equal"], len(hidden["differing"])), (6, 5, 1))
        self.assertEqual(hidden["differing"][0]["differences"],
                         {"size": [16, 24], "stride": [16, 24]})
        sample_tool = next(r for r in reports if r["image"] == "sample_tool")
        self.assertEqual(sample_tool["status"], "unavailable")

    def test_conflicting_duplicate_raises(self):
        self.oracle["types"].append(copy.deepcopy(self.oracle["types"][0]))
        self.oracle["types"][-1]["vwt"]["size"] = 9
        with self.assertRaisesRegex(ValueError, "conflicting duplicate"):
            three.compare_image(self.run, self.oracle, self.pair, self.dwarf)

    def test_command_line_reuses_external_receipts_without_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original, current = root / "original", root / "current"
            name = self.run["name"]
            oracle_path = original / "receipts" / "oracle" / (name + ".json")
            oracle_path.parent.mkdir(parents=True)
            oracle_path.write_text(json.dumps(self.oracle))
            dwarf_path = original / "receipts" / "dwarf" / (name + ".json")
            dwarf_path.parent.mkdir(parents=True)
            dwarf_path.write_text(json.dumps(self.dwarf))
            for mode, census in zip(("unstripped", "stripped"), self.pair):
                group = "O-" + mode + "-01"
                inputs = original / "census" / group / "inputs.txt"
                inputs.parent.mkdir(parents=True)
                inputs.write_text(self.run["path"] + (".unstripped" if mode == "unstripped" else "") + "\n")
                receipt = original / "receipts" / "census" / group / "census-sample.json"
                receipt.parent.mkdir(parents=True)
                receipt.write_text(json.dumps(census))
            (current / "receipts").mkdir(parents=True)
            document = {"runs": [dict(self.run, receipt=str(oracle_path))],
                        "census_run_dir": str(original), "dwarf_run_dir": str(original)}
            (current / "receipts" / "run.json").write_text(json.dumps(document))
            output = current / "receipts" / "compare"
            self.assertEqual(three.main([str(current), "--out", str(output)]), 0)
            result = json.loads((output / ("compare-" + name + ".json")).read_text())
            self.assertEqual(result["staticUnstripped"]["incompleteJoined"], 1)
            self.assertEqual(result["dwarf"]["joined"], 4)
            with open(current / "receipts" / "disagreements.csv") as handle:
                rows = list(csv.DictReader(handle))
            static = next(row for row in rows if row["field"] == "static-unstripped.size")
            self.assertEqual((static["runtime"], static["static"], static["dwarf"]), ("16", "15", "16"))
            self.assertFalse((current / "receipts" / "oracle").exists())
            self.assertFalse((current / "receipts" / "dwarf").exists())
            self.assertFalse((current / "census").exists())

    def test_command_line_writes_scoreboard_and_every_disagreement(self):
        with tempfile.TemporaryDirectory() as directory:
            run_dir = Path(directory)
            runs = []
            for opt, path, oracle in (("O", "/images/sample", self.oracle),
                                      ("Osize", "/images/sample2", second_build(self.oracle))):
                name = "sample-app-{}-SampleApp".format(opt)
                runs.append({"name": name, "image": "sample-app", "opt": opt,
                             "product": "SampleApp", "path": path})
                for sub in ("oracle", "dwarf"):
                    (run_dir / "receipts" / sub).mkdir(parents=True, exist_ok=True)
                (run_dir / "receipts" / "oracle" / (name + ".json")).write_text(json.dumps(oracle))
                (run_dir / "receipts" / "dwarf" / (name + ".json")).write_text(json.dumps(self.dwarf))
                stem = Path(path).stem
                for group, census, line in ((opt + "-unstripped-01", self.pair[0], path + ".unstripped"),
                                            (opt + "-stripped-01", self.pair[1], path)):
                    (run_dir / "census" / group).mkdir(parents=True)
                    (run_dir / "census" / group / "inputs.txt").write_text(line + "\n")
                    (run_dir / "receipts" / "census" / group).mkdir(parents=True)
                    receipt = "census-" + Path(path).name + ".json"
                    (run_dir / "receipts" / "census" / group / receipt).write_text(json.dumps(census))
                del stem
            (run_dir / "receipts" / "run.json").write_text(json.dumps({"runs": runs}))
            self.assertEqual(three.main([str(run_dir), "--out", str(run_dir / "receipts" / "compare")]), 0)
            with open(run_dir / "receipts" / "scoreboard.csv") as handle:
                board = list(csv.reader(handle))
            self.assertEqual(board[0], ["image", "opt", "measure", "numerator", "denominator"])
            self.assertIn(["sample-app/SampleApp", "O", "static_joined_stripped", "3", "5"], board)
            self.assertIn(["sample-app/SampleApp", "O", "rt_answered", "7", "8"], board)
            self.assertIn(["sample-app/SampleApp", "O", "static_agree_unstripped", "3", "4"], board)
            self.assertIn(["sample-app/SampleApp", "O", "static_agree_stripped", "1", "2"], board)
            for mode in ("unstripped", "stripped"):
                self.assertIn(["sample-app/SampleApp", "O", "static_incomplete_joined_" + mode,
                               "1", "5" if mode == "unstripped" else "3"], board)
            self.assertIn(["sample-app/SampleApp", "O", "static_incomplete_stripped", "1", "3"], board)
            self.assertIn(["sample-app/SampleApp", "O->Osize", "xbuild_equal", "5", "6"], board)
            with open(run_dir / "receipts" / "disagreements.csv") as handle:
                rows = list(csv.reader(handle))
            self.assertEqual(rows[0], ["image", "opt", "mangled", "kind", "field", "runtime", "static", "dwarf"])
            self.assertIn(["sample-app/SampleApp", "O", "6Sample1BV", "struct",
                           "static-unstripped.size", "16", "15", "16"], rows)
            self.assertIn(["sample-app/SampleApp", "O", "6Sample1DV", "struct",
                           "dwarf.size", "8", "", "4"], rows)
            self.assertFalse(any(row[2] == "6Sample1CV" and row[4].startswith("static-")
                                 for row in rows[1:]))
            self.assertTrue((run_dir / "receipts" / "compare" / "summary-tables.md").exists())


if __name__ == "__main__":
    unittest.main()
