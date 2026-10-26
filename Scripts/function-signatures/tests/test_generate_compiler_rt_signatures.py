#!/usr/bin/env python3
import importlib.util
import json
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "generate_compiler_rt_signatures.py"


def load_generator():
    if not SCRIPT.exists():
        return None
    spec = importlib.util.spec_from_file_location("function_signature_generator", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fat32(entries):
    """Build a minimal big-endian FAT_MAGIC container.

    entries is [(cpu_type, cpu_subtype, payload)].
    """
    header_size = 8 + 20 * len(entries)
    offset = header_size
    arch_headers = []
    payloads = []
    for cpu_type, cpu_subtype, payload in entries:
        arch_headers.append(
            struct.pack(">IIIII", cpu_type, cpu_subtype, offset, len(payload), 0)
        )
        payloads.append(payload)
        offset += len(payload)
    return struct.pack(">II", 0xCAFE_BABE, len(entries)) + b"".join(arch_headers + payloads)


def fat64(entries):
    """Build a minimal big-endian FAT_MAGIC_64 container."""
    header_size = 8 + 32 * len(entries)
    offset = header_size
    arch_headers = []
    payloads = []
    for cpu_type, cpu_subtype, payload in entries:
        arch_headers.append(
            struct.pack(">IIQQII", cpu_type, cpu_subtype, offset, len(payload), 0, 0)
        )
        payloads.append(payload)
        offset += len(payload)
    return struct.pack(">II", 0xCAFE_BABF, len(entries)) + b"".join(arch_headers + payloads)


def ar_member(name, payload, *, extended=True):
    if extended:
        encoded_name = name.encode("ascii") + b"\0"
        name_field = f"#1/{len(encoded_name)}"
        body = encoded_name + payload
    else:
        name_field = name + "/"
        body = payload
    header = (
        name_field.ljust(16)
        + "0".ljust(12)
        + "0".ljust(6)
        + "0".ljust(6)
        + "100644".ljust(8)
        + str(len(body)).ljust(10)
        + "`\n"
    ).encode("ascii")
    return header + body + (b"\n" if len(body) % 2 else b"")


def bsd_archive(members):
    return b"!<arch>\n" + b"".join(ar_member(*member) for member in members)


def archive_with_symdef(objects):
    """Build a BSD archive with a valid __.SYMDEF SORTED member.

    objects is [(member_name, symbol_name, object_bytes)].
    """
    strings = b"".join(symbol_name.encode("utf-8") + b"\0" for _, symbol_name, _ in objects)

    def ranlib(offsets):
        entries = bytearray()
        string_index = 0
        for (_, symbol_name, _), member_offset in zip(objects, offsets):
            entries.extend(struct.pack("<II", string_index, member_offset))
            string_index += len(symbol_name.encode("utf-8")) + 1
        return struct.pack("<I", len(entries)) + entries + struct.pack("<I", len(strings)) + strings

    placeholder_symdef = ar_member("__.SYMDEF SORTED", ranlib([0] * len(objects)))
    offsets = []
    cursor = 8 + len(placeholder_symdef)
    object_members = []
    for member_name, _symbol_name, object_bytes in objects:
        offsets.append(cursor)
        encoded = ar_member(member_name, object_bytes)
        object_members.append(encoded)
        cursor += len(encoded)
    symdef = ar_member("__.SYMDEF SORTED", ranlib(offsets))
    assert len(symdef) == len(placeholder_symdef)
    return b"!<arch>\n" + symdef + b"".join(object_members)


def macho64_object(*, code, symbols, relocations=b"", cpu_subtype=0, text_address=0):
    """Build a minimal arm64 MH_OBJECT with one __TEXT,__text section.

    symbols is [(name, n_type, value)] or [(name, n_type, n_sect, value)].
    Relocations are raw relocation_info bytes.
    """
    header_size = 32
    segment_size = 72 + 80
    commands_size = segment_size + 24
    text_offset = header_size + commands_size
    relocation_offset = text_offset + len(code)
    symbol_offset = relocation_offset + len(relocations)

    strings = bytearray(b"\0")
    nlists = bytearray()
    for symbol in symbols:
        if len(symbol) == 3:
            name, n_type, value = symbol
            section_index = 1
        else:
            name, n_type, section_index, value = symbol
        string_index = len(strings)
        strings.extend(name.encode("utf-8") + b"\0")
        nlists.extend(struct.pack("<IBBHQ", string_index, n_type, section_index, 0, value))
    string_offset = symbol_offset + len(nlists)

    header = struct.pack(
        "<IIIIIIII",
        0xFEED_FACF,
        0x0100_000C,
        cpu_subtype,
        1,
        2,
        commands_size,
        0,
        0,
    )
    segment = struct.pack(
        "<II16sQQQQiiII",
        0x19,
        segment_size,
        b"__TEXT".ljust(16, b"\0"),
        text_address,
        len(code),
        text_offset,
        len(code),
        7,
        5,
        1,
        0,
    )
    section = struct.pack(
        "<16s16sQQIIIIIIII",
        b"__text".ljust(16, b"\0"),
        b"__TEXT".ljust(16, b"\0"),
        text_address,
        len(code),
        text_offset,
        2,
        relocation_offset if relocations else 0,
        len(relocations) // 8,
        0x8000_0400,
        0,
        0,
        0,
    )
    symtab = struct.pack(
        "<IIIIII", 0x2, 24, symbol_offset, len(symbols), string_offset, len(strings)
    )
    return bytes(header + segment + section + symtab + code + relocations + nlists + strings)


def relocation(address, *, symbol_index, pcrel, length, external, kind):
    attributes = (
        symbol_index
        | (int(pcrel) << 24)
        | (length << 25)
        | (int(external) << 27)
        | (kind << 28)
    )
    return struct.pack("<iI", address, attributes)


class FatSelectionTests(unittest.TestCase):
    def test_selects_exact_arm64_all_slice_instead_of_arm64e(self):
        generator = load_generator()
        self.assertIsNotNone(generator, "generator module must exist")

        arm64_all = b"!<arch>\narm64-all"
        arm64e = b"!<arch>\narm64e"
        container = fat32(
            [
                (0x0100_000C, 0x8000_0002, arm64e),
                (0x0100_000C, 0, arm64_all),
            ]
        )

        selected = generator.select_arm64_all_slice(container)

        self.assertEqual(selected.data, arm64_all)
        self.assertEqual(selected.cpu_type, 0x0100_000C)
        self.assertEqual(selected.cpu_subtype, 0)

    def test_supports_fat64_without_truncating_offsets(self):
        generator = load_generator()
        payload = b"!<arch>\nfat64"

        selected = generator.select_arm64_all_slice(
            fat64([(0x0100_000C, 0, payload)])
        )

        self.assertEqual(selected.data, payload)

    def test_normalizes_capability_bits_but_never_accepts_arm64e(self):
        generator = load_generator()
        arm64_all = b"!<arch>\narm64-all-with-capability"
        selected = generator.select_arm64_all_slice(
            fat32(
                [
                    (0x0100_000C, 0x8000_0002, b"arm64e"),
                    (0x0100_000C, 0x8000_0000, arm64_all),
                ]
            )
        )

        self.assertEqual(selected.cpu_subtype, 0x8000_0000)
        self.assertEqual(selected.data, arm64_all)

    def test_rejects_overlapping_fat_slices(self):
        generator = load_generator()
        header = struct.pack(">II", 0xCAFE_BABE, 2)
        arches = b"".join(
            [
                struct.pack(">IIIII", 0x0100_000C, 0, 48, 4, 0),
                struct.pack(">IIIII", 0x0100_0007, 3, 48, 4, 0),
            ]
        )

        with self.assertRaisesRegex(generator.ParseError, "overlap"):
            generator.select_arm64_all_slice(header + arches + b"DATA")

    def test_supports_byte_swapped_fat32_and_fat64(self):
        generator = load_generator()
        payload32 = b"fat32-cigam"
        payload64 = b"fat64-cigam"
        swapped32 = (
            struct.pack(">I", 0xBEBA_FECA)
            + struct.pack("<I", 1)
            + struct.pack("<IIIII", 0x0100_000C, 0, 28, len(payload32), 0)
            + payload32
        )
        swapped64 = (
            struct.pack(">I", 0xBFBA_FECA)
            + struct.pack("<I", 1)
            + struct.pack("<IIQQII", 0x0100_000C, 0, 40, len(payload64), 0, 0)
            + payload64
        )

        self.assertEqual(generator.select_arm64_all_slice(swapped32).data, payload32)
        self.assertEqual(generator.select_arm64_all_slice(swapped64).data, payload64)


class MalformedContainerTests(unittest.TestCase):
    def test_archive_rejects_non_newline_odd_member_padding(self):
        generator = load_generator()
        malformed = b"!<arch>\n" + ar_member("odd.o", b"abc")[:-1] + b"X"

        with self.assertRaisesRegex(generator.ParseError, "padding"):
            generator.parse_bsd_archive(malformed)


class BSDArchiveTests(unittest.TestCase):
    def test_parses_extended_names_and_odd_member_padding(self):
        generator = load_generator()
        archive = bsd_archive(
            [
                ("first-object.o", b"abc"),
                ("second-object.o", b"WXYZ"),
            ]
        )

        members = generator.parse_bsd_archive(archive)

        self.assertEqual([member.name for member in members], ["first-object.o", "second-object.o"])
        self.assertEqual([member.data for member in members], [b"abc", b"WXYZ"])
        self.assertEqual(members[0].header_offset, 8)
        self.assertEqual(members[1].header_offset % 2, 0)

    def test_parses_sorted_ranlib_and_binds_exact_member_offsets(self):
        generator = load_generator()
        strings = b"_alpha\0_beta\0"
        entries = struct.pack("<IIII", 0, 128, 7, 256)
        payload = struct.pack("<I", len(entries)) + entries + struct.pack("<I", len(strings)) + strings

        parsed = generator.parse_ranlib(payload, valid_member_offsets={128, 256})

        self.assertEqual(
            [(entry.name, entry.member_header_offset) for entry in parsed],
            [("_alpha", 128), ("_beta", 256)],
        )

    def test_ranlib_rejects_string_index_into_middle_of_name(self):
        generator = load_generator()
        strings = b"_alpha\0"
        entries = struct.pack("<II", 1, 128)
        payload = struct.pack("<I", len(entries)) + entries + struct.pack("<I", len(strings)) + strings

        with self.assertRaisesRegex(generator.ParseError, "start of a name"):
            generator.parse_ranlib(payload, valid_member_offsets={128})


class MachOObjectTests(unittest.TestCase):
    def test_parses_text_bytes_and_preserves_local_helper_boundaries(self):
        generator = load_generator()
        code = bytes(range(16))
        obj = macho64_object(
            code=code,
            symbols=[
                ("_alpha", 0x0F, 0),
                ("_helper", 0x0E, 8),
                ("ltmp0", 0x0E, 0),
            ],
        )

        parsed = generator.parse_macho_object(obj, member_name="fixture.o", member_header_offset=64)

        self.assertEqual(parsed.text.bytes, code)
        self.assertEqual(
            [(symbol.name, symbol.value) for symbol in parsed.boundary_symbols],
            [("_alpha", 0), ("_helper", 8)],
        )
        self.assertEqual(parsed.external_names_by_address, {0: ("_alpha",)})
        self.assertEqual(parsed.defined_names, ("_alpha", "_helper", "ltmp0"))

    def test_unions_paired_relocations_and_preserves_external_branch_reference(self):
        generator = load_generator()
        relocations = b"".join(
            [
                relocation(4, symbol_index=2, pcrel=False, length=2, external=False, kind=10),
                relocation(4, symbol_index=1, pcrel=True, length=2, external=True, kind=2),
            ]
        )
        obj = macho64_object(
            code=bytes(range(40)),
            symbols=[
                ("_alpha", 0x0F, 0),
                ("_callee", 0x01, 0, 0),
                ("ltmp0", 0x0E, 0),
            ],
            relocations=relocations,
        )

        parsed = generator.parse_macho_object(obj, member_name="relocated.o", member_header_offset=64)

        self.assertEqual(len(parsed.relocation_sites), 1)
        site = parsed.relocation_sites[0]
        self.assertEqual(site.instruction_offset, 4)
        self.assertEqual(site.kinds, (2, 10))
        self.assertEqual(site.external_branch_names, ("_callee",))

    def test_addend_immediately_pairs_at_same_site_with_supported_targets(self):
        generator = load_generator()
        target_forms = [(2, True), (3, True), (4, False)]

        for target_kind, target_pcrel in target_forms:
            with self.subTest(target_kind=target_kind):
                relocations = b"".join(
                    [
                        relocation(
                            4,
                            symbol_index=7,
                            pcrel=False,
                            length=2,
                            external=False,
                            kind=10,
                        ),
                        relocation(
                            4,
                            symbol_index=1,
                            pcrel=target_pcrel,
                            length=2,
                            external=True,
                            kind=target_kind,
                        ),
                    ]
                )

                parsed = generator.parse_macho_object(
                    macho64_object(
                        code=bytes(range(16)),
                        symbols=[("_alpha", 0x0F, 0), ("_undefined", 0x01, 0, 0)],
                        relocations=relocations,
                    ),
                    member_name="legal-addend.o",
                    member_header_offset=64,
                )

                self.assertEqual(parsed.relocation_issues, ())
                self.assertEqual(parsed.relocation_sites[0].kinds, (target_kind, 10))

    def test_malformed_addend_pair_becomes_stable_atom_drop(self):
        generator = load_generator()
        addend = relocation(
            4,
            symbol_index=7,
            pcrel=False,
            length=2,
            external=False,
            kind=10,
        )
        branch_at_four = relocation(
            4,
            symbol_index=1,
            pcrel=True,
            length=2,
            external=True,
            kind=2,
        )
        malformed_forms = {
            "orphan": addend,
            "reversed": branch_at_four + addend,
            "different-site": addend
            + relocation(
                8,
                symbol_index=1,
                pcrel=True,
                length=2,
                external=True,
                kind=2,
            ),
            "unsupported-target": addend
            + relocation(
                4,
                symbol_index=1,
                pcrel=True,
                length=2,
                external=True,
                kind=5,
            ),
        }

        for label, relocations in malformed_forms.items():
            with self.subTest(label=label):
                parsed = generator.parse_macho_object(
                    macho64_object(
                        code=bytes(range(16)),
                        symbols=[("_alpha", 0x0F, 0), ("_undefined", 0x01, 0, 0)],
                        relocations=relocations,
                    ),
                    member_name=f"{label}.o",
                    member_header_offset=64,
                )
                atoms, drops = generator.discover_function_atoms(
                    [parsed],
                    ranlib_names_by_member={64: {"_alpha"}},
                )

                self.assertEqual(atoms, [])
                self.assertEqual([drop.reason for drop in drops], ["malformed-addend-pair"])

    def test_text_address_range_accepts_uint64_boundary_and_rejects_overflow(self):
        generator = load_generator()
        code = bytes(range(4))
        exact_boundary = (1 << 64) - 1 - len(code)
        parsed = generator.parse_macho_object(
            macho64_object(
                code=code,
                symbols=[("_alpha", 0x0F, exact_boundary)],
                text_address=exact_boundary,
            ),
            member_name="boundary.o",
            member_header_offset=64,
        )
        self.assertEqual(parsed.text.address, exact_boundary)

        overflowing_address = exact_boundary + 1
        with self.assertRaisesRegex(generator.ParseError, "__text address range overflows UInt64"):
            generator.parse_macho_object(
                macho64_object(
                    code=code,
                    symbols=[("_alpha", 0x0F, overflowing_address)],
                    text_address=overflowing_address,
                ),
                member_name="overflow.o",
                member_header_offset=64,
            )

    def test_zero_length_text_temporary_marker_is_not_a_boundary_error(self):
        generator = load_generator()
        obj = macho64_object(code=b"", symbols=[("ltmp0", 0x0E, 0)])

        parsed = generator.parse_macho_object(
            obj,
            member_name="empty.o",
            member_header_offset=64,
        )

        self.assertEqual(parsed.text.bytes, b"")
        self.assertEqual(parsed.boundary_symbols, ())

    def test_temporary_names_use_raw_macho_spelling(self):
        generator = load_generator()
        obj = macho64_object(
            code=bytes(range(16)),
            symbols=[
                ("Ltmp0", 0x0E, 0),
                ("lCPI0_0", 0x0E, 4),
                ("_LocalFunction", 0x0E, 8),
            ],
        )

        parsed = generator.parse_macho_object(
            obj,
            member_name="temporary.o",
            member_header_offset=64,
        )

        self.assertEqual(
            [(symbol.name, symbol.value) for symbol in parsed.boundary_symbols],
            [("_LocalFunction", 8)],
        )

    def test_object_subtype_normalizes_capability_bits(self):
        generator = load_generator()
        parsed = generator.parse_macho_object(
            macho64_object(
                code=bytes(range(16)),
                symbols=[("_alpha", 0x0F, 0)],
                cpu_subtype=0x8000_0000,
            ),
            member_name="capability.o",
            member_header_offset=64,
        )

        self.assertEqual(parsed.external_names_by_address, {0: ("_alpha",)})

    def test_relocation_forms_enforce_kind_specific_flags(self):
        generator = load_generator()
        invalid_forms = [
            (2, False, True),
            (3, False, True),
            (4, True, True),
            (5, True, False),
            (6, False, False),
            (10, True, False),
            (10, False, True),
        ]
        symbols = [("_alpha", 0x0F, 0), ("_undefined", 0x01, 0, 0)]

        for kind, pcrel, external in invalid_forms:
            with self.subTest(kind=kind, pcrel=pcrel, external=external):
                raw = relocation(
                    4,
                    symbol_index=1 if external else 0,
                    pcrel=pcrel,
                    length=2,
                    external=external,
                    kind=kind,
                )
                parsed = generator.parse_macho_object(
                    macho64_object(code=bytes(range(16)), symbols=symbols, relocations=raw),
                    member_name="bad-relocation.o",
                    member_header_offset=64,
                )
                self.assertEqual(
                    [(issue.reason, issue.instruction_offset) for issue in parsed.relocation_issues],
                    [("invalid-relocation-flags", 4)],
                )

    def test_unknown_relocation_becomes_stable_atom_drop_not_archive_failure(self):
        generator = load_generator()
        raw = relocation(4, symbol_index=1, pcrel=False, length=2, external=True, kind=1)
        parsed = generator.parse_macho_object(
            macho64_object(
                code=bytes(range(16)),
                symbols=[("_alpha", 0x0F, 0), ("_undefined", 0x01, 0, 0)],
                relocations=raw,
            ),
            member_name="unknown-relocation.o",
            member_header_offset=64,
        )

        atoms, drops = generator.discover_function_atoms(
            [parsed],
            ranlib_names_by_member={64: {"_alpha"}},
        )

        self.assertEqual(atoms, [])
        self.assertEqual([drop.reason for drop in drops], ["unsupported-relocation-type"])

    def test_external_branch_to_defined_symbol_is_not_import_reference_evidence(self):
        generator = load_generator()
        raw = relocation(4, symbol_index=1, pcrel=True, length=2, external=True, kind=2)
        parsed = generator.parse_macho_object(
            macho64_object(
                code=bytes(range(16)),
                symbols=[("_alpha", 0x0F, 0), ("_defined", 0x0F, 8)],
                relocations=raw,
            ),
            member_name="defined-target.o",
            member_header_offset=64,
        )

        self.assertEqual(parsed.relocation_sites[0].external_branch_names, ())


class FunctionAtomTests(unittest.TestCase):
    def test_local_symbol_ends_exported_atom_and_alias_atom_is_dropped(self):
        generator = load_generator()
        bounded = generator.parse_macho_object(
            macho64_object(
                code=bytes(range(16)),
                symbols=[("_alpha", 0x0F, 0), ("_local_helper", 0x0E, 8)],
            ),
            member_name="bounded.o",
            member_header_offset=64,
        )
        aliased = generator.parse_macho_object(
            macho64_object(
                code=bytes(range(16)),
                symbols=[("_alias_a", 0x0F, 0), ("_alias_b", 0x0F, 0)],
            ),
            member_name="aliased.o",
            member_header_offset=128,
        )

        atoms, drops = generator.discover_function_atoms(
            [aliased, bounded],
            ranlib_names_by_member={
                64: {"_alpha"},
                128: {"_alias_a", "_alias_b"},
            },
        )

        self.assertEqual([(atom.name, atom.bytes) for atom in atoms], [("_alpha", bytes(range(8)))])
        self.assertEqual(
            [(drop.reason, drop.member_name, drop.names) for drop in drops],
            [("same-address-alias", "aliased.o", ("_alias_a", "_alias_b"))],
        )


class SignatureDerivationTests(unittest.TestCase):
    def test_derives_frozen_prefix_checksum_tail_and_imported_reference(self):
        generator = load_generator()
        atom = generator.FunctionAtom(
            member_name="derived.o",
            member_header_offset=64,
            name="_derived",
            start_address=0,
            bytes=bytes(range(48)),
            relocation_sites=(
                generator.RelocationSite(4, (2,), ("_external_call",)),
                generator.RelocationSite(40, (3, 4), ()),
            ),
        )

        result = generator.derive_signature(
            atom,
            archive_defined_names={"_derived"},
            library_name="compiler-rt",
        )

        self.assertIsNone(result.drop_reason)
        signature = result.signature
        self.assertEqual(signature.prefix.bytes[4:8], b"\0\0\0\0")
        self.assertEqual(signature.prefix.mask[4:8], b"\0\0\0\0")
        self.assertEqual(signature.prefix.mask[:4], b"\xff" * 4)
        self.assertEqual((signature.checksum.offset, signature.checksum.byte_count), (32, 8))
        self.assertEqual(signature.checksum.crc32, zlib.crc32(bytes(range(32, 40))))
        self.assertEqual(
            [(run.offset, run.bytes) for run in signature.tail_runs],
            [(44, bytes(range(44, 48)))],
        )
        self.assertEqual(
            [(reference.instruction_offset, reference.symbol_name) for reference in signature.references],
            [(4, "_external_call")],
        )

    def test_long_atom_with_variable_instruction_at_checksum_start_is_dropped(self):
        generator = load_generator()
        atom = generator.FunctionAtom(
            member_name="unstable.o",
            member_header_offset=64,
            name="_unstable",
            start_address=0,
            bytes=bytes(range(40)),
            relocation_sites=(generator.RelocationSite(32, (2,), ("_outside",)),),
        )

        result = generator.derive_signature(
            atom,
            archive_defined_names={"_unstable"},
            library_name="compiler-rt",
        )

        self.assertIsNone(result.signature)
        self.assertEqual(result.drop_reason, "unstable-checksum")

    def test_function_larger_than_schema_limit_is_dropped_before_derivation(self):
        generator = load_generator()
        atom = generator.FunctionAtom(
            "oversized.o",
            64,
            "_oversized",
            0,
            b"\0" * (1024 * 1024 + 4),
            (),
        )

        result = generator.derive_signature(
            atom,
            archive_defined_names={"_oversized"},
            library_name="compiler-rt",
        )

        self.assertIsNone(result.signature)
        self.assertEqual(result.drop_reason, "length-exceeds-schema-limit")

    def test_schema_names_must_be_trimmed_nonempty_and_control_free(self):
        generator = load_generator()
        atom = generator.FunctionAtom("name.o", 64, " bad\nname", 0, bytes(range(16)), ())

        bad_function = generator.derive_signature(
            atom,
            archive_defined_names=set(),
            library_name="compiler-rt",
        )
        bad_library = generator.derive_signature(
            generator.FunctionAtom("name.o", 64, "_good", 0, bytes(range(16)), ()),
            archive_defined_names=set(),
            library_name=" compiler-rt ",
        )

        self.assertEqual(bad_function.drop_reason, "invalid-function-name")
        self.assertEqual(bad_library.drop_reason, "invalid-library-name")

    def test_cross_identity_predicate_collision_drops_all_independent_of_input_order(self):
        generator = load_generator()
        atom_a = generator.FunctionAtom("a.o", 64, "_alpha", 0, bytes(range(16)), ())
        atom_b = generator.FunctionAtom("b.o", 128, "_beta", 0, bytes(range(16)), ())
        signature_a = generator.derive_signature(
            atom_a,
            archive_defined_names={"_alpha", "_beta"},
            library_name="compiler-rt",
        ).signature
        signature_b = generator.derive_signature(
            atom_b,
            archive_defined_names={"_alpha", "_beta"},
            library_name="compiler-rt",
        ).signature

        forward = generator.filter_predicate_collisions(
            [(signature_b, atom_b), (signature_a, atom_a)]
        )
        reverse = generator.filter_predicate_collisions(
            [(signature_a, atom_a), (signature_b, atom_b)]
        )

        self.assertEqual(forward, reverse)
        accepted, drops = forward
        self.assertEqual(accepted, [])
        self.assertEqual(
            [(drop.reason, drop.names) for drop in drops],
            [("predicate-collision", ("_alpha",)), ("predicate-collision", ("_beta",))],
        )

    def test_conflicting_branch_names_drop_before_archive_defined_filtering(self):
        generator = load_generator()
        atom = generator.FunctionAtom(
            "conflict.o",
            64,
            "_conflict",
            0,
            bytes(range(32)),
            (generator.RelocationSite(4, (2,), ("_inside", "_outside")),),
        )

        result = generator.derive_signature(
            atom,
            archive_defined_names={"_conflict", "_inside"},
            library_name="compiler-rt",
        )

        self.assertIsNone(result.signature)
        self.assertEqual(result.drop_reason, "conflicting-imported-reference")

    def test_nonidentical_predicates_jointly_matching_source_candidate_are_dropped(self):
        generator = load_generator()
        candidate_bytes = bytes(range(32))
        atom_a = generator.FunctionAtom("a.o", 64, "_alpha", 0, candidate_bytes, ())
        atom_b = generator.FunctionAtom("b.o", 128, "_beta", 0, candidate_bytes, ())
        signature_a = generator.derive_signature(
            atom_a,
            archive_defined_names={"_alpha", "_beta"},
            library_name="compiler-rt",
        ).signature
        signature_b = generator.SignatureRecord(
            name="_beta",
            library_name="compiler-rt",
            total_length=32,
            prefix=generator.MaskedPattern(b"\0\0\0\0" + candidate_bytes[4:], b"\0\0\0\0" + b"\xff" * 28),
            checksum=generator.ChecksumSpan(32, 0, 0),
            tail_runs=(),
            references=(),
        )

        accepted, drops = generator.filter_predicate_collisions(
            [(signature_a, atom_a), (signature_b, atom_b)]
        )

        self.assertEqual(accepted, [])
        self.assertEqual([drop.reason for drop in drops], ["predicate-collision", "predicate-collision"])


class WitnessCollisionTests(unittest.TestCase):
    """A static function byte-identical to an exported one must not let the exported record
    survive: once linked, the record would name the static function wrongly (H18)."""

    @staticmethod
    def code(seed, words):
        return b"".join(struct.pack("<I", (seed * 2654435761 + index * 40503) & 0xFFFF_FFFF | 0x0800_0000)
                        for index in range(words))

    def generate(self, objects):
        generator = load_generator()
        artifacts = generator.generate_artifacts(fat32([(0x0100_000C, 0, archive_with_symdef(objects))]),
                                                 library_name="compiler-rt")
        names = [fixture["name"] for fixture in json.loads(artifacts.oracle_fixture_json)]
        reasons = {(row["reason"], tuple(row["names"])) for row in json.loads(artifacts.rejections_json)}
        return names, reasons

    def test_static_twin_in_the_same_object_drops_the_exported_record(self):
        body = self.code(1, 16)
        names, reasons = self.generate([
            ("twin.o", "_pub", macho64_object(code=body + body, symbols=[("_pub", 0x0F, 0), ("_helper", 0x0E, 64)])),
            ("solo.o", "_solo", macho64_object(code=self.code(2, 16), symbols=[("_solo", 0x0F, 0)])),
        ])
        self.assertEqual(names, ["_solo"])
        self.assertIn(("witness-collision", ("_pub",)), reasons)

    def test_static_twin_in_another_member_with_a_local_call_still_collides(self):
        body = self.code(3, 16)
        call = relocation(8, symbol_index=1, pcrel=True, length=2, external=True, kind=2)
        exported = macho64_object(code=body, symbols=[("_f", 0x0F, 0), ("_bar", 0x01, 0, 0)], relocations=call)
        # The twin calls _bar defined in its own object: no imported-reference name in the object.
        twin = macho64_object(code=body + self.code(4, 4),
                              symbols=[("_g", 0x0E, 0), ("_bar", 0x0F, 64)], relocations=call)
        names, reasons = self.generate([("f.o", "_f", exported), ("g.o", "_bar", twin)])
        self.assertNotIn("_f", names)
        self.assertIn(("witness-collision", ("_f",)), reasons)

    def test_distinct_static_helper_does_not_drop_anything(self):
        names, reasons = self.generate([
            ("a.o", "_pub", macho64_object(code=self.code(5, 16) + self.code(6, 16),
                                           symbols=[("_pub", 0x0F, 0), ("_helper", 0x0E, 64)])),
        ])
        self.assertEqual(names, ["_pub"])
        self.assertFalse(any(reason == "witness-collision" for reason, _ in reasons))


class EndToEndSmokeTests(unittest.TestCase):
    def test_synthetic_archive_generation_is_byte_deterministic(self):
        generator = load_generator()
        thin_archive = archive_with_symdef(
            [
                (
                    "alpha.o",
                    "_alpha",
                    macho64_object(code=bytes(range(48)), symbols=[("_alpha", 0x0F, 0)]),
                ),
                (
                    "beta.o",
                    "_beta",
                    macho64_object(code=bytes(range(16)), symbols=[("_beta", 0x0F, 0)]),
                ),
            ]
        )
        container = fat32([(0x0100_000C, 0, thin_archive)])

        first = generator.generate_artifacts(container, library_name="compiler-rt")
        second = generator.generate_artifacts(container, library_name="compiler-rt")

        self.assertEqual(first, second)
        self.assertTrue(first.swift_source.endswith(b"\n"))
        self.assertIn(b"FunctionSignatureCorpus", first.swift_source)
        manifest = json.loads(first.manifest_json)
        self.assertEqual(manifest["counts"]["mach_o_objects"], 2)
        self.assertEqual(manifest["counts"]["emitted_signatures"], 2)
        self.assertNotIn(str(Path.cwd()).encode(), first.manifest_json)
        fixtures = json.loads(first.oracle_fixture_json)
        self.assertEqual([fixture["name"] for fixture in fixtures], ["_alpha", "_beta"])

    def test_parses_independent_apple_tool_evidence(self):
        generator = load_generator()
        evidence = generator.parse_apple_tool_evidence(
            lipo_output="""architecture arm64
    cputype CPU_TYPE_ARM64
    cpusubtype CPU_SUBTYPE_ARM64_ALL
    offset 360552
    size 245008
""",
            archive_headers_output="""8\t-rw-r--r-- 0/0 10 x __.SYMDEF SORTED
78\t-rw-r--r-- 0/0 10 x alpha.o
""",
            nm_output="""archive(alpha.o):
0000000000000000 T _alpha
0000000000000000 t ltmp0
0000000000000008 t _LocalHelper
""",
            otool_output="""archive(alpha.o):
Relocation information (__TEXT,__text) 2 entries
address pcrel length extern type scattered symbolnum/value
00000004 True long True BR26 False _callee
00000008 False long True PAGOF12 False _data
""",
        )

        self.assertEqual(
            evidence,
            {
                "arm64_offset": 360552,
                "arm64_size": 245008,
                "archive_members": 2,
                "boundary_symbols": 2,
                "text_relocation_records": 2,
            },
        )

    def test_object_raw_subtype_must_agree_with_selected_fat_record(self):
        generator = load_generator()
        thin_archive = archive_with_symdef(
            [
                (
                    "alpha.o",
                    "_alpha",
                    macho64_object(code=bytes(range(16)), symbols=[("_alpha", 0x0F, 0)]),
                )
            ]
        )
        container = fat32([(0x0100_000C, 0x8000_0000, thin_archive)])

        with self.assertRaisesRegex(generator.ParseError, "disagrees with fat slice"):
            generator.generate_artifacts(container, library_name="compiler-rt")

    def test_checkpoint_resume_matches_uninterrupted_generation(self):
        generator = load_generator()
        thin_archive = archive_with_symdef(
            [
                (
                    "alpha.o",
                    "_alpha",
                    macho64_object(code=bytes(range(48)), symbols=[("_alpha", 0x0F, 0)]),
                ),
                (
                    "beta.o",
                    "_beta",
                    macho64_object(code=bytes(range(16)), symbols=[("_beta", 0x0F, 0)]),
                ),
            ]
        )
        container = fat32([(0x0100_000C, 0, thin_archive)])
        uninterrupted = generator.generate_artifacts(container, library_name="compiler-rt")

        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "checkpoint.json"
            with self.assertRaises(generator.CheckpointStop):
                generator.generate_artifacts(
                    container,
                    library_name="compiler-rt",
                    checkpoint_path=checkpoint,
                    stop_after_members=1,
                )
            checkpoint_bytes = checkpoint.read_bytes()
            self.assertNotIn(str(Path.cwd()).encode(), checkpoint_bytes)
            self.assertNotIn(b"bytes_hex", checkpoint_bytes)
            self.assertEqual(json.loads(checkpoint_bytes)["next_member_index"], 1)

            resumed = generator.generate_artifacts(
                container,
                library_name="compiler-rt",
                checkpoint_path=checkpoint,
            )

        self.assertEqual(resumed, uninterrupted)

    def test_checkpoint_rejects_noncanonical_or_type_confused_metadata(self):
        generator = load_generator()
        thin_archive = archive_with_symdef(
            [
                ("alpha.o", "_alpha", macho64_object(code=bytes(range(48)), symbols=[("_alpha", 0x0F, 0)])),
                ("beta.o", "_beta", macho64_object(code=bytes(range(16)), symbols=[("_beta", 0x0F, 0)])),
            ]
        )
        container = fat32([(0x0100_000C, 0, thin_archive)])

        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "checkpoint.json"
            with self.assertRaises(generator.CheckpointStop):
                generator.generate_artifacts(
                    container,
                    library_name="compiler-rt",
                    checkpoint_path=checkpoint,
                    stop_after_members=1,
                )
            value = json.loads(checkpoint.read_bytes())
            checkpoint.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(generator.ParseError, "canonical"):
                generator.generate_artifacts(
                    container,
                    library_name="compiler-rt",
                    checkpoint_path=checkpoint,
                )

            checkpoint.write_bytes((json.dumps({**value, "schema_version": True}, sort_keys=True, indent=2) + "\n").encode())
            with self.assertRaisesRegex(generator.ParseError, "schema_version"):
                generator.generate_artifacts(
                    container,
                    library_name="compiler-rt",
                    checkpoint_path=checkpoint,
                )

    def test_checkpoint_rejects_canonical_non_object_top_levels(self):
        generator = load_generator()
        thin_archive = archive_with_symdef(
            [
                ("alpha.o", "_alpha", macho64_object(code=bytes(range(48)), symbols=[("_alpha", 0x0F, 0)])),
                ("beta.o", "_beta", macho64_object(code=bytes(range(16)), symbols=[("_beta", 0x0F, 0)])),
            ]
        )
        container = fat32([(0x0100_000C, 0, thin_archive)])

        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "checkpoint.json"
            for value in ([], None, "checkpoint", 1, True):
                with self.subTest(value=value):
                    checkpoint.write_bytes(generator._canonical_json(value))
                    try:
                        generator.generate_artifacts(
                            container,
                            library_name="compiler-rt",
                            checkpoint_path=checkpoint,
                        )
                    except Exception as error:
                        self.assertIs(type(error), generator.ParseError)
                        self.assertEqual(
                            str(error),
                            "checkpoint top level must be an object",
                        )
                    else:
                        self.fail("canonical non-object checkpoint was accepted")

    def test_check_mode_reports_drift_without_rewriting_outputs(self):
        generator = load_generator()
        artifacts = generator.GeneratedArtifacts(b"swift\n", b"fixtures\n", b"manifest\n", b"drops\n")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outputs = {
                "swift_source": root / "corpus.swift",
                "oracle_fixture_json": root / "fixtures.json",
                "manifest_json": root / "manifest.json",
                "rejections_json": root / "drops.json",
            }
            for path in outputs.values():
                path.write_bytes(b"stale\n")

            drift = generator.synchronize_artifacts(artifacts, outputs, refresh=False)

            self.assertEqual(sorted(drift), sorted(str(path) for path in outputs.values()))
            self.assertTrue(all(path.read_bytes() == b"stale\n" for path in outputs.values()))

            self.assertEqual(generator.synchronize_artifacts(artifacts, outputs, refresh=True), [])
            self.assertEqual(generator.synchronize_artifacts(artifacts, outputs, refresh=False), [])

    def test_artifact_refresh_preserves_archive_at_legacy_temporary_path(self):
        generator = load_generator()
        artifacts = generator.GeneratedArtifacts(b"swift\n", b"fixtures\n", b"manifest\n", b"drops\n")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "corpus.swift.tmp"
            archive.write_bytes(b"archive\n")
            outputs = {
                "swift_source": root / "corpus.swift",
                "oracle_fixture_json": root / "fixtures.json",
                "manifest_json": root / "manifest.json",
                "rejections_json": root / "drops.json",
            }

            generator._validate_refresh_paths(outputs, archive=archive, checkpoint_path=None)
            generator.synchronize_artifacts(artifacts, outputs, refresh=True)

            self.assertTrue(archive.exists(), "refresh moved or deleted the input archive")
            self.assertEqual(archive.read_bytes(), b"archive\n")
            self.assertEqual(outputs["swift_source"].read_bytes(), b"swift\n")

    def test_checkpoint_write_preserves_archive_at_legacy_temporary_path(self):
        generator = load_generator()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkpoint = root / "checkpoint.json"
            archive = root / "checkpoint.json.tmp"
            archive.write_bytes(b"archive\n")

            generator._write_checkpoint(checkpoint, {"next_member_index": 1})

            self.assertTrue(archive.exists(), "checkpoint write moved or deleted the input archive")
            self.assertEqual(archive.read_bytes(), b"archive\n")
            self.assertEqual(
                checkpoint.read_bytes(),
                generator._canonical_json({"next_member_index": 1}),
            )

    def test_refresh_supports_output_named_like_another_outputs_legacy_temporary_path(self):
        generator = load_generator()
        artifacts = generator.GeneratedArtifacts(b"swift\n", b"fixtures\n", b"manifest\n", b"drops\n")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outputs = {
                "swift_source": root / "swift.json",
                "oracle_fixture_json": root / "x",
                "manifest_json": root / "x.tmp",
                "rejections_json": root / "drops.json",
            }

            generator._validate_refresh_paths(outputs, archive=root / "archive.a", checkpoint_path=None)
            generator.synchronize_artifacts(artifacts, outputs, refresh=True)

            self.assertTrue(
                outputs["manifest_json"].exists(),
                "refresh moved or deleted an earlier output",
            )
            self.assertEqual(outputs["manifest_json"].read_bytes(), b"manifest\n")
            self.assertEqual(outputs["oracle_fixture_json"].read_bytes(), b"fixtures\n")

    def test_refresh_paths_reject_resolved_aliases_to_inputs_and_outputs(self):
        generator = load_generator()
        validator = getattr(generator, "_validate_refresh_paths", None)
        self.assertIsNotNone(validator, "refresh mode must validate resolved write paths")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "archive.a"
            archive.write_bytes(b"archive")
            checkpoint = root / "checkpoint.json"
            outputs = {
                "swift_source": root / "corpus.swift",
                "oracle_fixture_json": root / "fixtures.json",
                "manifest_json": root / "manifest.json",
                "rejections_json": root / "drops.json",
            }
            validator(outputs, archive=archive, checkpoint_path=checkpoint)

            archive_alias = root / "archive-alias"
            archive_alias.symlink_to(archive)
            with self.assertRaisesRegex(generator.ParseError, "aliases archive"):
                validator(
                    {**outputs, "swift_source": archive_alias},
                    archive=archive,
                    checkpoint_path=checkpoint,
                )

            checkpoint_alias = root / "checkpoint-alias"
            checkpoint_alias.symlink_to(checkpoint)
            with self.assertRaisesRegex(generator.ParseError, "aliases checkpoint"):
                validator(
                    {**outputs, "swift_source": checkpoint_alias},
                    archive=archive,
                    checkpoint_path=checkpoint,
                )

            output_alias = root / "corpus-alias"
            output_alias.symlink_to(outputs["swift_source"])
            with self.assertRaisesRegex(generator.ParseError, "output paths must be distinct"):
                validator(
                    {**outputs, "oracle_fixture_json": output_alias},
                    archive=archive,
                    checkpoint_path=checkpoint,
                )


if __name__ == "__main__":
    unittest.main()
