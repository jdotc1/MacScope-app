#!/usr/bin/env python3
"""Explicit unsigned Debug builds using already accepted local preparation.

This path is never a release, archive, signing or qualification entry point.
It reuses recorded dependencies; it cannot produce or requalify a dependency.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))

PHASES = {
    'Verify certificate-backed signing environment': 'guard',
    'Stage verified Ghostty surface build inputs': 'surface',
    'Build repository-owned Ghostty VT': 'vt',
    'Stage cached parser engines': 'parsers',
    'Verify canonical embedded REA resource': 'rea',
    'Verify exact MachOKit source materialization': 'machokit',
    'Build verified native decompiler bridge': 'bridge',
    'Stage verified native decompiler package': 'package',
    'Validate native decompiler bridge golden': 'golden',
    'Generate sealed Release build provenance': 'development-record',
}
# Dependency and verifier declarations must match the accepted donor. App/UI
# source is deliberately excluded: it is compiled freshly by the real target.
CONTRACT_PATHS = ('ThirdParty', 'Tools/NativeDecompilerBridge',
                  'Scripts/dependencies', 'Scripts/native-decompiler-xpc',
                  'Scripts/native-decompiler-direct', 'Scripts/machokit_source_identity.py',
                  'MacScope/DependencyRoots.xcconfig', 'MacScope/SigningIdentity.xcconfig',
                  'MacScope/project.yml', 'MacScope/ParserEngines')


def git(root, *args):
    return subprocess.check_output(['/usr/bin/git', '-C', str(root), *args], text=True).strip()


def specification(text):
    """Replace only development consumers; the authored release spec is untouched."""
    lines = text.splitlines(keepends=True)
    result, name, index = [], '', 0
    while index < len(lines):
        line = lines[index]
        if line.startswith('      - name: '):
            name = line.split(': ', 1)[1].strip()
        # Unsigned products have no CodeResources. This input belongs only to
        # the replaced sealed-provenance phase, never to release generation.
        if '/Contents/_CodeSignature/CodeResources' in line:
            index += 1
            continue
        if line == '        script: |\n' and name in PHASES:
            result.append(line)
            phase = PHASES[name]
            result.append('          /usr/bin/python3 -B "$SRCROOT/../Scripts/unsigned_development.py" phase --phase ' + phase + '\n')
            index += 1
            while index < len(lines) and (lines[index].startswith('          ') or not lines[index].strip()):
                index += 1
            continue
        result.append(line)
        index += 1
    return ''.join(result)


def load(path):
    return json.loads(Path(path).read_text())


def guard(environment):
    import check_local_signing_policy as policy
    errors = policy.validate_build_environment(environment)
    if environment.get('MACSCOPE_DEV_UNSIGNED') != 'YES':
        errors.append('development-generated project requires explicit unsigned opt-in')
    if errors:
        raise ValueError('; '.join(errors))
    admission_path = environment.get('MACSCOPE_DEV_UNSIGNED_ADMISSION')
    if not admission_path:
        raise ValueError('development admission is missing')
    admission = load(admission_path)
    if admission.get('repository') != str(ROOT):
        raise ValueError('development admission belongs to another checkout')
    validate_development_generation(ROOT / 'MacScope', admission['generation'])


def copy(source, destination):
    """Copy admitted bytes while keeping only build-owned directories writable."""
    source, destination = Path(source), Path(destination)
    if not source.exists() or destination.is_symlink():
        raise ValueError(f'missing retained input or indirect output: {source} -> {destination}')
    admission_path = os.environ.get('MACSCOPE_DEV_UNSIGNED_ADMISSION')
    if admission_path:
        allowed = Path(admission_path).resolve().parent
        if allowed not in destination.resolve().parents:
            raise ValueError('development copy must remain in its admitted output root')
    if source.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        destination.chmod(0o700)
        for child in source.iterdir():
            copy(child, destination / child.name)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.parent.chmod(0o700)
        if destination.exists():
            destination.unlink()
        shutil.copy2(source, destination, follow_symlinks=True)


def prepare(donor, donor_derived, output):
    donor, donor_derived = donor.resolve(strict=True), donor_derived.resolve(strict=True)
    workspace = str(donor / 'MacScope/MacScope.xcodeproj')
    if plistlib.loads((donor_derived / 'info.plist').read_bytes()).get('WorkspacePath') != workspace:
        raise ValueError('retained DerivedData belongs to another checkout')
    requests = [load(path) for path in (donor_derived / 'Build/Intermediates.noindex/XCBuildData').glob('*.xcbuilddata/build-request.json')]
    if not any(request.get('containerPath') == workspace and
               request.get('parameters', {}).get('configurationName') == 'Debug' and
               request.get('parameters', {}).get('activeArchitecture') == 'arm64' and
               request.get('parameters', {}).get('arenaInfo', {}).get('derivedDataPath') == str(donor_derived)
               for request in requests):
        raise ValueError('retained Debug/arm64 build request is missing')
    identities = {}
    for relative in CONTRACT_PATHS:
        old, new = git(donor, 'rev-parse', 'HEAD:' + relative), git(ROOT, 'rev-parse', 'HEAD:' + relative)
        if old != new:
            raise ValueError('retained development contract differs: ' + relative)
        if git(donor, 'status', '--porcelain', '--untracked-files=no', '--', relative) or git(ROOT, 'status', '--porcelain', '--untracked-files=no', '--', relative):
            raise ValueError('dependency contract has local changes: ' + relative)
        identities[relative] = old
    config = donor / 'MacScope/DependencyRoots.local.xcconfig'
    if not (donor / 'MacScope/MacScope.xcodeproj/.macscope-project-generation.sha256').is_file():
        raise ValueError('donor has no successful preparation receipt')
    settings = {}
    for line in config.read_text().splitlines():
        if line and not line.startswith('//'):
            key, value = line.split(' = ', 1)
            settings[key] = value
    # Consume the existing read-only VIEW receipts, not cache producers.
    helper = ROOT / 'Scripts/qualification/dev_dependency_cache.py'
    spec = importlib.util.spec_from_file_location('unsigned_dependency_cache', helper)
    cache = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cache)
    # A memo miss must never re-read/re-hash unchanged governed inputs.
    def no_reverification(*_args, **_kwargs):
        raise ValueError('retained source/tool identity memo required; no verification fallback')
    cache.blob_records = no_reverification
    cache.CACHE.external_file_identity = no_reverification
    view_root = macscope_work_root() / 'MacScopeDevLoop.noindex/dependency-views'
    views, entries = {}, {}
    for component in ('ghostty-surface', 'ghostty-vt', 'sleigh-native-source', 'native-bridge'):
        key = cache.component_key(component, ROOT, view_root)
        directory = view_root / component / key
        receipt_path = directory / 'VIEW.json'
        receipt = load(receipt_path)
        view = Path(receipt['view'])
        if cache.view_receipt_valid(receipt_path, Path(receipt['entry']), view, component, key) is None:
            raise ValueError('accepted unchanged dependency view required: ' + component)
        views[component] = str(view)
        entries[component] = load(Path(receipt['entry']) / 'ENTRY.json')
    # The existing MachOKit admission uses metadata identity and falls closed
    # here rather than falling back to payload verification.
    import machokit_source_identity as machokit
    macho_root = Path(settings['MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT'])
    if load(machokit._admission_receipt(macho_root)) != machokit._admission_identity(macho_root):
        raise ValueError('unchanged MachOKit admission required')
    donor_build = donor_derived / 'Build/Intermediates.noindex/MacScope.build'
    for target, phase in (('AnalysisWorkerXPCService', 'rea-resource'),
                          ('AnalysisWorkerXPCService', 'machokit-source'),
                          ('NativeDecompilerXPCService', 'native-package-stage')):
        receipt = load(donor_build / 'Debug' / (target + '.build') / 'DerivedSources/MacScopePhaseStamps' / (phase + '.json'))
        if receipt.get('schema') != 1 or receipt.get('phase') != phase or not receipt.get('inputs'):
            raise ValueError('retained successful phase required: ' + phase)
    # Reuse the recorded golden only when its semantic input identities match
    # the accepted immutable bridge/materialization records and donor app record.
    donor_resources = donor_derived / 'Build/Products/Debug/NativeDecompilerXPCService.xpc/Contents/Resources'
    golden = load(donor_resources / 'NativeDecompilerBridgeGolden.json')
    provenance = load(donor_derived / 'Build/Products/Debug/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json')
    configuration = load(Path(views['native-bridge']) / 'CONFIGURATION.json')
    bridge_records = {row['path']: row for row in entries['native-bridge']['payload_records']}
    materialization = load(Path(views['sleigh-native-source']) / 'materialization/MATERIALIZATION.json')
    if not (golden.get('passed') is True and provenance.get('native_decompiler_golden_result') == golden and
            golden.get('wrapperGitRevision') == configuration['wrapper_revision'] and
            golden.get('materializationManifestSHA256') == configuration['materialization_manifest_sha256'] and
            golden.get('materializationTreeSHA256') == materialization['package']['treeSha256'] and
            golden.get('contractArchiveSHA256') == bridge_records['libmacscope_native_decompiler_contract.a']['sha256']):
        raise ValueError('retained golden does not cover the admitted native inputs')
    # The parser stage receipt names immutable published entries; use those
    # directly instead of trusting mutable donor staging directories.
    parsers = load(donor_build / 'MacScopeParserEngines/STAGED.json')
    parser_roots = {}
    for component, key in parsers['keys'].items():
        entry = Path(parsers['cache_root']) / 'artifacts/v1' / component / key
        manifest = load(entry / 'ENTRY.json')
        payload = entry / 'payload'
        observed, _size = cache.CACHE.payload_records(payload, hash_files=False, allow_hardlinks=True)
        expected = [{k: v for k, v in row.items() if k != 'sha256'} for row in manifest['payload_records']]
        if manifest['component'] != component or manifest['key'] != key or observed != expected:
            raise ValueError('retained parser entry differs: ' + component)
        if any(path.stat().st_mode & 0o222 for path in [payload, *payload.rglob('*')] if not path.is_symlink()):
            raise ValueError('retained parser entry is not read-only')
        parser_roots[component] = str(payload)
    output.parent.mkdir(parents=True, exist_ok=True)
    value = {'schema': 1, 'repository': str(ROOT), 'donor': str(donor),
             'donor_derived': str(donor_derived), 'source_ids': identities, 'views': views,
             'entries': entries, 'golden': golden, 'parser_roots': parser_roots, 'parser_stage': parsers}
    output.write_text(json.dumps(value, indent=2) + '\n')
    settings['MACSCOPE_SLEIGH_COMPONENT_ROOT'] = str(ROOT / 'ThirdParty/SleighNative')
    (ROOT / 'MacScope/DependencyRoots.local.xcconfig').write_text(''.join(f'{k} = {v}\n' for k, v in settings.items()))
    local = ROOT / 'MacScope/LocalPackages'
    if local.is_symlink():
        if local.resolve() != macho_root:
            raise ValueError('existing LocalPackages points at a different input')
    elif not local.exists():
        local.symlink_to(macho_root, target_is_directory=True)
    else:
        raise ValueError('LocalPackages already exists without the accepted link')
    value['generation'] = generate_development_project(ROOT / 'MacScope')
    output.write_text(json.dumps(value, indent=2) + '\n')
    print('Reused accepted dependency and source-phase receipts; generated unsigned-development project.')


def file_identity(path, *, symlink=False):
    value = path.lstat()
    if symlink:
        if not stat.S_ISLNK(value.st_mode):
            raise ValueError('expected admitted package symlink: ' + str(path))
    elif not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
        raise ValueError('expected ordinary generation input: ' + str(path))
    fields = [value.st_dev, value.st_ino, value.st_mode, value.st_uid,
              value.st_gid, getattr(value, 'st_flags', 0), value.st_nlink,
              value.st_size, value.st_mtime_ns, value.st_ctime_ns]
    if symlink:
        target = path.resolve(strict=True).stat()
        return {'link': fields, 'target': os.readlink(path),
                'target_identity': [target.st_dev, target.st_ino, target.st_mode, target.st_uid, target.st_gid]}
    return fields


def generation_inputs(source):
    relatives = ('project.yml', 'DependencyRoots.xcconfig', 'SigningIdentity.xcconfig',
                 'DependencyRoots.local.xcconfig', '../ThirdParty/SleighNative/PATCHED_RESOURCES.json',
                 '../Scripts/unsigned_development.py', '../Scripts/generate_xcode_json_project.py')
    return {relative: file_identity(source / relative) for relative in relatives}


def generate_development_project(source):
    from generate_xcode_json_project import generate
    from project_freshness import generated_project_source_paths
    project = source / 'project.yml'
    before, paths = generation_inputs(source), generated_project_source_paths(project)
    link = file_identity(source / 'LocalPackages', symlink=True)
    generate(source, unsigned_development=True)
    if before != generation_inputs(source) or paths != generated_project_source_paths(project) or link != file_identity(source / 'LocalPackages', symlink=True):
        raise ValueError('development generation inputs changed during generation')
    return {'inputs': before, 'source_paths': paths, 'packages': link,
            'project': file_identity(source / 'MacScope.xcodeproj/project.xcproj'),
            'marker': file_identity(source / 'MacScope.xcodeproj/.unsigned-development')}


def validate_development_generation(source, receipt):
    from project_freshness import generated_project_source_paths
    observed = {'inputs': generation_inputs(source),
                'source_paths': generated_project_source_paths(source / 'project.yml'),
                'packages': file_identity(source / 'LocalPackages', symlink=True),
                'project': file_identity(source / 'MacScope.xcodeproj/project.xcproj'),
                'marker': file_identity(source / 'MacScope.xcodeproj/.unsigned-development')}
    if observed != receipt:
        raise ValueError('development generated project, source membership or input metadata changed; regenerate explicitly')


def phase(name):
    env = dict(os.environ)
    guard(env)
    if name == 'guard':
        return
    admission = load(env['MACSCOPE_DEV_UNSIGNED_ADMISSION'])
    if admission['repository'] != str(ROOT):
        raise ValueError('development admission belongs to another checkout')
    for relative, identity in admission['source_ids'].items():
        if git(ROOT, 'rev-parse', 'HEAD:' + relative) != identity:
            raise ValueError('development source contract changed: ' + relative)
    donor_derived = Path(admission['donor_derived'])
    donor_temp = donor_derived / 'Build/Intermediates.noindex/MacScope.build'
    donor_products = donor_derived / 'Build/Products/Debug'
    views = {k: Path(v) for k, v in admission['views'].items()}
    resources = Path(env['TARGET_BUILD_DIR']) / env['UNLOCALIZED_RESOURCES_FOLDER_PATH']
    if name in ('rea', 'machokit'):
        print('Reusing accepted unchanged ' + name + ' source evidence')
    elif name == 'surface':
        surface = views['ghostty-surface']
        artifact = surface / 'macos/GhosttyKit.xcframework/macos-arm64'
        destination = Path(env['MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT'])
        descriptor = {'schema_version': 1, 'leaves': []}
        records = {row['path']: row for row in admission['entries']['ghostty-surface']['payload_records']}
        descriptor['source_manifest_sha256'] = records['macos/.macscope-ghostty-surface-manifest']['sha256']
        for role, relative in (('archive', 'libghostty-internal.a'), ('header', 'Headers/ghostty.h'), ('module_map', 'Headers/module.modulemap')):
            source = artifact / relative
            copy(source, destination / relative)
            descriptor['leaves'].append({'role': role, 'relative_path': relative, 'sha256': records[source.relative_to(surface).as_posix()]['sha256']})
        (destination / 'STAGED_GHOSTTY_SURFACE.json').write_text(json.dumps(descriptor, sort_keys=True) + '\n')
    elif name == 'vt':
        copy(views['ghostty-vt'] / 'artifacts', Path(env['MACSCOPE_GHOSTTY_VT_BUILD_ROOT']) / 'artifacts')
        copy(views['ghostty-vt'] / 'artifacts/lib/libghostty-vt.dylib', Path(env['TARGET_BUILD_DIR']) / env['FRAMEWORKS_FOLDER_PATH'] / 'libghostty-vt.dylib')
    elif name == 'parsers':
        destination = Path(env['MACSCOPE_PARSER_ENGINES_ROOT'])
        for component, source in admission['parser_roots'].items():
            copy(source, destination / component)
        (destination / 'STAGED.json').write_text(json.dumps(admission['parser_stage'], sort_keys=True) + '\n')
    elif name == 'bridge':
        destination = Path(env['MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT'])
        copy(views['native-bridge'], destination)
        links = destination / 'macscope-native-decompiler-link-inputs.xcfilelist'
        links.write_text(str(destination / 'libmacscope_native_decompiler_contract.a') + '\n')
    elif name in ('package', 'golden'):
        donor_resources = donor_products / 'NativeDecompilerXPCService.xpc/Contents/Resources'
        if name == 'package':
            copy(views['sleigh-native-source'] / 'materialization', resources / 'NativeDecompilerPackage')
            copy(donor_temp / 'Debug/NativeDecompilerXPCService.build/NativeDecompilerPackageStage', Path(env['TARGET_TEMP_DIR']) / 'NativeDecompilerPackageStage')
        else:
            resources.mkdir(parents=True, exist_ok=True)
            (resources / 'NativeDecompilerBridgeGolden.json').write_text(json.dumps(admission['golden'], sort_keys=True, separators=(',', ':')) + '\n')
    elif name == 'development-record':
        resources.mkdir(parents=True, exist_ok=True)
        (resources / 'MacScopeBuildProvenance.json').write_text(json.dumps({'kind': 'unsigned-development', 'qualification': 'not-performed', 'source_commit': git(ROOT, 'rev-parse', 'HEAD')}) + '\n')
    else:
        raise ValueError('unknown development phase')
    print('Unsigned development phase: ' + name + '; no signing or dependency verification')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prep = sub.add_parser('prepare')
    prep.add_argument('--prepared-repository', type=Path, required=True)
    prep.add_argument('--prepared-derived-data', type=Path, required=True)
    prep.add_argument('--admission', type=Path, required=True)
    consumer = sub.add_parser('phase')
    consumer.add_argument('--phase', choices=tuple(PHASES.values()), required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.prepared_repository, args.prepared_derived_data, args.admission)
    else:
        phase(args.phase)

if __name__ == '__main__':
    main()
