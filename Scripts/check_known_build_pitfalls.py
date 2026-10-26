#!/usr/bin/env python3
"""Cheap changed-file checks; deliberately not a Swift parser or qualification gate."""
import argparse
import pathlib
import re
import subprocess


def inspect(path, text):
    findings = []
    def add(offset, message):
        findings.append((text.count('\n', 0, offset) + 1, message))
    # Same-file UInt8 fixtures: do not flag UInt16 helpers or unrelated literals.
    if '/CoreTests/' in '/' + path:
        helpers = re.findall(r'func\s+(\w*UUID\w*)\s*\(\s*(?:_\s+)?\w+\s*:\s*UInt8\s*\)', text)
        for helper in helpers:
            for match in re.finditer(r'\b' + re.escape(helper) + r'\(\s*(\d+)\s*\)', text):
                if int(match[1]) > 255:
                    add(match.start(), f'{helper} takes UInt8; literal {match[1]} exceeds 255')
        # Only app retrieval boundaries need app-owned enum identity. Local test
        # copies and rawValue strings remain legitimate everywhere else.
        if 'ReconstructionRetrievalQuery(' in text:
            for match in re.finditer(r'(?<![.\w])ReconstructionOperationID\b', text):
                add(match.start(), 'review enum identity at app retrieval boundary; use MacScope.ReconstructionOperationID for app DTO values')
    if path.endswith('XPCREAInspectionProvider.swift'):
        for match in re.finditer(r'let saved = lock\.withLock\s*\{(?!\s*\(\)\s*->\s*Result<Data, Error>\?)', text):
            # finish() has an explicitly typed tuple; only the optional saved result is affected.
            add(match.start(), 'optional saved result needs explicit () -> Result<Data, Error>? closure type')
    for match in re.finditer(r'case\s+\.flagsChanged\s*:(.*?)(?=\n\s*(?:case\s|default\s*:)|\Z)', text, re.S):
        if re.search(r'\bevent\.(?:characters(?:IgnoringModifiers)?|isARepeat)\b', match[1]):
            add(match.start(), 'flagsChanged cannot query NSEvent characters or isARepeat')
    # Subprocess pipes must be drained while the child runs: a child writing more than the
    # ~64 KB pipe buffer blocks in write() and never exits. Function bounds are approximated
    # by the nearest preceding `func`; drains that read on another thread are not flagged.
    func_starts = [m.start() for m in re.finditer(r'\bfunc\s+\w+', text)]
    def enclosing_func(offset):
        starts = [s for s in func_starts if s < offset]
        return starts[-1] if starts else 0
    pipe_read = r'(\w+)\.fileHandleForReading\.(?:readDataToEndOfFile\(\)|readToEnd\(\))'
    reads_by_func = {}
    for match in re.finditer(pipe_read, text):
        start = enclosing_func(match.start())
        reads_by_func.setdefault(start, []).append(match)
        preceding = text[start:match.start()]
        if re.search(r'waitUntilExit\(\)|\.wait\(timeout:|while\s+\w+\.isRunning', preceding):
            add(match.start(), 'pipe read after waiting for process exit deadlocks above ~64 KB; drain concurrently while the child runs')
    for matches in reads_by_func.values():
        if len({m[1] for m in matches}) > 1:
            add(matches[1].start(), 'sequential reads of two pipes deadlock when the second fills first; drain both concurrently')
    for match in re.finditer(r'\.standard(?:Output|Error)\s*=\s*Pipe\(\)', text):
        add(match.start(), 'unread Pipe() fills at ~64 KB and blocks the child; use FileHandle.nullDevice or drain it')
    # waitUntilExit()/RunLoop.run spin the caller's run loop. On the main thread inside SwiftUI
    # view construction, a StateObject initializer or body this re-enters AppKit layout and
    # aborts in AttributeGraph. Flag calls (not comments) in view code and debugger services.
    if re.search(r'(^|/)MacScope/(Features|Services/Debugger)/', path):
        for match in re.finditer(r'^[^\n]*?(\.waitUntilExit\(\)|\bRunLoop\.(?:current|main)\.run\b)', text, re.M):
            if '//' in match[0][:match.start(1) - match.start()]:
                continue
            add(match.start(1), 'run-loop wait may re-enter SwiftUI/AppKit if reached on the main thread; use a semaphore/termination handler off the run loop')
    # Private declarations inside View.body are invalid; top-level helpers are fine.
    body = re.search(r'\bvar body\s*:\s*some View\s*\{', text)
    if body:
        depth = 1
        end = body.end()
        while end < len(text) and depth:
            depth += (text[end] == '{') - (text[end] == '}')
            end += 1
        for match in re.finditer(r'\bprivate\s+(?:func|var|let)\b', text[body.end():end]):
            add(body.end() + match.start(), 'move private helper outside View.body')
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', help='explicit Swift files relative to repository root')
    parser.add_argument('--base', help='inspect Swift files changed from this Git revision to working tree')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    paths = set(args.paths)
    if args.base:
        paths.update(subprocess.check_output(['git', 'diff', '--name-only', '-z', args.base, '--', '*.swift'], cwd=root).decode().split('\0'))
    if not paths:
        parser.error('pass --base <revision> or explicit files; no repository-wide scan is implicit')
    count = 0
    for name in sorted(paths):
        path = root / name
        if not path.is_file() or path.suffix != '.swift':
            continue
        count += 1
        for line, message in inspect(name, path.read_text()):
            print(f'REVIEW {name}:{line}: {message}')
    print(f'Known-pitfall review complete: {count} Swift files. Review findings before the gate; this heuristic does not establish build correctness.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
