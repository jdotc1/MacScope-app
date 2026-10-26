#!/usr/bin/env python3
"""Enforce width-matched raw p-code targets; never substitute for native budget."""
import argparse
import hashlib
import json
import pathlib
from decode_receipt import VARIANTS, lift_batch, metrics

WORDS = ('c000ffef', 'c040ffef', 'c080ffef', 'c0c0ffef', 'c0c1ffef')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('resources', 'lifter', 'report'):
        parser.add_argument('--' + name, type=pathlib.Path, required=True)
    args = parser.parse_args()
    rows = []
    values = [int(word, 16) for word in WORDS]
    for variant, filename in VARIANTS.items():
        sla = args.resources / filename
        lifts = lift_batch(args.lifter, sla, values + [word & ~0x8000 for word in values], args.resources / 'AARCH64.pspec')
        for word, vertical, horizontal in zip(WORDS, lifts[:5], lifts[5:]):
            for lift in (vertical, horizontal):
                assert lift['decoded'] and not lift['error'] and lift['pcode']
                assert metrics(lift)['intraInstructionBranchCount'] == 0
                assert 'CALLOTHER' not in lift['pcode']
            v, h = metrics(vertical)['pcodeOpCount'], metrics(horizontal)['pcodeOpCount']
            assert v <= 2 * h, (variant, word, v, h)
            rows.append({'variant': variant, 'word': word, 'verticalOps': v,
                         'horizontalOps': h, 'targetMaximum': 2 * h,
                         'passes': True, 'slaSHA256': hashlib.sha256(sla.read_bytes()).hexdigest(),
                         'verticalPcode': vertical['pcode'], 'horizontalPcode': horizontal['pcode']})
    args.report.write_text(json.dumps({'scope': __doc__, 'nativeExporterRun': False,
                                      'testSHA256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
                                      'checks': len(rows), 'rows': rows}, indent=2) + '\n')
    print('PASS:', len(rows), 'width-matched raw-op targets; native acceptance/budget unverified')


if __name__ == '__main__':
    main()
