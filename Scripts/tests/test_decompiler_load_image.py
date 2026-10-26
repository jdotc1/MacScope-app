from __future__ import annotations

import copy
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOL_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
sys.path.insert(0, str(TOOL_ROOT))

from macscope_decompiler_proof.canonical import bytes_sha256
from macscope_decompiler_proof.load_image import (
    EffectiveLoadImageError,
    build_effective_load_image,
)
from macscope_decompiler_proof.request import parse_request_bytes

BASE = 0x100001000


def request_value(code: bytes) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "requestId": "effective-load-image-test",
        "engine": {
            "languageId": "AARCH64:LE:64:AppleSilicon",
            "compilerSpecId": "default",
        },
        "image": {
            "imageId": "fixture-image",
            "uuid": "00000000-0000-4000-8000-000000000042",
            "preferredLoadAddress": f"0x{BASE:x}",
        },
        "function": {
            "functionId": "fixture-image:test",
            "name": "_test",
            "entryAddress": f"0x{BASE:x}",
            "endAddressExclusive": f"0x{BASE + len(code):x}",
        },
        "memoryRegions": [
            {
                "name": "__TEXT.__text",
                "startAddress": f"0x{BASE:x}",
                "permissions": "r-x",
                "bytesHex": code.hex(),
            }
        ],
        "symbols": [],
        "relocations": [],
        "fixups": [],
        "typeHints": [],
        "budgets": {
            "maxCodeBytes": max(4, len(code)),
            "maxInstructions": 64,
            "maxPcodeOps": 512,
            "maxOutputBytes": 1024 * 1024,
            "maxWallTimeMs": 1000,
        },
    }


def parsed(value: dict[str, object]):
    return parse_request_bytes(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )


def relocation(
    address: int,
    kind: str,
    *,
    target: int | None = None,
    symbol: str | None = None,
    addend: int = 0,
) -> dict[str, object]:
    return {
        "address": f"0x{address:x}",
        "kind": kind,
        "targetAddress": None if target is None else f"0x{target:x}",
        "symbol": symbol,
        "addend": addend,
    }


def fixup(
    address: int,
    kind: str,
    target: int | None,
    *,
    authenticated: bool,
    key: str | None = None,
    diversity: int | None = None,
) -> dict[str, object]:
    return {
        "address": f"0x{address:x}",
        "kind": kind,
        "targetAddress": None if target is None else f"0x{target:x}",
        "authenticated": authenticated,
        "key": key,
        "diversity": diversity,
    }


