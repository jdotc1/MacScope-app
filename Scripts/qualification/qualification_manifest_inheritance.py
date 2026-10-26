#!/usr/bin/env python3
"""Inherit manifest identities from accepted, unchanged dependency cache views.

The qualifier calls this only after reuse-verified has admitted/cloned each
entry and recorded the current event. No dependency leaves are opened here.
"""
import json
import importlib.util
import os
from pathlib import Path
import re
import stat

SPECS = (
    ('ghostty-vt', 'ghostty_artifact_manifest_sha256', 'ghostty_source_dir',
     'artifacts/lib/.macscope-ghostty-vt-manifest', 'zig-out/lib/.macscope-ghostty-vt-manifest'),
    ('ghostty-surface', 'ghostty_surface_manifest_sha256', 'ghostty_surface_source_dir',
     'macos/.macscope-ghostty-surface-manifest', 'macos/.macscope-ghostty-surface-manifest'),
    ('sleigh-native-source', 'sleigh_materialization_manifest_sha256', 'sleigh_materialization_root',
     'materialization/MATERIALIZATION.json', 'MATERIALIZATION.json'),
)


def size(path):
    path = Path(path)
    observed = path.stat()
    if not stat.S_ISREG(observed.st_mode):
        raise ValueError('manifest inheritance requires regular files: ' + str(path))
    return observed.st_size


def revalidate(lease):
    """The lease names the receipts consulted; they only need to still exist.

    D1: identity is git + pinned content digests. Device, inode, timestamps,
    link counts and modes are not compared, so a reboot or move never blocks.
    """
    for item in lease:
        if isinstance(item, dict):
            continue
        path = item[0] if isinstance(item, tuple) else item
        if not Path(path).exists():
            raise ValueError('admitted receipt disappeared: ' + str(path))


def _native_dependency(source, admission):
    spec = importlib.util.spec_from_file_location(
        'manifest_native_dependency', Path(__file__).with_name('retained_toolchain_admission.py'))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper.native_dependency(Path(source), Path(admission))


def copy_native_dependency(source, admission, destination, receipt):
    """Make the canonical run view from current accepted native package bytes."""
    source, destination, receipt = map(Path, (source, destination, receipt))
    expected = receipt.parent / 'dependencies/sleigh-native-source/SleighNativeSource/materialization'
    if receipt.name != 'NATIVE_DEPENDENCY_ADMISSION.json' or destination != expected:
        raise ValueError('native dependency copy must use the canonical run view')
    native, value = _native_dependency(source, admission)
    copied = native.copy_package(value, destination)
    payload = {'schema_version': 2,
               'scope': ('current-native-dependency-retained-original-view'
                         if copied.get('method') == 'retained-original-view'
                         else 'current-native-dependency-controlled-copy'),
               'source': str(source), 'native_admission': str(admission),
               'identity': value['archive']['package_identities'],
               'destination': str(destination)}
    receipt.unlink(missing_ok=True)
    native.D.publish(receipt, payload)


