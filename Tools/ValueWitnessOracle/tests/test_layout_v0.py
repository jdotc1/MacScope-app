import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from layout_v0 import compare_layouts


def witness(size, stride, alignment, pod=True, takable=True, extra=0):
    return {"size": size, "stride": stride, "alignment": alignment,
            "isPOD": pod, "isBitwiseTakable": takable,
            "extraInhabitants": extra}


class LayoutTests(unittest.TestCase):
    def test_fixed_layout_examples_and_unsupported_enum(self):
        oracle = {"types": [
            {"qualifiedName": "Fixture.Mixed", "kind": "struct",
             "fields": [{"name": "a", "vwt": witness(1, 1, 1)},
                        {"name": "b", "vwt": witness(8, 8, 8)}],
             "vwt": witness(16, 16, 8)},
            {"qualifiedName": "Fixture.Empty", "kind": "struct",
             "fields": [], "vwt": witness(0, 1, 1)},
            {"qualifiedName": "Fixture.Bools", "kind": "struct",
             "fields": [{"name": "a", "vwt": witness(1, 1, 1, extra=254)},
                        {"name": "b", "vwt": witness(1, 1, 1, extra=254)},
                        {"name": "c", "vwt": witness(4, 4, 4)}],
             "vwt": witness(8, 8, 4, extra=254)},
            {"qualifiedName": "Fixture.Choice", "kind": "enum"},
        ]}
        report = compare_layouts(oracle)
        self.assertEqual((report["computable"], report["agree"],
                          report["disagree"], report["unsupported"]), (3, 3, 0, 1))
        self.assertEqual(report["rate"], 1.0)
        mixed, empty, bools, choice = report["types"]
        self.assertEqual([f["offset"] for f in mixed["computed"]["fieldOffsets"]], [0, 8])
        self.assertEqual([f["offset"] for f in bools["computed"]["fieldOffsets"]], [0, 1, 4])
        self.assertEqual((empty["computed"]["size"], empty["computed"]["stride"],
                          empty["computed"]["alignment"]), (0, 1, 1))
        self.assertEqual(choice["status"], "unsupported")

    def test_class_reference_optional_nesting_and_flag_bits(self):
        report = compare_layouts({"types": [
            {"qualifiedName": "Fixture.Reference", "kind": "struct",
             "fields": [{"name": "reference", "vwt": witness(8, 8, 8, pod=False,
                                                                    extra=2147483647)}],
             "vwt": witness(8, 8, 8, pod=False, extra=2147483647)},
            {"qualifiedName": "Fixture.OptionalReference", "kind": "struct",
             "fields": [{"name": "reference", "vwt": witness(8, 8, 8, pod=False,
                                                                    extra=2147483646)}],
             "vwt": witness(8, 8, 8, pod=False, extra=2147483646)},
            {"qualifiedName": "Fixture.NestedOptionalReference", "kind": "struct",
             "fields": [{"name": "reference", "vwt": witness(8, 8, 8, pod=False,
                                                                    extra=2147483645)}],
             "vwt": witness(8, 8, 8, pod=False, extra=2147483645)},
            {"qualifiedName": "Fixture.NonTakable", "kind": "struct",
             "fields": [{"name": "value", "vwt": witness(8, 8, 8, takable=False)}],
             "vwt": witness(8, 8, 8, takable=False)},
        ]})
        self.assertEqual(report["agree"], 4)
        self.assertEqual(report["rate"], 1.0)

    def test_first_difference_and_unresolved_are_explicit(self):
        report = compare_layouts({"types": [
            {"kind": "struct", "qualifiedName": "Fixture.Mismatch", "fields": [],
             "vwt": witness(1, 2, 2)},
            {"kind": "struct", "qualifiedName": "Fixture.Dependent",
             "fields": [{"name": "value", "dependent": True}],
             "vwt": witness(8, 8, 8)},
            {"kind": "struct", "qualifiedName": "Fixture.MissingFields",
             "vwt": witness(0, 1, 1)},
        ]})
        self.assertEqual(report["computable"], 1)
        self.assertEqual(report["disagree"], 1)
        self.assertEqual(report["unresolved"], 2)
        self.assertEqual(report["rate"], 0.0)
        self.assertEqual(report["types"][0]["firstDifference"],
                         {"field": "size", "computed": 0, "oracle": 1})


if __name__ == "__main__":
    unittest.main()
