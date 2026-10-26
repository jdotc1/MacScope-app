#!/usr/bin/env python3
"""Select non-window CoreTests and retain an explicit uncovered-scope ledger.

This is a conservative source inventory, not proof that arbitrary AppKit code is
headless. New window construction/presentation outside reviewed files fails closed.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re

WINDOW_FILES = frozenset({
    'DSCommandPaletteFocusTests.swift', 'DSThemeTests.swift',
    'DisassemblyRowAccessibilityLeafTests.swift', 'FocusedPresentationIdentityTests.swift',
    'HexEditModelTests.swift', 'MacScopeGhosttyLifecycleTests.swift',
    'MacScopeGhosttyLinkedSurfaceAdapterTests.swift', 'ReconstructionPresentationRoutingTests.swift',
    'WorkspaceDocumentSaveSheetPresenterTests.swift', 'WorkspaceDocumentSessionTests.swift',
})
WINDOW_MARKER = re.compile(r'\b(?:NSWindow|NSPanel|NSWindowController)\s*\(|:\s*(?:NSWindow|NSPanel)\b|\.(?:orderFront|makeKeyAndOrderFront|showWindow)\s*\(')
TEST_CLASS = re.compile(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b')


def selection(source: Path) -> dict:
    # Hosted bundles (D12 layer 3): folder -> selector prefix.
    bundles = {name: source / 'MacScope/Tests' / name for name in ('CoreTests', 'Phase2Tests')}
    located = {p.name: (bundle, p) for bundle, folder in bundles.items() if folder.is_dir()
               for p in folder.glob('*.swift')}
    found = {name for name, (_, path) in located.items() if WINDOW_MARKER.search(path.read_text())}
    unknown = found - WINDOW_FILES
    if unknown:
        raise ValueError('unreviewed window-capable test files: ' + ', '.join(sorted(unknown)))
    suites = set()
    for name in sorted(WINDOW_FILES):
        if name not in located:
            raise ValueError('window-test inventory changed: ' + name)
        bundle, path = located[name]
        classes = TEST_CLASS.findall(path.read_text())
        if not classes:
            raise ValueError('no XCTestCase declarations in ' + name)
        suites.update(f'{bundle}/{cls}' for cls in classes)
    return {'schema_version': 1, 'coverage': 'partial-nonwindow',
            'window_test_status': 'uncovered; excluded by owner GUI prohibition',
            'excluded_files': sorted(WINDOW_FILES), 'excluded_suites': sorted(suites),
            'claim': 'No full CoreTests or GUI acceptance claim is authorized by this selection.'}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    value = selection(args.source_root)
    args.receipt.write_text(json.dumps(value, indent=2) + '\n')
    for suite in value['excluded_suites']:
        print('-skip-testing:' + suite)


if __name__ == '__main__':
    main()
