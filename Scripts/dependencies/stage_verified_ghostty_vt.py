#!/usr/bin/env python3
"""Bind and stage the complete verified VT consumer closure; never invoke a builder."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
from stage_verified_ghostty_surface import _stable_bytes, _copy_verified, _canonical_path


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def consumed_source(root, relative):
    path = root / relative
    # Zig publishes this one governed alias; consumers receive ordinary bytes.
    if relative == 'lib/libghostty-vt.dylib' and path.is_symlink():
        target = os.readlink(path)
        if target == 'libghostty-vt.0.dylib':
            major = root / 'lib/libghostty-vt.0.dylib'
            if not major.is_symlink() or os.readlink(major) != 'libghostty-vt.0.1.0.dylib':
                raise ValueError('unexpected VT major-version alias')
        elif target != 'libghostty-vt.0.1.0.dylib':
            raise ValueError('unexpected VT dylib alias')
        path = root / 'lib/libghostty-vt.0.1.0.dylib'
    current = root
    for part in path.relative_to(root).parts:
        current /= part
        if current.is_symlink():
            raise ValueError('indirect artifact member')
    return path


def records(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('artifact root must be an ordinary directory')
    paths = [root / 'lib/libghostty-vt.dylib', root / 'lib/.macscope-ghostty-vt-manifest']
    include = root / 'include'
    if include.is_symlink() or not include.is_dir():
        raise ValueError('missing ordinary include closure')
    paths += sorted(include.rglob('*'))
    if len(paths) > 10000:
        raise ValueError('artifact member bound exceeded')
    result = []
    total = 0
    for path in paths:
        relative = path.relative_to(root).as_posix()
        path = consumed_source(root, relative)
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ValueError('nonordinary artifact member')
        payload = _stable_bytes(path, label=relative, maximum_size=128 * 1024 * 1024)
        total += len(payload)
        if total > 512 * 1024 * 1024:
            raise ValueError('artifact aggregate bound exceeded')
        result.append({'path': relative, 'sha256': hashlib.sha256(payload).hexdigest()})
    if not {'include/ghostty/vt.h', 'include/module.modulemap'} <= {r['path'] for r in result}:
        raise ValueError('incomplete header closure')
    return sorted(result, key=lambda r: r['path'])


def describe(root, output):
    value = {'schema_version': 1, 'leaves': records(root)}
    payload = canonical(value)
    if output.exists() or output.is_symlink():
        if _stable_bytes(output, label='existing VT descriptor') != payload:
            raise ValueError('existing VT descriptor differs')
    else:
        with output.open('xb') as stream:
            stream.write(payload)
        output.chmod(0o444)
    return hashlib.sha256(payload).hexdigest()


def stage(root, descriptor, expected, destination, allowed):
    root = _canonical_path(root, label='artifact root', must_exist=True)
    allowed = _canonical_path(allowed, label='allowed root', must_exist=True)
    destination = _canonical_path(destination, label='destination', must_exist=False)
    if destination.parent != allowed or destination.name != 'artifacts':
        raise ValueError('destination must be build-owned artifacts child')
    payload = _stable_bytes(descriptor, label='VT descriptor', maximum_size=1024*1024)
    if hashlib.sha256(payload).hexdigest() != expected:
        raise ValueError('descriptor identity differs')
    value = json.loads(payload)
    if canonical(value) != payload or set(value) != {'schema_version', 'leaves'} or value['schema_version'] != 1:
        raise ValueError('invalid descriptor')
    if records(root) != value['leaves']:
        raise ValueError('verified artifact closure changed')
    lock = os.open(allowed / '.vt-stage.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    temporary = None
    backup = None
    try:
        if not stat.S_ISREG(os.fstat(lock).st_mode) or os.fstat(lock).st_nlink != 1:
            raise ValueError('unsafe stage lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_dir():
                raise ValueError('unsafe destination')
            # Xcode may precreate declared output directories before this phase.
            # Repair only ordinary incomplete trees; never replace unsafe members.
            existing = list(destination.rglob('*'))
            if len(existing) > 10000:
                raise ValueError('existing artifact member bound exceeded')
            for member in existing:
                metadata = member.lstat()
                if not (stat.S_ISDIR(metadata.st_mode) or
                        (stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1)):
                    raise ValueError('unsafe existing artifact member')
            complete = all((destination / leaf['path']).is_file() for leaf in value['leaves'])
            if complete and records(destination) == value['leaves']:
                return
        temporary = Path(tempfile.mkdtemp(prefix='.vt-stage-', dir=allowed))
        for leaf in value['leaves']:
            _copy_verified(consumed_source(root, leaf['path']), temporary / leaf['path'], expected_sha256=leaf['sha256'], label=leaf['path'])
        if records(temporary) != value['leaves']:
            raise ValueError('staged closure differs')
        if destination.exists():
            backup = allowed / ('.vt-previous-' + temporary.name)
            os.replace(destination, backup)
        try:
            os.replace(temporary, destination)
            temporary = None
        except BaseException:
            if backup is not None:
                os.replace(backup, destination)
                backup = None
            raise
        if backup is not None:
            shutil.rmtree(backup)
    finally:
        if temporary is not None:
            shutil.rmtree(temporary)
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifact-root', type=Path, required=True)
    parser.add_argument('--descriptor', type=Path, required=True)
    parser.add_argument('--describe', action='store_true')
    parser.add_argument('--descriptor-sha256')
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--allowed-root', type=Path)
    args = parser.parse_args()
    if args.describe:
        print(describe(args.artifact_root, args.descriptor))
    else:
        if not all((args.descriptor_sha256, args.destination, args.allowed_root)):
            parser.error('staging requires descriptor identity, destination and allowed root')
        stage(args.artifact_root, args.descriptor, args.descriptor_sha256, args.destination, args.allowed_root)

if __name__ == '__main__':
    main()
