"""Instruction-stream checks; no executable inputs or disassembler required."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("tiers", ROOT / "tiers.py")
tiers = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tiers)


def fixture(name):
    lines = (ROOT / "tests" / "fixtures" / name).read_text().splitlines()
    return [(int(line.split(":", 1)[0], 16), line.split(":", 1)[1].strip()) for line in lines]


def stream(*instructions):
    return [(0x1000 + 4 * index, text) for index, text in enumerate(instructions)]


def section(data, name="__cstring", address=0x9010):
    return {("__TEXT", name): dict(addr=address, size=len(data), data=data)}


def digest(data):
    return "CONST:" + hashlib.sha256(data).hexdigest()[:16]



class StrictOperandTests(unittest.TestCase):
    def analyse_pair(self, left, right, identical=False, constants=None, segment="__TEXT"):
        # Byte markers express equality and length; they are not executable code.
        sections = []
        for index, instructions in enumerate((left, right)):
            marker = b"A" if identical or index == 0 else b"B"
            entries = section(marker * (4 * len(instructions)), "__text", 0x1000)
            if constants is not None:
                entries[(segment, "__const")] = dict(addr=0x2000, size=len(constants[index]),
                                                     data=constants[index])
            sections.append(entries)
        args = argparse.Namespace(a_bin="A", a_nm="A.nm", b_bin="B", b_nm="B.nm",
                                  label="operands", callee_names=True, source_root=[],
                                  list_all=True, sections=True, units=True)
        with mock.patch.object(tiers, "macho_sections", side_effect=[(s, {}) for s in sections]), \
             mock.patch.object(tiers, "nm_by_addr", return_value={0x1000: ["_function"]}), \
             mock.patch.object(tiers, "disassemble", side_effect=[dict(stream(*left)), dict(stream(*right))]):
            result = tiers.analyse(args)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["paired_functions"], 1)
        row = result["functions"][0]
        self.assertEqual(row["members"], ["_function"])
        return row, sections

    def assert_tier(self, row, tier):
        self.assertEqual((row["tier"], row["unit_tier"], row["certified"]),
                         (tier, tier, tier != "different"))

    def test_shift_immediate_stays_different(self):
        left = ["adrp x8, 0x2000", "lsl x0, x8, #1", "ret"]
        right = ["adrp x8, 0x2000", "lsl x0, x8, #2", "ret"]
        row, _ = self.analyse_pair(left, right)
        self.assert_tier(row, "different")
        self.assertEqual(row["data_unverified_sections"], [])
        self.assertEqual(row["first_masked_diff"], [1, left[1], right[1]])

    def test_add_page_offsets_still_normalise_with_digests(self):
        left = ["adrp x8, 0x2000", "add x0, x8, #0x10", "ret"]
        right = ["adrp x8, 0x2000", "add x0, x8, #0x20", "ret"]
        row, sections = self.analyse_pair(left, right, constants=[b"a" * 128] * 2)
        self.assert_tier(row, "normalised")
        masked = tiers.normalise(stream(*left), 0x1000, 0x100c, sections=sections[0])
        self.assertEqual(masked[1], "add x0, x8, #LO12:" + digest(b"a" * 16))

    def test_other_arithmetic_immediates_stay_verbatim(self):
        for mnemonic, suffix in (("sub", ""), ("add", ", lsl #12"), ("add", ", lsr #12")):
            with self.subTest(mnemonic=mnemonic, suffix=suffix):
                left = ["adrp x8, 0x2000", f"{mnemonic} x0, x8, #0x10{suffix}", "ret"]
                right = ["adrp x8, 0x2000", f"{mnemonic} x0, x8, #0x20{suffix}", "ret"]
                row, _ = self.analyse_pair(left, right, constants=[b"a" * 128] * 2)
                self.assert_tier(row, "different")
                self.assertEqual(row["first_masked_diff"], [1, left[1], right[1]])

    def check_writeback(self, instruction, identical=True, segment="__TEXT"):
        constants = []
        for value in (1, 2):
            data = bytearray(128)
            data[0x40:0x48] = value.to_bytes(8, "little")
            constants.append(bytes(data))
        instructions = ["adrp x8, 0x2000", instruction, "ldr x0, [x8, #0x20]", "ret"]
        row, sections = self.analyse_pair(instructions, instructions, identical, constants, segment)
        self.assert_tier(row, "different")
        self.assertEqual(row["reason"], "unverified-constant")
        self.assertEqual(row["data_sections"], [])
        consts, refs, dependencies = [], set(), {}
        masked = tiers.normalise(stream(*instructions), 0x1000, 0x1010,
                                 sections=sections[0], consts=consts, data_refs=refs,
                                 dependencies=dependencies)
        self.assertEqual(masked[1:], instructions[1:])
        self.assertEqual(consts, [])
        self.assertEqual(refs, set())
        self.assertTrue(dependencies["unverified_constant"])

    def test_pre_index_load_invalidates_constant_dependency(self):
        self.check_writeback("ldr x9, [x8, #0x20]!")

    def test_post_index_load_invalidates_constant_dependency(self):
        self.check_writeback("ldr x9, [x8], #0x20")

    def test_pre_index_store_invalidates_constant_dependency(self):
        self.check_writeback("str x9, [x8, #0x20]!")

    def test_pair_load_pre_index_invalidates_constant_dependency(self):
        self.check_writeback("ldp x9, x10, [x8, #0x20]!")

    def test_pair_store_post_index_withholds_data_token(self):
        self.check_writeback("stp x9, x10, [x8], #0x20", segment="__DATA")

    def test_register_post_index_vector_load_invalidates_constant_dependency(self):
        self.check_writeback("ld1.16b { v0 }, [x8], x2")

    def test_register_post_index_vector_store_invalidates_constant_dependency(self):
        self.check_writeback("st1.16b { v0 }, [x8], x2")

    def test_writeback_cannot_normalise_different_bytes(self):
        self.check_writeback("ldr x9, [x8, #0x20]!", identical=False)

    def test_untracked_stack_writeback_keeps_previous_tiers(self):
        instructions = ["adrp x8, 0x2000", "str x9, [sp, #-16]!", "ldr x0, [x8, #0x20]", "ret"]
        for identical, expected in ((True, "exact"), (False, "normalised")):
            with self.subTest(identical=identical):
                row, _ = self.analyse_pair(instructions, instructions, identical, [b"a" * 128] * 2)
                self.assert_tier(row, expected)

    def test_no_writeback_load_keeps_digest(self):
        instructions = ["adrp x8, 0x2000", "ldr x0, [x8, #0x20]", "ret"]
        row, sections = self.analyse_pair(instructions, instructions, True, [b"a" * 128, b"b" * 128])
        self.assert_tier(row, "different")
        self.assertEqual(row["reason"], "constant")
        masked = tiers.normalise(stream(*instructions), 0x1000, 0x100c, sections=sections[0])
        self.assertEqual(masked[1], "ldr x0, [x8, #LO12:" + digest(b"a" * 16) + "]")


class NormaliseTests(unittest.TestCase):
    def test_tbz_target_relative_and_bit_preserved(self):
        result = tiers.normalise(fixture("branches.txt"), 0x1000, 0x1010)
        self.assertEqual(result[0], "tbz w0, #0x3, REL+12")

    def test_hoisted_page_remains_live_for_28_instructions(self):
        result = tiers.normalise(fixture("hoisted_page.txt"), 0x1000, 0x1078)
        self.assertEqual(result[28], "ldr x0, [x20, #LO12]")

    def test_call_target_resolved_by_name(self):
        result = tiers.normalise(fixture("branches.txt"), 0x1000, 0x1010, {0x8000: ["_callee"]})
        self.assertEqual(result[2], "bl CALL:_callee")

    def test_internal_branch_relative_to_instruction(self):
        result = tiers.normalise(fixture("branches.txt"), 0x1000, 0x1010)
        self.assertEqual(result[1], "b REL+8")

    def test_tail_branch_resolved_by_name(self):
        result = tiers.normalise(stream("b 0x8000"), 0x1000, 0x1004, {0x8000: ["_tail"]})
        self.assertEqual(result, ["b TAIL:_tail"])

    def test_call_drops_caller_saved_page(self):
        seq = stream("adrp x8, 0x9000", "bl 0x8000", "ldr x0, [x8, #0x40]")
        self.assertEqual(tiers.normalise(seq, 0x1000, 0x100c)[2], seq[2][1])

    def test_call_preserves_callee_saved_page(self):
        seq = stream("adrp x20, 0x9000", "bl 0x8000", "ldr x0, [x20, #0x40]")
        self.assertEqual(tiers.normalise(seq, 0x1000, 0x100c)[2], "ldr x0, [x20, #LO12]")

    def test_mov_propagates_page(self):
        seq = stream("adrp x8, 0x9000", "mov x20, x8", "ldr x0, [x20, #0x40]")
        self.assertEqual(tiers.normalise(seq, 0x1000, 0x100c)[2], "ldr x0, [x20, #LO12]")

    def test_redefinition_drops_page(self):
        seq = stream("adrp x20, 0x9000", "mov x20, x0", "ldr x0, [x20, #0x40]")
        self.assertEqual(tiers.normalise(seq, 0x1000, 0x100c)[2], seq[2][1])

    def test_constant_content_is_hashed(self):
        result = tiers.normalise(fixture("constants.txt"), 0x1000, 0x1010,
                                 sections=section(b"hello\0"))
        self.assertEqual(result[1], "add x0, x20, #LO12:" + digest(b"hello\0"))

    def test_all_requested_memory_users_hash_constants(self):
        for mnemonic in ("ldr", "ldrb", "ldrh", "ldrsw", "ldp"):
            with self.subTest(mnemonic=mnemonic):
                operands = "x0, x1" if mnemonic == "ldp" else "x0"
                seq = stream("adrp x20, 0x9000", f"{mnemonic} {operands}, [x20, #0x10]")
                self.assertIn(digest(b"hello\0"), tiers.normalise(seq, 0x1000, 0x1008,
                                                               sections=section(b"hello\0"))[1])

    def test_literal_constant_uses_16_bytes(self):
        self.assertEqual(tiers.constant_token(section(bytes(range(32)), "__literal16"), 0x9010),
                         digest(bytes(range(16))))

    def test_constant_window_can_cross_section_boundary(self):
        sections = section(b"abcd", "__literal4")
        sections[("__TEXT", "__literal4")]["constant_window"] = b"abcdefghijklmnop"
        self.assertEqual(tiers.constant_token(sections, 0x9010), digest(b"abcdefghijklmnop"))

    def test_source_root_removed_before_hashing(self):
        left = tiers.constant_token(section(b"/source/one/main.swift\0"), 0x9010, "/source/one")
        right = tiers.constant_token(section(b"/source/two/main.swift\0"), 0x9010, "/source/two/")
        self.assertEqual(left, digest(b"/main.swift\0"))
        self.assertEqual(left, right)

    def test_source_root_does_not_remove_partial_component(self):
        value = b"/source/ones/main.swift\0"
        self.assertEqual(tiers.constant_token(section(value), 0x9010, "/source/one"), digest(value))

    def test_changed_string_is_different_when_bytes_differ(self):
        seq = stream("adrp x20, 0x9000", "add x0, x20, #0x10")
        result = tiers.compare_function(b"a" * 8, b"b" * 8, seq, seq,
                                        (0x1000, 0x1008), (0x1000, 0x1008),
                                        a_sections=section(b"hello\0"), b_sections=section(b"world\0"))
        self.assertEqual(result[0], "different")
        self.assertEqual(result[2][0], 1)

    def test_identical_text_with_differing_constant_is_different(self):
        seq = stream("adrp x20, 0x9000", "add x0, x20, #0x10")
        result = tiers.compare_function(b"a" * 8, b"a" * 8, seq, seq,
                                        (0x1000, 0x1008), (0x1000, 0x1008),
                                        a_sections=section(b"hello\0"), b_sections=section(b"world\0"))
        self.assertEqual(result[0], "different")
        detail = result[2]
        self.assertEqual(detail["reason"], "constant")
        self.assertEqual(detail["constants"][0]["sectionA"], "__cstring")
        self.assertEqual(detail["constants"][0]["hashA"], digest(b"hello\0")[6:])
        self.assertEqual(detail["constants"][0]["hashB"], digest(b"world\0")[6:])

    def test_identical_text_with_equal_constants_is_exact(self):
        seq = stream("adrp x20, 0x9000", "add x0, x20, #0x10")
        result = tiers.compare_function(b"a" * 8, b"a" * 8, seq, seq,
                                        (0x1000, 0x1008), (0x1000, 0x1008),
                                        a_sections=section(b"hello\0"), b_sections=section(b"hello\0"))
        self.assertEqual(result, ("exact", None, None))

    def test_w_register_write_drops_x_page(self):
        seq = stream("adrp x8, 0x9000", "mov w8, #1", "ldr x0, [x8, #0x40]")
        self.assertEqual(tiers.normalise(seq, 0x1000, 0x100c)[2], seq[2][1])

    def test_pair_load_drops_both_pages(self):
        for dest in ("x8", "x9"):
            seq = stream("adrp " + dest + ", 0x9000", "ldp x8, x9, [sp, #0x10]", "ldr x0, [" + dest + ", #0x40]")
            self.assertEqual(tiers.normalise(seq, 0x1000, 0x100c)[2], seq[2][1])
        for mn in ("ldpsw", "ldnp"):
            seq = stream("adrp x9, 0x9000", mn + " x8, x9, [sp, #0x10]", "ldr x0, [x9, #0x40]")
            self.assertEqual(tiers.normalise(seq, 0x1000, 0x100c)[2], seq[2][1])

    def test_outside_supported_sections_keeps_plain_mask(self):
        seq = fixture("constants.txt")
        result = tiers.normalise(seq, 0x1000, 0x1010, sections=section(b"hello\0", "__other"))
        self.assertEqual(result[1], "add x0, x20, #LO12")

    def test_pc_relative_address_and_literal_load(self):
        seq = stream("adr x0, 0x9000", "ldr x1, 0x9010")
        self.assertEqual(tiers.normalise(seq, 0x1000, 0x1008), ["adr x0, ADR", "ldr x1, LIT"])

    def test_first_difference_includes_length_mismatch(self):
        self.assertEqual(tiers.first_difference(["nop"], ["nop", "ret"]), [1, None, "ret"])

    def test_missing_disassembly_is_an_error(self):
        with self.assertRaises(tiers.InputError):
            tiers.compare_function(b"a" * 4, b"b" * 4, [], [], (0, 4), (0, 4))

    def test_unterminated_string_is_an_error(self):
        with self.assertRaises(tiers.InputError):
            tiers.constant_token(section(b"hello"), 0x9010)

    def test_section_hashes_and_missing_sections(self):
        comparison = tiers.section_comparison(section(b"hello\0"), section(b"world\0"))
        self.assertFalse(comparison[0]["byte_equal"])
        self.assertEqual(comparison[0]["A"]["sha256"], hashlib.sha256(b"hello\0").hexdigest())
        self.assertIsNone(tiers.section_comparison(section(b"hello\0"), {})[0]["B"])

    def test_malformed_header_reports_input_error(self):
        with mock.patch("builtins.open", mock.mock_open(read_data=b"bad")):
            with self.assertRaises(tiers.InputError):
                tiers.macho_sections("unused")

    def test_missing_cli_arguments_emit_json_error(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = tiers.main([])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output.getvalue())["status"], "error")

    def test_cli_flags_work_without_optional_label(self):
        output = io.StringIO()
        with mock.patch.object(tiers, "analyse", return_value={"status": "ok"}) as analyse:
            with mock.patch("builtins.open", mock.mock_open()), contextlib.redirect_stdout(output):
                self.assertEqual(tiers.main(["a", "an", "b", "bn", "out", "--callee-names", "--list-all", "--units"]), 0)
        args = analyse.call_args[0][0]
        self.assertTrue(args.callee_names)
        self.assertTrue(args.list_all)
        self.assertTrue(args.units)
        self.assertEqual(args.label, "")

    def test_input_failure_is_json_and_nonzero(self):
        output = io.StringIO()
        with mock.patch.object(tiers, "analyse", side_effect=OSError("missing input")):
            with mock.patch("builtins.open", mock.mock_open()), contextlib.redirect_stdout(output):
                self.assertEqual(tiers.main(["a", "an", "b", "bn", "out"]), 2)
        self.assertEqual(json.loads(output.getvalue())["error"], "missing input")

    def test_pairing_aliases_unpaired_names_and_full_listing(self):
        args = argparse.Namespace(a_bin="a", a_nm="an", b_bin="b", b_nm="bn",
                                  label="example", callee_names=True, source_root=[],
                                  list_all=True, sections=False)
        left = section(b"a" * 8, "__text", 0x1000)
        right = section(b"b" * 8, "__text", 0x1000)
        names_a = {0x1000: ["_shared", "_alias"], 0x1004: ["_left"]}
        names_b = {0x1000: ["_shared", "_alias"], 0x1004: ["_right"]}
        with mock.patch.object(tiers, "macho_sections", side_effect=[(left, {}), (right, {})]):
            with mock.patch.object(tiers, "nm_by_addr", side_effect=[names_a, names_b]):
                with mock.patch.object(tiers, "disassemble", return_value={0x1000: "ret", 0x1004: "ret"}):
                    result = tiers.analyse(args, baseline_normalise=lambda seq, start, end, names: [s for _, s in seq])
        self.assertEqual(result["paired_functions"], 1)
        self.assertEqual(result["alias_pairs_deduplicated"], 1)
        self.assertEqual(result["unpaired"], dict(A_only=1, B_only=1, A_names=["_left"], B_names=["_right"]))
        self.assertEqual(result["tiers"], dict(exact=0, normalised=1, different=0))
        self.assertEqual(result["baseline_tiers"], result["tiers"])
        self.assertEqual(result["baseline_tier_changes"], [])
        self.assertEqual(result["non_exact"][0]["sizeA"], 4)
        self.assertEqual(result["non_exact"][0]["tier"], "normalised")

    def test_lenient_scan_keeps_page_across_sp_restore(self):
        shape = lambda imm: stream("adrp x19, 0x9000", "tbz w8, #0x0, 0x1010", "ldp x20, x19, [sp], #0x20", "ret",
                                   "strb w8, [x19, #" + imm + "]")
        left, right = shape("0x1d0"), shape("0xb08")
        self.assertNotEqual(tiers.normalise(left, 0x1000, 0x1014), tiers.normalise(right, 0x1000, 0x1014))
        self.assertEqual(tiers.normalise(left, 0x1000, 0x1014, lenient=True),
                         tiers.normalise(right, 0x1000, 0x1014, lenient=True))

    def test_restored_page_base_reason(self):
        shape = lambda imm: stream("adrp x19, 0x9000", "tbz w8, #0x0, 0x1010", "ldp x20, x19, [sp], #0x20", "ret",
                                   "strb w8, [x19, #" + imm + "]")
        result = tiers.classify_function(b"a" * 20, b"b" * 20, shape("0x1d0"), shape("0xb08"),
                                         (0x1000, 0x1014), (0x1000, 0x1014))
        self.assertEqual((result[0], result[3]), ("different", "restored-page-base"))
        self.assertEqual(tiers.compare_function(b"a" * 20, b"b" * 20, shape("0x1d0"), shape("0xb08"),
                                                (0x1000, 0x1014), (0x1000, 0x1014))[0], "different")

    def test_non_sp_pair_load_still_pops_under_lenient_scan(self):
        shape = lambda imm: stream("adrp x19, 0x9000", "ldp x19, x20, [x8]", "strb w8, [x19, #" + imm + "]")
        result = tiers.classify_function(b"a" * 12, b"b" * 12, shape("0x1d0"), shape("0xb08"),
                                         (0x1000, 0x100c), (0x1000, 0x100c))
        self.assertEqual((result[0], result[3]), ("different", "instruction"))

    def test_plain_instruction_difference_has_instruction_reason(self):
        result = tiers.classify_function(b"a" * 4, b"b" * 4, stream("nop"), stream("ret"),
                                         (0x1000, 0x1004), (0x1000, 0x1004))
        self.assertEqual((result[0], result[3]), ("different", "instruction"))

    def test_constant_reason_and_exact_and_normalised_have_no_other_reason(self):
        seq = stream("adrp x20, 0x9000", "add x0, x20, #0x10")
        constant = tiers.classify_function(b"a" * 8, b"a" * 8, seq, seq, (0x1000, 0x1008), (0x1000, 0x1008),
                                           a_sections=section(b"hello\0"), b_sections=section(b"world\0"))
        self.assertEqual(constant[3], "constant")
        same = tiers.classify_function(b"a" * 8, b"a" * 8, seq, seq, (0x1000, 0x1008), (0x1000, 0x1008),
                                       a_sections=section(b"hello\0"), b_sections=section(b"hello\0"))
        self.assertEqual(same[3], None)
        moved = tiers.classify_function(b"a" * 8, b"b" * 8, stream("adrp x8, 0x9000", "ret"),
                                        stream("adrp x8, 0xa000", "ret"), (0x1000, 0x1008), (0x1000, 0x1008))
        self.assertEqual((moved[0], moved[3]), ("normalised", None))

    def test_incomplete_stream_is_recorded_per_function(self):
        args = argparse.Namespace(a_bin="a", a_nm="an", b_bin="b", b_nm="bn",
                                  label="example", callee_names=False, source_root=[],
                                  list_all=True, sections=False)
        left = section(b"a" * 8, "__text", 0x1000)
        right = section(b"b" * 8, "__text", 0x1000)
        names = {0x1000: ["_whole"], 0x1004: ["_partial"]}
        with mock.patch.object(tiers, "macho_sections", side_effect=[(left, {}), (right, {})]):
            with mock.patch.object(tiers, "nm_by_addr", side_effect=[names, names]):
                with mock.patch.object(tiers, "disassemble", return_value={0x1000: "ret"}):
                    result = tiers.analyse(args)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(sum(result["tiers"].values()), 2)
        self.assertEqual(set(result["tiers"]), {"exact", "normalised", "different"})
        self.assertEqual(result["different_reasons"], {"incomplete-stream": 1})
        entry = [e for e in result["non_exact"] if e["reason"] == "incomplete-stream"][0]
        self.assertEqual(entry["tier"], "different")
        self.assertIn("incomplete instruction stream", entry["message"])


class UnitAndDataTests(unittest.TestCase):
    @staticmethod
    def record(name, tier="exact", refs=(), changed=()):
        return dict(name=name, aliases=[name], tier=tier,
                    reason="instruction" if tier == "different" else None,
                    data_sections=list(refs), data_unverified_sections=list(changed))

    def test_swift_closure_member(self):
        parent = "_$s4Demo5startyyF"
        self.assertTrue(tiers.nested_symbol(parent, parent + "yycfU_"))
        self.assertFalse(tiers.nested_symbol(parent, parent))

    def test_swift_local_specialisation_member(self):
        parent = "_$s4Demo4findyyF"
        self.assertTrue(tiers.nested_symbol(parent, parent + "0C0L_yyFTf0sn_n"))

    def test_objc_and_c_block_members(self):
        for parent, child in (("-[Class sel:]", "___12-[Class sel:]_block_invoke"),
                              ("_activate", "___activate_block_invoke"),
                              ("_activate", "___8activate_block_invoke_2")):
            self.assertTrue(tiers.nested_symbol(parent, child))
            records = [self.record(parent), self.record(child, "different")]
            tiers.roll_up_units(records, [parent, child])
            self.assertEqual(records[0]["unit_tier"], "different")

    def test_shared_partial_prefix_is_not_member(self):
        self.assertFalse(tiers.nested_symbol("_$s4Demo4findyyF", "_$s4Demo4findySiFyycfU_"))
        self.assertFalse(tiers.nested_symbol("_activate", "___activateOther_block_invoke"))

    def test_worst_member_and_reason_roll_up(self):
        parent = "_$s4Demo5startyyF"
        child = parent + "yycfU_"
        records = [self.record(parent, "normalised"), self.record(child, "different")]
        tiers.roll_up_units(records, [parent, child])
        self.assertEqual(records[0]["members"], sorted([parent, child]))
        self.assertEqual(records[0]["unit_tier"], "different")
        self.assertEqual(records[0]["unit_reason"], [dict(name=child, reason="instruction")])
        self.assertFalse(records[0]["certified"])

    def test_missing_member_withholds_certificate(self):
        parent = "_$s4Demo5startyyF"
        records = [self.record(parent)]
        tiers.roll_up_units(records, [parent, parent + "yycfU_"])
        self.assertEqual(records[0]["unit_reason"][0]["reason"], "unpaired-member")
        self.assertFalse(records[0]["certified"])

    def test_alias_can_supply_unit_parent(self):
        parent = "_$s4Demo5startyyF"
        child = parent + "yycfU_"
        records = [self.record("_alias"), self.record(child, "different")]
        records[0]["aliases"].append(parent)
        tiers.roll_up_units(records, ["_alias", parent, child])
        self.assertEqual(records[0]["unit_tier"], "different")

    def test_data_tokens_cover_both_segments_and_store_users(self):
        for segment in ("__DATA", "__DATA_CONST"):
            sections = {(segment, "__data"): dict(addr=0x9010, size=32, data=b"a" * 32)}
            refs = set()
            result = tiers.normalise(stream("adrp x20, 0x9000", "str x0, [x20, #0x10]"),
                                     0x1000, 0x1008, sections=sections, data_refs=refs)
            self.assertEqual(result[1], "str x0, [x20, #LO12:DATA:" + segment + ",__data]")
            self.assertEqual(refs, {segment + ",__data"})

    def test_got_excluded_and_section_bounds(self):
        sections = {("__DATA_CONST", "__got"): dict(addr=0x9010, size=8, data=b"a" * 8)}
        self.assertIsNone(tiers.data_section(sections, 0x9010))
        sections = {("__DATA", "__data"): dict(addr=0x9010, size=8, data=b"a" * 8)}
        self.assertIsNone(tiers.data_section(sections, 0x9018))
        self.assertIsNone(tiers.data_section(sections, 0x900f))

    def test_equal_cfstring_with_changed_text_is_unverified(self):
        records = [dict(name="__DATA_CONST,__cfstring", byte_equal=True),
                   dict(name="__TEXT,__cstring", byte_equal=False)]
        self.assertEqual(tiers.unverified_data(["__DATA_CONST,__cfstring"], records),
                         ["__TEXT,__cstring"])

    def test_data_transitive_rules(self):
        for name, target in (("__cfstring", "__TEXT,__ustring"),
                             ("__objc_selrefs", "__TEXT,__objc_methname"),
                             ("__objc_classrefs", "__DATA,__objc_data"),
                             ("__objc_superrefs", "__DATA,__objc_data")):
            source = "__DATA_CONST," + name
            records = [dict(name=source, byte_equal=True), dict(name=target, byte_equal=False)]
            self.assertEqual(tiers.unverified_data([source], records), [target])

    def test_equal_data_and_absent_transitive_section(self):
        refs = ["__DATA_CONST,__cfstring"]
        self.assertEqual(tiers.unverified_data(refs, [dict(name=refs[0], byte_equal=True)]), [])
        self.assertEqual(tiers.unverified_data(refs, []), refs)

    def test_child_data_withholds_parent_certificate(self):
        records = [self.record("_activate"), self.record("___activate_block_invoke", "normalised",
                   ["__DATA_CONST,__cfstring"], ["__TEXT,__cstring"])]
        tiers.roll_up_units(records, [r["name"] for r in records])
        self.assertEqual(records[0]["unit_tier"], "normalised")
        self.assertTrue(records[0]["data_unverified"])
        self.assertFalse(records[0]["certified"])
        self.assertEqual(records[0]["unit_data_sections"], ["__DATA_CONST,__cfstring"])

    def test_equal_units_are_certified(self):
        records = [self.record("_one"), self.record("_two", "normalised", ["__DATA,__data"])]
        tiers.roll_up_units(records, [r["name"] for r in records])
        self.assertTrue(all(r["certified"] for r in records))

    def test_path_length_reason_keeps_different_tier(self):
        for mnemonic in ("mov", "movz", "movk", "add", "sub"):
            operand = "w2, w2, " if mnemonic in ("add", "sub") else "w2, "
            result = tiers.classify_function(b"a" * 4, b"b" * 4,
                stream(mnemonic + " " + operand + "#0x6f"),
                stream(mnemonic + " " + operand + "#0x7a"), (0x1000, 0x1004), (0x1000, 0x1004),
                a_root="/a", b_root="/a12345678901")
            self.assertEqual((result[0], result[3]), ("different", "path-length"))

    def test_path_length_requires_every_difference_and_both_roots(self):
        self.assertFalse(tiers.path_length_difference(["mov w2, #1", "nop"],
                         ["mov w2, #12", "ret"], "/a", "/a12345678901"))
        self.assertFalse(tiers.path_length_difference(["mov w2, #1"], ["mov w2, #12"], "/a", None))
        self.assertFalse(tiers.path_length_difference(["mov w2, #1"], ["mov w2, #13"], "/a", "/a12345678901"))
        self.assertFalse(tiers.path_length_difference(["mov w2, #1"], ["mov w3, #12"], "/a", "/a12345678901"))

    def test_analyse_exact_data_reference_and_certified_counts(self):
        args = argparse.Namespace(a_bin="a", a_nm="an", b_bin="b", b_nm="bn", label="data",
                                  callee_names=False, source_root=[], list_all=True, sections=True, units=True)
        left = section(b"a" * 8, "__text", 0x1000)
        left[("__DATA", "__data")] = dict(addr=0x9010, size=8, data=b"a" * 8)
        right = dict(left)
        right[("__DATA", "__data")] = dict(addr=0x9010, size=8, data=b"b" * 8)
        with mock.patch.object(tiers, "macho_sections", side_effect=[(left, {}), (right, {})]), \
             mock.patch.object(tiers, "nm_by_addr", return_value={0x1000: ["_function"]}), \
             mock.patch.object(tiers, "disassemble", return_value=dict(stream("adrp x20, 0x9000", "add x0, x20, #0x10"))):
            result = tiers.analyse(args)
        self.assertEqual(result["tiers"], dict(exact=1, normalised=0, different=0))
        self.assertEqual(result["data_referencing"], 1)
        self.assertEqual(result["data_unverified"], 1)
        self.assertEqual(result["certified"], 0)
        self.assertEqual(result["functions"][0]["data_sections"], ["__DATA,__data"])


if __name__ == "__main__":
    unittest.main()
