#!/usr/bin/env python3
"""Prove display-only changes across every CP1 source constructor.

Top-level semantic patterns and bodies are compared exactly, except for added
exhaustive constant-only decimal display operands. Every subtable constant export
is evaluated for every assignment of its dependency bits, preserving correlated
overlapping token fields. Executable checks cover every specialized instruction
constructor, free CP1 field operand sweeps, fixture words and CP1b samples in all
three language variants. This is exhaustive constructor coverage, not exhaustive
all-word enumeration. Raw emitted p-code must be byte-identical by default; the
explicit --allow-unique-rebase option permits only one uniform translation of
changed unique-space offsets per instruction, pinning exactly unchanged spans.
Pairwise byte overlap and relative subpiece offsets must be invariant. Every
other byte must remain identical; all unique reads must follow initialization.
"""
import argparse, ast, collections, hashlib, json, operator, pathlib, re
from decode_receipt import lift_batch, metrics, VARIANTS

FIELD = re.compile(r'cp1_f(\d+)_(\d+)')
FIXED = re.compile(r'cp1_f(\d+)_(\d+)\s*=\s*(0x[0-9a-f]+|\d+)')
HELPER = re.compile(r'CP1Decimal\d+')


def constructors(path):
    out = []
    for block in path.read_text().split('\n\n'):
        block = re.sub(r'(?m)^#.*\n?', '', block).strip()
        if not block:
            continue
        head, rest = re.split(r'\s+is\s+', block, maxsplit=1)
        if re.search(r'\s+unimpl\s*$', rest):
            pattern = re.sub(r'\s+unimpl\s*$', '', rest)
            body = 'unimpl'
        else:
            pattern, body = rest.split('{', 1)
            body = '{' + body
        out.append((head, pattern.strip(), body))
    return out


def split_pattern(pattern):
    match = re.fullmatch(r'(.*?)(?:\s*\[([^\]]*)\])?\s*', pattern, re.S)
    assert match, ('invalid pattern', pattern)
    return match[1].strip(), match[2] or ''


def fixed_pattern(pattern):
    base = mask = 0
    for lo, width, value in FIXED.findall(pattern):
        lo, width, value = int(lo), int(width), int(value, 0)
        part = ((1 << width) - 1) << lo
        assert not ((base ^ (value << lo)) & mask & part), ('conflicting fields', pattern)
        base = (base & ~part) | (value << lo)
        mask |= part
    return base, mask


def fields_env(text, word):
    return {m[0]: (word >> int(m[1])) & ((1 << int(m[2])) - 1)
            for m in FIELD.finditer(text)}


def words_for_bits(bits):
    positions = [i for i in range(32) if bits >> i & 1]
    for choice in range(1 << len(positions)):
        yield sum(((choice >> i) & 1) << bit for i, bit in enumerate(positions))


def dependency_bits(text):
    bits = 0
    for lo, width in FIELD.findall(text):
        bits |= ((1 << int(width)) - 1) << int(lo)
    return bits


def evaluate(expression, env):
    binary = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
              ast.FloorDiv: operator.floordiv, ast.Div: operator.floordiv,
              ast.LShift: operator.lshift, ast.RShift: operator.rshift,
              ast.BitAnd: operator.and_, ast.BitOr: operator.or_, ast.BitXor: operator.xor}
    def walk(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name):
            return env[node.id]
        if isinstance(node, ast.BinOp) and type(node.op) in binary:
            return binary[type(node.op)](walk(node.left), walk(node.right))
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            return -walk(node.operand)
        raise AssertionError(('unsupported semantic expression', expression))
    return walk(ast.parse(expression.strip(), mode='eval').body)


def helper_tables(helpers):
    grouped = collections.defaultdict(list)
    for head, pattern, body in helpers:
        match = re.fullmatch(r'(CP1Decimal\d+):\s*"(\d+)"', head)
        export = re.fullmatch(r'\{\s*export\s+(\d+):4;\s*\}', body)
        assert match and export, ('decimal helper is not a literal constant export', head, body)
        assert int(match[2]) == int(export[1]), ('decimal display/export mismatch', head)
        base, mask = fixed_pattern(pattern)
        assert re.fullmatch(r'cp1_f\d+_\d+=\d+(?: & cp1_f\d+_\d+=\d+)*|epsilon', pattern)
        grouped[match[1]].append((base, mask, int(export[1])))
    tables = {}
    for name, rows in grouped.items():
        masks = {row[1] for row in rows}
        assert len(masks) == 1, ('helper inconsistent dependency masks', name)
        mask = masks.pop()
        values = {row[0]: row[2] for row in rows}
        assert len(values) == len(rows) == 1 << mask.bit_count(), ('helper not exhaustive/unambiguous', name)
        tables[name] = (mask, values)
    return tables


