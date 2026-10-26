#!/usr/bin/env python3
"""Reuse an accepted native Release component by identity, not file metadata.

D1 (2026-10-12): the component is keyed by the git blob identities of its
native source closure, its recorded content digests and the toolchain. Receipt
rows keep their historical {path, fields} shape, but fields are informational:
no device, inode, ctime/mtime, link-count or mode comparison is made, so a
reboot, a moved receipt or a half-finished copy never blocks reuse. Missing
outputs are reported plainly; incomplete copy destinations are regenerated.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess

ENV = 'MACSCOPE_NATIVE_RELEASE_ADMISSION'
STANDARD_SCOPE = 'native-Release-standard-component-adoption'
OUTPUTS = ('libmacscope_native_decompiler_contract.a',
           'generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp')
LIVE = 'MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING'


def _debug():
    path = Path(__file__).resolve().parents[1] / 'native-decompiler-xpc/debug_native_receipt.py'
    spec = importlib.util.spec_from_file_location('native_release_retained_io', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


D = _debug()


def fields(path):
    """Informational lstat row for newly written receipts; never compared."""
    return D.fields(Path(path))


def directory_fields(path):
    path = Path(path)
    value = path.lstat()
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid():
        raise ValueError('native directory must be an owner directory: ' + str(path))
    return [value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns]


def read(path, immutable=False):
    """Read receipt JSON; `immutable` is accepted for callers and ignored."""
    def closed(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('duplicate receipt field')
            value[key] = item
        return value
    value = json.loads(Path(path).read_bytes(), object_pairs_hook=closed)
    if not isinstance(value, dict):
        raise ValueError('receipt is not a JSON object: ' + str(path))
    return value


def bound(row, immutable=False):
    return read(row['path'])


def record(path):
    return {'path': str(path), 'fields': fields(path)}


def source_manifest(path):
    path = Path(path)
    if path.name != 'SOURCE_FILES.json':
        raise ValueError('invalid source manifest')
    before=fields(path)
    if path.stat().st_size>128*1024*1024:raise ValueError('source manifest exceeds bounded size')
    value = read(path)
    if fields(path)!=before:raise ValueError('source manifest changed while read')
    rows = value.get('files')
    if not isinstance(rows, list):
        raise ValueError('source manifest omits file declarations')
    paths = [row['path'] for row in rows]
    if len(paths) != len(set(paths)):
        raise ValueError('duplicate source manifest path')
    return value


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def source_paths(root):
    # Membership follows the existing declared Swift/wire/native computation
    # closure. The app provenance writer is a consumer, not a compiler input.
    return sorted((D.production_paths(root) | set(D.CONSUMERS))
                  - {'Scripts/generate_release_build_provenance.py'})


def accepted_source_updates(current, accepted, *, standard):
    """Keep compiled inputs exact while recording changed cache consumers.

    dev_dependency_cache materializes independently admitted dependency views;
    it changes no native translation unit, so it alone may differ.
    """
    if set(current) != set(accepted):
        raise ValueError('current native source/profile membership differs from accepted Release inputs')
    updates = {}
    consumer = 'Scripts/qualification/dev_dependency_cache.py'
    for path, row in current.items():
        old = accepted[path]
        if row == old:
            continue
        if (not standard or path != consumer or row.get('mode') != old.get('mode')
                or row.get('mode') not in ('100644', '100755')
                or re.fullmatch('[0-9a-f]{40}', row.get('blob_oid', '')) is None):
            raise ValueError('current native source/profile differs from accepted Release inputs: ' + path)
        updates[path] = {'accepted': old, 'current': row}
    return updates


def git_records(root, revision, paths):
    result = {}
    for line in git(root, 'ls-tree', '-r', revision, '--', *paths).splitlines():
        metadata, path = line.split('\t', 1)
        mode, kind, oid = metadata.split()
        if kind != 'blob' or mode not in ('100644', '100755'):
            raise ValueError('native source must be an ordinary Git blob: ' + path)
        result[path] = {'blob_oid': oid, 'mode': mode}
    if set(result) != set(paths):
        raise ValueError('native source membership is incomplete')
    return result


def _settings(archive):
    tools = archive['toolchain']
    if (archive.get('scope') != 'accepted-standard-native-Release-component'
            or tools.get('ARCHS') != 'arm64' or tools.get('MACOSX_DEPLOYMENT_TARGET') != '27.0'
            or not Path(archive['native_build_root']).is_absolute()):
        raise ValueError('accepted standard native target differs')


def project_paths(value):
    build = Path(value['native_build_root'])
    lists = Path(value['receipt_directory'])
    for path in (build, lists):
        if not path.is_absolute() or '\n' in str(path):
            raise ValueError('native project paths must be absolute single-line paths')
        directory_fields(path)
    return str(build), str(lists)


def write_filelists(value, admission_path):
    root = Path(value['receipt_directory'])
    archive_root = Path(value['native_build_root'])
    archive_inputs = [str(admission_path), value['archive_receipt']['path']]
    # Keep the original producer's output ownership in the current graph.
    # Otherwise Xcode prunes these admitted artifacts as stale before the
    # bridge phase can consume them. They are never recreated here.
    cache_scope = value.get('scope') == 'accepted-cache-native-Release-computation'
    configuration = 'CONFIGURATION.json' if cache_scope else 'CMakeCache.txt'
    retained_outputs = [str(archive_root / p) for p in (*OUTPUTS,
        configuration, 'macscope-native-decompiler-link-inputs.xcfilelist')]
    marker = '$(TARGET_TEMP_DIR)/NativeReleaseAdmission/bridge.json'
    resource = '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)'
    lists = {
        'bridge-inputs': archive_inputs,
        'bridge-outputs': [marker, *retained_outputs],
        'package-inputs': [str(admission_path), value['prior_inputs']['path']],
        'package-outputs': [resource + '/NativeDecompilerPackage/MATERIALIZATION.json',
                            resource + '/NativeDecompilerPackage/package/lib/libdecomp.a',
                            resource + '/NativeDecompilerPackage/package/lib/libsla.a'],
        'golden-inputs': [str(admission_path), marker],
        'golden-outputs': [resource + '/NativeDecompilerBridgeGolden.json'],
    }
    for name, lines in lists.items():
        path = root / (name + '.xcfilelist')
        with path.open('x') as stream:
            stream.write('\n'.join(lines) + '\n')
        path.chmod(0o400)


def admit(repository, environment=None, source_records=None):
    env = os.environ if environment is None else environment
    if env.get('CONFIGURATION') != 'Release' or any(LIVE in env.get(key, '') for key in (
            'MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'OTHER_SWIFT_FLAGS')):
        raise ValueError('native Release admission requires ordinary Release compilation')
    if env.get('SWIFT_OPTIMIZATION_LEVEL') != '-O':
        raise ValueError('native Release worker/app must use the declared -O optimization')
    if env.get('MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION', ''):
        raise ValueError('native Release live test condition must be empty')
    location = Path(env[ENV])
    value = read(location)
    if value.get('schema_version') == 1 and value.get('scope') == 'accepted-cache-native-Release-computation':
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import cache_native_release_adoption as cache_adoption
        return cache_adoption.admit(repository, env, value, location, source_records)
    if value.get('schema_version') != 1 or value.get('scope') != STANDARD_SCOPE:
        raise ValueError('unsupported native Release admission')
    archive = bound(value['archive_receipt'])
    prior = bound(value['prior_inputs'])
    # A preserved prior names the original golden path the archive recorded.
    origin = bound(prior['retained_origin']) if 'retained_origin' in prior else prior
    _settings(archive)
    golden = bound(prior['oldGolden'])
    provenance = bound(prior['oldProvenance'])
    if (value['component_source_commit'] != archive['source_commit']
            or value['native_build_root'] != archive['native_build_root']
            or [row['path'] for row in value['outputs']] != [row['path'] for row in archive['outputs']]
            or archive['computation_receipt'] != origin['oldGolden']['path']):
        raise ValueError('standard native adoption component/output authority differs')
    if (golden.get('passed') is not True
            or provenance.get('git_head_commit') != value['component_source_commit']
            or provenance.get('native_decompiler_golden_result') != golden
            or archive['wrapper_profile'] != golden['wrapperGitRevision']
            or archive['golden_profile'] != golden['goldenSourceSHA256']):
        raise ValueError('standard native adoption golden authority differs')
    for key, expected in archive['toolchain'].items():
        if env.get(key) != expected:
            raise ValueError('effective native Release toolchain differs: ' + key)
    repository = Path(repository).resolve(strict=True)
    paths = source_paths(repository)
    if source_records is None and (repository / 'SOURCE_FILES.json').is_file():
        source_records = {r['path']: r for r in source_manifest(repository / 'SOURCE_FILES.json')['files']}
    current = (git_records(repository, 'HEAD', paths) if source_records is None else
               {p: {k: source_records[p][k] for k in ('blob_oid', 'mode')} for p in paths})
    consumer_updates = accepted_source_updates(current, value['native_sources'], standard=True)
    missing = [row['path'] for row in value['outputs'] if not Path(row['path']).is_file()]
    if missing:
        raise ValueError('admitted native component output is missing (rebuild the native component): '
                         + ', '.join(missing))
    staged = bound(prior['stagedReceipt'])
    if not Path(staged['root']).is_dir():
        raise ValueError('admitted native package root is missing: ' + staged['root'])
    return dict(value, consumer_source_updates=consumer_updates, archive=archive, prior=prior,
                golden=golden, provenance=provenance, staged=staged, _admission_path=str(location))


def copy_package(value, destination):
    """Materialize the admitted package view; an incomplete copy is refilled."""
    destination = Path(destination)
    root = Path(value['staged']['root'])
    if destination == root:
        return {'destination': str(destination), 'source': value['prior']['stagedReceipt'],
                'method': 'retained-original-view'}
    if (root.resolve(strict=True) != root or destination.resolve(strict=False) != destination
            or destination.is_relative_to(root) or root.is_relative_to(destination)):
        raise ValueError('native package destination must be canonical and separate from admitted source')

    def copy_owned(source, target):
        if source.is_symlink() or target.is_symlink():
            raise ValueError('native package copy refuses indirect entries')
        if source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            before=target.lstat()
            if not stat.S_ISDIR(before.st_mode) or before.st_uid != os.getuid():
                raise ValueError('native package destination directory is not owned')
            # Retained staging inherits immutable source modes. Open only this
            # owned destination directory while replacing its children, then
            # restore the admitted directory mode even on an interrupted copy.
            target.chmod(stat.S_IMODE(before.st_mode) | 0o700)
            try:
                for child in source.iterdir():
                    copy_owned(child, target / child.name)
                shutil.copystat(source, target)
            finally:
                target.chmod(stat.S_IMODE(source.stat().st_mode))
        elif source.is_file():
            if target.exists() and (not target.is_file() or target.lstat().st_uid != os.getuid()):
                raise ValueError('native package destination leaf has an incompatible type or owner')
            target.unlink(missing_ok=True)
            shutil.copy2(source, target)
        else:
            raise ValueError('native package source has an unsupported entry')
    copy_owned(root, destination)
    return {'destination': str(destination), 'source': value['prior']['stagedReceipt'],
            'method': 'copy of the admitted package view'}


def runtime_evidence(value, golden_path):
    golden_path = Path(golden_path)
    evidence = {key: item for key, item in value['provenance'].items()
                if key.startswith('native_decompiler_') and key != 'native_decompiler_debug_cp4_supplement'}
    service = golden_path.parents[1]
    for role, relative in [('info_plist', 'Info.plist'), ('executable', 'MacOS/NativeDecompilerXPCService'),
                           ('code_resources', '_CodeSignature/CodeResources')]:
        path = service / relative
        evidence['native_decompiler_embedded_service_' + role + '_sha256'] = D.new_service_digest(
            path, fields(path), role)
    return evidence


def phase(value, selected, env):
    if selected == 'bridge':
        if Path(env['MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT']) != Path(value['native_build_root']):
            raise ValueError('native linker root is not the admitted Release archive')
        marker = Path(env['TARGET_TEMP_DIR']) / 'NativeReleaseAdmission/bridge.json'
        marker.parent.mkdir(parents=True, exist_ok=True)
        payload = {'admission': value['_admission_path'], 'archive': value['archive_receipt']['path']}
        if not marker.exists() or read(marker) != payload:
            marker.unlink(missing_ok=True)
            D.publish(marker, payload)
        return
    resources = Path(env['TARGET_BUILD_DIR']) / env['UNLOCALIZED_RESOURCES_FOLDER_PATH']
    if selected == 'package':
        copy_package(value, resources / 'NativeDecompilerPackage')
    elif selected == 'golden':
        target = resources / 'NativeDecompilerBridgeGolden.json'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.unlink(missing_ok=True)
        shutil.copyfile(value['prior']['oldGolden']['path'], target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('phase')
    p.add_argument('--repository-root', type=Path, required=True)
    p.add_argument('--phase', choices=('bridge', 'package', 'golden'), required=True)
    args = parser.parse_args()
    phase(admit(args.repository_root), args.phase, os.environ)
    print('Native Release admission consumed; retained digests and computation reused')


if __name__ == '__main__':
    main()
