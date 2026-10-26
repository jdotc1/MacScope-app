#!/usr/bin/env python3
"""Stage complete shipped sources, with transparent SDK-only overlays and provenance."""
import argparse
import hashlib
import json
from pathlib import Path

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, default=here.parents[1])
parser.add_argument('--receipt', type=Path, required=True)
args = parser.parse_args()
repo = args.repo.resolve()
target = here / 'Sources/RenderAll'
if args.receipt.exists():
    raise FileExistsError('Refuse to overwrite provenance: ' + str(args.receipt))
for entry in json.loads((here / 'resources.json').read_text()):
    if not (repo / entry['source']).is_file():
        raise FileNotFoundError('Required tree resource before compilation: ' + str(repo / entry['source']))
records = []
seen = set()
for path in (here / 'sources.txt').read_text().splitlines():
    if not path or path.startswith('#'):
        continue
    source = repo / path
    destination = target / source.name
    if source.name in seen:
        raise ValueError('Duplicate source basename: ' + source.name)
    seen.add(source.name)
    if not source.is_file() or source.is_symlink():
        raise FileNotFoundError('Expected regular tree source: ' + str(source))
    original_bytes = source.read_bytes()
    original = original_bytes.decode('utf-8')
    text = original
    overlays = []
    needs_platform_import = 'import Darwin' in original or source.name == 'AnalysisEngine.swift'
    if needs_platform_import:
        text = text.replace('import Darwin', '#if os(Linux)\nimport PortableDarwin\n#else\nimport Darwin\n#endif')
        if source.name == 'AnalysisEngine.swift':
            text = '#if os(Linux)\nimport PortableDarwin\n#endif\n' + text
        for call in ('open', 'close', 'fstat', 'read'):
            text = text.replace('Darwin.' + call + '(', 'PortableDarwin.' + call + '(')
        overlays.append('Linux SDK import/qualified-call compatibility')
    if source.name == 'ELFArchiveBinaryLoader.swift':
        anchor = '        size = metadata.st_size'
        if text.count(anchor) != 1:
            raise ValueError('off_t overlay anchor changed: ' + path)
        text = text.replace(anchor, '#if os(Linux)\n        size = Int64(metadata.st_size)\n#else\n' + anchor + '\n#endif')
        overlays.append('Value-preserving Linux off_t to Int64 conversion')
    staged = text.encode('utf-8') if overlays else original_bytes
    # Replace only generated symlink entries left by the original harness. Never
    # edit their targets. Unchanged ordinary files keep their existing timestamps.
    retired_reference = str(destination.readlink()) if destination.is_symlink() else None
    if destination.is_symlink():
        destination.unlink()
    if not destination.exists() or destination.read_bytes() != staged:
        destination.write_bytes(staged)
    records.append({'source': path, 'source_sha256': hashlib.sha256(original_bytes).hexdigest(),
                    'staged': str(destination.relative_to(here)),
                    'staged_sha256': hashlib.sha256(staged).hexdigest(), 'overlays': overlays,
                    'retired_generated_symlink_target': retired_reference})
args.receipt.parent.mkdir(parents=True, exist_ok=True)
with args.receipt.open('x') as stream:
    json.dump({'repo': str(repo), 'sources': records}, stream, indent=2)
    stream.write('\n')
print('Source staging receipt:', args.receipt)