def export_value(body, actions, env):
    env = dict(env)
    for action in actions.split(';'):
        if not action.strip():
            continue
        match = re.fullmatch(r'\s*(\w+)\s*=\s*(.*?)\s*', action)
        assert match, ('nonlocal context action', action)
        env[match[1]] = evaluate(match[2], env)
    export = re.fullmatch(r'\{\s*export\s+(.*?)\s*;\s*\}', body, re.S)
    assert export, ('subtable has non-export p-code', body)
    expression = export[1]
    pointer = re.fullmatch(r'\*\[const\]:(\d+)\s+(.*)', expression)
    literal = re.fullmatch(r'(.*):(\d+)', expression)
    if pointer:
        size, expression = int(pointer[1]), pointer[2]
    elif literal:
        expression, size = literal[1], int(literal[2])
    else:
        assert HELPER.fullmatch(expression), ('unexpected export', expression)
        size = 4
    return 'const', size, evaluate(expression, env) % (1 << (8 * size))


def source_proof(before, after):
    helpers = [row for row in after if row[0].startswith('CP1Decimal')]
    after = [row for row in after if not row[0].startswith('CP1Decimal')]
    tables = helper_tables(helpers)
    assert len(before) == len(after), 'constructor count changed'
    proof, words, coverage = [], set(), []
    for ordinal, ((h0, p0, b0), (h1, p1, b1)) in enumerate(zip(before, after)):
        pattern0, actions0 = split_pattern(p0)
        pattern1, actions1 = split_pattern(p1)
        dependencies = set(HELPER.findall(pattern1))
        assert dependencies <= tables.keys()
        cleaned = re.sub(r'\s*&\s*CP1Decimal\d+', '', pattern1).strip()
        assert pattern0 == cleaned, (ordinal, 'semantic pattern changed', pattern0, cleaned)
        item = {'ordinal': ordinal, 'beforeDisplay': h0, 'afterDisplay': h1}
        if h0.startswith(':'):
            assert h1.startswith(':') and actions0 == actions1 and b0 == b1, (ordinal, 'instruction semantics changed')
            item['proof'] = 'identical instruction body and semantic pattern; added operands export constants only'
            base, mask = fixed_pattern(pattern0)
            cases = {base, base | (~mask & 0xffffffff)}
            for lo, width in set(FIELD.findall(pattern0)):
                lo, width = int(lo), int(width)
                if width > 5:
                    continue
                part = ((1 << width) - 1) << lo
                for value in range(1 << width):
                    word = (base & ~part) | (value << lo)
                    if word & mask == base:
                        cases.add(word)
            words.update(cases)
            coverage.append({'ordinal': ordinal, 'display': h0, 'mask': f'{mask:08x}',
                             'base': f'{base:08x}', 'wordCount': len(cases), 'implemented': b0 != 'unimpl'})
        else:
            assert h0.split(':', 1)[0] == h1.split(':', 1)[0], (ordinal, 'subtable identity changed')
            # Enumerate only dependencies of actions/exports, not unrelated fields
            # which a display subtable may list in its matching pattern.
            expression_text = actions0 + b0 + actions1 + b1
            bits = dependency_bits(expression_text)
            for name in set(HELPER.findall(expression_text)):
                bits |= tables[name][0]
            base, mask = fixed_pattern(pattern0)
            compared = 0
            for selected in words_for_bits(bits & ~mask):
                word = base | selected
                env = fields_env(expression_text, word)
                env.update({name: values[word & depmask] for name, (depmask, values) in tables.items()})
                old = export_value(b0, actions0, env)
                new = export_value(b1, actions1, env)
                assert old == new, (ordinal, hex(word), 'constant export changed', old, new)
                compared += 1
            item.update(proof='exhaustive constant-export equivalence', dependencyBitCount=(bits & ~mask).bit_count(), dependencyAssignments=compared)
        item['semanticSHA256'] = hashlib.sha256((p0 + '\n' + b0).encode()).hexdigest()
        proof.append(item)
    return proof, words, coverage, helpers, tables


UNIQUE = re.compile(r'\(unique,(0x[0-9a-f]+),(\d+)\)')


def intervals_disjoint(left, right):
    left, right = sorted(left), sorted(right)
    i = j = 0
    while i < len(left) and j < len(right):
        a, n = left[i]
        b, m = right[j]
        assert a + n <= b or b + m <= a, 'fixed/translated unique pools overlap or alias differently'
        if a + n <= b + m:
            i += 1
        else:
            j += 1


