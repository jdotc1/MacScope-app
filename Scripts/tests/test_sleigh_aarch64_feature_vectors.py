"""T1 golden decode test: vendored sleigh-lift + patched AARCH64_AppleSilicon.sla over the
decoder lane's vectors.tsv (WP0 acceptance: MOPS decodes and matches llvm-objdump, pacm is
pacm; PAuth_LR (except pacm) and THE stay undecodable until WP2/WP5)."""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
from types import SimpleNamespace
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "check_sleigh_feature_vectors", ROOT / "Scripts/arm64_golden/check_sleigh_feature_vectors.py"
)
assert spec and spec.loader
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

RESOURCES = ROOT / "ThirdParty/SleighNative/AARCH64"
# Gaps owned by later work packages; shrink these as WP2 (PAuth_LR) and WP5 (THE) land.
EXPECTED_UNDECODABLE = {"pauth-lr": 40, "the": 48, "the-d128": 40}


class SleighAArch64FeatureVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        rows = checker.run(RESOURCES / "AARCH64_AppleSilicon.sla", RESOURCES / "AARCH64.pspec",
                           pcode=False, jobs=8)
        cls.vectors = [row for row in rows if row["corpus"] == "vectors"]
        cls.boundary = [row for row in rows if row["corpus"] == "boundary"]
        cls.summary = checker.summary(rows)

    def test_mops_and_lrcpc_vectors_decode_and_match_llvm(self) -> None:
        for row in self.vectors:
            if row["family"] in ("mops", "lrcpc"):
                self.assertEqual(row["match"], "yes", row)

    def test_pacm_is_not_bti(self) -> None:
        pacm = [row for row in self.vectors if row["mnemonic"] == "pacm"]
        self.assertEqual([row["sleigh"] for row in pacm], ["pacm"])

    def test_remaining_gaps_are_exactly_the_later_work_packages(self) -> None:
        undecodable: dict[str, int] = {}
        for row in self.vectors:
            if row["sleigh"] == "<undecodable>":
                undecodable[row["family"]] = undecodable.get(row["family"], 0) + 1
        self.assertEqual(undecodable, EXPECTED_UNDECODABLE)

    def test_wp0_defect_counters_are_zero_over_vectors_and_boundary(self) -> None:
        defects = {key: value for key, value in self.summary.items() if key.startswith("defect")}
        self.assertEqual(defects, {})


class SleighFRINTScalarSemanticTests(unittest.TestCase):
    def test_frint_scalar_rounding_range_width_and_aliases(self) -> None:
        import sys
        sys.path.insert(0, str(ROOT / "ThirdParty/SleighNative/tests"))
        import rx17_semantics
        with tempfile.TemporaryDirectory() as scratch:
            tree = checker.spec_root_for(RESOURCES / "AARCH64_AppleSilicon.sla",
                                        RESOURCES / "AARCH64.pspec", pathlib.Path(scratch))
            args = SimpleNamespace(lifter=checker.SLEIGH_LIFT, tree=tree,
                                   languages=tree / checker.LANGUAGE_RELATIVE,
                                   pspec=RESOURCES / "AARCH64.pspec")
            count = rx17_semantics.test_frint(rx17_semantics.Lifter(args, 'apple'), False)
            self.assertEqual(count, 2272)


class SleighSMECP1CheckpointTests(unittest.TestCase):
    def test_normal_paths_and_gates_have_exact_explicit_coverage(self) -> None:
        import json, os, subprocess, sys
        cp1 = ROOT / "ThirdParty/SleighNative/tests/cp1"
        lifter = os.environ.get("CP1_SLEIGH_LIFT")
        self.assertIsNotNone(lifter, "Set CP1_SLEIGH_LIFT to the documented CP1 API frontend; this is not a skip")
        with tempfile.TemporaryDirectory() as scratch:
            report = pathlib.Path(scratch) / "vectors.json"
            common = [sys.executable, str(cp1 / "emulator/run_vectors.py"),
                      "--fixture", str(cp1 / "sme-decoder-vectors.json"),
                      "--lifter", str(lifter), "--sla", str(RESOURCES / "AARCH64_AppleSilicon.sla"),
                      "--report", str(report)]
            subprocess.run(common, check=True, capture_output=True, text=True)
            result = json.loads(report.read_text())
            self.assertEqual(result["fixtureSHA256"], "5919c4c14d09f3c9221563763b4df2bd7116e33a9eae902dbe1474b8b5742f9a")
            self.assertEqual(result["caseCount"], 853)
            self.assertEqual(result["counts"], {"PASS": 492, "FAIL": 0, "UNSUPPORTED": 102, "GATE": 259})
            fixture = json.loads((cp1 / "sme-decoder-vectors.json").read_text())
            allocated = {c["instruction"] for c in fixture["catalogue"]}
            reserved = {c["instruction"] for c in fixture["reserved_vectors"]}
            self.assertEqual(len(allocated), 125)
            self.assertEqual(set(result["families"]), allocated | reserved)
            implemented = json.loads((cp1 / "implemented-forms.json").read_text())["forms"]
            self.assertEqual(len(implemented), 105)
            self.assertEqual({f for f,c in result["families"].items() if c["PASS"]}, set(implemented))
            for row in result["results"]:
                if row["instruction"] in implemented and row["verdict"] != "GATE":
                    self.assertEqual(row["verdict"], "PASS", row)
                    self.assertEqual(row["intraInstructionBranchCount"], 0, row)
                    self.assertEqual(row["u64OverflowVarnodes"], [], row)
            subprocess.run(common + ["--decode-only"], check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(report.read_text())["counts"], {"PASS": 50})


if __name__ == "__main__":
    unittest.main()
