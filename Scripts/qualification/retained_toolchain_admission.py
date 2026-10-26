#!/usr/bin/env python3
"""Admit retained dependency keys without rehashing unchanged producer inputs.

This is a same-host continuation for already accepted dependency artifacts, not
permission to produce new dependencies. Tools are bound by path, kind and
symlink target; the toolchain identity is the inherited platform-toolchain key.
No device, inode, timestamp, link-count or mode is recorded or compared (D1).
CMake/Ninja producer context is opaque in the old cache keys.
"""
import json
import importlib.util
import os
from pathlib import Path
import platform
import re
import stat

SCHEMA = 1
PREFIXES = {
    'ghostty-vt': (
        'ThirdParty/GhosttyVT', 'ThirdParty/Zig', 'Scripts/build_ghostty_vt.sh',
        'Scripts/ghostty-vt-source.contract', 'Scripts/prepare_zig_macos_sdk_overlay.py',
        'Scripts/dependencies/zig_toolchain_receipt.py'),
    'ghostty-surface': (
        'ThirdParty/GhosttySurface', 'ThirdParty/Zig',
        'Scripts/dependencies/build_vendored_ghostty_surface.sh',
        'Scripts/dependencies/build_ghostty_surface.sh',
        'Scripts/dependencies/zig_toolchain_receipt.py',
        'Scripts/ghostty-surface-source.contract', 'Scripts/ghostty-vt-source.contract'),
    'sleigh-native-source': (
        'ThirdParty/SleighNative', 'Scripts/dependencies/build_vendored_sleigh_native_source.sh',
        'Scripts/dependencies/verify_vendored_sleigh_source.py',
        'Scripts/native-decompiler-direct/sleigh_package.py',
        'Scripts/native-decompiler-direct/verify_sleigh_package.py'),
}
# This root-level change log is not consumed by the source builder, native
# package verifier, or compiler. Keep every other member of the producer's
# closure exact, including Source/MATERIALIZATION.json and all package leaves.
NATIVE_SOURCE_NONINPUTS = {'ThirdParty/SleighNative/PATCHES.md'}


# The canonical qualifier's platform identity: the same named files, hashed the
# same way, as the qualifier's canonical `dependency_cache.py external-identity` call.
# Keep this list identical to that call (a test compares them).
def platform_identity_files(developer):
    sdk = developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist'
    return [('xcode-version', developer.parent / 'version.plist'), ('macos-sdk-settings', sdk),
            ('clang', developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++'),
            ('system-version', Path('/System/Library/CoreServices/SystemVersion.plist')),
            *[(name, Path('/usr/bin') / name) for name in (
                'xcrun', 'ar', 'strip', 'lipo', 'codesign', 'otool', 'nm', 'git')],
            ('python', Path('/usr/bin/python3')), ('plist-buddy', Path('/usr/libexec/PlistBuddy'))]


def current_platform_identity(developer):
    spec = importlib.util.spec_from_file_location(
        'macscope_dependency_cache_identity', Path(__file__).with_name('dependency_cache.py'))
    cache = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cache)
    external = sorted((cache.external_file_identity(f'{name}={path}')
                       for name, path in platform_identity_files(developer)), key=lambda item: str(item['name']))
    import hashlib
    return hashlib.sha256(cache.canonical_json(external)).hexdigest()