def check_unique_initialized(pcode):
    """Track initialized unique bytes, including subpieces, before each read."""
    pages = {}
    def portions(offset, size):
        while size:
            count = min(size, 256 - offset % 256)
            yield offset // 256, ((1 << count) - 1) << (offset % 256)
            offset += count
            size -= count
    for line in pcode.splitlines():
        output, separator, inputs = line.partition(' = ')
        if not separator:
            inputs = output
            output = ''
        for value in UNIQUE.finditer(inputs):
            for page, mask in portions(int(value[1], 16), int(value[2])):
                assert pages.get(page, 0) & mask == mask, ('unique bytes read before written', line, value[0])
        match = UNIQUE.fullmatch(output)
        if match:
            for page, mask in portions(int(match[1], 16), int(match[2])):
                pages[page] = pages.get(page, 0) | mask


def compare_pcode(old, new, allow_unique_rebase=False):
    """Pin identical spans and allow one affine translation of remaining spans.

    Fixed and translated pools must be disjoint before and after translation.
    Within each pool a single translation preserves every pairwise byte overlap
    and relative subpiece offset; cross-pool disjointness proves the rest.
    """
    raw_identical = old == new
    old_unique, new_unique = list(UNIQUE.finditer(old)), list(UNIQUE.finditer(new))
    assert len(old_unique) == len(new_unique), 'unique varnode occurrence count changed'
    assert raw_identical or allow_unique_rebase, 'raw p-code changed'
    forward, reverse, deltas = {}, {}, set()
    fixed, moved = set(), set()
    for x, y in zip(old_unique, new_unique):
        assert x[2] == y[2], 'unique varnode width changed'
        before, after, size = int(x[1], 16), int(y[1], 16), int(x[2])
        assert forward.setdefault((before, size), (after, size)) == (after, size), 'inconsistent unique occurrence map'
        assert reverse.setdefault((after, size), (before, size)) == (before, size), 'unique occurrence map is not bijective'
        if after == before:
            fixed.add((before, size))
        else:
            deltas.add(after - before)
            moved.add((before, size))
    assert len(deltas) <= 1, 'nonuniform changed unique offset translation/alias change'
    delta = next(iter(deltas), 0)
    intervals_disjoint(fixed, moved)
    intervals_disjoint(fixed, {(offset + delta, size) for offset, size in moved})
    rebased = UNIQUE.sub(lambda m: '(unique,0x%x,%s)' % (reverse[(int(m[1], 16), int(m[2]))][0], m[2]), new)
    assert old == rebased, 'opcode, varnode order, space, width, constant, register, RAM or other p-code text changed'
    check_unique_initialized(old)
    check_unique_initialized(new)
    # Canonicalization is paired with the proven correspondence, rather than
    # silently discarding unique addresses independently in the two programs.
    return raw_identical, delta, hashlib.sha256(rebased.encode()).hexdigest(), fixed


def comparator_selftest():
    old = ('(unique,0x100,8) = COPY (const,0x7,8)\n'
           '(unique,0x108,4) = INT_XOR (unique,0x104,4), (register,0x20,4)\n')
    translated = UNIQUE.sub(lambda m: f'(unique,0x{int(m[1], 16) + 0x300:x},{m[2]})', old)
    assert compare_pcode(old, old)[:2] == (True, 0)
    assert compare_pcode(old, translated, True)[:2] == (False, 0x300)
    mutations = {
        'constant': translated.replace('(const,0x7,8)', '(const,0x8,8)'),
        'register': translated.replace('(register,0x20,4)', '(register,0x21,4)'),
        'opcode': translated.replace('INT_XOR', 'INT_OR'),
        'uniqueOverlap': translated.replace('(unique,0x404,4)', '(unique,0x405,4)'),
        'uniqueWidth': translated.replace('(unique,0x404,4)', '(unique,0x404,8)'),
        'addressSpace': translated.replace('(register,0x20,4)', '(ram,0x20,4)'),
        'readBeforeWrite': old.replace('COPY (const,0x7,8)', 'COPY (unique,0x500,8)'),
    }
    for name, mutated in mutations.items():
        try:
            compare_pcode(old, mutated, True)
        except AssertionError:
            continue
        raise AssertionError(('comparator accepted invalid mutation', name))
    fixed_prefix = '(unique,0x700,8) = COPY (const,0x0,8)\n'
    compare_pcode(fixed_prefix + old, fixed_prefix + translated, True)
    crossing = fixed_prefix + UNIQUE.sub(lambda m: f'(unique,0x{int(m[1], 16) + 0x600:x},{m[2]})', old)
    try:
        compare_pcode(fixed_prefix + old, crossing, True)
    except AssertionError:
        pass
    else:
        raise AssertionError('comparator accepted cross-pool alias mutation')
    uninitialized = '(unique,0x100,8) = COPY (unique,0x500,8)\n'
    try:
        compare_pcode(uninitialized, uninitialized, True)
    except AssertionError:
        pass
    else:
        raise AssertionError('comparator accepted identical programs reading unwritten unique bytes')
    return {'exactIdentityAccepted': True, 'uniformUniqueRebaseAccepted': True,
            'rejectedMutations': list(mutations) + ['crossPoolAlias'], 'uniqueReadBeforeWriteChecked': True}


