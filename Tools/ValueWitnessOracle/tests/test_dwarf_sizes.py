import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("dwarf_sizes", ROOT / "dwarf_sizes.py")
dwarf = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dwarf)
FIXTURE = ROOT / "tests" / "fixtures" / "dwarf_structures.txt"


class DwarfSizesTests(unittest.TestCase):
    def test_struct_enum_and_class_reference_sizes(self):
        with FIXTURE.open() as source:
            rows = list(dwarf.iter_sizes(source))
        self.assertEqual(rows, [
            {"mangled": "4Loop21AccentColorControllerC", "byteSize": 8,
             "dieOffset": "0x24f3fa"},
            {"mangled": "7SwiftUI5ColorV", "byteSize": 8, "dieOffset": "0x24fcc4"},
            {"mangled": "s5NeverO", "byteSize": 0, "dieOffset": "0x2500fb"},
        ])

    def test_children_and_null_markers_do_not_supply_parent_attributes(self):
        text = '''0x01: DW_TAG_structure_type
 DW_AT_linkage_name ("$s7Example1AVD")
0x02: DW_TAG_member
 DW_AT_byte_size (0x08)
0x03: DW_TAG_structure_type
 DW_AT_byte_size (0x04)
0x04: NULL
 DW_AT_linkage_name ("$s7Example1BVD")
0x05: DW_TAG_class_type
 DW_AT_linkage_name ("$s7Example1CCD")
 DW_AT_byte_size (0x08)
'''
        self.assertEqual(list(dwarf.iter_sizes(io.StringIO(text))), [])

    def test_duplicate_dies_are_preserved_and_final_die_is_flushed(self):
        text = '''0x0a: DW_TAG_structure_type
 DW_AT_byte_size (016)
 DW_AT_linkage_name ("$s7Example1AVD")
0x0b: DW_TAG_structure_type
 DW_AT_linkage_name ("$s7Example1AVD")
 DW_AT_byte_size (0x10)'''
        self.assertEqual(list(dwarf.iter_sizes(io.StringIO(text))), [
            {"mangled": "7Example1AV", "byteSize": 16, "dieOffset": "0xa"},
            {"mangled": "7Example1AV", "byteSize": 16, "dieOffset": "0xb"},
        ])

    def test_non_swift_and_non_type_linkage_are_excluded(self):
        text = '''0x01: DW_TAG_structure_type
 DW_AT_linkage_name ("foreign")
 DW_AT_byte_size (0x08)
0x02: DW_TAG_structure_type
 DW_AT_linkage_name ("$s7Example1AV")
 DW_AT_byte_size (0x08)
'''
        self.assertEqual(list(dwarf.iter_sizes(io.StringIO(text))), [])

    def test_input_is_consumed_lazily(self):
        def source():
            yield "0x01: DW_TAG_structure_type\n"
            yield ' DW_AT_linkage_name ("$s7Example1AVD")\n'
            yield " DW_AT_byte_size (0x08)\n"
            yield "0x02: NULL\n"
            self.fail("parser read past the requested row")
        row = next(dwarf.iter_sizes(source()))
        self.assertEqual(row["byteSize"], 8)

    def test_isolated_cli_streams_json_rows(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            output = Path(directory) / "sizes.json"
            subprocess.run([sys.executable, "-I", str(ROOT / "dwarf_sizes.py"),
                            str(FIXTURE), "--out", str(output)], check=True)
            rows = json.loads(output.read_text())
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[-1]["mangled"], "s5NeverO")


if __name__ == "__main__":
    unittest.main()
