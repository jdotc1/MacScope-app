#!/usr/bin/env python3
"""One signing admission, then content-keyed source reuse and copy equality.

The ordinary installer owns this receipt. Reuse keys on the bundle's path set,
entry kinds and sizes plus the policy/toolchain files' content, never on
device, inode, timestamps, link counts or modes, so a reboot or moved run root
does not invalidate it (D1). A changed source or verifier is an error, never
permission to silently re-run signing verification. The copied installed tree
is hashed once; unchanged source leaves are not reopened.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import stat
import subprocess
import sys


class AdmissionError(ValueError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


SCHEMA = 2


def identity(path):
    s = path.lstat()
    if stat.S_ISLNK(s.st_mode) or not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)):
        raise AdmissionError(f'unsafe entry: {path}')
    if stat.S_ISDIR(s.st_mode):
        return ['directory', 0]
    return ['file', s.st_size]


def tree_identity(root):
    if not root.is_absolute() or root.resolve(strict=True) != root or not root.is_dir():
        raise AdmissionError('bundle must be a canonical absolute directory')
    rows = {}
    def visit(path):
        row = identity(path)
        rows[str(path.relative_to(root))] = row
        if row[0] == 'directory':
            for child in sorted(path.iterdir()):
                visit(child)
    visit(root)
    return rows


def digest_tree(root, before):
    rows = []
    for name, item in sorted(before.items()):
        path = root / name
        mode = path.lstat().st_mode
        if item[0] == 'file':
            digest = hashlib.sha256()
            with path.open('rb') as source:
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
            content = digest.hexdigest()
        else:
            content = None
        # Include the complete path set, entry type, permissions and bytes.
        rows.append([name, mode, content])
    if tree_identity(root) != before:
        raise AdmissionError('bundle changed while recording its digest')
    return hashlib.sha256(canonical(rows)).hexdigest()


def authority_identity(paths):
    """Policy scripts and plists by content; large tools and directories by kind/size."""
    result = {}
    for path in sorted(set(paths)):
        row = identity(path)
        if row[0] == 'file' and row[1] <= 1024 * 1024:
            row = ['sha256', hashlib.sha256(path.read_bytes()).hexdigest()]
        result[str(path)] = row
    return result


def load_receipt(path):
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid():
        raise AdmissionError('receipt must be an owned regular file')
    data = path.read_bytes()
    value = json.loads(data)
    if canonical(value) != data:
        raise AdmissionError('receipt is noncanonical')
    if value.get('schema') != SCHEMA:
        raise AdmissionError('receipt predates content-keyed schema 2; pass a new --signing-receipt path')
    if (set(value) != {'schema', 'source', 'identity', 'authority', 'digest'}
            or not re.fullmatch('[0-9a-f]{64}', str(value['digest']))):
        raise AdmissionError('unsupported signing receipt')
    return value


def consume(source, receipt, authorities):
    value = load_receipt(receipt)
    if value['source'] != str(source) or value['authority'] != authority_identity(authorities):
        raise AdmissionError('source path or policy/toolchain identity changed; no re-verification allowed')
    if value['identity'] != tree_identity(source):
        raise AdmissionError('source identity changed; no re-verification allowed')
    return value


def admit(source, receipt, authorities, verifier):
    if (not receipt.is_absolute() or receipt.parent.resolve(strict=True) != receipt.parent
            or receipt == source or source in receipt.parents):
        raise AdmissionError('receipt must be canonical and outside source bundle')
    if receipt.exists() or receipt.is_symlink():
        consume(source, receipt, authorities)
        return 'reused'
    before = tree_identity(source)
    authority = authority_identity(authorities)
    # Hash before and after verification: the bytes the verifier accepted must
    # be the bytes the receipt records, not merely files of the same size.
    digest = digest_tree(source, before)
    errors = verifier(source)
    if errors:
        raise AdmissionError('; '.join(errors))
    if tree_identity(source) != before or authority_identity(authorities) != authority:
        raise AdmissionError('source or policy/toolchain changed during signing admission')
    if digest_tree(source, before) != digest:
        raise AdmissionError('source bytes changed during signing admission')
    value = {'schema': SCHEMA, 'source': str(source), 'identity': before,
             'authority': authority, 'digest': digest}
    if authority_identity(authorities) != authority:
        raise AdmissionError('policy/toolchain changed during digest admission')
    # Publish only a successful immutable admission; never overwrite evidence.
    fd = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(canonical(value))
        output.flush()
        os.fsync(output.fileno())
    return 'admitted'


def compare_copy(source, destination, receipt, authorities):
    value = consume(source, receipt, authorities)
    if os.path.samefile(source, destination):
        raise AdmissionError('installed copy must be physically distinct')
    if digest_tree(destination, tree_identity(destination)) != value['digest']:
        raise AdmissionError('installed closed tree differs from admitted source')


def production_authority():
    root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(root))
    from Scripts import check_local_signing_policy as policy
    selected = os.environ.get('DEVELOPER_DIR')
    if not selected:
        selected = subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip()
    developer = Path(selected).resolve(strict=True)
    env = dict(os.environ, DEVELOPER_DIR=str(developer))
    vtool = Path(subprocess.check_output(['/usr/bin/xcrun', '--find', 'vtool'], env=env, text=True).strip()).resolve(strict=True)
    paths = [Path(__file__).resolve(), Path(sys.executable).resolve(), developer,
             developer.parent / 'Info.plist', vtool]
    for tool in ('codesign', 'lipo', 'xcrun'):
        paths.append(Path('/usr/bin') / tool)
    paths.extend(Path(m.__file__).resolve() for n, m in list(sys.modules.items())
                 if n.startswith('Scripts.') and getattr(m, '__file__', None))
    return paths, lambda app: policy.validate_app_bundle(app, 'Release')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('admit', 'compare'))
    p.add_argument('--source', required=True, type=Path)
    p.add_argument('--receipt', required=True, type=Path)
    p.add_argument('--destination', type=Path)
    args = p.parse_args()
    if args.source.name != 'MacScope.app' or not args.receipt.is_absolute():
        raise AdmissionError('canonical MacScope.app and absolute receipt required')
    paths, verifier = production_authority()
    if args.action == 'admit':
        print('PASS: source signing receipt ' + admit(args.source, args.receipt, paths, verifier))
    else:
        if args.destination is None or args.destination.name != 'MacScope.app':
            raise AdmissionError('installed MacScope.app destination required')
        compare_copy(args.source, args.destination, args.receipt, paths)
        print('PASS: source and installed MacScope.app bundles match under the repository checker')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('ERROR: install signing receipt refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
