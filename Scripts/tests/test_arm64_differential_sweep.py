"""MS-23 differential sweep: pure-Python pieces (word generation, normalisation, classification,
objdump parsing, reserved-field attribution). No toolchain is needed; the sweep itself is offline."""

from __future__ import annotations

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "differential_sweep", ROOT / "Scripts/arm64_golden/differential_sweep.py"
)
assert spec and spec.loader
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)


class DifferentialSweepTests(unittest.TestCase):
    def test_generation_is_seeded_unique_and_honours_class_bits(self) -> None:
        first = sweep.generate_words(20261012, 500, 20)
        self.assertEqual(first, sweep.generate_words(20261012, 500, 20))
        self.assertNotEqual(first, sweep.generate_words(1, 500, 20))
        words = [w for w, _ in first]
        self.assertEqual(len(words), len(set(words)))
        classes = {name: (mask, value) for name, mask, value in sweep.STRUCTURED_CLASSES}
        for word, source in first:
            if source.startswith("class:"):
                mask, value = classes[source.split(":", 1)[1]]
                self.assertEqual(word & mask, value, f"{word:08x} {source}")

    def test_normalise_drops_padding_annotations_and_comments(self) -> None:
        self.assertEqual(sweep.normalize("b\t0x0000000100000018 <.text+0x18>"), "b 0x100000018")
        self.assertEqual(sweep.normalize("mov\tx0, #0x10 // =16"), "mov x0, #0x10")
        self.assertEqual(sweep.normalize("ADD  x0,x1 ,  x2"), "add x0, x1, x2")
        self.assertEqual(sweep.normalize("movz x0, #0x0"), "movz x0, #0x0")

    def test_classify(self) -> None:
        self.assertEqual(sweep.classify("add\tx0, x1, x2", "add x0, x1, x2"), "match")
        self.assertEqual(sweep.classify("rmif\tx1, #0x3f, #0xf", "str w15, [x1], #-0x8"), "mismatch")
        self.assertEqual(sweep.classify("<unknown>", "adds x21, x5, w22, uxtw #5"), "over-decode")
        self.assertEqual(sweep.classify("ldtp\tx0, x1, [x2]", "unknown 0x19400440"), "gap")
        self.assertEqual(sweep.classify("<unknown>", "unknown 0x00000000"), "both-reject")

    def test_spelling_only_separates_presentation_from_semantics(self) -> None:
        self.assertTrue(sweep.spelling_only("tbnz\tx24, #0x32, 0x1000057ec", "tbnz x24, #50, 0x1000057ec"))
        self.assertTrue(sweep.spelling_only("st1\t{ v9.s }[2], [x23], x24", "st1 {v9.s}[2], [x23], x24"))
        self.assertTrue(sweep.spelling_only("sub\tx21, x18, #0x505, lsl #12", "sub x21, x18, #0x505000"))
        self.assertTrue(sweep.spelling_only("bics\tw14, w4, w9, asr #0", "bics w14, w4, w9"))
        self.assertFalse(sweep.spelling_only("rmif\tx1, #0x3f, #0xf", "str w15, [x1], #-0x8"))
        self.assertFalse(sweep.spelling_only("adds\tw0, w8, w27, sxtx #3", "adds w0, w8, x27, sxtx #3"))

    def test_parse_objdump(self) -> None:
        text = ("Disassembly of section .text:\n\n0000000100000000 <.text>:\n"
                "100000000: ab3654b5    \t<unknown>\n100000004: 8b020020    \tadd\tx0, x1, x2\n")
        self.assertEqual(sweep.parse_objdump(text),
                         [(0x100000000, 0xAB3654B5, "<unknown>"), (0x100000004, 0x8B020020, "add\tx0, x1, x2")])

    def test_known_reserved_field_classes(self) -> None:
        expected = {
            0xAB3654B5: "addsub-ext-imm3>4",           # adds x21, x5, w22, uxtw #5
            0x4ADDE52C: "shifted-reg-sf0-imm6>31",     # eor w12, w9, w29, ror #57
            0x933D0452: "bitfield-N!=sf-or-sf0-imm>31",  # sbfiz x18, x2, #3, #2 with N=0
            0x3BA58780: "ls-lookalike-bit25",          # ldrsb x0, [x28, #0x961]
            0x3A000400: "ls-lookalike-bit25",          # strb
            0xBA1F842F: "rmif-as-store",               # rmif rendered as str
            0x1AC03000: "pacga-sf0",
            0x8B020020: "",                            # add x0, x1, x2 is valid
            0x93407C00: "",                            # sxtw x0, w0 is valid
        }
        for word, name in expected.items():
            self.assertEqual(sweep.known_class(word), name, f"{word:08x}")

    def test_decode_group(self) -> None:
        self.assertEqual(sweep.decode_group(0x8B020020)[0], "dp-reg")
        self.assertEqual(sweep.decode_group(0xF9400000)[0], "load-store")
        self.assertEqual(sweep.decode_group(0x91000000)[0], "dp-imm")
        self.assertEqual(sweep.decode_group(0x14000000)[0], "branch-sys")
        self.assertEqual(sweep.decode_group(0x04000000)[0], "sve")
        self.assertEqual(sweep.decode_group(0x80000000)[0], "sme")
        self.assertEqual(sweep.decode_group(0x4E000000)[0], "simd-fp")


if __name__ == "__main__":
    unittest.main()
