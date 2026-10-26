#!/usr/bin/env python3
"""Adopt an accepted Release-built cache computation for a fresh Release app.

This is not standard Release-app acceptance. The donor app was Debug; only its
already accepted native computation and immutable Release-built static inputs
are retained. The current app and workers must still compile/sign as Release.
No producer, golden replay, payload hash, or verification fallback is allowed.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import stat
import receipt_device_transition as devices

import native_release_admission as N

SCOPE = 'accepted-cache-native-Release-computation'
ARCHIVE_SCOPE = 'Release-built-native-cache-component'
CONSUMER = 'Scripts/native-decompiler-direct/sleigh_package.py'
# This exact parser-only resource-overlay admission changes no translation unit,
# wire/golden vector or compiled source. Do not extend this to arbitrary drift.
CONSUMER_DELTA = ('23e485447f99995b574c4048938b8179d748cdb8',
                  '23ec2317ebf4e2d7503ddc9b5410fa5cd4ea9e77')


def module(repository, relative, name):
    spec = importlib.util.spec_from_file_location(name, repository / relative)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def read_bound(path, consulted):
    path = Path(path)
    before = N.D.fields(path)
    value = N.D.read_json(path)
    if N.D.fields(path) != before:
        raise ValueError('adoption receipt changed while read: ' + str(path))
    consulted.append({'path': str(path), 'fields': before})
    return value


def require_bound(row):
    if not devices.fields_match(Path(row['path']), N.D.fields(Path(row['path'])), row['fields']):
        raise ValueError('accepted native adoption input changed: ' + row['path'])


def no_reverification(*_args, **_kwargs):
    raise ValueError('retained source/tool identity memo required; no verification fallback')


def source_contract(repository, donor):
    paths = N.source_paths(repository)
    current = N.git_records(repository, 'HEAD', paths)
    accepted = N.git_records(donor, 'HEAD', paths)
    for root in (repository, donor):
        if N.git(root, 'status', '--porcelain', '--untracked-files=no', '--', *paths):
            raise ValueError('native source contract has local changes')
    return current, accepted, source_updates(current, accepted)


def source_updates(current, accepted):
    if set(current) != set(accepted):
        raise ValueError('native source membership differs')
    delta = {}
    for path in current:
        if current[path] == accepted[path]:
            continue
        if (path != CONSUMER or accepted[path]['mode'] != current[path]['mode']
                or (accepted[path]['blob_oid'], current[path]['blob_oid']) != CONSUMER_DELTA):
            raise ValueError('native computation source differs: ' + path)
        delta[path] = {'accepted': accepted[path], 'current': current[path],
                       'scope': 'exact resource-overlay parser consumer change; no compiled input change'}
    return delta


def accepted_views(repository, donor, view_root, consulted):
    cache = module(repository, Path('Scripts/qualification/dev_dependency_cache.py'),
                   'native_adoption_dev_cache')
    cache.blob_records = no_reverification
    cache.CACHE.external_file_identity = no_reverification
    if dict(cache.COMPONENTS['native-bridge']['values']).get('configuration') != 'Release':
        raise ValueError('native cache no longer declares Release compilation')
    views, manifests = {}, {}
    for component in ('native-bridge', 'sleigh-native-source'):
        key = cache.component_key(component, donor, view_root)
        receipt_path = view_root / component / key / 'VIEW.json'
        receipt = read_bound(receipt_path, consulted)
        view = Path(receipt['view'])
        entry = Path(receipt['entry'])
        if cache.view_receipt_valid(receipt_path, entry, view, component, key) is None:
            raise ValueError('unchanged accepted native view required: ' + component)
        manifests[component] = read_bound(entry / 'ENTRY.json', consulted)
        views[component] = view
    return views, manifests


def prepare(repository, donor, derived, view_root, output):
    repository, donor, derived, view_root = [Path(p).resolve(strict=True)
                                           for p in (repository, donor, derived, view_root)]
    output = Path(output)
    if not output.is_absolute() or output.exists() or repository in output.parents:
        raise ValueError('native adoption needs a new absolute receipt outside source')
    consulted = []
    info = derived / 'info.plist'
    info_before = N.D.fields(info)
    if plistlib.loads(info.read_bytes()).get('WorkspacePath') != str(donor / 'MacScope/MacScope.xcodeproj'):
        raise ValueError('native computation DerivedData belongs to another donor')
    if N.D.fields(info) != info_before:
        raise ValueError('donor DerivedData identity changed')
    consulted.append({'path': str(info), 'fields': info_before})
    current, accepted, delta = source_contract(repository, donor)
    # The exact accepted cache producer is itself in the native Git closure.
    # It calls build_native_bridge.sh --configuration Release; CONFIGURATION
    # below binds the path-free output's wrapper and package identities.
    views, entries = accepted_views(repository, donor, view_root, consulted)
    products = derived / 'Build/Products/Debug'
    resources = products / 'NativeDecompilerXPCService.xpc/Contents/Resources'
    golden_path = resources / 'NativeDecompilerBridgeGolden.json'
    provenance_path = products / 'MacScope.app/Contents/Resources/MacScopeBuildProvenance.json'
    golden = read_bound(golden_path, consulted)
    provenance = read_bound(provenance_path, consulted)
    configuration = read_bound(views['native-bridge'] / 'CONFIGURATION.json', consulted)
    materialization_root = views['sleigh-native-source'] / 'materialization'
    materialization = read_bound(materialization_root / 'MATERIALIZATION.json', consulted)
    if set(p.name for p in materialization_root.iterdir()) != {'MATERIALIZATION.json','package'}:
        raise ValueError('cache native adoption only covers its ordinary baseline package layout')
    bridge_records = {r['path']: r for r in entries['native-bridge']['payload_records']}
    package_records = {r['path']: r for r in entries['sleigh-native-source']['payload_records']}
    for relative, digest in materialization['package']['criticalFileSha256'].items():
        if package_records.get('materialization/package/'+relative, {}).get('sha256') != digest:
            raise ValueError('accepted package critical facts differ from actual entry: '+relative)
    if not (provenance.get('configuration') == 'Debug' and golden.get('passed') is True
            and provenance.get('native_decompiler_golden_result') == golden
            and golden.get('wrapperGitRevision') == configuration.get('wrapper_revision')
            and golden.get('materializationManifestSHA256') == configuration.get('materialization_manifest_sha256')
            and golden.get('materializationManifestSHA256') == package_records['materialization/MATERIALIZATION.json']['sha256']
            and golden.get('materializationTreeSHA256') == materialization['package']['treeSha256']
            and golden.get('contractArchiveSHA256') == bridge_records[N.OUTPUTS[0]]['sha256']
            and golden.get('contractBuildIdentitySHA256') == bridge_records[N.OUTPUTS[1]]['sha256']
            and golden.get('decompilerArchiveSHA256') == materialization['package']['criticalFileSha256']['lib/libdecomp.a']
            and golden.get('sleighArchiveSHA256') == materialization['package']['criticalFileSha256']['lib/libsla.a']):
        raise ValueError('accepted Debug golden does not bind the Release-built cache computation')
    if (golden.get('architecture') != 'arm64' or golden.get('deploymentTarget') != '27.0'
            or golden.get('backendID') != 'ghidra-native-decompiler'):
        raise ValueError('unsupported accepted native architecture/backend')
    developer = os.environ.get('DEVELOPER_DIR', '')
    sdkroot = os.environ.get('SDKROOT', '')
    if not developer or not sdkroot or not Path(developer).is_dir() or not Path(sdkroot).is_dir():
        raise ValueError('selected current DEVELOPER_DIR and SDKROOT are required')
    # component_key above admits the selected platform/toolchain through its
    # retained stat memo, with every fallback producer/hash disabled. Read the
    # small version declaration solely to match the accepted golden's names.
    version_path = Path(developer).parent / 'version.plist'
    version_before = N.D.fields(version_path)
    version = plistlib.loads(version_path.read_bytes())
    if N.D.fields(version_path) != version_before or version.get('ProductBuildVersion') != golden['xcodeBuild']:
        raise ValueError('selected Xcode differs from accepted native computation')
    consulted.append({'path': str(version_path), 'fields': version_before})
    toolchain = dict(DEVELOPER_DIR=developer, SDKROOT=sdkroot,
                     SDK_NAME=golden['sdkName'], SDK_VERSION=golden['sdkVersion'],
                     SDK_PRODUCT_BUILD_VERSION=golden['sdkBuild'], ARCHS='arm64',
                     MACOSX_DEPLOYMENT_TARGET='27.0')
    for k, v in [('sdk_name', golden['sdkName']), ('sdk_version', golden['sdkVersion']),
                 ('sdk_build', golden['sdkBuild']), ('xcode_build', golden['xcodeBuild'])]:
        if provenance.get(k) != v:
            raise ValueError('accepted Debug golden/provenance toolchain differs: ' + k)
    # Capture metadata continuity of the immutable accepted payloads. No leaf
    # is rehashed, copied output is never substituted as prior evidence.
    snapshots = {str(root): N.D.snapshot(root) for root in views.values()}
    for row in consulted:
        require_bound(row)
    output.parent.mkdir(parents=True, exist_ok=True)
    receipt_root = output.parent / (output.stem + '-outputs')
    receipt_root.mkdir(mode=0o700)
    origin_records = [row for row in consulted if str(derived) in row['path']]
    for role, data, origin in [('golden', golden, golden_path), ('provenance', provenance, provenance_path)]:
        frozen = receipt_root / (role + '.json')
        N.D.publish(frozen, data)
        consulted = [row for row in consulted if row['path'] != str(origin)]
        consulted.append(N.record(frozen))
    # Future owner builds may legitimately update DerivedData after this bound
    # read; immutable frozen receipts now own consumption, with origins retained
    # as historical lineage rather than ongoing locks on the donor's work.
    consulted = [row for row in consulted if row not in origin_records]
    golden_path = receipt_root / 'golden.json'
    provenance_path = receipt_root / 'provenance.json'
    build = receipt_root / 'native-build'
    shutil.copytree(views['native-bridge'], build)
    build.chmod(0o700)
    (build / 'macscope-native-decompiler-link-inputs.xcfilelist').write_text(
        str(build / N.OUTPUTS[0]) + '\n')
    build.chmod(0o700)
    build_snapshot = N.D.snapshot(build)
    value = dict(schema_version=1, scope=SCOPE, source_commit=N.git(repository, 'rev-parse', 'HEAD'),
                 component_source_commit=N.git(donor, 'rev-parse', 'HEAD'),
                 native_sources=current, accepted_native_sources=accepted,
                 consumer_source_updates=delta, origin_records=origin_records, native_build_root=str(build),
                 receipt_directory=str(receipt_root), consulted=consulted,
                 view_snapshots=snapshots, build_snapshot=build_snapshot,
                 golden=golden, provenance=provenance, toolchain=toolchain,
                 staged={'root': str(materialization_root), 'identity': materialization},
                 cache_views={k: str(v) for k, v in views.items()},
                 outputs=[dict(N.record(build / name), sha256=bridge_records[name]['sha256']) for name in N.OUTPUTS])
    for root, snapshot in snapshots.items():
        if not devices.snapshots_match(root, N.D.snapshot(Path(root)), snapshot):
            raise ValueError('accepted cache input changed while copied')
    if N.D.snapshot(build) != build_snapshot:
        raise ValueError('native output changed during admission')
    for row in consulted:
        require_bound(row)
    # Native phase filelists use these two metadata records, never a fabricated
    # prior Release app or qualification-input record.
    archive_path = receipt_root / 'CACHE_NATIVE_COMPONENT.json'
    prior_path = receipt_root / 'CACHE_NATIVE_COMPUTATION.json'
    identities = {k: golden[k] for k in ('materializationManifestSHA256', 'materializationTreeSHA256',
                                        'decompilerArchiveSHA256', 'sleighArchiveSHA256')}
    N.D.publish(archive_path, dict(scope=ARCHIVE_SCOPE, source_commit=value['component_source_commit'],
                                  native_build_root=str(build), toolchain=toolchain,
                                  package_identities=identities, outputs=value['outputs']))
    N.D.publish(prior_path, dict(oldGolden=N.record(golden_path), oldProvenance=N.record(provenance_path),
                                stagedReceipt={'path': str(materialization_root / 'MATERIALIZATION.json'),
                                               'fields': N.D.fields(materialization_root / 'MATERIALIZATION.json')}))
    value['archive_receipt'], value['prior_inputs'] = N.record(archive_path), N.record(prior_path)
    value['build_snapshot'] = N.D.snapshot(build)
    N.write_filelists(value, output)
    N.D.publish(output, value)
    return value


def admit(repository, environment, value, location, source_records=None):
    if (environment.get('CONFIGURATION') != 'Release' or environment.get('SWIFT_OPTIMIZATION_LEVEL') != '-O'
            or environment.get('MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION', '')
            or any(N.LIVE in environment.get(k, '') for k in ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'OTHER_SWIFT_FLAGS'))):
        raise ValueError('cache-native adoption requires ordinary optimized Release compilation')
    for key, expected in value['toolchain'].items():
        if environment.get(key) != expected:
            raise ValueError('effective Release toolchain differs from accepted computation: ' + key)
    repository = Path(repository).resolve(strict=True)
    paths = N.source_paths(repository)
    if source_records is None and (repository / 'SOURCE_FILES.json').is_file():
        source_records = {r['path']: r for r in N.source_manifest(repository / 'SOURCE_FILES.json')['files']}
    current = (N.git_records(repository, 'HEAD', paths) if source_records is None else
               {p: {k: source_records[p][k] for k in ('blob_oid', 'mode')} for p in paths})
    N.accepted_source_updates(current, value['native_sources'], standard=False)
    for row in [*value['consulted'], value['archive_receipt'], value['prior_inputs']]:
        require_bound(row)
    for root, snapshot in value['view_snapshots'].items():
        if not devices.snapshots_match(root, N.D.snapshot(Path(root)), snapshot):
            raise ValueError('accepted native view changed after adoption')
    if not devices.snapshots_match(value['native_build_root'], N.D.snapshot(Path(value['native_build_root'])), value['build_snapshot']):
        raise ValueError('adopted native linker outputs changed')
    # require_bound above enforces either the original exact binding or the
    # explicit device-only audit; read_json still checks stability while read.
    archive = N.D.read_json(Path(value['archive_receipt']['path']))
    prior = N.D.read_json(Path(value['prior_inputs']['path']))
    return dict(value, archive=archive, prior=prior, _admission_path=str(location))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repository-root', 'donor-repository', 'donor-derived-data', 'view-root', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    prepare(args.repository_root, args.donor_repository, args.donor_derived_data, args.view_root, args.output)
    print('Adopted accepted cache native Release computation; no app Release acceptance claimed')


if __name__ == '__main__':
    main()