def admit_manifests(retained_receipt, current, dependency_events, native_admission=None):
    """Return (inherited digest fields, consulted receipt paths); fail closed on drift."""
    retained_receipt = Path(retained_receipt)
    lease = []

    def read(path):
        path = Path(path)
        value = json.loads(path.read_text(encoding='utf-8'))
        lease.append(path)
        return value

    prior = read(retained_receipt)
    if (prior.get('schema_version') != 4 or prior.get('mode') != 'release'
            or prior.get('dependency_network_used') is not False):
        raise ValueError('retained qualification inputs are not an offline Release receipt')
    old_contract = prior['source_identity']['dependency_contract']
    new_contract = current['source_identity']['dependency_contract']
    if any(old_contract.get(k) != new_contract.get(k) for k in (
            'component_manifest_sha256', 'component_pins', 'notices_sha256')):
        raise ValueError('retained dependency contract differs')
    old_events = read(retained_receipt.parent / 'DEPENDENCY_CACHE_EVENTS.json')
    new_events = read(dependency_events)
    for document, receipt in ((old_events, prior), (new_events, current)):
        if (document.get('schema_version') != 1
                or document.get('dependency_cache_root') != receipt['dependency_cache_root']
                or document.get('source') != {
                    'commit': receipt['source_identity']['git_head_commit'],
                    'tree': receipt['source_identity']['git_head_tree']}):
            raise ValueError('dependency event authority differs')
    if prior['dependency_cache_root'] != current['dependency_cache_root']:
        raise ValueError('retained dependency cache root differs')
    digests = {}
    native_admission = native_admission or os.environ.get('MACSCOPE_NATIVE_RELEASE_ADMISSION')
    for component, field, root_field, entry_relative, view_relative in SPECS:
        if component == 'sleigh-native-source' and native_admission:
            native, value = _native_dependency(current['build_source_root'], native_admission)
            root = Path(current[root_field])
            expected_root = Path(dependency_events).parent / 'dependencies/sleigh-native-source/SleighNativeSource/materialization'
            copied = read(Path(dependency_events).parent / 'NATIVE_DEPENDENCY_ADMISSION.json')
            if (copied.get('schema_version') != 2
                    or copied.get('scope') not in ('current-native-dependency-controlled-copy',
                                                  'current-native-dependency-retained-original-view')
                    or copied.get('source') != current['build_source_root']
                    or copied.get('native_admission') != str(native_admission)
                    or copied.get('identity') != value['archive']['package_identities']
                    or root != expected_root or copied.get('destination') != str(root)):
                raise ValueError('current native dependency authority differs')
            # A typed native package copy is not a content-addressed cache hit.
            if any(e['component'] == component for e in new_events['events']):
                raise ValueError('current native package must not masquerade as an old cache event')
            lease.append({'native': native, 'value': value, 'root': root})
            digests[field] = value['archive']['package_identities']['materializationManifestSHA256']
            continue
        matches = [[e for e in d['events'] if e['component'] == component]
                   for d in (old_events, new_events)]
        if any(len(rows) != 1 for rows in matches):
            raise ValueError('dependency event missing or duplicate: ' + component)
        old, new = matches[0][0], matches[1][0]
        if (new['status'] != 'receipt-reused-hit'
                or any(old[k] != new[k] for k in ('entry', 'key', 'component'))):
            raise ValueError('dependency was not reused from the retained entry: ' + component)
        entry = Path(new['entry'])
        expected_entry = Path(current['dependency_cache_root']) / 'artifacts/v1' / component / new['key']
        if entry != expected_entry:
            raise ValueError('dependency entry path differs: ' + component)
        view = Path(new['run_view'])
        manifest = Path(current[root_field]) / view_relative
        expected = view / entry_relative
        if component == 'ghostty-vt':
            # The qualifier copies the already admitted VT manifest into its
            # historical qualification layout; bind both sides of that copy.
            if manifest != Path(dependency_events).parent / 'dependencies/ghostty-vt-qualification/zig-out/lib/.macscope-ghostty-vt-manifest':
                raise ValueError('qualification VT manifest path differs')
            size(expected)
            lease.append(expected)
        elif manifest != expected:
            raise ValueError('dependency manifest path differs: ' + component)
        document = read(entry / 'ENTRY.json')
        if (document.get('schema_version') != 1 or document.get('component') != component
                or document.get('key') != new['key']):
            raise ValueError('dependency entry declaration differs: ' + component)
        rows = [r for r in document['payload_records'] if r['path'] == entry_relative]
        digest = prior.get(field)
        if (len(rows) != 1 or rows[0].get('kind') != 'file'
                or not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest)
                or rows[0].get('sha256') != digest):
            raise ValueError('retained manifest identity differs: ' + component)
        if component == 'ghostty-vt':
            for relative in ('artifacts/lib/libghostty-vt.0.1.0.dylib',
                             'artifacts/include/ghostty/vt.h', 'artifacts/include/module.modulemap'):
                leaves = [r for r in document['payload_records'] if r['path'] == relative]
                if len(leaves) != 1 or leaves[0].get('kind') != 'file':
                    raise ValueError('admitted VT leaf declaration missing: ' + relative)
                leaf = view / relative
                if size(leaf) != leaves[0]['size']:
                    raise ValueError('admitted VT leaf size differs: ' + relative)
                lease.append(leaf)
            copied_dylib = Path(current[root_field]) / 'zig-out/lib/libghostty-vt.dylib'
            if size(copied_dylib) != size(view / 'artifacts/lib/libghostty-vt.0.1.0.dylib'):
                raise ValueError('controlled VT qualification copy size differs')
            lease.append(copied_dylib)
        if size(manifest) != rows[0]['size']:
            raise ValueError('admitted manifest size differs: ' + component)
        lease.append(manifest)
        digests[field] = digest
    return digests, lease


