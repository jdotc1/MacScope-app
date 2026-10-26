#!/usr/bin/env python3
"""Compare CP1 baseline and CP1B predicated vertical MOVA normal-path effects.

This is differential regression evidence, not an independent architectural oracle
or a native/hardware acceptance test. No fixture expected state is consulted.
Each initial state randomizes every byte of the VM's entire 0x30000-byte register
address space (including full Z/P/ZA tails and holes) and RAM sentinels. The final
comparison covers all of that storage and every additional non-unique byte.
Only SLEIGH's nonarchitectural `unique` temporaries are excluded.

The VM and p-code interpreter are unchanged. ByteStorage merely provides compact
byte-addressed register backing via the same mapping get/set operations; its
agreement with the ordinary dictionary backing is self-tested before execution.
"""
from __future__ import annotations
import argparse
import collections
import hashlib
import json
import pathlib
import random
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'emulator'))
from cp1_vm import SMEVM, parse
from decode_receipt import VARIANTS, lift_batch, metrics

REGISTER_BYTES = 0x30000
WORDS = (
    ('MOVA_ZA_P_RZ_B', 0xc0008000, 1),
    ('MOVA_ZA_P_RZ_H', 0xc0408000, 2),
    ('MOVA_ZA_P_RZ_W', 0xc0808000, 4),
    ('MOVA_ZA_P_RZ_D', 0xc0c08000, 8),
    ('MOVA_ZA_P_RZ_Q', 0xc0c18000, 16),
    ('MOVA_ZA_P_RZ_B_fixture', 0xc000ffef, 1),
    ('MOVA_ZA_P_RZ_H_fixture', 0xc040ffef, 2),
    ('MOVA_ZA_P_RZ_W_fixture', 0xc080ffef, 4),
    ('MOVA_ZA_P_RZ_D_fixture', 0xc0c0ffef, 8),
    ('MOVA_ZA_P_RZ_Q_fixture', 0xc0c1ffef, 16),
)
SVLS = (16, 32, 64, 128, 256)
PREDICATES = ('zero', 'all', 'mixed')
SEED = 0x435031424d4f5641
FORBIDDEN = {'CALLOTHER', 'BRANCH', 'CBRANCH', 'BRANCHIND', 'CALL', 'CALLIND', 'RETURN'}


