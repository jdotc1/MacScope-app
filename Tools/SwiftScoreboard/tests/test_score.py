"""Hand-computed measurements for twelve distinct twin function starts."""

import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("score", ROOT / "score.py")
score = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(score)
FIXTURES = Path(__file__).with_name("fixtures")


class ScoreTests(unittest.TestCase):
    def setUp(self):
        self.capture = json.loads((FIXTURES / "synthetic.functions.json").read_text())
        self.nm = (FIXTURES / "synthetic.nm.txt").read_text()
        self.alignment = json.loads((FIXTURES / "synthetic.alignment.json").read_text())
        self.spellings = json.loads((FIXTURES / "synthetic.demangled.json").read_text())
        self.expected = json.loads((FIXTURES / "synthetic.expected.json").read_text())

    def result(self, control=False):
        return score.score_binary(self.capture, self.nm, self.alignment, self.spellings,
                                  binary="Synthetic", opt="O", control=control)

    def test_hand_computed_twelve_function_counts(self):
        result = self.result()
        for measure, (numerator, denominator) in self.expected["metrics"].items():
            self.assertEqual(result["metrics"][measure],
                             {"numerator": numerator, "denominator": denominator}, measure)
        for class_name, counts in self.expected["class_counts"].items():
            actual = result["classes"][class_name]
            values = [actual[key]["numerator"] for key in
                      ("class_census", "fn_start_recall", "name_given", "name_exact")]
            values += [actual["merged"], actual["specialised"]]
            self.assertEqual(values, counts, class_name)

    def test_aliases_and_non_text_alias_names_are_accepted_once(self):
        self.capture[1][2]["name"] = "data_alias"
        result = self.result()
        self.assertEqual(result["metrics"]["name_exact"]["numerator"], 6)
        self.assertEqual(result["metrics"]["fn_start_recall"]["denominator"], 12)
        self.assertEqual(result["classes"]["metadataAccessor"]["name_exact"]["numerator"], 1)

    def test_echoed_mangled_name_is_not_normalized_as_c_symbol(self):
        raw = "_$s4Test3fooyyF"
        self.spellings[raw] = raw
        self.capture[1][1]["name"] = raw
        result = self.result()
        self.assertEqual(result["metrics"]["name_exact"]["numerator"], 7)
        row = next(r for r in result["ground_truth"] if r["address"] == "0x1010")
        self.assertEqual(row["expected_spellings"], [raw])

    def test_normalization_prefixes_and_raw_aliases(self):
        for prefix in ("_$s", "$s", "_$S", "$S", "_T0", "_$e"):
            raw = prefix + "example"
            self.assertEqual(score.normalized_name(raw, {raw: "decoded"}), "decoded")
        self.assertEqual(score.normalized_name("_name", {}), "name")
        self.assertEqual(score.normalized_name("__name", {}), "_name")
        self.assertEqual(score.normalized_name("sub_1010", {}), "sub_1010")
        result = self.result()
        self.assertEqual(result["metrics"]["name_raw_exact"], {"numerator": 2, "denominator": 10})
        self.assertEqual(result["classes"]["metadataAccessor"]["name_exact"]["numerator"], 1)

    def test_existing_cache_batches_only_new_app_names(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            cache = output / "spellings.json"
            cache.write_text(json.dumps(self.spellings))
            with patch.object(score, "demangle_names", side_effect=lambda names: {n: n for n in names}) as batch:
                score.score_capture(
                    FIXTURES / "synthetic.functions.json", FIXTURES / "synthetic.nm.txt",
                    FIXTURES / "synthetic.alignment.json", output / "Synthetic.scoreboard.json",
                    {"binary": "Synthetic", "opt": "O"}, demangle_cache_path=cache)
            self.assertEqual(batch.call_count, 1)
            expected = {row["name"] for row in self.capture[1]} - self.spellings.keys()
            self.assertEqual(batch.call_args.args[0], expected)

    def test_all_address_records_retain_specialisation_and_merge_flags(self):
        result = self.result()
        row = next(r for r in result["ground_truth"] if r["address"] == "0x1050")
        self.assertTrue(row["merged"])
        self.assertTrue(row["specialised"])

    def test_extra_starts_distinguish_splits_and_gaps(self):
        extras = self.result()["extra_starts"]
        self.assertEqual({row["address"]: row["placement"] for row in extras}, self.expected["extras"])
        self.assertEqual(extras[0]["nearest_twin_address"], "0x1030")
        self.assertEqual(extras[1]["nearest_twin_address"], "0x1080")

    def test_control_lists_every_name_and_discovery_miss(self):
        result = self.result(control=True)
        self.assertTrue(result["control"])
        self.assertEqual([row["address"] for row in result["fn_start_recall_misses"]], self.expected["unreached"])
        self.assertEqual([row["address"] for row in result["name_wrong"]], self.expected["wrong"])
        self.assertEqual(len(result["name_exact_misses"]), 4)
        self.assertTrue(all("app_name" in row and "app_name_normalized" in row and "expected_spellings" in row
                            for row in result["name_exact_misses"]))

    def test_generated_rule_preserves_named_prefixes(self):
        for name in ("", "_entry", "__text", "sub_123", "loc_0xABC", "unk_0Xabcd", "off_f", "nullsub_99"):
            self.assertTrue(score.is_generated_name(name), name)
        for name in ("sub_", "sub_0x", "sub_hello", "function", "_main", "sub_abcd_extra"):
            self.assertFalse(score.is_generated_name(name), name)

    def test_dwarf_only_start_is_counted_without_inventing_nm_names(self):
        self.nm = "\n".join(line for line in self.nm.splitlines() if not line.endswith(" _eleven"))
        result = self.result()
        self.assertEqual(result["metrics"]["fn_start_recall"]["denominator"], 12)
        row = result["addresses_without_twin_names"][0]
        self.assertEqual(row["address"], "0x10a0")
        self.assertEqual(row["expected_spellings"], [])
        self.assertEqual(row["dwarf_names"], ["_eleven"])

    def test_nm_only_extent_uses_next_start_and_section_end(self):
        self.alignment["functions"] = [row for row in self.alignment["functions"]
                                       if row["low_pc"] not in ("0x1000", "0x10b0")]
        self.assertEqual(self.result()["metrics"]["fn_extent_exact"]["numerator"], 8)

    def test_empty_sets_have_zero_denominators(self):
        self.nm = ""
        self.alignment = {"functions": []}
        self.capture[1] = []
        result = self.result()
        self.assertTrue(all(metric == {"numerator": 0, "denominator": 0}
                            for metric in result["metrics"].values()))

    def test_reject_conflicting_duplicate_rows_and_missing_fields(self):
        self.capture[1].append({**self.capture[1][0], "name": "different"})
        with self.assertRaisesRegex(ValueError, "Conflicting app"):
            self.result()
        self.capture[1].pop()
        del self.capture[1][0]["end"]
        with self.assertRaisesRegex(ValueError, "address"):
            self.result()

    def test_actual_result_envelope_and_text_section_required(self):
        with self.assertRaisesRegex(ValueError, "four CLI results"):
            score.parse_capture({"results": self.capture})
        self.capture[0][0]["name"] = "__TEXT.__stubs"
        with self.assertRaisesRegex(ValueError, "exactly one __text"):
            self.result()

    def test_demangler_batch_preserves_echoed_lines_and_detects_loss(self):
        with patch.object(score, "_run_demangler", return_value="Swift.foo() -> ()\n_main\n") as run:
            result = score.demangle_names(["_main", "_$s3foo", "_main"])
        self.assertEqual(result, {"_$s3foo": "Swift.foo() -> ()", "_main": "_main"})
        run.assert_called_once_with("_$s3foo\n_main\n")
        with patch.object(score, "_run_demangler", return_value="only one\n"):
            with self.assertRaisesRegex(ValueError, "returned 1 lines for 2"):
                score.demangle_names(["a", "b"])

    def test_large_real_demangler_batch(self):
        names = ["_$s4Test3foo{}yyF".format(i) for i in range(200000)]
        names.append("_$s4Test3fooyyF")
        result = score.demangle_names(names)
        self.assertEqual(len(result), 200001)
        self.assertEqual(set(result), set(names))
        self.assertEqual(result["_$s4Test3fooyyF"], "Test.foo() -> ()")
        self.assertTrue(all(result.values()))

    def test_demangler_timeout_rejects_partial_output(self):
        import subprocess
        import sys
        real_popen = subprocess.Popen
        def slow_process(command, **kwargs):
            return real_popen([sys.executable, "-c",
                "import sys,time; print('partial', flush=True); time.sleep(10)"], **kwargs)
        with patch.object(score.subprocess, "Popen", side_effect=slow_process), \
                patch.object(score, "DEMANGLE_TIMEOUT_SECONDS", 0.1):
            with self.assertRaises(subprocess.TimeoutExpired):
                score.demangle_names(["x" * 200000])

    def test_writes_full_unreached_csv_and_excludes_controls_from_class_totals(self):
        main = self.result()
        control = self.result(control=True)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            score.write_receipt(main, output / "Synthetic.scoreboard.json", output / "Synthetic.unreached.txt")
            score.write_aggregate([main, control], output)
            receipt = json.loads((output / "Synthetic.scoreboard.json").read_text())
            self.assertEqual(receipt, main)
            missing = (output / "Synthetic.unreached.txt").read_text()
            for addr in self.expected["unreached"]:
                self.assertIn(addr, missing)
            with (output / "scoreboard.csv").open() as stream:
                rows = list(csv.DictReader(stream))
            self.assertTrue(any(row["binary"] == "Synthetic (unstripped control)" for row in rows))
            self.assertTrue(any(row["measure"] == "fn_extent_within" for row in rows))
            summary = (output / "SUMMARY.md").read_text()
            self.assertIn("| function | 3 | 3 | 2 | 2 | 1 | 1 |", summary)
            self.assertIn("10/12 (83.33%)", summary)

    def test_unreached_receipt_truncates_only_per_class_list(self):
        self.capture[1] = []
        self.capture[0][0]["size"] = 16000
        self.alignment = {"functions": []}
        self.nm = "\n".join("{:016x} T _name{}".format(0x1000 + i * 16, i) for i in range(501))
        self.spellings = {"_name{}".format(i): "_name{}".format(i) for i in range(501)}
        result = self.result()
        self.assertEqual(len(result["classes"]["other"]["unreached"]), 500)
        self.assertTrue(result["classes"]["other"]["unreached_list_truncated"])
        self.assertEqual(len(result["fn_start_recall_misses"]), 501)

    def test_cache_reuses_one_demangle_batch_for_control(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            cache = output / "spellings.json"
            with patch.object(score, "demangle_names", side_effect=lambda names: {
                    name: self.spellings.get(name, name) for name in names}) as demangle:
                for control in (False, True):
                    score.score_capture(
                        FIXTURES / "synthetic.functions.json", FIXTURES / "synthetic.nm.txt",
                        FIXTURES / "synthetic.alignment.json", output / "Synthetic.scoreboard.json",
                        {"binary": "Synthetic", "opt": "O", "control": control},
                        demangle_cache_path=cache)
            self.assertEqual(demangle.call_count, 1)

    def test_unavailable_captures_are_visible_without_fabricating_counts(self):
        failure = {"binary": "Failed main", "opt": "O", "control": False,
                   "exit_code": 1, "first_stderr_line": "outputTooLarge", "wall_seconds": 2}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            score.write_aggregate([], output, failures=[failure])
            summary = (output / "SUMMARY.md").read_text()
            self.assertIn("| Failed main | O | unavailable |", summary)
            self.assertIn("outputTooLarge", summary)
            with (output / "scoreboard.csv").open() as stream:
                row = list(csv.DictReader(stream))[0]
            self.assertEqual(row["numerator"], "")
            self.assertEqual(row["denominator"], "")


if __name__ == "__main__":
    unittest.main()
