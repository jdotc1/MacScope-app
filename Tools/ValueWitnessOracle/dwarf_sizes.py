#!/usr/bin/env python3
"""Extract Swift reference/value byte sizes from streamed dwarfdump text."""

import argparse
import json
from pathlib import Path
import re


DIE_HEADER = re.compile(r"^\s*(0x[0-9a-fA-F]+):\s*(.*)$")
LINKAGE = re.compile(r'^\s*DW_AT_linkage_name\b.*\("(\$s[^"\n]+D)"\)')
BYTE_SIZE = re.compile(r"^\s*DW_AT_byte_size\b.*\((0x[0-9a-fA-F]+|[0-9]+)\)")


def iter_sizes(lines):
    """Yield every eligible DIE, retaining duplicates and their source offsets.

    Only the current DIE is held in memory. Attributes on children, NULL
    markers, and subsequent compile units cannot leak into a structure row.
    Swift structs, enums and class references all use DW_TAG_structure_type.
    """
    offset = None
    linkage = None
    size = None
    for line in lines:
        header = DIE_HEADER.match(line)
        if header:
            if offset is not None and linkage is not None and size is not None:
                yield {"mangled": linkage[2:-1], "byteSize": size, "dieOffset": offset}
            tag = header.group(2).split()
            offset = (hex(int(header.group(1), 16))
                      if tag and tag[0] == "DW_TAG_structure_type" else None)
            linkage = None
            size = None
            continue
        if offset is None:
            continue
        match = LINKAGE.match(line)
        if match:
            linkage = match.group(1)
        match = BYTE_SIZE.match(line)
        if match:
            value = match.group(1)
            size = int(value, 16 if value.startswith("0x") else 10)
    if offset is not None and linkage is not None and size is not None:
        yield {"mangled": linkage[2:-1], "byteSize": size, "dieOffset": offset}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("debug_info", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    if args.debug_info.resolve() == args.out.resolve():
        parser.error("input and output must be different files")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.debug_info.open(encoding="utf-8", errors="replace") as source:
        with args.out.open("w", encoding="utf-8") as output:
            output.write("[\n")
            separator = ""
            for row in iter_sizes(source):
                output.write(separator)
                output.write("  " + json.dumps(row, sort_keys=True))
                separator = ",\n"
            output.write("\n]\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
