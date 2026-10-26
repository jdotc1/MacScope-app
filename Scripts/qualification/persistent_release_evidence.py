#!/usr/bin/env python3
"""Preserve an accepted run's proof before incrementally replacing its outputs.

No artifact reads, hashes or verification. Bundle/source renames retain leaf
identities; a new admission explicitly records the immutable prior authority.
DerivedData objects, archives and dependency views stay in their existing paths.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def native_module():
    spec = importlib.util.spec_from_file_location('persistent_native', Path(__file__).with_name('native_release_admission.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def preserve(run, admission, native):
    run, admission = Path(run), Path(admission)
    if (not run.is_absolute() or run.resolve(strict=True) != run
            or not admission.is_absolute() or admission.resolve(strict=True) != admission):
        raise ValueError('persistent evidence paths must be absolute and canonical')
    value = native.read(admission)
    prior = native.bound(value['prior_inputs'])
    paths = {key: Path(prior[key]['path']) for key in ('oldGolden', 'oldProvenance')}
    if (not any(path.is_relative_to(run) for path in paths.values())
            or all(path.is_relative_to(run / 'accepted-evidence') for path in paths.values())):
        return admission
    if value['scope'] != native.STANDARD_SCOPE or Path(value['prior_inputs']['path']).is_relative_to(run):
        raise ValueError('persistent evidence requires an external immutable standard admission origin')
    bundles = {}
    for key, path in paths.items():
        candidates = [parent for parent in path.parents if parent.suffix in ('.app', '.xpc')]
        if len(candidates) != 1 or candidates[0].parent != run / 'DerivedData/Build/Products/Release':
            raise ValueError('persistent evidence must be a direct Release app or worker bundle')
        bundle = candidates[0]
        bundles[key] = bundle
    if len(set(bundles.values())) != 2:
        raise ValueError('persistent app and worker evidence must have distinct bundles')
    for row in value['outputs']:
        if any(Path(row['path']).is_relative_to(bundle) for bundle in bundles.values()):
            raise ValueError('native archive cannot be inside a replacing product bundle')
    root = run / 'accepted-evidence'
    root.mkdir(mode=0o700, exist_ok=True)
    saved = Path(tempfile.mkdtemp(prefix='native-', dir=root))
    products, records, receipts = saved / 'products', saved / 'run-records', saved / 'receipts'
    for directory in (products, records, receipts):
        directory.mkdir(mode=0o700)
    projected = dict(prior)
    projected['retained_origin'] = value['prior_inputs']
    plan = {'origin_admission': native.record(admission), 'origin_prior': value['prior_inputs'],
            'moves': {str(bundle): str(products / bundle.name) for bundle in bundles.values()},
            'method': 'same-run bundle rename; leaf identities retained; no hashes or tests'}
    native.D.publish(saved / 'PRESERVATION_PLAN.json', plan)
    for key, bundle in bundles.items():
        destination = products / bundle.name
        bundle.rename(destination)
        path = destination / paths[key].relative_to(bundle)
        projected[key] = native.record(path)
    # Retain the old source declarations and run receipts, rather than deleting
    # them during rotation. Their recorded original paths remain historical.
    for name in ('source', 'QUALIFICATION_INPUTS.json', 'bootstrap-reuse-key.json',
                 'DEPENDENCY_CACHE_EVENTS.json', 'QUALIFICATION_RECEIPT.json'):
        source = run / name
        if source.is_symlink():
            raise ValueError('persistent run record must not be indirect: ' + name)
        if source.exists():
            source.rename(records / name)
    prior_path = saved / 'PRIOR_INPUTS.json'
    native.D.publish(prior_path, projected)
    result = dict(value, prior_inputs=native.record(prior_path), receipt_directory=str(receipts))
    output = saved / 'NATIVE_ADMISSION.json'
    native.D.publish(output, result)
    native.write_filelists(result, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-root', required=True, type=Path)
    parser.add_argument('--admission', required=True, type=Path)
    parser.add_argument('--lock', required=True, type=Path)
    args = parser.parse_args()
    helper = Path(__file__).with_name('heavy_gate_lock.py')
    fd = os.open(args.lock, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    acquired = False
    try:
        subprocess.run([sys.executable, str(helper), 'acquire', '--fd', str(fd),
            '--lock', str(args.lock), '--timeout', '0', '--pid', str(os.getpid()),
            '--work-root', str(args.run_root.parent.parent), '--integration-ref', 'persistent-run-evidence',
            '--mode', 'retain-accepted-evidence', '--run-root', str(args.run_root)], pass_fds=(fd,), check=True)
        acquired = True
        print(preserve(args.run_root, args.admission, native_module()))
    finally:
        if acquired:
            subprocess.run([sys.executable, str(helper), 'release', '--lock', str(args.lock),
                            '--pid', str(os.getpid())], check=False)
        os.close(fd)


if __name__ == '__main__':
    main()
