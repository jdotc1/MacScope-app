"""Role census checks with independently labelled, real symbol spellings."""

import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("swift_scoreboard_classify", ROOT / "classify.py")
classify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(classify)
FIXTURES = Path(__file__).resolve().parent / "fixtures"


class ClassifierTests(unittest.TestCase):

    def test_first_match_role_wins_over_nested_closure_and_accessor(self):
        examples = {
            "protocol witness for M.X.value.getter : Swift.Int in conformance M.X : M.P in M": "protocolWitness",
            "partial apply forwarder for closure #1 () -> () in M.X.init() -> M.X": "partialApply",
            "(2) await resume partial function for closure #1 () async -> () in M.f()": "asyncPartial",
            "closure #1 () -> () in M.X.value.getter : () -> ()": "closure",
            "variable initialization expression of M.X.value : () -> ()": "varInit",
            "default argument 0 of M.X.init(value: Swift.Int) -> M.X": "defaultArg",
        }
        for name, expected in examples.items():
            with self.subTest(name=name):
                self.assertEqual(classify.classify_demangled(name)["class"], expected)

    def test_nested_specialization_and_merge_flags(self):
        name = "merged generic specialization <Swift.Array<Swift.Int>> of function signature specialization <Arg[0] = Dead> of M.X.value.getter : Swift.Int"
        self.assertEqual(classify.classify_demangled(name), {
            "class": "accessor", "merged": True, "specialised": True,
        })
        self.assertEqual(classify.classify_mangled("_$s1M1XV5valueSivgTf4d_nTm"), {
            "class": "accessor", "merged": True, "specialised": True,
        })

    def test_specialization_inside_partial_apply_does_not_set_outer_flag(self):
        self.assertEqual(classify.classify_demangled(
            "partial apply forwarder for generic specialization <Swift.Int> of M.f<A>(A) -> ()"
        ), {"class": "partialApply", "merged": False, "specialised": False})
        self.assertEqual(classify.classify_mangled("_$s1M1fyyxlFSiTg5TA"), {
            "class": "partialApply", "merged": False, "specialised": False,
        })
        self.assertEqual(classify.classify_mangled("_$s1M1fyyFTf4d_nTA"), {
            "class": "partialApply", "merged": False, "specialised": False,
        })

    def test_non_swift_stems_and_import_spellings(self):
        examples = {
            "___swift_closure_destructor.9": "closureContextDestructor",
            "___swift__destructor": "boxDestructor",
            "___swift_exist.box.addr_destructor": "existentialDestructor",
            "___swift_memcpy16_8": "sharedHelper",
            "___swift_noop_void_return": "sharedHelper",
            "___swift_instantiateConcreteTypeFromMangledName": "sharedHelper",
            "_get_witness_table 1M1XV": "sharedHelper",
            "_block_copy_helper.3": "blockHelper",
            "_block_destroy_helper": "blockHelper",
            "___copy_helper_block": "blockHelper",
            "___destroy_helper_block": "blockHelper",
            "_main": "main",
            "-[Object method:]": "objcMethod",
            "+[Object method]": "objcMethod",
            "__ZN5swift4testEv": "other",
        }
        for raw, kind in examples.items():
            expected = {"class": kind, "merged": False, "specialised": False}
            with self.subTest(raw=raw):
                self.assertEqual(classify.classify_mangled(raw), expected)
                imported = raw[1:] if raw.startswith("_") else raw
                self.assertEqual(classify.classify_demangled(imported, raw), expected)

    def test_unknown_non_swift_name_and_unrecognised_swift_role(self):
        self.assertEqual(classify.classify_demangled("plain_c_function", "_plain_c_function")["class"], "other")
        self.assertEqual(classify.classify_demangled("M.someFutureEntity", "_$s1M16someFutureEntity")["class"], "function")
        self.assertEqual(classify.classify_mangled("_$s1M16someFutureEntity")["class"], "function")

    def test_nonmatching_underscore_lookalikes(self):
        for name in ("_swift_memcpy16_8", "swift_memcpy16_8", "____swift_memcpy16_8", "__main"):
            with self.subTest(name=name):
                self.assertEqual(classify.classify_mangled(name)["class"], "other")
                self.assertEqual(classify.classify_demangled(name, name)["class"], "other")
        self.assertEqual(classify.classify_demangled("__swift_memcpy16_8")["class"], "sharedHelper")

    def test_terminal_role_table(self):
        examples = {
            "Ma": "metadataAccessor", "Mi": "metadataInstantiation", "Mr": "metadataCompletion",
            "TW": "protocolWitness", "Wl": "witnessTableAccessor", "TA": "partialApply",
            "_WZ": "onceInit", "TK": "keyPath", "Tk": "keyPath", "To": "objcThunk",
            "WOy": "outlined", "WOe": "outlined", "WOh": "outlined", "WOc": "outlined",
            "WOd": "outlined", "WOr": "outlined", "WOs": "outlined", "Teo_": "outlined",
            "TQ0_": "asyncPartial", "TY1_": "asyncPartial", "TR": "reabstraction",
            "fU_": "closure", "fU0_": "closure", "fi": "varInit",
            "fA_": "defaultArg", "fA2_": "defaultArg", "vg": "accessor", "vs": "accessor",
            "vM": "accessor", "vr": "accessor", "vau": "accessor", "vgZ": "accessor",
            "fC": "initDeinit", "fD": "initDeinit", "fd": "initDeinit", "fc": "initDeinit",
        }
        for suffix, kind in examples.items():
            with self.subTest(suffix=suffix):
                self.assertEqual(classify.classify_mangled("_$s1M1XV" + suffix)["class"], kind)

    def test_demangled_roles_without_corpus_examples(self):
        examples = {
            "M.X.value.read : Swift.Int": "accessor",
            "outlined retain of M.X": "outlined",
            "outlined release of M.X": "outlined",
            "outlined bridged method M.X.f() -> ()": "outlined",
            "specialized M.X.f() -> ()": "function",
            "M.X.__allocating_init() -> M.X": "initDeinit",
        }
        for name, kind in examples.items():
            with self.subTest(name=name):
                self.assertEqual(classify.classify_demangled(name)["class"], kind)
        self.assertTrue(classify.classify_demangled("specialized M.X.f() -> ()")["specialised"])



    def test_installed_outlined_samples(self):
        samples = [{'stdin': '$sSiWOr\n$sSiWOs\n$sSiWObr\n$sSiTe\n$sSiTe_\n$sSiTe0_\n$sSiTT\n$sSiTR\n$sSiTr\n', 'stdout': 'outlined retain of Swift.Int\noutlined release of Swift.Int\n$sSiWObr\n$sSiTe\n$sSiTe_\n$sSiTe0_\n$sSiTT\nreabstraction thunk helper from <null node pointer> to Swift.Int\nreabstraction thunk from <null node pointer> to Swift.Int\n'}, {'stdin': '$s1M1fyyFTeo_\n$s1M1fyyFTepnbg_\n', 'stdout': 'outlined bridged method (o) of M.f() -> ()\noutlined bridged method (pnbg) of M.f() -> ()\n', 'grammar_source': 'https://github.com/swiftlang/swift/blob/main/lib/Demangling/Demangler.cpp'}]
        for sample in samples:
            for raw, rendered in zip(sample["stdin"].splitlines(), sample["stdout"].splitlines()):
                if rendered.startswith("outlined "):
                    with self.subTest(raw=raw):
                        self.assertEqual(classify.classify_demangled(rendered, raw)["class"], "outlined")
                        self.assertEqual(classify.classify_mangled(raw)["class"], "outlined")


if __name__ == "__main__":
    unittest.main()
