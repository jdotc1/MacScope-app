#!/usr/bin/env python3
"""Adopt an actually accepted standard Release native component without replay."""
import argparse
from pathlib import Path
import stat
import native_release_admission as N

SCOPE = 'accepted-standard-native-Release-component'
CACHE_PATH = 'Scripts/qualification/dependency_cache.py'
CACHE_DELTA = '578ad0e75d7a2179f1dd6f18b67ac0d10cfdc9f9'


def prepare(repository, run, result_path, acceptance_path, output):
    repository, run, output = map(lambda p: Path(p).resolve(), (repository, run, output))
    rows = []
    def read(path):
        rows.append(N.record(path))
        return N.read(path)
    result = read(result_path)
    acceptance = read(acceptance_path)
    q = read(run / 'QUALIFICATION_INPUTS.json')
    old_source = run / 'source'
    source = N.source_manifest(old_source / 'SOURCE_FILES.json')
    rows.append(N.record(old_source / 'SOURCE_FILES.json'))
    head = q['source_identity']['git_head_commit']
    if (result.get('exit') != 0 or result.get('commit') != head
            or acceptance.get('installed_commit') != head
            or q.get('mode') != 'release' or q.get('dependency_network_used') is not False
            or q['build_source_root'] != str(old_source)):
        raise ValueError('standard Release was not accepted offline at the recorded source')
    paths = N.source_paths(repository)
    prior_sources = {r['path']: {k: r[k] for k in ('blob_oid', 'mode')}
                     for r in source['files'] if r['path'] in paths}
    current = N.git_records(repository, 'HEAD', paths)
    if set(prior_sources) != set(current):
        raise ValueError('native computation source membership changed')
    differences = {p for p in current if current[p] != prior_sources[p]}
    if differences - {CACHE_PATH}:
        raise ValueError('native computation/compiler source changed')
    delta = None
    if differences:
        before = N.git(repository, 'rev-parse', CACHE_DELTA + '^:' + CACHE_PATH)
        after = N.git(repository, 'rev-parse', CACHE_DELTA + ':' + CACHE_PATH)
        if (prior_sources[CACHE_PATH]['blob_oid'] != before
                or current[CACHE_PATH]['blob_oid'] != after
                or prior_sources[CACHE_PATH]['mode'] != current[CACHE_PATH]['mode']):
            raise ValueError('cache consumer change is not the exact accepted PR563 delta')
        delta = {'path': CACHE_PATH, 'accepted_change_commit': CACHE_DELTA,
                 'before': prior_sources[CACHE_PATH], 'after': current[CACHE_PATH]}
    products = run / 'DerivedData/Build/Products/Release'
    resources = products / 'NativeDecompilerXPCService.xpc/Contents/Resources'
    golden_path = resources / 'NativeDecompilerBridgeGolden.json'
    provenance_path = products / 'MacScope.app/Contents/Resources/MacScopeBuildProvenance.json'
    golden, provenance = read(golden_path), read(provenance_path)
    if (golden.get('passed') is not True or provenance.get('git_head_commit') != head
            or provenance.get('configuration') != 'Release'
            or provenance.get('qualification_eligible') is not True
            or provenance.get('native_decompiler_golden_result') != golden):
        raise ValueError('accepted standard golden/provenance identity differs')
    build = run / 'DerivedData/Build/Intermediates.noindex/MacScope.build/NativeDecompilerBridge'
    cache_path = build / 'CMakeCache.txt'
    cache = dict(line.split('=', 1) for line in cache_path.read_text().splitlines()
                 if '=' in line and not line.startswith(('#', '//')))
    rows.append(N.record(cache_path))
    bootstrap = read(run / 'bootstrap-reuse-key.json')
    developer = bootstrap['bindings']['developer-dir']
    toolchain = dict(DEVELOPER_DIR=developer, SDKROOT=cache['CMAKE_OSX_SYSROOT:PATH'],
                     SDK_NAME=provenance['sdk_name'], SDK_VERSION=provenance['sdk_version'],
                     SDK_PRODUCT_BUILD_VERSION=provenance['sdk_build'], ARCHS='arm64',
                     MACOSX_DEPLOYMENT_TARGET='27.0')
    if (cache['CMAKE_BUILD_TYPE:STRING'] != 'Release'
            or cache['CMAKE_OSX_ARCHITECTURES:STRING'] != 'arm64'
            or cache['CMAKE_OSX_DEPLOYMENT_TARGET:UNINITIALIZED'] != '27.0'
            or not cache['CMAKE_CXX_COMPILER:STRING'].startswith(developer + '/')):
        raise ValueError('accepted native CMake target/toolchain differs')
    events = read(run / 'DEPENDENCY_CACHE_EVENTS.json')
    event = [e for e in events['events'] if e['component'] == 'sleigh-native-source']
    if len(event) != 1:
        raise ValueError('accepted SLEIGH cache event missing or duplicate')
    entry = read(Path(event[0]['entry']) / 'ENTRY.json')
    materialization = Path(q['sleigh_materialization_root'])
    manifest = read(materialization / 'MATERIALIZATION.json')
    snapshot = N.D.snapshot(materialization)
    inherited = {r['path'].removeprefix('materialization/'): r for r in entry['payload_records']
                 if r['path'].startswith('materialization/')}
    if set(snapshot) != set(inherited):
        raise ValueError('accepted package membership differs from content receipt')
    staged_rows = []
    for name, fields in snapshot.items():
        row = inherited[name]
        kind = 'directory' if stat.S_ISDIR(fields[2]) else 'file'
        if row['kind'] != kind or (kind == 'file' and row['size'] != fields[4]):
            raise ValueError('accepted package declaration differs')
        staged_rows.append([name, kind, fields, row.get('sha256')])
    if (inherited['MATERIALIZATION.json']['sha256'] != golden['materializationManifestSHA256']
            or manifest['package']['treeSha256'] != golden['materializationTreeSHA256']):
        raise ValueError('accepted package/golden content identities differ')
    output.parent.mkdir(parents=True, exist_ok=True)
    staged_path = output.parent / 'STANDARD_NATIVE_PACKAGE.json'
    N.D.publish(staged_path, dict(root=str(materialization),
                                snapshot=staged_rows, identity=manifest))
    archive_path = output.parent / 'STANDARD_NATIVE_COMPONENT.json'
    outputs = []
    for name, digest in zip(N.OUTPUTS, ('contractArchiveSHA256', 'contractBuildIdentitySHA256')):
        row = N.record(build / name)
        outputs.append(dict(row, size=row['fields'][4], sha256=golden[digest]))
    archive = dict(scope=SCOPE, source_commit=head, native_build_root=str(build),
                   toolchain=toolchain, outputs=outputs, accepted_authorities=rows,
                   wrapper_profile=golden['wrapperGitRevision'], golden_profile=golden['goldenSourceSHA256'],
                   computation_receipt=str(golden_path), receipt_consumer_delta=delta,
                   package_identities={k: golden[k] for k in ('materializationManifestSHA256',
                       'materializationTreeSHA256', 'decompilerArchiveSHA256', 'sleighArchiveSHA256')})
    N.D.publish(archive_path, archive)
    prior_path = output.parent / 'STANDARD_NATIVE_PRIOR.json'
    N.D.publish(prior_path, dict(head=head, repository=str(repository), sources=prior_sources,
                               oldGolden=N.record(golden_path), oldProvenance=N.record(provenance_path),
                               stagedReceipt=N.record(staged_path), toolchain=toolchain))
    value = dict(schema_version=1, scope=N.STANDARD_SCOPE, source_commit=N.git(repository, 'rev-parse', 'HEAD'),
                 component_source_commit=head, native_sources=current, archive_receipt=N.record(archive_path),
                 prior_inputs=N.record(prior_path), native_build_root=str(build), outputs=outputs,
                 receipt_directory=str(output.parent / (output.stem + '-outputs')))
    Path(value['receipt_directory']).mkdir(mode=0o700)
    N.write_filelists(value, output)
    N.D.publish(output, value)
    return value


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repository-root', 'accepted-run', 'accepted-result', 'acceptance', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    print(prepare(args.repository_root, args.accepted_run, args.accepted_result, args.acceptance, args.output))
