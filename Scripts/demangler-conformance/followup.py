#!/usr/bin/env python3
"""Capture only the bounded Followup.swift sample; fixture consumes retained captures.

No system images, runtime execution, toolchain downloads, or T8 oracle regeneration.
"""
import argparse
import base64
import json
from pathlib import Path
import re
import struct
import subprocess

from generate import oracle_rows

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'Scripts/demangler-conformance/Followup.swift'
LIBRARY = 'libDemanglerFollowup.dylib'


def selected_symbols(directory):
    inventory = (directory / 'nm.txt').read_text().splitlines()
    functions = [name[1:] for name in inventory if name.startswith('_$s')
                 and any(part in name for part in ('4wide', '8extended', '7repeats', '5words'))
                 and name.endswith('F')]
    image = (directory / LIBRARY).read_bytes()
    if len(image) > 1024 * 1024:
        raise ValueError('sample exceeded 1 MiB bound')
    legacy = sorted(set(name.decode('ascii') for name in re.findall(rb'(?<=\x00)_TtC[^\x00]+', image)))
    if len(functions) != 4 or len(legacy) != 3:
        raise ValueError('unexpected compiler sample inventory')
    return functions, legacy


def metadata_sections(image):
    magic, _, _, _, command_count, _, _, _ = struct.unpack_from('<8I', image)
    if magic != 0xfeedfacf or command_count > 100:
        raise ValueError('expected bounded little-endian Mach-O64')
    cursor = 32
    sections = []
    wanted = {'__const', '__constg_swiftt', '__objc_classname', '__cstring', '__swift5_types', '__swift5_fieldmd', '__swift5_reflstr', '__swift5_typeref'}
    for _ in range(command_count):
        command, size = struct.unpack_from('<II', image, cursor)
        if size < 8 or cursor + size > len(image):
            raise ValueError('invalid load command')
        if command == 0x19:
            count = struct.unpack_from('<I', image, cursor + 64)[0]
            if 72 + 80 * count > size:
                raise ValueError('invalid section table')
            for index in range(count):
                entry = cursor + 72 + 80 * index
                name = image[entry:entry + 16].split(b'\0')[0].decode()
                segment = image[entry + 16:entry + 32].split(b'\0')[0].decode()
                address, length, offset = struct.unpack_from('<QQI', image, entry + 32)
                if name not in wanted or length == 0:
                    continue
                if length > 65536 or offset + length > len(image):
                    raise ValueError('out-of-range metadata section')
                sections.append({'name': name, 'segment': segment, 'address': address,
                                 'fileOffset': offset, 'size': length,
                                 'bytes': base64.b64encode(image[offset:offset + length]).decode()})
        cursor += size
    if not any(s['name'] == '__swift5_typeref' for s in sections):
        raise ValueError('no symbolic metadata section')
    return sections


def capture(directory):
    directory.mkdir(parents=True, exist_ok=False)
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-name',
               'DemanglerFollowup', '-emit-library', SOURCE, '-o', str(directory / LIBRARY)]
    subprocess.run(command, cwd=ROOT, check=True, stdout=(directory / 'compile.log').open('w'), stderr=subprocess.STDOUT)
    inventory = subprocess.check_output(['xcrun', 'nm', '-j', str(directory / LIBRARY)], text=True)
    (directory / 'nm.txt').write_text(inventory)
    functions, legacy = selected_symbols(directory)
    symbols = functions + legacy
    (directory / 'selected-symbols.txt').write_text('\n'.join(symbols) + '\n')
    oracle = subprocess.check_output(['xcrun', 'swift-demangle', '--expand'], input='\n'.join(symbols) + '\n', text=True)
    (directory / 'oracle.txt').write_text(oracle)
    compiler = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip()
    (directory / 'capture.json').write_text(json.dumps({'command': command, 'source': SOURCE, 'compiler': compiler}, indent=2) + '\n')


def fixture(directory, oracles, output):
    functions, legacy = selected_symbols(directory)
    expected = {}
    for oracle in oracles:
        expected.update(oracle_rows(oracle.read_text()))
    selected = functions + legacy
    if set(selected) - expected.keys():
        raise ValueError('missing retained oracle for selected names')
    rows = [{'mangled': s, 'expected': expected[s], 'kind': 'legacy-runtime-class' if s in legacy else 'stable-substitution'}
            for s in selected]
    value = {'schemaVersion': 1, 'source': SOURCE,
             'compiler': json.loads((directory / 'capture.json').read_text())['compiler'],
             'scope': 'Seven selected names and exact mapped metadata-section bytes from one bounded linked sample. Legacy _TF function grammar and indirect symbolic references remain unverified.',
             'symbols': rows, 'sections': metadata_sections((directory / LIBRARY).read_bytes())}
    output.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    print(f'Captured {len(rows)} names and {len(value["sections"])} exact metadata sections')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    cap = commands.add_parser('capture')
    cap.add_argument('--output-dir', type=Path, required=True)
    fix = commands.add_parser('fixture')
    fix.add_argument('--capture-dir', type=Path, required=True)
    fix.add_argument('--oracle', type=Path, action='append', required=True)
    fix.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'capture':
        capture(args.output_dir.resolve())
    else:
        fixture(args.capture_dir.resolve(), args.oracle, args.output)


if __name__ == '__main__':
    main()
