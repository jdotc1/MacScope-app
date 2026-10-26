#!/usr/bin/env python3
"""Produce one new Release archive from receipt-admitted native inputs.

This is archive production, not CTest, golden, signing or app qualification.
The caller holds the machine heavy-job lock. Old digests are consumed from the
accepted computation receipt; only the two newly produced outputs are hashed.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import time


def read(path):
    return json.loads(Path(path).read_text())


def git(repository, *args):
    return subprocess.check_output(['git', '-C', str(repository), *args])


def admit(golden, prior, manifest):
    if golden.get('passed') is not True or manifest['package']['treeSha256'] != golden['materializationTreeSHA256']:
        raise ValueError('accepted computation/package declarations differ')
    for key in ('wrapperGitRevision', 'goldenSourceSHA256'):
        if re.fullmatch(r'[0-9a-f]{64}', golden.get(key, '')) is None:
            raise ValueError('missing accepted native profile identity')
    if prior.get('proof', {}).get('scope') != 'cp4-production-boundary-only':
        raise ValueError('unsupported retained computation boundary')
    toolchain = prior['toolchain']
    if (toolchain['ARCHS'] != 'arm64' or toolchain['MACOSX_DEPLOYMENT_TARGET'] != '27.0'
            or toolchain['SDK_NAME'] != golden['sdkName'] or toolchain['SDK_VERSION'] != golden['sdkVersion']
            or toolchain['SDK_PRODUCT_BUILD_VERSION'] != golden['sdkBuild']):
        raise ValueError('accepted platform declarations differ')
    return toolchain


def metadata(path):
    value = Path(path).lstat()
    return [getattr(value, key) for key in ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')]


def admitted_materialization(prior, requested):
    record = prior['stagedReceipt']
    if metadata(record['path']) != record['fields']:
        raise ValueError('accepted package receipt metadata changed')
    receipt = read(record['path'])
    root = Path(receipt['root'])
    if requested != root or root.resolve(strict=True) != root:
        raise ValueError('native include root is not the accepted staged package')
    if metadata(root) != receipt['rootFields']:
        raise ValueError('accepted package root metadata changed')
    package = receipt['identity']['package']['relativeRoot']
    for relative, _kind, fields, _digest in receipt['snapshot']:
        if relative in (package, package + '/include') or relative.startswith(package + '/include/'):
            if metadata(root / relative) != fields:
                raise ValueError('accepted native include identity changed: ' + relative)
    if metadata(record['path']) != record['fields']:
        raise ValueError('accepted package receipt changed during consumption')
    return receipt['identity']


def target_sources(cmake):
    patterns = [r'add_library\(macscope_native_decompiler_contract STATIC\s+(.*?)\)',
                r'target_sources\(macscope_native_decompiler_contract PRIVATE\s+(.*?)\)']
    result = []
    for pattern in patterns:
        match = re.search(pattern, cmake, re.S)
        if not match:
            raise ValueError('native target source declaration changed')
        result.extend(match.group(1).split())
    if len(result) != 12 or len(set(result)) != 12 or any(not re.fullmatch(r'src/[A-Za-z0-9]+\.cpp', p) for p in result):
        raise ValueError('unsupported native target membership')
    return result


def release_flags(ninja, sources, sdk):
    """Consume the existing target recipe, refusing any source/define/flag drift."""
    blocks = re.findall(
        r'build CMakeFiles/macscope_native_decompiler_contract\.dir/(src/[^ :]+\.cpp)\.o: [^\n]+\n(.*?)(?=\n(?:build |#)|\Z)',
        ninja, re.S)
    if {name for name, _ in blocks} != set(sources) or len(blocks) != len(sources):
        raise ValueError('retained recipe target membership differs from CMake declaration')
    expected = ['-O3', '-DNDEBUG', '-std=c++20', '-arch', 'arm64', '-isysroot', sdk,
                '-mmacosx-version-min=27.0', '-fPIC', '-fvisibility=hidden', '-fvisibility-inlines-hidden',
                '-Wall', '-Wextra', '-Wpedantic', '-Werror']
    definitions = ['-DMACSCOPE_ENABLE_GHIDRA_PROVIDER=1', '-DMACSCOPE_NATIVE_DECOMPILER_SANITIZER_PROFILE="none"']
    for _, block in blocks:
        values = dict(re.findall(r'^  (CONFIG|FLAGS|DEFINES) = (.*)$', block, re.M))
        actual_defines = [value.replace('\\"', '"') for value in values.get('DEFINES', '').split()]
        if values.get('CONFIG') != 'Release' or shlex.split(values.get('FLAGS', '')) != expected or actual_defines != definitions:
            raise ValueError('retained target recipe differs from the explicit Release contract')
    return expected + definitions


def digest_new(path):
    # Called only for files created in the new, exclusive output directory.
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository-root', type=Path, required=True)
    parser.add_argument('--computation-receipt', type=Path, required=True)
    parser.add_argument('--prior-inputs', type=Path, required=True)
    parser.add_argument('--materialization-root', type=Path, required=True)
    parser.add_argument('--output-root', type=Path, required=True)
    parser.add_argument('--retained-build-root', type=Path, required=True)
    parser.add_argument('--jobs', type=int, choices=(3,), default=3)
    args = parser.parse_args()
    repository = args.repository_root.resolve(strict=True)
    output = args.output_root
    if not output.is_absolute() or output.exists() or repository == output or repository in output.parents:
        raise ValueError('first Release output requires a new external absolute directory')
    golden, prior = read(args.computation_receipt), read(args.prior_inputs)
    if prior['oldGolden']['path'] != str(args.computation_receipt.resolve(strict=True)):
        raise ValueError('computation receipt is not the accepted prior golden')
    manifest = admitted_materialization(prior, args.materialization_root)
    toolchain = admit(golden, prior, manifest)
    head = git(repository, 'rev-parse', 'HEAD').decode().strip()
    # Compare canonical Git declarations to the accepted source commit. No old
    # source leaf is read or hashed to establish the unchanged profile again.
    # This producer never invokes the app provenance writer. Its independent
    # receipt-consumer fixes do not change native computation or compiler inputs.
    paths = [path for path in prior['sources']
             if path != 'Scripts/generate_release_build_provenance.py']
    paths += ['Tools/NativeDecompilerBridge']
    if git(repository, 'diff', '--name-only', prior['head'], head, '--', *paths).strip():
        raise ValueError('native inputs changed since the accepted computation proof')
    output.mkdir(parents=True, mode=0o700)
    started = time.monotonic()
    source = output / 'source'
    prefix = 'Tools/NativeDecompilerBridge/'
    entries = git(repository, 'ls-tree', '-r', '-z', head, '--', prefix).split(b'\0')
    for entry in filter(None, entries):
        metadata, path = entry.decode().split('\t', 1)
        mode, kind, oid = metadata.split()
        relative = path.removeprefix(prefix)
        if kind != 'blob' or mode not in ('100644', '100755') or '..' in Path(relative).parts:
            raise ValueError('native source must be a canonical regular Git blob')
        if relative == 'CMakeLists.txt' or relative.startswith(('src/', 'include/')):
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(git(repository, 'cat-file', 'blob', oid))
    sources = target_sources((source / 'CMakeLists.txt').read_text())
    package = manifest['package']
    values = {
        'RELOCATABLE_MATERIALIZATION': 'true', 'MATERIALIZATION_ROOT': '', 'PACKAGE_ROOT': '',
        'GLOBAL_SPEC_ROOT': '', 'PROCESSOR_SPEC_ROOT': '', 'PACKAGE_RELATIVE_ROOT': package['relativeRoot'],
        'GLOBAL_SPEC_RELATIVE_ROOT': 'share/sleigh/specfiles', 'PROCESSOR_SPEC_RELATIVE_ROOT': package['processorSpecRelativeRoot'],
        'MANIFEST_SHA256': golden['materializationManifestSHA256'], 'TREE_SHA256': golden['materializationTreeSHA256'],
        'SLEIGH_VERSION': '12.1.2', 'GHIDRA_VERSION': golden['engineVersion'], 'GHIDRA_REVISION': golden['engineGitRevision'],
        'WRAPPER_VERSION': golden['wrapperVersion'], 'WRAPPER_REVISION': golden['wrapperGitRevision'],
    }
    template = (source / 'src/GhidraBuildIdentity.hpp.in').read_text()
    for key, value in values.items():
        escaped = value if key == 'RELOCATABLE_MATERIALIZATION' else json.dumps(value)[1:-1]
        template = template.replace('@MACSCOPE_ATTESTED_' + key + '@', escaped)
    if re.search(r'@[A-Z_]+@', template):
        raise ValueError('unhandled native build identity declaration')
    generated = output / 'generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp'
    generated.parent.mkdir(parents=True)
    generated.write_text(template)
    developer = Path(toolchain['DEVELOPER_DIR'])
    compiler = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++'
    libtool = compiler.with_name('libtool')
    version = subprocess.check_output([str(compiler), '--version'], text=True)
    flags = release_flags((args.retained_build_root / 'build.ninja').read_text(), sources, toolchain['SDKROOT'])
    flags += ['-I' + str(source / 'include'), '-I' + str(output / 'generated'),
              '-isystem', str(args.materialization_root / package['relativeRoot'] / 'include/sleigh')]
    objects = output / 'objects'; objects.mkdir()
    commands = [[str(compiler), *flags, '-c', str(source / name), '-o', str(objects / (Path(name).stem + '.o'))] for name in sources]
    archive = output / 'libmacscope_native_decompiler_contract.a'
    archive_command = [str(libtool), '-static', '-o', str(archive), *[command[-1] for command in commands]]
    contract = {'configuration': 'Release', 'compiler': str(compiler), 'compiler_version': version,
                'flags': flags, 'jobs': args.jobs,
                'cmake_source_blob': git(repository, 'rev-parse', head + ':Tools/NativeDecompilerBridge/CMakeLists.txt').decode().strip(),
                'target_sources': sources, 'retained_recipe': str(args.retained_build_root / 'build.ninja'), 'compile_commands': commands, 'archive_command': archive_command}
    (output / 'EXECUTED_BUILD_CONTRACT.json').write_text(json.dumps(contract, indent=2) + '\n')
    def compile_one(command):
        log = output / (Path(command[-1]).stem + '.log')
        with log.open('w') as stream:
            subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(compile_one, commands))
    subprocess.run(archive_command, check=True)
    receipt = {'schema_version': 1, 'scope': 'first-native-Release-archive-production-only',
               'source_commit': head, 'accepted_source_commit': prior['head'], 'wrapper_profile': golden['wrapperGitRevision'],
               'golden_profile': golden['goldenSourceSHA256'], 'computation_receipt': str(args.computation_receipt),
               'computation_scope': 'retained; no CTest or golden replay', 'toolchain': toolchain, 'build_contract': contract,
               'package_identities': {key: golden[key] for key in ('materializationManifestSHA256', 'materializationTreeSHA256', 'decompilerArchiveSHA256', 'sleighArchiveSHA256')},
               'outputs': [{'path': str(path), 'size': path.stat().st_size, 'sha256': digest_new(path)} for path in (archive, generated)],
               'production_seconds': round(time.monotonic() - started, 3), 'worker_or_app_qualified': False}
    receipt_path = output / 'NATIVE_RELEASE_ARCHIVE.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n'); receipt_path.chmod(0o400)
    print(json.dumps({'receipt': str(receipt_path), 'seconds': receipt['production_seconds'], 'objects': len(commands), 'jobs': args.jobs}))


if __name__ == '__main__':
    main()
