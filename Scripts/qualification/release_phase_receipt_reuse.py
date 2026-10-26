#!/usr/bin/env python3
"""Consume admitted phase inputs without re-reading or hashing sealed leaves.

Admission JSON schema 1: prior_inputs, current_inputs, phase, source_paths,
read_paths, copies [{source, destination}], optional sign_new_dylib.
All paths are absolute. Source records and dependency contracts must agree.
Native phases consume the declared wrapper/golden source closure; this source
admission alone does not qualify Release settings or retained artifact identity.
Copies are explicitly authorized paths; no executable actions are accepted.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

PHASES = {
    'rea': ('ThirdParty/REA/', 'Scripts/dependencies/rea_'),
    'machokit': ('Scripts/machokit_', 'ThirdParty/MachOKit/'),
    'machokit-compiled': ('Scripts/machokit_', 'ThirdParty/MachOKit/'),
    'ghostty-surface': ('Scripts/dependencies/stage_verified_ghostty_surface.py',),
    'ghostty-vt': ('Scripts/build_ghostty_vt.sh', 'Scripts/ghostty-vt-source.contract',
                   'Scripts/dependencies/stage_verified_ghostty_vt.py'),
    'native-bridge': (),
    'native-package': (),
    'native-golden': (),
}

def read(path):
    return json.loads(Path(path).read_text())

def absolute(value):
    p = Path(os.path.expandvars(value))
    if not p.is_absolute() or '..' in p.parts:
        raise ValueError('admission paths must be absolute and normalized')
    return p

def records(root, phase):
    rows = read(Path(root) / 'SOURCE_FILES.json')['files']
    if not phase.startswith('native-'):
        return {r['path']: r for r in rows
                if any(r['path'].startswith(p) for p in PHASES[phase])}
    # Use the existing declarations, but select from admitted records rather
    # than walking or hashing either retained source tree again. The helper is
    # itself a wrapper input, so a changed declaration also refuses reuse.
    helper = Path(__file__).resolve().parents[1] / 'native-decompiler-xpc/native_decompiler_source_identity.py'
    spec = importlib.util.spec_from_file_location('native_phase_profiles', helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fixed = set(module.WRAPPER_FIXED)
    if phase != 'native-bridge':
        fixed.update(module.GOLDEN_FIXED)
    selected = {}
    for row in rows:
        path = row['path']
        if path in fixed or any(path.startswith(tree + '/') for tree in module.WRAPPER_TREES):
            if path in selected:
                raise ValueError('duplicate native source record: ' + path)
            selected[path] = row
    if not fixed.issubset(selected) or any(
            not any(path.startswith(tree + '/') for path in selected)
            for tree in module.WRAPPER_TREES):
        raise ValueError('native source profile records are incomplete')
    return selected

def _helper(root, relative, name):
    import sys
    spec = importlib.util.spec_from_file_location(name, root / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def current_release_context(phase, environment):
    """Consume the actual new qualification and explicit accepted prior run."""
    if environment.get('CONFIGURATION') != 'Release':
        raise ValueError('current retained phase requires Release')
    current_path = absolute(environment['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT'])
    retained_path = absolute(environment['MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS'])
    current, prior = read(current_path), read(retained_path)
    if any(x.get('schema_version') != 4 or x.get('mode') != 'release' for x in (current, prior)):
        raise ValueError('current/prior phase inputs must be real Release qualification records')
    root = absolute(current['build_source_root'])
    if root != current_path.parent / 'source' or (absolute(environment['SRCROOT']) / '..').resolve() != root:
        raise ValueError('phase source is outside current qualification')
    before, after = records(prior['build_source_root'], phase), records(root, phase)
    if not before or before != after:
        raise ValueError('retained phase source/contract records differ: ' + phase)
    helper = _helper(root, 'Scripts/qualification/qualification_manifest_inheritance.py', 'current_phase_manifest_admission')
    inherited, lease = helper.admit_manifests(retained_path, current, current_path.parent / 'DEPENDENCY_CACHE_EVENTS.json')
    if any(current.get(key) != digest for key, digest in inherited.items()):
        raise ValueError('current phase dependency identity differs')
    return root, current, helper, lease


def _copy(source, target):
    """Copy one admitted leaf; a leftover partial output is simply replaced."""
    target.parent.mkdir(parents=True, exist_ok=True)
    target.unlink(missing_ok=True)
    shutil.copy2(source, target)


def current_release_phase(phase, environment):
    root, current, authority, metadata_lease = current_release_context(phase, environment)
    if phase in ('rea', 'machokit-compiled'):
        # REA bytes are canonical records in the new verified source export.
        # The required compiled marker is proved once by app provenance AFTER
        # target signing and embedding, over the fresh final worker bytes.
        authority.revalidate(metadata_lease)
        print('Required compiled MachOKit proof deferred to signed embedded-output provenance'
              if phase == 'machokit-compiled' else 'Canonical REA source records inherited')
        return
    if phase == 'machokit':
        module = _helper(root, 'Scripts/machokit_source_identity.py', 'current_phase_machokit')
        materialization = absolute(environment['MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT'])
        if (root / 'MacScope/LocalPackages').resolve(strict=True) != materialization.resolve(strict=True):
            raise ValueError('LocalPackages differs from admitted MachOKit root')
        materialization = module._canonical_admission_root(materialization)
        if not module._admission_receipt(materialization).is_file():
            raise ValueError('MachOKit controlled copy has no admission receipt')
        authority.revalidate(metadata_lease)
        return
    if phase not in ('ghostty-surface', 'ghostty-vt'):
        raise ValueError('unsupported current retained Release phase')
    native = _helper(root, 'Scripts/qualification/native_release_admission.py', 'current_phase_copy_io')
    size = lambda path: Path(path).stat().st_size
    events = read(Path(environment['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT']).parent / 'DEPENDENCY_CACHE_EVENTS.json')
    rows = [x for x in events['events'] if x['component'] == phase]
    if len(rows) != 1 or rows[0]['status'] != 'receipt-reused-hit':
        raise ValueError('phase artifact lacks completed cache reuse')
    event = rows[0]
    view = absolute(event['run_view'])
    entry = read(absolute(event['entry']) / 'ENTRY.json')
    if entry['key'] != event['key'] or entry['component'] != phase:
        raise ValueError('phase cache entry identity differs')
    payload = {row['path']: row for row in entry['payload_records'] if row['kind'] == 'file'}
    marker = Path(environment['TARGET_TEMP_DIR']) / ('RetainedPhase-' + phase + '.json')
    if marker.exists():
        previous = read(marker)
        if previous['current_inputs'] != environment['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT']:
            raise ValueError('phase destination receipt belongs to a different qualification')
        if all(Path(row['path']).is_file() for row in previous['outputs']):
            authority.revalidate(metadata_lease)
            return
        marker.unlink()
    copies = []
    if phase == 'ghostty-surface':
        destination = absolute(environment['MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT'])
        allowed = absolute(environment['PROJECT_TEMP_DIR'])
        if destination.parent != allowed:
            raise ValueError('surface admission needs a build-owned staging child')
        descriptor_leaves = []
        for role, setting, relative in (
                ('archive', 'MACSCOPE_GHOSTTY_SURFACE_INPUT_ARCHIVE', 'libghostty-internal.a'),
                ('header', 'MACSCOPE_GHOSTTY_SURFACE_INPUT_HEADER', 'Headers/ghostty.h'),
                ('module_map', 'MACSCOPE_GHOSTTY_SURFACE_INPUT_MODULE_MAP', 'Headers/module.modulemap')):
            source = absolute(environment[setting]); target = destination / relative
            record = payload.get(source.relative_to(view).as_posix())
            if record is None or size(source) != record['size']:
                raise ValueError('surface source is outside admitted entry')
            _copy(source, target)
            copies.append(native.record(target))
            descriptor_leaves.append({'role': role, 'relative_path': relative, 'sha256': record['sha256']})
        descriptor = destination / 'STAGED_GHOSTTY_SURFACE.json'
        descriptor.unlink(missing_ok=True)
        native.D.publish(descriptor, {'schema_version': 1, 'leaves': descriptor_leaves,
                         'source_manifest_sha256': current['ghostty_surface_manifest_sha256']})
        copies.append(native.record(descriptor))
    else:
        build_root = absolute(environment['MACSCOPE_GHOSTTY_VT_BUILD_ROOT'])
        if build_root != absolute(environment['CONFIGURATION_TEMP_DIR']) / 'MacScopeGhosttyVT':
            raise ValueError('VT destination is not build-owned')
        destination = build_root / 'artifacts'
        selected = {p: row for p, row in payload.items() if p.startswith('artifacts/include/') or p == 'artifacts/lib/.macscope-ghostty-vt-manifest'}
        dylib = 'artifacts/lib/libghostty-vt.0.1.0.dylib'
        if dylib not in payload:
            raise ValueError('VT concrete dylib missing from admitted entry')
        selected[dylib] = payload[dylib]
        for relative, row in selected.items():
            source = view / relative
            target = destination / ('lib/libghostty-vt.dylib' if relative == dylib else relative.removeprefix('artifacts/'))
            if size(source) != row['size']:
                raise ValueError('VT source size differs')
            _copy(source, target)
            copies.append(native.record(target))
        bundle_dylib = absolute(environment['TARGET_BUILD_DIR']) / environment['FRAMEWORKS_FOLDER_PATH'] / 'libghostty-vt.dylib'
        source = destination / 'lib/libghostty-vt.dylib'
        _copy(source, bundle_dylib)
        identity = environment.get('EXPANDED_CODE_SIGN_IDENTITY', '')
        if not identity or identity == '-' or environment.get('CODE_SIGNING_ALLOWED') != 'YES':
            raise ValueError('new VT bundle copy requires certificate-backed signing')
        bundle_dylib.chmod(0o700)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--identifier',
                        'org.macscope.app.GhosttyVT', '--options', 'runtime', '--timestamp=none', str(bundle_dylib)], check=True)
        bundle_dylib.chmod(0o555)
        copies.append(native.record(bundle_dylib))
    authority.revalidate(metadata_lease)
    marker.parent.mkdir(parents=True, exist_ok=True)
    native.D.publish(marker, {'current_inputs': environment['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT'],
                             'outputs': copies, 'method': 'controlled copy of receipt-admitted cache bytes'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', required=True, choices=PHASES)
    parser.add_argument('--admission')
    parser.add_argument('--current-release', action='store_true')
    args = parser.parse_args()
    if args.current_release:
        if args.admission:
            raise ValueError('current qualification and historical phase admissions are distinct')
        current_release_phase(args.phase, dict(os.environ))
        return
    if not args.admission:
        parser.error('--admission or --current-release is required')
    admission = read(args.admission)
    if admission.get('schema_version') != 1 or admission.get('phase') != args.phase:
        raise ValueError('wrong phase admission')
    old = read(absolute(admission['prior_inputs']))
    new = read(absolute(admission['current_inputs']))
    if any(old['source_identity']['dependency_contract'].get(k) != new['source_identity']['dependency_contract'].get(k) for k in ('component_manifest_sha256', 'component_pins', 'notices_sha256')):
        raise ValueError('retained dependency contract does not match')
    before = records(old['build_source_root'], args.phase)
    after = records(new['build_source_root'], args.phase)
    if not before or before != after:
        raise ValueError('phase source records differ or are absent')
    for name in admission.get('read_paths', []):
        if not absolute(name).exists():
            raise ValueError('missing admitted retained input: ' + name)
    copies = admission.get('copies', [])
    if args.phase in ('rea', 'machokit', 'native-bridge') and copies:
        raise ValueError('source admission phases cannot copy artifacts')
    for item in copies:
        source, destination = absolute(item['source']), absolute(item['destination'])
        if source == destination or not source.exists():
            raise ValueError('invalid retained artifact copy')
        if source.is_symlink():
            raise ValueError('artifact copy root may not be a symlink')
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, destination, dirs_exist_ok=True, symlinks=True)
        else:
            shutil.copy2(source, destination)
    sign = admission.get('sign_new_dylib')
    if sign:
        if args.phase != 'ghostty-vt' or not any(x['destination'] == sign for x in copies):
            raise ValueError('only newly copied VT dylib may be signed')
        identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY', '')
        if not identity or identity == '-':
            raise ValueError('certificate-backed signing identity required')
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity,
                        '--options', 'runtime', '--timestamp=none', str(absolute(sign))], check=True)
    print(json.dumps({'phase': args.phase, 'status': 'retained-receipt-consumed',
                      'admission': str(absolute(args.admission)), 'copied': len(copies)}))

if __name__ == '__main__':
    main()