def copy_admitted_machokit(source, retained_receipt, destination):
    """Copy the accepted MachOKit view when its git source closure is unchanged.

    The view is keyed by the SOURCE_FILES rows (git blobs) of its closure, not
    by the old tree's inode/ctime metadata. A leftover partial destination from
    an interrupted run is replaced.
    """
    import shutil
    import sys
    prior = json.loads(retained_receipt.read_text())
    if prior.get('schema_version') != 4 or prior.get('mode') != 'release':
        raise ValueError('MachOKit inheritance requires accepted Release inputs')
    old_root = retained_receipt.parent / 'private-machokit-input'
    old_source = Path(prior['build_source_root'])

    def closure(root):
        rows = json.loads((root / 'SOURCE_FILES.json').read_text())['files']
        return {r['path']: r for r in rows if r['path'].startswith(
            ('ThirdParty/MachOKit/', 'Scripts/machokit_'))}

    before, after = closure(old_source), closure(source)
    if not before or before != after:
        raise ValueError('MachOKit source/contract closure differs')
    spec = importlib.util.spec_from_file_location('inherited_machokit', source / 'Scripts/machokit_source_identity.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    old_root = module._canonical_admission_root(old_root)
    if destination.is_symlink():
        destination.unlink()
    module._remove_private_staging(destination)
    shutil.copytree(old_root, destination, copy_function=shutil.copy2)
    module._freeze_tree(destination)
    module._write_admission(destination, module._admission_identity(destination))
    return module.MATERIALIZATION_TREE_SHA256


def admit_bootstrap(source, current_receipt, retained_receipt, environment):
    """Admit unchanged bootstrap consumers; changed surface/project checks stay live."""
    current_path, retained_path = Path(current_receipt), Path(retained_receipt)
    current = json.loads(current_path.read_text())
    prior = json.loads(retained_path.read_text())
    if (current.get('schema_version') != 4 or current.get('mode') != 'release'
            or Path(current['build_source_root']) != source
            or current_path != source.parent / 'QUALIFICATION_INPUTS.json'
            or not environment.get('MACSCOPE_NATIVE_RELEASE_ADMISSION')):
        raise ValueError('bootstrap inheritance requires exact current typed Release authority')
    admit_manifests(retained_path, current, current_path.parent / 'DEPENDENCY_CACHE_EVENTS.json',
                              native_admission=environment['MACSCOPE_NATIVE_RELEASE_ADMISSION'])
    roots = {
        'MACSCOPE_SLEIGH_MATERIALIZATION_ROOT': current['sleigh_materialization_root'],
        'MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT': str(Path(current['sleigh_materialization_root']).parent),
        'MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR': current['ghostty_surface_source_dir'],
        'MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT': current['ghostty_surface_artifact_root'],
        'MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT': str(source.parent / 'private-machokit-input'),
    }
    if any(environment.get(name) != expected for name, expected in roots.items()):
        raise ValueError('bootstrap consumed dependency roots differ from current qualification inputs')

    def source_records(root):
        rows = json.loads((root / 'SOURCE_FILES.json').read_text())['files']
        records = {r['path']: r for r in rows}
        if len(records) != len(rows):
            raise ValueError('bootstrap source records contain duplicates')
        return records

    old, new = source_records(Path(prior['build_source_root'])), source_records(source)

    def same(fixed, prefixes=()):
        def select(rows):
            return {p: r for p, r in rows.items() if p in fixed or p.startswith(prefixes)}
        before, after = select(old), select(new)
        return bool(before) and set(fixed).issubset(before) and before == after

    policy = same({
        'Scripts/dependencies/validate_policy_consistency.py',
        'MacScope/PARITY_CONTRACT.md',
        'THIRD_PARTY_COMPONENTS.yml', 'THIRD_PARTY_NOTICES.md',
        'docs/dependencies/LicenseDecision.md', 'Scripts/ghostty-vt-source.contract',
        'Scripts/ghostty-surface-source.contract'}, ('ThirdParty/MachOKit/',))
    inventory = same({
        'Scripts/dependencies/validate_third_party_components.py',
        'Scripts/dependencies/first_party_components.py',
        'Scripts/dependencies/third_party_components.schema.json',
        '.gitignore', 'THIRD_PARTY_COMPONENTS.yml', 'THIRD_PARTY_NOTICES.md',
        },
        ('ThirdParty/', 'Vendor/', 'Dependencies/', 'Scripts/function-signatures/'))
    tool = same({'Scripts/dependencies/materialize_xcodegen.py', 'ThirdParty/XcodeGen/bin/xcodegen'},
                ('ThirdParty/XcodeGen/',))
    # SLEIGH is already bound above to the current native producer and its
    # controlled run copy. The older nonnative run cannot authorize its source.
    if not tool:
        raise ValueError('accepted bootstrap tool source/contract changed')
    if environment.get('MACSCOPE_XCODEGEN', str(source / 'ThirdParty/XcodeGen/bin/xcodegen')) != str(source / 'ThirdParty/XcodeGen/bin/xcodegen'):
        raise ValueError('bootstrap inheritance refuses an alternate XcodeGen binary')
    tool_pin = [r['pin'] for r in prior['source_identity']['dependency_contract']['component_pins']
                if r['id'] == 'xcodegen-tool']
    if len(tool_pin) != 1 or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', tool_pin[0].get('version', '')):
        raise ValueError('accepted XcodeGen version declaration is absent')
    return {'policy': policy, 'inventory': inventory,
            'xcodegen_version': tool_pin[0]['version']}


_SEALED_CONTEXT = None


def sealed_source_digest(path):
    """Return the recorded digest of a sealed source leaf on the retained Release route.

    SOURCE_FILES.json digests are computed once per git blob (D1); a leaf is
    matched by path and size, never by timestamps, inode or mode.
    """
    global _SEALED_CONTEXT
    if os.environ.get("MACSCOPE_CACHE_RELEASE_ADMISSION"):
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import cache_release_inputs
        return cache_release_inputs.source_digest(path)
    names = ('MACSCOPE_QUALIFICATION_INPUTS_RECEIPT',
             'MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS', 'MACSCOPE_NATIVE_RELEASE_ADMISSION')
    authority = tuple(os.environ.get(name, '') for name in names)
    if not any(authority):
        return None
    if not all(authority):
        raise ValueError('sealed source digests require complete typed Release authority')
    if _SEALED_CONTEXT is None:
        current_path, retained_path, native_path = map(Path, authority)
        current = json.loads(current_path.read_text())
        source = Path(current['build_source_root'])
        admit_bootstrap(source, current_path, retained_path, os.environ)
        if json.loads((source / 'SOURCE_PROVENANCE.json').read_text()) != current['source_identity']:
            raise ValueError('sealed source provenance differs from current qualification receipt')
        rows = json.loads((source / 'SOURCE_FILES.json').read_text())['files']
        records = {r['path']: r for r in rows}
        if len(records) != len(rows) or len(rows) != current['source_identity']['source_file_count']:
            raise ValueError('sealed source record membership differs')
        import native_release_admission as native
        admission = native.read(native_path)
        if admission.get('schema_version') != 1 or admission.get('scope') != native.STANDARD_SCOPE:
            raise ValueError('unsupported native Release authority for source digests')
        current_sources = {p: {k: records[p][k] for k in ('blob_oid', 'mode')}
                           for p in admission['native_sources'] if p in records}
        native.accepted_source_updates(current_sources, admission['native_sources'], standard=True)
        _SEALED_CONTEXT = (authority, source, records)
    admitted, source, records = _SEALED_CONTEXT
    if authority != admitted:
        raise ValueError('sealed source authority changed during semantic validation')
    path = Path(path)
    relative = path.relative_to(source).as_posix()
    row = records.get(relative)
    if (row is None or row.get('mode') not in ('100644', '100755')
            or size(path) != row['size'] or not re.fullmatch('[0-9a-f]{64}', row.get('sha256', ''))):
        raise ValueError('sealed source leaf differs from admitted record: ' + relative)
    return row['sha256']
