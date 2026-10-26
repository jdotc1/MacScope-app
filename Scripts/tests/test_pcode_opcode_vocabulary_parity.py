#!/usr/bin/env python3
"""Pin the p-code opcode vocabulary to one source of truth.

MS-2026-08-18-01 / MS-2026-08-18-14. The exported opcode vocabulary used to exist
in three hand-maintained copies: the native provider's export path, this codec's
wire allowlist, and the Swift decoder's enum. Nothing checked that they agreed.

That is not a cosmetic risk. The wire codec rejects an unrecognised opcode name by
failing the WHOLE decompilation result, so a single name present in one copy and
absent from another silently destroys every result containing that opcode.

The native and Objective-C++ production sides now both expand
PcodeOpcodeVocabulary.def, so they cannot drift by construction. Swift cannot
include a C preprocessor manifest, and the Objective-C++ golden test retains an
ordered human-readable expectation, so both remaining copies are pinned here.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "Tools/NativeDecompilerBridge/include/MacScopeNativeDecompiler/PcodeOpcodeVocabulary.def"
CODEC = ROOT / "MacScope/NativeDecompilerXPCService/Bridge/NativeDecompilerWireCodec.mm"
PROVIDER = ROOT / "Tools/NativeDecompilerBridge/src/GhidraProvider.cpp"
NATIVE_BRIDGE = ROOT / "Tools/NativeDecompilerBridge"
SWIFT = ROOT / "MacScope/Models/NativeDecompilerWire/NativeDecompilerWireResultModels.swift"
OBJC_TESTS = ROOT / "MacScope/Tests/CoreTests/NativeDecompilerObjCBridgeTests.mm"
OBJC_BRIDGE = ROOT / "MacScope/NativeDecompilerXPCService/Bridge/NativeDecompilerObjCBridge.mm"

ROW = re.compile(
    r'^\s*MACSCOPE_PCODE_OPCODE\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)',
    re.MULTILINE,
)

# CPUI_ZPULL is exported as EXTRACT/extract. This is the single deliberate
# departure from "canonical name is the enumerator without its CPUI_ prefix".
# It is recorded here so that a second, undocumented exception cannot be added
# without failing this test.
SANCTIONED_ALIASES = {"CPUI_ZPULL": ("EXTRACT", "extract")}


def manifest_rows():
    rows = ROW.findall(MANIFEST.read_text(encoding="utf-8"))
    if not rows:
        raise AssertionError("opcode manifest parsed to zero rows")
    return rows


def swift_raw_values():
    body = re.search(
        r"enum NativeDecompilerWireOpcode:[^\n]*\{(.*?)\n\}",
        SWIFT.read_text(encoding="utf-8"),
        re.S,
    )
    if body is None:
        raise AssertionError("NativeDecompilerWireOpcode enum not found")
    values = []
    for line in body.group(1).splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for member in line[len("case "):].split(","):
            member = member.strip()
            if not member:
                continue
            if "=" in member:
                values.append(member.split("=", 1)[1].strip().strip('"'))
            else:
                values.append(member.strip("`"))
    return values


def objc_coverage_fixture_opcodes():
    body = re.search(
        r'assertStringArrayEquals\(enums\[@"opcodes"\],\s*@\[(.*?)\]\s*\);',
        OBJC_TESTS.read_text(encoding="utf-8"),
        re.S,
    )
    if body is None:
        raise AssertionError(
            'ordered enums[@"opcodes"] coverage fixture expectation not found in '
            "NativeDecompilerObjCBridgeTests.mm"
        )
    values = re.findall(r'@"([^"]+)"', body.group(1))
    if not values:
        raise AssertionError(
            'ordered enums[@"opcodes"] coverage fixture expectation parsed to zero values'
        )
    return values


class PcodeOpcodeVocabularyParityTests(unittest.TestCase):
    def test_manifest_rows_are_unique_and_well_formed(self):
        rows = manifest_rows()
        self.assertEqual(len(rows), len({r[0] for r in rows}), "duplicate enumerator")
        self.assertEqual(len(rows), len({r[1] for r in rows}), "duplicate canonical name")
        self.assertEqual(len(rows), len({r[2] for r in rows}), "duplicate wire token")
        for enumerator, canonical, wire in rows:
            self.assertTrue(enumerator.startswith("CPUI_"), enumerator)
            self.assertEqual(wire, canonical.lower(), f"{canonical} wire token must be its lowercase")
            if enumerator in SANCTIONED_ALIASES:
                self.assertEqual((canonical, wire), SANCTIONED_ALIASES[enumerator])
            else:
                self.assertEqual(
                    canonical,
                    enumerator[len("CPUI_"):],
                    f"{enumerator} exports an alias that is not recorded in SANCTIONED_ALIASES",
                )

    def test_swift_enum_matches_the_manifest_exactly(self):
        expected = sorted(r[2] for r in manifest_rows())
        actual = sorted(swift_raw_values())
        self.assertEqual(
            actual,
            expected,
            "Swift NativeDecompilerWireOpcode has drifted from PcodeOpcodeVocabulary.def; "
            "an opcode present on one side only fails the whole decompilation result",
        )

    def test_objc_coverage_fixture_expectation_matches_the_manifest(self):
        expected = [row[2] for row in manifest_rows()]
        actual = objc_coverage_fixture_opcodes()
        self.assertEqual(
            actual,
            expected,
            "NativeDecompilerObjCBridgeTests.mm ordered opcode coverage fixture has drifted "
            "from PcodeOpcodeVocabulary.def",
        )

    def test_codec_has_no_hand_transcribed_vocabulary_anywhere(self):
        # The codec carries the vocabulary TWICE: the opcodeWireTag allowlist and the
        # mappingCoverageResult fixture. An earlier revision of this test only checked
        # the first, so the second stayed hand-written and the two could disagree while
        # this test was green. Assert on the whole file instead of one block.
        codec = CODEC.read_text(encoding="utf-8")
        self.assertIn("PcodeOpcodeVocabulary.def", codec)
        expansions = codec.count('#include "MacScopeNativeDecompiler/PcodeOpcodeVocabulary.def"')
        self.assertEqual(
            expansions, 2,
            "both the wire allowlist and the coverage fixture must expand the manifest",
        )
        for token in ('"copy",', '"lzcount",', '"int_sborrow",'):
            self.assertNotIn(
                token, codec,
                f"{token} is transcribed by hand in the codec; expand the manifest instead",
            )

    def test_provider_exports_canonical_names_not_get_opname(self):
        provider = PROVIDER.read_text(encoding="utf-8")
        vocabulary = (NATIVE_BRIDGE / "src/PcodeOpcodeVocabulary.hpp").read_text(
            encoding="utf-8"
        )
        self.assertIn("canonicalOpcodeName", provider)
        self.assertIn("PcodeOpcodeVocabulary.hpp", provider)
        self.assertIn("PcodeOpcodeVocabulary.def", vocabulary)
        # get_opname's table disagrees with the OpCode enum for eleven opcodes in the
        # pinned package, nine of them result-destroying. It must not reach the export.
        self.assertIsNone(re.search(r"\bget_opname\s*\(", "\n".join(
            line for line in provider.splitlines() if not line.lstrip().startswith("//")
        )))

    def test_native_bridge_has_no_get_opname_call(self):
        call = re.compile(r"\bget_opname\s*\(")
        offenders = []
        for path in NATIVE_BRIDGE.rglob("*"):
            if path.is_file() and path.suffix in {".cpp", ".hpp", ".cc", ".h"}:
                source = "\n".join(
                    line for line in path.read_text(encoding="utf-8").splitlines()
                    if not line.lstrip().startswith("//")
                )
                if call.search(source):
                    offenders.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(offenders, [], "get_opname calls remain: " + ", ".join(offenders))

    def test_unrepresentable_opcode_maps_to_typed_unavailable_failure(self):
        bridge = OBJC_BRIDGE.read_text(encoding="utf-8")
        self.assertIn('"native-provider-operation-opcode-unavailable"', bridge)
        unavailable_branch = re.search(
            r'native-provider-operation-opcode-unavailable"\)\s*\{(?P<body>.*?)\n\s*\}',
            bridge,
            re.DOTALL,
        )
        self.assertIsNotNone(unavailable_branch, "typed opcode-unavailable branch is missing")
        self.assertIn(
            "WireFailureCode::unavailable",
            unavailable_branch.group("body"),
            "unrepresentable opcode must not become a successful or generic native result",
        )


if __name__ == "__main__":
    unittest.main()