class EffectiveLoadImageTests(unittest.TestCase):
    def test_identity_view_preserves_raw_bytes_and_hashes(self) -> None:
        code = bytes.fromhex("1f2003d5c0035fd6")
        request = parsed(request_value(code))
        result = build_effective_load_image(request)
        self.assertEqual(result.read(BASE, BASE + len(code)), code)
        self.assertEqual(result.output["patches"], [])
        self.assertEqual(result.output["unmappedEvidence"], [])
        region = result.output["memoryRegions"][0]
        self.assertEqual(region["rawSha256"], bytes_sha256(code))
        self.assertEqual(region["effectiveSha256"], bytes_sha256(code))
        self.assertEqual(region["appliedPatchIds"], [])

    def test_branch26_relocation_resolves_symbol_and_patches_bl(self) -> None:
        value = request_value(bytes.fromhex("00000094c0035fd6"))
        value["symbols"] = [
            {
                "imageId": "fixture-image",
                "address": f"0x{BASE + 0x14:x}",
                "name": "_helper",
                "kind": "function",
            }
        ]
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_BRANCH26", symbol="_helper")
        ]
        result = build_effective_load_image(parsed(value))
        self.assertEqual(result.read(BASE, BASE + 4), bytes.fromhex("05000094"))
        patch = result.output["patches"][0]
        self.assertEqual(patch["id"], "patch000000")
        self.assertEqual(patch["targetAddress"], f"0x{BASE + 0x14:x}")
        self.assertEqual(patch["encoding"], "aarch64Branch26")
        self.assertEqual(result.patch_ids_intersecting(BASE, BASE + 8), ["patch000000"])

    def test_target_and_symbol_must_agree(self) -> None:
        value = request_value(bytes.fromhex("00000094"))
        value["symbols"] = [
            {
                "imageId": "fixture-image",
                "address": f"0x{BASE + 0x10:x}",
                "name": "_helper",
                "kind": "function",
            }
        ]
        value["relocations"] = [
            relocation(
                BASE,
                "ARM64_RELOC_BRANCH26",
                target=BASE + 0x14,
                symbol="_helper",
            )
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "contradicts"):
            build_effective_load_image(parsed(value))

    def test_symbol_resolution_must_have_one_distinct_address(self) -> None:
        value = request_value(bytes.fromhex("00000094"))
        value["symbols"] = [
            {
                "imageId": "fixture-image",
                "address": f"0x{BASE + 0x10:x}",
                "name": "_helper",
                "kind": "function",
            },
            {
                "imageId": "fixture-image",
                "address": f"0x{BASE + 0x14:x}",
                "name": "_helper",
                "kind": "label",
            },
        ]
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_BRANCH26", symbol="_helper")
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "multiple addresses"):
            build_effective_load_image(parsed(value))

    def test_missing_symbol_target_fails_closed(self) -> None:
        value = request_value(bytes.fromhex("00000094"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_BRANCH26", symbol="_missing")
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "no exact"):
            build_effective_load_image(parsed(value))

    def test_branch26_requires_a_branch_instruction(self) -> None:
        value = request_value(bytes.fromhex("1f2003d5"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_BRANCH26", target=BASE + 0x10)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "B or BL"):
            build_effective_load_image(parsed(value))

    def test_branch26_alignment_and_range_fail_closed(self) -> None:
        value = request_value(bytes.fromhex("0000009400000000"))
        value["relocations"] = [
            relocation(BASE + 2, "ARM64_RELOC_BRANCH26", target=BASE + 0x10)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "address.*aligned"):
            build_effective_load_image(parsed(value))

        value = request_value(bytes.fromhex("00000094"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_BRANCH26", target=BASE + (1 << 27))
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "out of signed 26-bit"):
            build_effective_load_image(parsed(value))

    def test_page21_requires_adrp_and_signed_page_range(self) -> None:
        value = request_value(bytes.fromhex("1f2003d5"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGE21", target=BASE + 0x1000)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "ADRP"):
            build_effective_load_image(parsed(value))

        value = request_value(bytes.fromhex("00000090"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGE21", target=BASE + (1 << 32))
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "signed 21-bit"):
            build_effective_load_image(parsed(value))

    def test_page21_patches_adrp_page_delta(self) -> None:
        value = request_value(bytes.fromhex("00000090"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGE21", target=BASE + 0x4678)
        ]
        result = build_effective_load_image(parsed(value))
        self.assertEqual(result.read(BASE, BASE + 4).hex(), "20000090")
        self.assertEqual(result.output["patches"][0]["encoding"], "aarch64AdrpPage21")

    def test_pageoff12_patches_add_immediate(self) -> None:
        value = request_value(bytes.fromhex("00000091"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGEOFF12", target=BASE + 0x678)
        ]
        result = build_effective_load_image(parsed(value))
        self.assertEqual(result.read(BASE, BASE + 4).hex(), "00e01991")
        self.assertEqual(
            result.output["patches"][0]["encoding"],
            "aarch64AddImmediatePageOffset12",
        )

    def test_pageoff12_scales_unsigned_integer_load_store(self) -> None:
        value = request_value(bytes.fromhex("000040f9"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGEOFF12", target=BASE + 0x18)
        ]
        result = build_effective_load_image(parsed(value))
        self.assertEqual(result.read(BASE, BASE + 4).hex(), "000c40f9")
        self.assertEqual(
            result.output["patches"][0]["encoding"],
            "aarch64UnsignedLoadStorePageOffset12",
        )

    def test_pageoff12_rejects_unsupported_or_misaligned_encoding(self) -> None:
        value = request_value(bytes.fromhex("1f2003d5"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGEOFF12", target=BASE + 0x10)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "unsupported instruction"):
            build_effective_load_image(parsed(value))

        value = request_value(bytes.fromhex("000040f9"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGEOFF12", target=BASE + 3)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "alignment"):
            build_effective_load_image(parsed(value))

    def test_pageoff12_rejects_prefetch_and_reserved_load_store_forms(self) -> None:
        # PRFM (unsigned immediate) shares the broad scalar memory encoding
        # class but is intentionally outside the bounded load/store contract.
        value = request_value(bytes.fromhex("000080f9"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGEOFF12", target=BASE + 0x18)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "prefetch or reserved"):
            build_effective_load_image(parsed(value))

        # size=2/opc=3 is reserved in the scalar unsigned-immediate class.
        value = request_value((0xB9C00000).to_bytes(4, "little"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_PAGEOFF12", target=BASE + 0x18)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "prefetch or reserved"):
            build_effective_load_image(parsed(value))

    def test_got_pageoff_rejects_add_immediate(self) -> None:
        value = request_value(bytes.fromhex("00000091"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_GOT_LOAD_PAGEOFF12", target=BASE + 8)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "requires a load/store"):
            build_effective_load_image(parsed(value))

    def test_unsigned_relocation_materializes_little_endian_pointer(self) -> None:
        value = request_value(b"\x00" * 8)
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_UNSIGNED", target=0x1122334455667788)
        ]
        result = build_effective_load_image(parsed(value))
        self.assertEqual(result.read(BASE, BASE + 8).hex(), "8877665544332211")
        self.assertEqual(
            result.output["patches"][0]["encoding"],
            "littleEndianUnsigned64",
        )

    def test_supported_patch_range_cannot_overflow_address_space(self) -> None:
        value = request_value(bytes.fromhex("1f2003d5"))
        value["relocations"] = [
            relocation(0xFFFFFFFFFFFFFFFC, "ARM64_RELOC_UNSIGNED", target=0x2000)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "unsigned 64-bit address space"):
            build_effective_load_image(parsed(value))

    def test_relocation_addend_cannot_overflow_unsigned_target(self) -> None:
        value = request_value(b"\x00" * 8)
        value["relocations"] = [
            relocation(
                BASE,
                "ARM64_RELOC_UNSIGNED",
                target=0xFFFFFFFFFFFFFFFF,
                addend=1,
            )
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "exceeds unsigned"):
            build_effective_load_image(parsed(value))

        value = request_value(b"\x00" * 8)
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_UNSIGNED", target=0, addend=-1)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "exceeds unsigned"):
            build_effective_load_image(parsed(value))

    def test_authenticated_fixup_normalizes_target_and_preserves_auth_evidence(self) -> None:
        value = request_value(b"\xaa" * 8)
        value["fixups"] = [
            fixup(
                BASE,
                "DYLD_CHAINED_AUTH_REBASE64",
                0x123456789ABC,
                authenticated=True,
                key="ia",
                diversity=0x1234,
            )
        ]
        result = build_effective_load_image(parsed(value))
        self.assertEqual(
            result.read(BASE, BASE + 8),
            (0x123456789ABC).to_bytes(8, "little"),
        )
        patch = result.output["patches"][0]
        self.assertTrue(patch["authenticated"])
        self.assertEqual(patch["key"], "ia")
        self.assertEqual(patch["diversity"], 0x1234)

    def test_fixup_kind_and_authentication_fields_must_agree(self) -> None:
        value = request_value(b"\x00" * 8)
        value["fixups"] = [
            fixup(
                BASE,
                "DYLD_CHAINED_REBASE64",
                0x2000,
                authenticated=True,
                key="ia",
                diversity=1,
            )
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "contradicts"):
            build_effective_load_image(parsed(value))

    def test_authenticated_fixup_requires_key_and_diversity(self) -> None:
        value = request_value(b"\x00" * 8)
        value["fixups"] = [
            fixup(
                BASE,
                "DYLD_CHAINED_AUTH_BIND64",
                0x2000,
                authenticated=True,
                key=None,
                diversity=None,
            )
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "requires.*key.*diversity"):
            build_effective_load_image(parsed(value))

    def test_overlapping_patches_fail_closed(self) -> None:
        value = request_value(b"\x00" * 16)
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_UNSIGNED", target=0x2000),
        ]
        value["fixups"] = [
            fixup(
                BASE + 4,
                "DYLD_CHAINED_REBASE64",
                0x3000,
                authenticated=False,
            )
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "overlap"):
            build_effective_load_image(parsed(value))

    def test_patch_cannot_cross_memory_region_boundary(self) -> None:
        value = request_value(b"\x00" * 8)
        value["memoryRegions"] = [
            {
                "name": "left",
                "startAddress": f"0x{BASE:x}",
                "permissions": "r-x",
                "bytesHex": "00000000",
            },
            {
                "name": "right",
                "startAddress": f"0x{BASE + 4:x}",
                "permissions": "r-x",
                "bytesHex": "00000000",
            },
        ]
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_UNSIGNED", target=0x2000)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "boundary"):
            build_effective_load_image(parsed(value))

    def test_patch_starting_before_region_cannot_partially_overlap_it(self) -> None:
        value = request_value(b"\x00" * 8)
        value["relocations"] = [
            relocation(BASE - 4, "ARM64_RELOC_UNSIGNED", target=0x2000)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "partially overlaps"):
            build_effective_load_image(parsed(value))

    def test_unsupported_mapped_fails_but_unmapped_is_preserved(self) -> None:
        value = request_value(bytes.fromhex("1f2003d5"))
        value["relocations"] = [
            relocation(BASE, "ARM64_RELOC_UNKNOWN", target=0x2000)
        ]
        with self.assertRaisesRegex(EffectiveLoadImageError, "unsupported mapped"):
            build_effective_load_image(parsed(value))

        value["relocations"] = [
            relocation(BASE + 0x1000, "ARM64_RELOC_UNKNOWN", target=0x2000)
        ]
        result = build_effective_load_image(parsed(value))
        self.assertEqual(result.output["patches"], [])
        self.assertEqual(
            result.output["unmappedEvidence"],
            [
                {
                    "sourceKind": "relocation",
                    "sourceIndex": 0,
                    "address": f"0x{BASE + 0x1000:x}",
                    "kind": "ARM64_RELOC_UNKNOWN",
                    "reason": "outsideSuppliedMemory",
                }
            ],
        )

    def test_output_is_independent_of_input_record_order(self) -> None:
        value = request_value(b"\x00" * 24)
        value["relocations"] = [
            relocation(BASE + 16, "ARM64_RELOC_UNSIGNED", target=0x5000),
            relocation(BASE, "ARM64_RELOC_UNSIGNED", target=0x3000),
        ]
        expected = build_effective_load_image(parsed(value)).output
        reversed_value = copy.deepcopy(value)
        reversed_value["relocations"].reverse()
        self.assertEqual(build_effective_load_image(parsed(reversed_value)).output, expected)


if __name__ == "__main__":
    unittest.main()