class ByteStorage(dict):
    """Same byte mapping as VM.mem, with dense backing for register addresses."""
    def __init__(self, raw):
        super().__init__()
        self.registers = bytearray(raw)

    def get(self, key, default=None):
        space, offset = key
        if space == 'register' and 0 <= offset < len(self.registers):
            return self.registers[offset]
        return super().get(key, default)

    def __getitem__(self, key):
        space, offset = key
        if space == 'register' and 0 <= offset < len(self.registers):
            return self.registers[offset]
        return super().__getitem__(key)

    def __setitem__(self, key, value):
        space, offset = key
        if space == 'register':
            if not 0 <= offset < len(self.registers):
                raise ValueError('register write outside whole-storage comparison')
            self.registers[offset] = value
        else:
            super().__setitem__(key, value)

    def nonunique(self):
        return {key: value for key, value in super().items() if key[0] != 'unique'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def state_digest(vm):
    h = hashlib.sha256()
    h.update(vm.mem.registers)
    rest = [[sp, off, val] for (sp, off), val in sorted(vm.mem.nonunique().items())]
    h.update(json.dumps(rest, separators=(',', ':')).encode())
    return h.hexdigest()


def backing_self_test():
    """Check byte order, overlapping writes, large sizes and default-zero reads."""
    rng = random.Random(SEED)
    checks = 0
    for be in (False, True):
        dense = SMEVM(be=be)
        ordinary = SMEVM(be=be)
        dense.mem = ByteStorage(bytes(REGISTER_BYTES))
        for size in (1, 2, 4, 8, 16, 32, 224, 256):
            for space, offset in (('register', 0x5000), ('register', 0x2ff00),
                                  ('unique', 0x100), ('ram', 0x123000)):
                value = rng.getrandbits(size * 8)
                node = (space, offset, size)
                dense.write(node, value)
                ordinary.write(node, value)
                for shift, width in ((0, size), (0, 1), (size - 1, 1)):
                    probe = (space, offset + shift, width)
                    assert dense.read(probe) == ordinary.read(probe)
                    checks += 1
        for space in ('register', 'unique', 'ram'):
            assert dense.read((space, 0x14000, 16)) == ordinary.read((space, 0x14000, 16)) == 0
            checks += 1
    return checks


def initial_state(meta, svl, element_bytes, predicate, selector, seed, word):
    rng = random.Random(seed)
    vm = SMEVM(be=meta['bigEndian'], spaces=meta['spaces'])
    # randbytes consumes deterministic Random bits and is available in Python 3.9.
    vm.mem = ByteStorage(rng.randbytes(REGISTER_BYTES))
    for address in (0, 0x1000, 0xfeed0000, 0xffffffff00000000):
        vm.write(('ram', address, 64), rng.getrandbits(512))
    vm.set('SVL_BYTES', svl)
    vm.set('NONSTREAM_VL_BYTES', 256)
    vm.set('SVCR', 3)
    for name in ('ZA_VALID', 'ZT0_VALID', 'SME2_PRESENT', 'FPMR_PRESENT'):
        vm.set(name, 1)
    # Nonzero upper X bits confirm the encoded selector consumes only W.
    vm.set('X'+str(12+((word >> 13)&3)), ((rng.getrandbits(32) | 1) << 32) | selector)
    if predicate == 'zero':
        raw_predicate = 0
    elif predicate == 'all':
        raw_predicate = (1 << 256) - 1
    else:
        raw_predicate = rng.getrandbits(256)
        # Alternate effective lane bits over the complete maximum vector length;
        # retain random irrelevant bits to test element-size predicate spacing.
        for lane in range(256 // element_bytes):
            bit = 1 << (lane * element_bytes)
            raw_predicate = (raw_predicate | bit) if lane % 2 == 0 else (raw_predicate & ~bit)
    vm.set('P'+str((word >> 10)&7), raw_predicate)
    return vm


def copy_initial(initial, meta):
    vm = SMEVM(be=meta['bigEndian'], spaces=meta['spaces'])
    vm.mem = ByteStorage(initial.mem.registers)
    for key, value in initial.mem.nonunique().items():
        vm.mem[key] = value
    return vm


def selectors(elements):
    # Keep named boundary cases even when values coincide at SVL=16, Q lanes=1.
    return (('zero', 0), ('last', elements - 1), ('wrap', elements),
            ('wrap_plus_one', elements + 1), ('high_bit', 0x80000000),
            ('high_near_max', 0xfffffffe), ('high_max', 0xffffffff))


def compare_case(initial, before, after, baseline_ops, candidate_ops):
    before.run(baseline_ops)
    after.run(candidate_ops)
    equal = (before.mem.registers == after.mem.registers and
             before.mem.nonunique() == after.mem.nonunique())
    result = {'verdict': 'PASS' if equal else 'FAIL',
              'initialStateSHA256': state_digest(initial),
              'baselineFinalStateSHA256': state_digest(before),
              'candidateFinalStateSHA256': state_digest(after),
              'baselineExecutedOps': before.executed_ops,
              'candidateExecutedOps': after.executed_ops,
              'baselineOpaqueCalls': len(before.calls),
              'candidateOpaqueCalls': len(after.calls),
              'baselineMemoryAccesses': before.memory_accesses,
              'candidateMemoryAccesses': after.memory_accesses}
    if before.calls or after.calls or before.memory_accesses or after.memory_accesses:
        result.update(verdict='FAIL', reason='unexpected opaque call or architectural memory access')
    if not equal:
        offsets = [n for n, (a, b) in enumerate(zip(before.mem.registers, after.mem.registers)) if a != b]
        result['registerDifferenceCount'] = len(offsets)
        result['firstRegisterDifferences'] = [
            {'offset': hex(n), 'baseline': before.mem.registers[n], 'candidate': after.mem.registers[n]}
            for n in offsets[:32]]
        a, b = before.mem.nonunique(), after.mem.nonunique()
        result['otherDifferences'] = [
            {'space': k[0], 'offset': hex(k[1]), 'baseline': a.get(k), 'candidate': b.get(k)}
            for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lifter', required=True, type=pathlib.Path)
    parser.add_argument('--baseline', required=True, type=pathlib.Path)
    parser.add_argument('--candidate', required=True, type=pathlib.Path)
    parser.add_argument('--report', required=True, type=pathlib.Path)
    parser.add_argument('--variant', choices=tuple(VARIANTS), action='append')
    args = parser.parse_args()
    variants = args.variant or list(VARIANTS)
    report = {
        'scope': 'Differential whole-storage normal-path MOVA regression; not independent architectural or native acceptance',
        'registerStorage': {'start': 0, 'endExclusive': REGISTER_BYTES,
                            'includes': 'all register bytes, full Z/P/ZA tails, holes, and modeled scalar/control state'},
        'otherStorage': 'All initialized or written non-unique bytes; four 64-byte randomized RAM sentinels',
        'excludedStorage': 'SLEIGH unique temporaries only',
        'seed': hex(SEED), 'SVLBytes': list(SVLS), 'predicates': list(PREDICATES),
        'selectorCases': [n for n, _ in selectors(16)],
        'words': [{'instruction': n, 'word': f'0x{w:08x}', 'elementBytes': b} for n, w, b in WORDS],
        'backingSelfTestChecks': backing_self_test(),
        'lifterSHA256': digest(args.lifter), 'testSHA256': digest(pathlib.Path(__file__)),
        'variantInputs': {}, 'pcodeChecks': [], 'results': []}
    for variant in variants:
        paths = [directory / VARIANTS[variant] for directory in (args.baseline, args.candidate)]
        metas = [json.loads(subprocess.check_output(
            [str(args.lifter.resolve()), 'metadata', str(path.resolve())], text=True)) for path in paths]
        if any(metas[0][key] != metas[1][key] for key in ('bigEndian', 'registers', 'spaces')):
            raise ValueError(f'{variant}: baseline/candidate register or address-space ABI differs')
        meta = metas[0]
        rows = [lift_batch(args.lifter, path, [w for _, w, _ in WORDS], path.parent / 'AARCH64.pspec') for path in paths]
        report['variantInputs'][variant] = {
            'baselineSLA': str(paths[0]), 'candidateSLA': str(paths[1]),
            'baselineSHA256': digest(paths[0]), 'candidateSHA256': digest(paths[1]),
            'baselinePSpecSHA256': digest(paths[0].parent / 'AARCH64.pspec'),
            'candidatePSpecSHA256': digest(paths[1].parent / 'AARCH64.pspec'),
            'bigEndian': meta['bigEndian']}
        for wi, (instruction, word, element_bytes) in enumerate(WORDS):
            parsed = []
            for label, source_rows in zip(('baseline', 'candidate'), rows):
                row = source_rows[wi]
                ops = parse(row['pcode'])
                m = metrics(row)
                bad = sorted({op for op, _, _ in ops} & FORBIDDEN)
                check = {'variant': variant, 'source': label, 'word': f'0x{word:08x}',
                         'decoded': row['decoded'], 'decodeError': row['error'], 'forbiddenOps': bad,
                         'pcodeSHA256': hashlib.sha256(row['pcode'].encode()).hexdigest(), **m}
                report['pcodeChecks'].append(check)
                if not row['decoded'] or row['error'] or not ops or bad or m['u64OverflowVarnodes']:
                    raise ValueError(f'Cannot run ordinary branch-free p-code: {check}')
                parsed.append(ops)
            for svl in SVLS:
                for predicate in PREDICATES:
                    for selector_name, selector in selectors(svl // element_bytes):
                        label = f'{variant}/{instruction}/{svl}/{predicate}/{selector_name}'
                        case_seed = int.from_bytes(hashlib.sha256(f'{SEED}:{label}'.encode()).digest()[:8], 'big')
                        initial = initial_state(meta, svl, element_bytes, predicate, selector, case_seed, word)
                        before, after = (copy_initial(initial, meta) for _ in range(2))
                        result = {'id': label, 'variant': variant, 'instruction': instruction,
                                  'word': f'0x{word:08x}', 'SVLBytes': svl,
                                  'predicate': predicate, 'selectorCase': selector_name,
                                  'selectorRegister': 'W'+str(12+((word >> 13)&3)), 'selectorValue': f'0x{selector:08x}', 'seed': hex(case_seed)}
                        try:
                            result.update(compare_case(initial, before, after, *parsed))
                        except Exception as exc:
                            result.update(verdict='FAIL', reason=f'{type(exc).__name__}: {exc}')
                        report['results'].append(result)
            print(json.dumps({'variant': variant, 'instruction': instruction,
                              'completedCases': len(report['results'])}), flush=True)
    report['caseCount'] = len(report['results'])
    report['counts'] = dict(collections.Counter(r['verdict'] for r in report['results']))
    report['byVariant'] = {
        v: dict(collections.Counter(r['verdict'] for r in report['results'] if r['variant'] == v))
        for v in variants}
    report['pcodeContractChecks'] = len(report['pcodeChecks'])
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ('caseCount', 'counts', 'byVariant', 'pcodeContractChecks', 'backingSelfTestChecks')}, indent=2))
    return int(report['counts'].get('FAIL', 0) != 0)


if __name__ == '__main__':
    raise SystemExit(main())
