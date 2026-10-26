#!/usr/bin/env python3
"""Audit actual emitted CP1B packed vertical B/H/S MOVA p-code.

This is bounded normal-path interpreter evidence, not native/hardware acceptance.
An independent physical-byte oracle checks both baseline and candidate final
non-unique state. Candidate _access/write hooks additionally check every STORE,
including idempotent inactive stores that a final-state comparison cannot detect.
The oracle does not import or call the SLEIGH generator or fixture expectations.
Coverage is an explicit covering matrix, NOT an exhaustive encoding/state product.
"""
from __future__ import annotations
import argparse
import bisect
import collections
import hashlib
import json
import pathlib
import random
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'emulator'))
from cp1_vm import SMEVM, parse
from decode_receipt import VARIANTS, lift_batch, metrics
from test_cp1b_mova_equivalence import ByteStorage, REGISTER_BYTES, digest

SEED = 0x4350314257524954
SVLS = tuple(range(16, 257, 16))
BASES = {1: 0xc0008000, 2: 0xc0408000, 4: 0xc0808000}
FORBIDDEN = {'CALLOTHER', 'BRANCH', 'CBRANCH', 'BRANCHIND', 'CALL', 'CALLIND', 'RETURN'}
SELECTOR_NAMES = ('zero', 'last', 'wrap', 'wrap_plus_one', 'high_bit', 'near_max', 'max')


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def word_for(b, z, p, w, tile, off):
    # Independently decode/encode the architectural fields, not generator tables.
    return BASES[b] | z << 5 | p << 10 | (w - 12) << 13 | tile * (16 // b) | off


def fields(word, b):
    return {'z': (word >> 5) & 31, 'p': (word >> 10) & 7,
            'w': 12 + ((word >> 13) & 3), 'tile': (word & 15) // (16 // b),
            'off': word & (16 // b - 1)}


def unique_layout(ops):
    nodes = {v for _, out, ins in ops for v in ([out] if out else []) + ins if v[0] == 'unique'}
    intervals = []
    for _, off, size in sorted(nodes, key=lambda v: v[1]):
        if intervals and off <= intervals[-1][1]:
            intervals[-1][1] = max(intervals[-1][1], off + size)
        else:
            intervals.append([off, off + size])
    starts = [lo for lo, _ in intervals]
    bases, total = [], 0
    for lo, hi in intervals:
        bases.append(total)
        total += hi - lo
    mapped = {}
    for node in nodes:
        i = bisect.bisect_right(starts, node[1]) - 1
        start = bases[i] + node[1] - starts[i]
        mapped[node] = (start, start + node[2])
    return mapped, total


class AuditVM(SMEVM):
    """Unchanged SMEVM dispatch/arithmetic, self-tested dense byte read/write.

    Compact unique backing preserves overlapping varnodes. Each unique read is
    checked at runtime for initialization of EVERY byte, including subpieces.
    _access and write are both observed, so direct non-unique writes cannot hide.
    """
    def __init__(self, meta, raw, rest, layout):
        super().__init__(be=meta['bigEndian'], spaces=meta['spaces'])
        self.mem = ByteStorage(raw)
        for key, value in rest.items():
            self.mem[key] = value
        self.unique_map, n = layout
        self.unique_raw = bytearray(n)
        self.unique_initialized = bytearray(n)
        self.unique_reads = self.unique_read_bytes = 0
        self.trace = []
        self.accesses = []
        self.pending_store = None
        self.auditing = False

    def read(self, node):
        self.bounded(node)
        space, off, size = node
        if space == 'unique':
            lo, hi = self.unique_map[node]
            require(0 not in self.unique_initialized[lo:hi], f'uninitialized unique read {node}')
            self.unique_reads += 1
            self.unique_read_bytes += size
            raw = self.unique_raw[lo:hi]
        elif space == 'register':
            raw = self.mem.registers[off:off + size]
        else:
            return super().read(node)
        return int.from_bytes(raw, 'big' if self.be else 'little')

    def write(self, node, value):
        self.bounded(node)
        space, off, size = node
        raw = (value & ((1 << (size * 8)) - 1)).to_bytes(size, 'big' if self.be else 'little')
        if self.auditing and space != 'unique':
            is_store = self.pending_store == node
            self.trace.append((space, off, size, int.from_bytes(raw, 'big' if self.be else 'little'), is_store))
            if is_store:
                self.pending_store = None
        if space == 'unique':
            lo, hi = self.unique_map[node]
            self.unique_raw[lo:hi] = raw
            self.unique_initialized[lo:hi] = b'\1' * size
        elif space == 'register':
            self.mem.registers[off:off + size] = raw
        else:
            super().write(node, value)

    def _access(self, space, off, size, store=False):
        node = super()._access(space, off, size, store)
        self.accesses.append((space, off, size, store))
        if store:
            require(self.pending_store is None, 'unconsumed previous STORE')
            self.pending_store = node
        return node

    def run(self, ops):
        self.auditing = True
        try:
            super().run(ops)
            require(self.pending_store is None, 'STORE did not reach write hook')
        finally:
            self.auditing = False


def source_address(z, byte_index, b, be):
    # Logical Z[0:32] and Z[32:256] are separate physical register objects.
    if byte_index < 32:
        base, width, local = 0x5000 + z * 32, 32, byte_index
    else:
        base, width, local = 0x10000 + z * 224, 224, byte_index - 32
    return base + (width - local - b if be else local)


def predicate_value(kind, b, seed):
    if kind == 'zero':
        return 0
    if kind == 'all':
        return (1 << 256) - 1
    if kind.startswith('bit_'):
        return 1 << int(kind[4:])
    if kind == 'irrelevant_only':
        return sum(1 << i for i in range(256) if i % b)
    rng = random.Random(seed ^ 0x50524544)
    raw = rng.getrandbits(256)
    # Alternate effective bits while retaining randomized irrelevant bits.
    for i in range(0, 256, b):
        raw = raw | (1 << i) if (i // b) % 2 == 0 else raw & ~(1 << i)
    return raw


def selector_value(name, elements):
    return dict(zip(SELECTOR_NAMES, (0, elements - 1, elements, elements + 1,
                                   0x80000000, 0xfffffffe, 0xffffffff)))[name]


def make_initial(meta, case):
    rng = random.Random(case['seed'])
    vm = SMEVM(be=meta['bigEndian'], spaces=meta['spaces'])
    vm.mem = ByteStorage(rng.randbytes(REGISTER_BYTES))
    for address in (0, 0x1000, 0xfeed0000, 0xffffffff00000000):
        vm.write(('ram', address, 64), rng.getrandbits(512))
    vm.set('SVL_BYTES', case['svl'])
    vm.set('NONSTREAM_VL_BYTES', 256)
    vm.set('SVCR', 3)
    for name in ('ZA_VALID', 'ZT0_VALID', 'SME2_PRESENT', 'FPMR_PRESENT'):
        vm.set(name, 1)
    f = fields(case['word'], case['b'])
    # Keep nonzero unrelated high X bits, ensuring W selection is zero-extended.
    vm.set('X' + str(f['w']), ((rng.getrandbits(32) | 1) << 32) | case['selector'])
    pred = predicate_value(case['predicate'], case['b'], case['seed'])
    vm.set('P' + str(f['p']), pred)
    return vm, pred


def independent_expected(initial, case, pred):
    """Pure coordinate/physical-byte oracle; no packed-pointer arithmetic."""
    before = initial.mem.registers
    after = bytearray(before)
    f, b, svl = fields(case['word'], case['b']), case['b'], case['svl']
    column = (case['selector'] + f['off']) % (svl // b)
    trace, active = [], 0
    for byte_index in range(0, 256, b):
        src = source_address(f['z'], byte_index, b, initial.be)
        raw = before[src:src + b]
        is_active = byte_index < svl and bool(pred & (1 << byte_index))
        if is_active:
            # ZA(tile,row,column), row=byte_index/b, physical max-row stride=256.
            dst = 0x20000 + (f['tile'] + byte_index) * 256 + column * b
            after[dst:dst + b] = raw
            active += 1
        else:
            dst = src
        trace.append(('register', dst, b, int.from_bytes(raw, 'big' if initial.be else 'little'), True))
    return after, initial.mem.nonunique(), trace, active


def validate_candidate(vm, expected_trace):
    require(len(vm.trace) == len(expected_trace), f'non-unique write count {len(vm.trace)} != {len(expected_trace)}')
    for lane, (actual, expected) in enumerate(zip(vm.trace, expected_trace)):
        require(actual == expected, f'STORE lane {lane}: actual {actual}; expected {expected}')
    require(len(vm.accesses) == len(expected_trace), 'unexpected candidate LOAD/access')
    require(all(sp == 'register' and store for sp, _, _, store in vm.accesses), 'unexpected nonregister access or LOAD')
    require(not vm.calls and not vm.memory_accesses, 'opaque call or architectural RAM access')


def check_state(vm, expected_raw, expected_rest, label):
    if vm.mem.registers != expected_raw:
        changes = [(hex(i), a, b) for i, (a, b) in enumerate(zip(vm.mem.registers, expected_raw)) if a != b][:12]
        raise AssertionError(f'{label} differs from independent expected register state: {changes}')
    require(vm.mem.nonunique() == expected_rest, f'{label} differs in other non-unique storage')
    require(not vm.calls and not vm.memory_accesses, f'{label}: opaque call or RAM access')


def state_hash(raw, rest):
    h = hashlib.sha256(raw)
    h.update(json.dumps([[s, o, v] for (s, o), v in sorted(rest.items())], separators=(',', ':')).encode())
    return h.hexdigest()


def make_cases():
    cases = []
    seen = set()
    def add(suite, b, word, svl, pred, selector_name):
        selector = selector_value(selector_name, svl // b)
        key = (b, word, svl, pred, selector_name)
        if key in seen:
            return
        seen.add(key)
        label = f'{suite}/{b}/{word:08x}/{svl}/{pred}/{selector_name}'
        seed = int.from_bytes(hashlib.sha256(f'{SEED}:{label}'.encode()).digest()[:8], 'big')
        cases.append(dict(suite=suite, b=b, word=word, svl=svl, predicate=pred,
                          selectorName=selector_name, selector=selector, seed=seed, id=label))
    for b in BASES:
        # Every Z field, every P/W field pairing, every tile/off pair, each legal
        # SVL. Predicate and W-value combinations are deliberately rotated.
        for z in range(32):
            tileoff = z % 16
            word = word_for(b, z, z % 8, 12 + z // 8, tileoff // (16 // b), tileoff % (16 // b))
            for si, svl in enumerate(SVLS):
                add('field_svl_cover', b, word, svl, ('zero', 'all', 'mixed')[(z + si) % 3], SELECTOR_NAMES[(3 * z + si) % 7])
        # Complete product on two encoded corners only, stated explicitly.
        for word in (word_for(b, 0, 0, 12, 0, 0), word_for(b, 31, 7, 15, b - 1, 16 // b - 1)):
            for svl in SVLS:
                for pred in ('zero', 'all', 'mixed'):
                    for selector_name in SELECTOR_NAMES:
                        add('corner_product', b, word, svl, pred, selector_name)
        word = word_for(b, 17, 5, 14, b - 1, 16 // b - 1)
        # Single bits on each side of split/group/SVL boundaries, including
        # irrelevant H/S predicate bits and predicate bits above current SVL.
        for svl in SVLS:
            boundaries = {0, 1, svl - b, svl - 1, svl, svl + 1, 256 - b, 255}
            for edge in range(32, 256, 32):
                boundaries.update((edge - b, edge - 1, edge, edge + 1))
            for bit in sorted(n for n in boundaries if 0 <= n < 256):
                add('single_boundaries', b, word, svl, f'bit_{bit}', 'max')
            if b > 1:
                add('irrelevant_predicates', b, word, svl, 'irrelevant_only', 'near_max')
        # At maximum SVL, execute every single predicate bit for each width.
        for bit in range(256):
            add('single_all_max_svl', b, word, 256, f'bit_{bit}', 'max')
    return cases


def self_test_storage():
    checks = 0
    rng = random.Random(SEED)
    for be in (False, True):
        meta = {'bigEndian': be, 'spaces': {'4': 'register'}}
        nodes = [('unique', 0x100 + off, n) for off, n in ((0, 256), (1, 224), (16, 32), (20, 4), (21, 2), (22, 1))]
        ops = [('COPY', node, [('const', 0, node[2])]) for node in nodes]
        fast = AuditVM(meta, rng.randbytes(REGISTER_BYTES), {}, unique_layout(ops))
        ordinary = SMEVM(be=be)
        ordinary.mem = ByteStorage(fast.mem.registers)
        try:
            fast.read(nodes[0])
        except AssertionError:
            checks += 1
        else:
            raise AssertionError('unique initialization guard failed')
        for node in nodes + [('register', 0x5000 + off, n) for off, n in ((0, 256), (1, 224), (16, 32), (20, 4), (21, 2), (22, 1))]:
            value = rng.getrandbits(node[2] * 8)
            fast.write(node, value)
            ordinary.write(node, value)
            require(fast.read(node) == ordinary.read(node), 'dense byte write/read mismatch')
            checks += 1
        for node in nodes:
            require(fast.read(node) == ordinary.read(node), 'dense overlap mismatch')
            checks += 1
        require(fast.mem.registers == ordinary.mem.registers, 'dense register full-state mismatch')
        checks += 1
    return checks


def parity_and_mutation_tests(meta, ops_pair, layouts, case):
    """Validate adapters against ordinary VM; show trace catches no-op writes."""
    initial, pred = make_initial(meta, case)
    expected_raw, rest, expected_trace, _ = independent_expected(initial, case, pred)
    checks = 0
    for ops, layout in zip(ops_pair, layouts):
        fast = AuditVM(meta, initial.mem.registers, rest, layout)
        slow = SMEVM(be=meta['bigEndian'], spaces=meta['spaces'])
        slow.mem = ByteStorage(initial.mem.registers)
        for key, value in rest.items():
            slow.mem[key] = value
        fast.run(ops)
        slow.run(ops)
        require(fast.mem.registers == slow.mem.registers and fast.mem.nonunique() == slow.mem.nonunique(), 'ordinary/dense interpreter state mismatch')
        require(fast.executed_ops == slow.executed_ops and fast.calls == slow.calls and fast.memory_accesses == slow.memory_accesses, 'ordinary/dense execution mismatch')
        check_state(fast, expected_raw, rest, 'adapter parity')
        checks += 1
    # Mutate actual emitted STORE into idempotent P and neighboring-Z writes.
    # Final state remains unchanged, so only address/write instrumentation can
    # reject these mutations. Use an all-inactive instruction explicitly.
    zero_case = dict(case, predicate='zero')
    zero_initial, zero_pred = make_initial(meta, zero_case)
    unchanged, zero_rest, zero_trace, _ = independent_expected(zero_initial, zero_case, zero_pred)
    candidate_ops = ops_pair[1]
    first = next(i for i, (op, _, _) in enumerate(candidate_ops) if op == 'STORE')
    b = case['b']
    for bad_address in (0x6000, 0x1768, source_address((fields(case['word'], b)['z'] + 1) % 32, 0, b, meta['bigEndian'])):
        bad = list(candidate_ops)
        op, out, ins = bad[first]
        old_value = int.from_bytes(zero_initial.mem.registers[bad_address:bad_address + b], 'big' if meta['bigEndian'] else 'little')
        bad[first] = (op, out, [ins[0], ('const', bad_address, 4), ('const', old_value, b)])
        vm = AuditVM(meta, zero_initial.mem.registers, zero_rest, unique_layout(bad))
        vm.run(bad)
        check_state(vm, unchanged, zero_rest, 'idempotent negative control')
        try:
            validate_candidate(vm, zero_trace)
        except AssertionError:
            checks += 1
        else:
            raise AssertionError('write-address audit accepted idempotent forbidden write')
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lifter', type=pathlib.Path, required=True)
    parser.add_argument('--baseline', type=pathlib.Path, required=True)
    parser.add_argument('--candidate', type=pathlib.Path, required=True)
    parser.add_argument('--report', type=pathlib.Path, required=True)
    parser.add_argument('--variant', choices=tuple(VARIANTS), action='append')
    parser.add_argument('--limit', type=int, help='Smoke-only limit per variant; receipt labels this restriction')
    args = parser.parse_args()
    variants = args.variant or list(VARIANTS)
    all_cases = make_cases()
    cases = all_cases[:args.limit] if args.limit else all_cases
    words = sorted({c['word'] for c in cases})
    report = {
        'scope': 'Actual emitted-pcode normal-path vertical predicated B/H/S MOVA; instrumented STORE address/value audit plus independent physical-byte and baseline full-state checks. Not native/hardware acceptance or exhaustive encoding/state product.',
        'matrixDescription': ['All 32 Z fields and all 32 P0-7/W12-15 field pairings, all 16 tile/off field combinations, each legal SVL, with rotated predicate/W-value profiles.', 'Full product of 16 legal SVLs, zero/all/mixed predicates and seven W-value profiles at two encoded field corners per width.', 'Single predicate bits beside every 32-byte group/split and SVL boundary for every SVL; every one of 256 single predicate bits at SVL=256 per width; irrelevant-only H/S predicates.'],
        'oracle': 'Original physical source bytes, independently calculated ZA(tile,row,column), predicate bit at byte offset, W32 plus immediate promoted before modulo. BE reverses within each low32/high224 Z object independently.',
        'fullState': {'registerBytes': REGISTER_BYTES, 'includes': 'Every register byte including Z/P/ZA tails, holes, controls, flags, neighbors; every other initialized/written non-unique byte; four randomized 64-byte RAM sentinels', 'excluded': 'Unique temporaries only; every unique read byte is nevertheless initialized-before-read checked at runtime'},
        'writeContract': 'Exactly 256/elementBytes candidate STOREs: active lanes to exact ZA byte range, inactive lanes to exact original Z byte range and original value; no other access/write. _access and write independently observed, including idempotent writes.',
        'seed': hex(SEED), 'SVLBytes': list(SVLS), 'elementBytes': list(BASES),
        'selectorProfiles': list(SELECTOR_NAMES), 'fullMatrixCasesPerVariant': len(all_cases),
        'appliedLimit': args.limit, 'casesPerVariant': len(cases), 'uniqueWordsPerVariant': len(words),
        'testSHA256': digest(pathlib.Path(__file__)), 'lifterSHA256': digest(args.lifter),
        'storageSelfTestChecks': self_test_storage(), 'adapterParityAndMutationChecks': 0,
        'variantInputs': {}, 'pcodeChecks': [], 'results': []}
    start = time.monotonic()
    totals = collections.Counter()
    coverage = {v: {} for v in variants}
    for variant in variants:
        paths = [d / VARIANTS[variant] for d in (args.baseline, args.candidate)]
        metas = [json.loads(subprocess.check_output([str(args.lifter.resolve()), 'metadata', str(p.resolve())], text=True)) for p in paths]
        require(all(metas[0][k] == metas[1][k] for k in ('bigEndian', 'registers', 'spaces')), f'{variant}: metadata ABI changed')
        meta = metas[0]
        rows_pair = [lift_batch(args.lifter, p, words, p.parent / 'AARCH64.pspec') for p in paths]
        report['variantInputs'][variant] = {'bigEndian': meta['bigEndian'], 'baselineSLA': str(paths[0]), 'candidateSLA': str(paths[1]), 'baselineSHA256': digest(paths[0]), 'candidateSHA256': digest(paths[1]), 'baselinePSpecSHA256': digest(paths[0].parent / 'AARCH64.pspec'), 'candidatePSpecSHA256': digest(paths[1].parent / 'AARCH64.pspec')}
        programs = {}
        for wi, word in enumerate(words):
            pair = []
            for label, rows in zip(('baseline', 'candidate'), rows_pair):
                row = rows[wi]
                ops = parse(row['pcode'])
                m = metrics(row)
                bad = sorted({op for op, _, _ in ops} & FORBIDDEN)
                check = dict(variant=variant, source=label, word=f'0x{word:08x}', decoded=row['decoded'], decodeError=row['error'], forbiddenOps=bad, pcodeSHA256=hashlib.sha256(row['pcode'].encode()).hexdigest(), **m)
                report['pcodeChecks'].append(check)
                require(row['decoded'] and not row['error'] and ops and not bad and not m['u64OverflowVarnodes'], f'p-code contract failed: {check}')
                pair.append((ops, unique_layout(ops)))
            programs[word] = pair
        del rows_pair
        parity_widths = set()
        for ci, case in enumerate(cases):
            pair = programs[case['word']]
            if case['b'] not in parity_widths:
                for pred in ('zero', 'all', 'mixed'):
                    pc = dict(case, svl=256, predicate=pred)
                    report['adapterParityAndMutationChecks'] += parity_and_mutation_tests(meta, [x[0] for x in pair], [x[1] for x in pair], pc)
                parity_widths.add(case['b'])
            initial, pred = make_initial(meta, case)
            want_raw, rest, expected_trace, active = independent_expected(initial, case, pred)
            vms = [AuditVM(meta, initial.mem.registers, rest, layout) for _, layout in pair]
            result = {'id': variant + '/' + case['id'], 'variant': variant, 'suite': case['suite'], 'elementBytes': case['b'], 'word': f'0x{case["word"]:08x}', 'SVLBytes': case['svl'], 'predicate': case['predicate'], 'selectorProfile': case['selectorName'], 'selectorValue': f'0x{case["selector"]:08x}', 'seed': hex(case['seed']), **fields(case['word'], case['b'])}
            try:
                for vm, (ops, _) in zip(vms, pair):
                    vm.run(ops)
                validate_candidate(vms[1], expected_trace)
                for label, vm in zip(('baseline', 'candidate'), vms):
                    check_state(vm, want_raw, rest, label)
                require(vms[0].mem.registers == vms[1].mem.registers and vms[0].mem.nonunique() == vms[1].mem.nonunique(), 'baseline/candidate differ')
                result.update(verdict='PASS', activeZAStores=active, inactiveIdentityZStores=256 // case['b'] - active,
                              expectedFinalStateSHA256=state_hash(want_raw, rest),
                              baselineFinalStateSHA256=state_hash(vms[0].mem.registers, vms[0].mem.nonunique()),
                              candidateFinalStateSHA256=state_hash(vms[1].mem.registers, vms[1].mem.nonunique()),
                              candidateWriteTraceSHA256=hashlib.sha256(json.dumps(vms[1].trace, separators=(',', ':')).encode()).hexdigest(),
                              initializedUniqueReads=sum(vm.unique_reads for vm in vms),
                              initializedUniqueReadBytes=sum(vm.unique_read_bytes for vm in vms))
                totals.update(cases=1, candidateStores=len(vms[1].trace), activeZAStores=active, inactiveIdentityZStores=256 // case['b'] - active,
                              initializedUniqueReads=result['initializedUniqueReads'], initializedUniqueReadBytes=result['initializedUniqueReadBytes'],
                              baselineExecutedOps=vms[0].executed_ops, candidateExecutedOps=vms[1].executed_ops)
            except Exception as exc:
                result.update(verdict='FAIL', reason=f'{type(exc).__name__}: {exc}')
                print(json.dumps(result), flush=True)
            report['results'].append(result)
            if (ci + 1) % 500 == 0 or ci + 1 == len(cases):
                print(json.dumps({'variant': variant, 'completed': ci + 1, 'total': len(cases), 'elapsedSeconds': round(time.monotonic() - start, 1), 'failures': sum(r['verdict'] == 'FAIL' for r in report['results'])}), flush=True)
        for b in BASES:
            subset = [c for c in cases if c['b'] == b]
            coverage[variant][str(b)] = {'Z': sorted({fields(c['word'], b)['z'] for c in subset}), 'P': sorted({fields(c['word'], b)['p'] for c in subset}), 'W': sorted({fields(c['word'], b)['w'] for c in subset}), 'PW': sorted({(fields(c['word'], b)['p'], fields(c['word'], b)['w']) for c in subset}), 'tileOff': sorted({(fields(c['word'], b)['tile'], fields(c['word'], b)['off']) for c in subset}), 'SVLBytes': sorted({c['svl'] for c in subset}), 'selectorProfiles': sorted({c['selectorName'] for c in subset}), 'singleBitsAt256': sorted({int(c['predicate'][4:]) for c in subset if c['svl'] == 256 and c['predicate'].startswith('bit_')})}
    report['coverage'] = coverage
    report['totals'] = dict(totals)
    report['counts'] = dict(collections.Counter(r['verdict'] for r in report['results']))
    report['byVariant'] = {v: dict(collections.Counter(r['verdict'] for r in report['results'] if r['variant'] == v)) for v in variants}
    report['bySuite'] = dict(collections.Counter(r['suite'] for r in report['results']))
    report['elapsedSeconds'] = round(time.monotonic() - start, 3)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ('counts', 'byVariant', 'bySuite', 'totals', 'storageSelfTestChecks', 'adapterParityAndMutationChecks', 'elapsedSeconds')}, indent=2), flush=True)
    return int(report['counts'].get('FAIL', 0) != 0)


if __name__ == '__main__':
    raise SystemExit(main())
