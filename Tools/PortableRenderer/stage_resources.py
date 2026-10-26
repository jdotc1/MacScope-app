#!/usr/bin/env python3
"""Admit exact tree resources beside the executable for unchanged Bundle.main lookup."""
import argparse
import hashlib
import json
from pathlib import Path

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--executable', type=Path, required=True)
parser.add_argument('--receipt', type=Path, required=True)
args = parser.parse_args()
if not args.executable.is_file():
    raise FileNotFoundError(args.executable)
records = []
for entry in json.loads((here / 'resources.json').read_text()):
    source = args.repo.resolve() / entry['source']
    if not source.is_file() or source.is_symlink():
        raise FileNotFoundError('Required exact tree resource: ' + str(source))
    data = source.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != entry['bytes'] or digest != entry['sha256']:
        raise ValueError('Resource does not match declared pinned identity: ' + str(source))
    destination = args.executable.resolve().parent / entry['bundle_name']
    if destination.is_symlink():
        raise ValueError('Refuse resource symlink: ' + str(destination))
    if not destination.exists() or destination.read_bytes() != data:
        destination.write_bytes(data)
    records.append({'source': str(source), 'bundle_candidate': str(destination),
                    'bytes': len(data), 'sha256': digest})
args.receipt.parent.mkdir(parents=True, exist_ok=True)
with args.receipt.open('x') as stream:
    json.dump({'resources': records, 'runtime_lookup': 'Must additionally pass production Bundle.main admission'}, stream, indent=2)
    stream.write('\n')
print('Resource staging receipt:', args.receipt)
