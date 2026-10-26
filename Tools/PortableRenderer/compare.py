#!/usr/bin/env python3
"""Byte-level function calibration and contract C4 payoff inventory."""
import argparse
import csv
import difflib
import hashlib
import json
from pathlib import Path
import re


def split(data):
    matches = list(re.finditer(rb'^// FUNCTION name=(.*?) start=(0x[0-9a-f]+)\n', data, re.M))
    result = {}
    for i, match in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(data)
        body = data[match.end():end]
        if not body.endswith(b'\n\n'):
            raise ValueError('Missing witness function separator')
        key = (match[1].decode(), match[2].decode())
        if key in result:
            raise ValueError('Duplicate function identity')
        result[key] = body[:-2]
    if not result:
        raise ValueError('No function headers found')
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def statement_sha(data):
    lines = sorted(line.strip() for line in data.decode().splitlines() if line.strip())
    return sha(('\n'.join(lines) + '\n').encode())


def compare(before, after, out, pin, metric):
    if not re.fullmatch(r'[0-9a-f]{40}', pin):
        raise ValueError('An explicit full source pin is required')
    allowed_metrics = {'byte_identical_functions_vs_pinned_dump',
                       'byte_identical_functions_vs_pin_6467045e0_dump'}
    if metric not in allowed_metrics:
        raise ValueError('Unknown calibration metric: ' + metric)
    before_bytes, after_bytes = before.read_bytes(), after.read_bytes()
    expected, actual = split(before_bytes), split(after_bytes)
    if list(expected) != list(actual):
        raise ValueError('Function identities/order do not match the pinned witness')
    (out / 'census').mkdir(parents=True, exist_ok=True)
    (out / 'predicted-diff').mkdir(parents=True, exist_ok=True)
    mismatch = []
    equal = 0
    with (out / 'census/calibration.csv').open('w', newline='') as c, (out / 'payoff.csv').open('w', newline='') as p:
        census = csv.writer(c)
        census.writerow(['function', 'start', 'identical(0/1)', 'first_diff_line', 'expected_sha256', 'actual_sha256'])
        payoff = csv.writer(p)
        payoff.writerow(['function','start','metric','before','after','stmt_multiset_sha_before','stmt_multiset_sha_after','changed_lines'])
        for (name, start), left in expected.items():
            right = actual[name, start]
            identical = left == right
            equal += identical
            lines1, lines2 = left.decode().splitlines(), right.decode().splitlines()
            first = next((i + 1 for i in range(max(len(lines1), len(lines2))) if lines1[i:i+1] != lines2[i:i+1]), '')
            changed = sum(max(j-i, l-k) for tag, i, j, k, l in difflib.SequenceMatcher(None, lines1, lines2, autojunk=False).get_opcodes() if tag != 'equal')
            census.writerow([name, start, int(identical), first, sha(left), sha(right)])
            identity = pin + '__' + name + '@' + start
            payoff.writerow([identity,start,metric,0,int(identical),statement_sha(left),statement_sha(right),changed])
            if '/' in name or '\\' in name or name in ('.','..'):
                raise ValueError('Unsafe prediction filename: ' + name)
            (out / 'predicted-diff' / (identity + '.before.txt')).write_bytes(left)
            (out / 'predicted-diff' / (identity + '.after.txt')).write_bytes(right)
            if not identical:
                diff = list(difflib.unified_diff(lines1, lines2, fromfile='macOS', tofile='Linux', n=2))
                mismatch.append({'function':name,'start':start,'diff':diff})
    (out / 'census/mismatch-details.json').write_text(json.dumps(mismatch, indent=2) + '\n')
    summary = {'revision':pin, 'metric':metric, 'functions':len(expected),'identical':equal,'mismatched':len(expected)-equal,'required':914, 'reference_sha256':sha(before_bytes), 'render_sha256':sha(after_bytes)}
    (out / 'census/summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))
    return summary

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('out', type=Path)
    parser.add_argument('--pin', required=True)
    parser.add_argument('--metric', required=True)
    args = parser.parse_args()
    compare(args.before, args.after, args.out, args.pin, args.metric)