def decimal_assembly(text):
    """Convert only known register-format defects, preserving operand values."""
    return re.sub(r'\b(za|pn|z|p|w|x)0x([0-9a-f]+)',
                  lambda match: match[1] + str(int(match[2], 16)),
                  text.replace('cp1tmp_w', 'w'))


def error_class(row):
    # SLEIGH's decode-only diagnostic embeds assembly text, which is expected
    # to change in a display-only patch. Never normalize any other diagnostic.
    expression = (r'(Instruction not implemented in pcode:\n\s*0x[0-9a-f]+:\s*)'
                  + re.escape(row['mnemonic']) + r'\s+' + re.escape(row['body']))
    match = re.fullmatch(expression, row['error'])
    return match[1] + '<verified disassembly>' if match else row['error']


def main():
    parser = argparse.ArgumentParser()
    for name in ('before', 'after', 'fixture', 'samples', 'lifter', 'report'):
        parser.add_argument('--' + name, type=pathlib.Path, required=True)
    parser.add_argument('--batch-size', type=int, default=48)
    parser.add_argument('--allow-unique-rebase', action='store_true')
    args = parser.parse_args()
    assert args.batch_size > 0
    selftest = comparator_selftest()
    unchanged_source = {}
    for filename in ('AARCH64instructions.sinc', 'AARCH64sme_core.sinc'):
        original, revised = (args.before / filename).read_bytes(), (args.after / filename).read_bytes()
        assert original == revised, ('unchanged source pool changed', filename)
        unchanged_source[filename] = hashlib.sha256(original).hexdigest()
    before = constructors(args.before / 'AARCH64sme_cp1.sinc')
    after = constructors(args.after / 'AARCH64sme_cp1.sinc')
    proof, words, coverage, helpers, tables = source_proof(before, after)
    fixture = json.loads(args.fixture.read_text())
    words.update(int(row['encoding'], 16) for key in ('vectors', 'reserved_vectors') for row in fixture[key])
    words.update(int(row['base'], 16) for row in fixture['decode_only'])
    words.update(int(row['word'], 16) for row in json.loads(args.samples.read_text())['fixtures'])
    words = sorted(words)
    print(f'Static proof passed: {len(before)} original constructors, {len(coverage)} instruction constructors, {len(tables)} exhaustive decimal tables; {len(words)} words per variant.', flush=True)
    cp1_patterns = [(int(row['base'], 16), int(row['mask'], 16)) for row in coverage]
    rows = []
    raw_difference_example = None
    xzr_difference_example = None
    fixed_inventory = collections.defaultdict(set)
    for variant, filename in VARIANTS.items():
        for start in range(0, len(words), args.batch_size):
            batch = words[start:start + args.batch_size]
            old = lift_batch(args.lifter, args.before / filename, batch, args.before / 'AARCH64.pspec')
            new = lift_batch(args.lifter, args.after / filename, batch, args.after / 'AARCH64.pspec')
            for word, x, y in zip(batch, old, new):
                assert x['decoded'] == y['decoded'] and error_class(x) == error_class(y), (variant, hex(word), 'decode changed', x['error'], y['error'])
                try:
                    raw_identical, unique_delta, canonical_hash, fixed_spans = compare_pcode(x['pcode'], y['pcode'], args.allow_unique_rebase)
                except AssertionError as error:
                    raise AssertionError((variant, hex(word), str(error))) from error
                fixed_inventory[variant].update(fixed_spans)
                if word == 0x04bf583f:
                    xzr_difference_example = {'variant': variant, 'word': f'{word:08x}', 'beforePcode': x['pcode'], 'afterPcode': y['pcode'], 'uniqueOffsetDelta': unique_delta}
                if not raw_identical and raw_difference_example is None:
                    raw_difference_example = {'variant': variant, 'word': f'{word:08x}',
                        'reason': 'Display subtable exports change compiler allocation of temporary slots; changed unique addresses in this instruction move by one identical offset, while exact unchanged spans stay pinned. Pairwise aliasing and every other raw p-code byte remain identical.',
                        'uniqueOffsetDelta': unique_delta, 'beforePcode': x['pcode'], 'afterPcode': y['pcode']}
                stats = metrics(y)
                cp1_source = any(word & mask == base for base, mask in cp1_patterns)
                if cp1_source and y['decoded'] and not y['error']:
                    assert not stats['intraInstructionBranchCount'], (variant, hex(word), 'branch')
                if cp1_source:
                    expected = decimal_assembly(x['mnemonic'] + ' ' + x['body'])
                    actual = y['mnemonic'] + ' ' + y['body']
                    assert expected == actual, (variant, hex(word), 'operand value or unexpected display change', expected, actual)
                    assert not re.search(r'\b(?:z|p|pn|w|x|za)0x[0-9a-f]+', y['body']), (variant, hex(word), 'hex register', y['body'])
                    assert 'cp1tmp_w' not in y['body'], (variant, hex(word), 'unnamed W selector', y['body'])
                rows.append({'variant': variant, 'word': f'{word:08x}', 'matchesCp1SourcePattern': cp1_source, 'decoded': y['decoded'], 'error': y['error'],
                             'beforeError': x['error'], 'afterError': y['error'], 'errorClass': error_class(y),
                             'before': x['mnemonic'] + ' ' + x['body'], 'after': y['mnemonic'] + ' ' + y['body'],
                             'rawByteIdentical': raw_identical, 'uniqueOffsetDelta': unique_delta, 'fixedUniqueSpanCount': len(fixed_spans),
                             'beforeRawPcodeSHA256': hashlib.sha256(x['pcode'].encode()).hexdigest(),
                             'afterRawPcodeSHA256': hashlib.sha256(y['pcode'].encode()).hexdigest(),
                             'canonicalPcodeSHA256': canonical_hash, **stats})
            if (start // args.batch_size) % 20 == 19:
                print(f'{variant}: {min(start + args.batch_size, len(words))}/{len(words)} comparisons passed.', flush=True)
        print(f'{variant}: {len(words)} exact/translation-only p-code comparisons passed.', flush=True)
    report = {'scope': __doc__, 'originalSourceConstructors': len(before),
              'specializedInstructionConstructors': len(coverage), 'displayOnlyConstructors': len(helpers),
              'exhaustiveDecimalTables': len(tables), 'subtableDependencyAssignments': sum(item.get('dependencyAssignments', 0) for item in proof),
              'wordsPerVariant': len(words), 'compiledComparisons': len(rows),
              'byteIdenticalPcode': all(row['rawByteIdentical'] for row in rows),
              'rawByteIdenticalComparisons': sum(row['rawByteIdentical'] for row in rows),
              'uniformUniqueRebaseComparisons': sum(not row['rawByteIdentical'] for row in rows),
              'structurallyIdenticalPcode': True, 'comparisonAllowsUniformUniqueRebase': args.allow_unique_rebase,
              'comparatorSelftest': selftest, 'rawDifferenceExample': raw_difference_example,
              'xzrDifferenceExample': xzr_difference_example, 'unchangedSourceSHA256': unchanged_source,
              'fixedUniquePoolEvidence': {'source': 'AARCH64instructions.sinc includes identical AARCH64sme_core.sinc at line 4163, before CP1 at line 4168. Rd_GPR64 XZR exports an initialized 8-byte temporary at line 2060; Rn_GPR64 XZR does so at line 2074. Exact fixed spans and read-before-write checks are recorded; fixed spans cannot overlap the translated pool.',
                  'spansByVariant': {variant: [{'offset': offset, 'size': size, 'classification': 'upstream XZR' if offset in (0x700, 0xb00) and size == 8 else 'unchanged core/upstream temporary pool'} for offset, size in sorted(spans)] for variant, spans in fixed_inventory.items()}},
              'zeroInternalBranchesForImplementedCp1': True, 'decimalCp1RegisterDisplays': True,
              'registerNumbersPreservedAcrossDecimalDisplay': True,
              'cp1Comparisons': sum(row['matchesCp1SourcePattern'] for row in rows),
              'nonCp1ControlComparisons': sum(not row['matchesCp1SourcePattern'] for row in rows),
              'sourceConstructorProof': proof, 'constructorCoverage': coverage, 'rows': rows}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key not in ('sourceConstructorProof', 'constructorCoverage', 'rows', 'fixedUniquePoolEvidence', 'rawDifferenceExample', 'xzrDifferenceExample')}, indent=2))


if __name__ == '__main__':
    main()