def _absolute(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('toolchain admission requires normalized absolute paths')
    return path


def _snapshot(path):
    observed = path.lstat()
    if observed.st_uid not in (0, os.getuid()):
        raise ValueError('toolchain path has an unexpected owner: ' + str(path))
    if stat.S_ISDIR(observed.st_mode):
        return {'kind': 'directory'}
    if stat.S_ISLNK(observed.st_mode):
        return {'kind': 'symlink', 'target': os.readlink(path)}
    if not stat.S_ISREG(observed.st_mode):
        raise ValueError('toolchain input is not an ordinary file: ' + str(path))
    return {'kind': 'file'}


def _bind(path, rows):
    """Capture the complete path/symlink chain and final leaf kind."""
    original = _absolute(path)
    pending, cursor, links = list(original.parts[1:]), Path('/'), 0
    while pending:
        cursor = cursor / pending.pop(0)
        observed = _snapshot(cursor)
        previous = rows.setdefault(str(cursor), observed)
        if previous != observed:
            raise ValueError('toolchain metadata changed during admission: ' + str(cursor))
        if observed['kind'] == 'symlink':
            links += 1
            if links > 40:
                raise ValueError('toolchain symlink chain is cyclic')
            target = Path(observed['target'])
            target = target if target.is_absolute() else cursor.parent / target
            target = Path(os.path.normpath(str(target)))
            pending, cursor = list(target.parts[1:]) + pending, Path('/')
        elif pending and observed['kind'] != 'directory':
            raise ValueError('toolchain path crosses a non-directory')
    if _snapshot(cursor)['kind'] != 'file':
        raise ValueError('toolchain input does not resolve to a file: ' + str(original))
    return cursor


def _read(path, rows):
    path = _absolute(path)
    if _bind(path, rows) != path:
        raise ValueError('retained declaration must be canonical: ' + str(path))
    document = json.loads(path.read_text(encoding='utf-8'))
    if _snapshot(path) != rows[str(path)]:
        raise ValueError('retained declaration changed while reading: ' + str(path))
    return document


def _digest(value, label):
    if not isinstance(value, str) or re.fullmatch('[0-9a-f]{64}', value) is None:
        raise ValueError('malformed inherited digest: ' + label)
    return value


def _closure(document, prefixes):
    selected = {}
    for row in document['files']:
        path = row['path']
        if any(path == prefix or path.startswith(prefix + '/') for prefix in prefixes):
            if path in selected:
                raise ValueError('duplicate dependency source declaration: ' + path)
            selected[path] = row
    if any(not any(path == p or path.startswith(p + '/') for path in selected) for p in prefixes):
        raise ValueError('dependency source closure is incomplete')
    return selected


def revalidate(document):
    """Check the path kinds/symlink targets captured by prepare; nothing is hashed."""
    if document.get('schema_version') != SCHEMA:
        raise ValueError('unsupported retained toolchain admission')
    for row in document['metadata']:
        if _snapshot(Path(row['path'])) != row['snapshot']:
            raise ValueError('retained toolchain metadata changed: ' + row['path'])


def native_dependency(source, admission_path, source_records=None):
    """Consume current native authority, never an older dependency cache key.

    The environment below describes receipt consumption before Xcode runs. The
    actual compiler phases separately enforce their effective build settings.
    """
    source = _absolute(source)
    spec = importlib.util.spec_from_file_location(
        'retained_native_dependency', Path(__file__).with_name('native_release_admission.py'))
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    admission = native.read(_absolute(admission_path))
    archive = native.bound(admission['archive_receipt'])
    environment = dict(archive['toolchain'], CONFIGURATION='Release',
                       SWIFT_OPTIMIZATION_LEVEL='-O',
                       MACSCOPE_NATIVE_RELEASE_ADMISSION=str(admission_path))
    records = source_records or {
        row['path']: row for row in native.source_manifest(source / 'SOURCE_FILES.json')['files']}
    value = native.admit(source, environment=environment, source_records=records)
    # The wrapper admission binds its own declared source profile. The native
    # dependency additionally binds the complete SLEIGH source/producer closure
    # to the accepted native head, including added/deleted files. Git blob IDs
    # are canonical declarations, not a new hash of accepted source bytes.
    prefixes = PREFIXES['sleigh-native-source']
    selected = _closure({'files': list(records.values())}, prefixes)
    current = {path: {key: row[key] for key in ('blob_oid', 'mode')}
               for path, row in selected.items() if path not in NATIVE_SOURCE_NONINPUTS}
    prior = value['prior']
    listing = native.git(Path(prior['repository']), 'ls-tree', '-r', '--full-tree',
                         prior['head'], '--', *prefixes)
    expected = {}
    for line in listing.splitlines():
        declaration, path = line.split('\t', 1)
        mode, kind, oid = declaration.split()
        if kind != 'blob' or mode not in ('100644', '100755'):
            raise ValueError('native dependency source is not an ordinary Git blob')
        if path not in NATIVE_SOURCE_NONINPUTS:
            expected[path] = {'blob_oid': oid, 'mode': mode}
    if not expected or current != expected:
        raise ValueError('current SLEIGH source closure differs from accepted native producer')
    if (records['ThirdParty/SleighNative/Source/MATERIALIZATION.json']['sha256']
            != value['staged']['identity']['sourceBuild']['sourceManifestSha256']):
        raise ValueError('current SLEIGH source manifest differs from admitted package producer')
    identity = value['archive']['package_identities']
    manifest = [row for row in value['staged']['snapshot'] if row[0] == 'MATERIALIZATION.json']
    if (len(manifest) != 1 or manifest[0][1] != 'file'
            or manifest[0][3] != identity['materializationManifestSHA256']
            or value['staged']['identity']['package']['treeSha256'] != identity['materializationTreeSHA256']):
        raise ValueError('current native package identity differs from its producer')
    return native, value


def prepare(retained_inputs, source, developer, cmake, ninja, output, native_admission=None):
    """Return and publish immutable admission for retained-only dependencies.

    cmake/ninja are accepted for caller compatibility, deliberately not inspected:
    current dependency production must remain disabled when consuming this result.
    """
    retained_inputs, source = _absolute(retained_inputs), _absolute(source)
    developer, output = _absolute(developer), _absolute(output)
    rows = {}
    prior = _read(retained_inputs, rows)
    bootstrap_path = retained_inputs.parent / 'bootstrap-reuse-key.json'
    bootstrap = _read(bootstrap_path, rows)
    events = _read(retained_inputs.parent / 'DEPENDENCY_CACHE_EVENTS.json', rows)
    old_source = _absolute(prior['build_source_root'])
    before = _read(old_source / 'SOURCE_FILES.json', rows)
    after = _read(source / 'SOURCE_FILES.json', rows)
    current_identity = _read(source / 'SOURCE_PROVENANCE.json', rows)
    if (prior.get('schema_version') != 4 or prior.get('mode') != 'release'
            or prior.get('dependency_network_used') is not False
            or bootstrap.get('schema_version') != 1
            or old_source != retained_inputs.parent / 'source'):
        raise ValueError('retained toolchain requires accepted offline Release inputs')
    old_identity = prior['source_identity']
    if bootstrap['bindings'].get('source-tree') != old_identity['git_head_tree']:
        raise ValueError('retained bootstrap source identity differs')
    old_contract, new_contract = old_identity['dependency_contract'], current_identity['dependency_contract']
    if any(old_contract.get(k) != new_contract.get(k) for k in (
            'component_manifest_sha256', 'component_pins', 'notices_sha256')):
        raise ValueError('retained dependency contract differs')
    if (events.get('schema_version') != 1
            or events.get('dependency_cache_root') != prior['dependency_cache_root']
            or events.get('source') != {'commit': old_identity['git_head_commit'],
                                       'tree': old_identity['git_head_tree']}):
        raise ValueError('retained dependency event authority differs')
    if developer.resolve(strict=True) != developer or str(developer) != bootstrap['bindings']['developer-dir']:
        raise ValueError('selected Xcode differs from retained producer')
    if platform.machine() != 'arm64' or bootstrap['system']['machine'] != 'arm64':
        raise ValueError('retained toolchain requires the accepted arm64 host')
    scalar_values = {'MACSCOPE_GHOSTTY_SIMD': 'false', 'MACSCOPE_NATIVE_SOURCE_JOBS': '8'}
    for key, default in scalar_values.items():
        old_value = bootstrap['environment'].get(key, default) or default
        if (os.environ.get(key, default) or default) != old_value:
            raise ValueError('retained dependency configuration changed: ' + key)
    keys = {}
    for component, prefixes in PREFIXES.items():
        if component == 'sleigh-native-source' and native_admission is not None:
            continue
        if _closure(before, prefixes) != _closure(after, prefixes):
            raise ValueError('retained dependency source closure changed: ' + component)
        matches = [e for e in events['events'] if e['component'] == component]
        if len(matches) != 1 or matches[0]['status'] != 'receipt-reused-hit':
            raise ValueError('retained dependency is not an accepted cache reuse: ' + component)
        key = _digest(matches[0]['key'], component)
        if bootstrap['bindings'].get(component + '-key') != key:
            raise ValueError('retained dependency key differs from bootstrap: ' + component)
        expected = Path(prior['dependency_cache_root']) / 'artifacts/v1' / component / key
        if matches[0]['entry'] != str(expected):
            raise ValueError('retained dependency cache location differs')
        keys[component] = key
    native_package = None
    compiler_authority = None
    if native_admission is not None:
        native, value = native_dependency(source, native_admission,
                                          {row['path']: row for row in after['files']})
        if value['archive']['toolchain']['DEVELOPER_DIR'] != str(developer):
            raise ValueError('current native producer Xcode differs from selected developer')
        compiler = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++'
        authorities = value['archive']['accepted_authorities']
        accepted_result = authorities[0]
        result = native.bound(accepted_result)
        if result.get('exit') != 0 or result.get('commit') != value['component_source_commit']:
            raise ValueError('adopted native compiler lacks accepted standard result')
        cache_path = Path(value['native_build_root']) / 'CMakeCache.txt'
        declarations = [line for line in cache_path.read_text().splitlines()
                        if line.startswith('CMAKE_CXX_COMPILER:STRING=')]
        if declarations != ['CMAKE_CXX_COMPILER:STRING=' + str(compiler)]:
            raise ValueError('adopted native compiler differs from selected compiler')
        compiler_authority = {'path': str(compiler), 'receipt': accepted_result['path']}
        native_package = {
            'admission': str(native_admission),
            'identity': value['archive']['package_identities'],
            'source_commit': value['prior']['head'],
            'excluded_noninputs': sorted(NATIVE_SOURCE_NONINPUTS),
            'root': value['staged']['root'],
        }
    paths = {
        'xcode-version': developer.parent / 'version.plist',
        'macos-sdk-settings': developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist',
        'clang': developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++',
        'system-version': Path('/System/Library/CoreServices/SystemVersion.plist'),
        'plist-buddy': Path('/usr/libexec/PlistBuddy'),
    }
    paths.update({name: Path('/usr/bin') / name for name in (
        'xcrun', 'ar', 'strip', 'lipo', 'codesign', 'otool', 'nm', 'git', 'python3', 'xcodebuild')})
    if bootstrap['which']['xcodebuild']['path'] != str(paths['xcodebuild']):
        raise ValueError('retained xcodebuild path differs')
    # Python's selected Xcode interpreter is also part of the bootstrap consumer.
    paths['bootstrap-python'] = _absolute(bootstrap['python']['executable'])
    for path in paths.values():
        _bind(path, rows)
    # Toolchain identity by content, not timestamps: the OS build must match the
    # accepted bootstrap, and the Xcode/SDK/compiler/tool contents must produce the
    # same platform identity the accepted bootstrap recorded. An in-place Xcode
    # update at the same path must not inherit the old key.
    import hashlib
    if current_platform_identity(developer) != bootstrap['bindings'].get('platform-toolchain'):
        raise ValueError('Xcode, SDK or compiler differs from the accepted bootstrap toolchain')
    if (hashlib.sha256(paths['system-version'].read_bytes()).hexdigest()
            != bootstrap['system']['system_version_sha256']):
        raise ValueError('macOS build differs from the accepted bootstrap toolchain')
    document = {
        'schema_version': SCHEMA,
        'scope': 'retained-dependencies-only; no dependency production',
        'retained_inputs': str(retained_inputs), 'source': str(source),
        'platform_identity': _digest(bootstrap['bindings']['platform-toolchain'], 'platform'),
        'component_keys': keys, 'prior_bootstrap': bootstrap,
        'native_package': native_package,
        'compiler_historical_authority': compiler_authority,
        'inherited_system_version_sha256': _digest(bootstrap['system']['system_version_sha256'], 'system'),
        'inherited_xcodebuild_sha256': _digest(bootstrap['which']['xcodebuild']['sha256'], 'xcodebuild'),
        'configuration': {'architecture': 'arm64', 'surface': 'ReleaseFast',
                          'sleigh': 'Release', 'deployment_target': '27.0',
                          **{k: bootstrap['environment'].get(k, v) or v for k, v in scalar_values.items()}},
        'producer_tool_identity': 'Inherited opaque component keys; CMake/Ninja are not current consumers',
        'metadata': [{'path': path, 'snapshot': value} for path, value in sorted(rows.items())],
    }
    revalidate(document)
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(document, stream, sort_keys=True, separators=(',', ':'))
        stream.write('\n')
        stream.flush()
        os.fchmod(stream.fileno(), 0o400)
    revalidate(document)
    return document
