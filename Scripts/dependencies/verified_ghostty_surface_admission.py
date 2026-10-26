#!/usr/bin/env python3
"""Admit the consumed leaves of a surface view already verified by qualification.

The qualifier creates this digest-bound handoff only after its ordinary full
producer verifier. Bootstrap consumes no source/toolchain bytes on this path.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from stage_verified_ghostty_surface import LEAVES, _parse_manifest, _stable_bytes


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def ordinary_path(path, *, directory=False, immutable=False):
    if not path.is_absolute():
        raise ValueError('admission path must be absolute')
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ValueError('indirect admission path')
    metadata = path.lstat()
    if directory:
        if not stat.S_ISDIR(metadata.st_mode):
            raise ValueError('admission directory is not ordinary')
    elif not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ValueError('admission leaf is not ordinary and singly linked')
    if immutable and metadata.st_mode & 0o222:
        raise ValueError('verified admission input is writable')


def observe(source_root):
    ordinary_path(source_root, directory=True, immutable=True)
    artifact_root = source_root / 'macos/GhosttyKit.xcframework'
    manifest = source_root / 'macos/.macscope-ghostty-surface-manifest'
    identity = source_root / '.git/macscope-vendored-inputs'
    for directory in (source_root / 'macos', artifact_root, artifact_root / 'macos-arm64',
                      artifact_root / 'macos-arm64/Headers', source_root / '.git'):
        ordinary_path(directory, directory=True, immutable=True)
    ordinary_path(manifest, immutable=True)
    ordinary_path(identity, immutable=True)
    values, manifest_digest = _parse_manifest(manifest)
    leaves = []
    for role, relative, _, digest_key in LEAVES:
        path = artifact_root / relative
        ordinary_path(path, immutable=True)
        digest = hashlib.sha256(_stable_bytes(path, label=role, maximum_size=512*1024*1024)).hexdigest()
        if digest != values[digest_key]:
            raise ValueError('surface consumed leaf differs from verified manifest')
        leaves.append({'path': relative.as_posix(), 'sha256': digest})
    return {'schema_version': 1, 'source_root': str(source_root),
            'manifest_sha256': manifest_digest,
            'producer_identity_sha256': hashlib.sha256(_stable_bytes(identity, label='producer identity', maximum_size=65536)).hexdigest(),
            'leaves': leaves}


def describe(source_root, descriptor):
    payload = canonical(observe(source_root))
    if descriptor.exists() or descriptor.is_symlink():
        ordinary_path(descriptor, immutable=True)
        if _stable_bytes(descriptor, label='existing admission descriptor') != payload:
            raise ValueError('existing admission descriptor differs')
    else:
        ordinary_path(descriptor.parent, directory=True)
        descriptor_fd, temporary_name = tempfile.mkstemp(prefix='.surface-admission-', dir=descriptor.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor_fd, 'wb') as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            temporary.chmod(0o444)
            os.replace(temporary, descriptor)
        finally:
            temporary.unlink(missing_ok=True)
    return hashlib.sha256(payload).hexdigest()


def admit(source_root, descriptor, expected_sha256):
    ordinary_path(descriptor, immutable=True)
    payload = _stable_bytes(descriptor, label='admission descriptor', maximum_size=65536)
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise ValueError('surface admission descriptor identity differs')
    # Compare canonical bytes directly: duplicate keys, extra fields and stale
    # roots cannot be admitted through permissive JSON decoding.
    if canonical(observe(source_root)) != payload:
        raise ValueError('surface admission differs from verified producer handoff')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--descriptor', type=Path, required=True)
    parser.add_argument('--describe', action='store_true')
    parser.add_argument('--descriptor-sha256')
    args = parser.parse_args()
    if args.describe:
        print(describe(args.source_root, args.descriptor))
    else:
        if not args.descriptor_sha256:
            parser.error('admission requires descriptor identity')
        admit(args.source_root, args.descriptor, args.descriptor_sha256)
        print('GHOSTTY_SURFACE_VERIFIED_ADMISSION=1')

if __name__ == '__main__':
    main()
