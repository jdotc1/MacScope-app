#!/usr/bin/env python3
"""Explicit device-number transition for retained receipt metadata only."""
from __future__ import annotations
import json
import os
from pathlib import Path
import stat

ENV = 'MACSCOPE_RECEIPT_DEVICE_TRANSITION'
FIELDS = ('st_dev','st_ino','st_mode','st_nlink','st_size','st_mtime_ns','st_ctime_ns')
SCOPE = 'retained-device-number-transition-v1'


def metadata(path):
    path=Path(path)
    if not path.is_absolute() or path.resolve(strict=True)!=path:
        raise ValueError('device transition requires an unchanged canonical path')
    item=path.lstat()
    if item.st_uid!=os.getuid() or not stat.S_ISREG(item.st_mode) or item.st_nlink!=1:
        raise ValueError('device transition requires an ordinary owned receipt')
    return [getattr(item,k) for k in FIELDS]


def declaration(rows, roots, entries, *, previous, target, observe=metadata, read=None):
    """Read receipt declarations only; never inspect or hash dependency payloads."""
    read=read or (lambda p:json.loads(Path(p).read_text()))
    mapping=None; accepted={}
    for row in rows:
        path=row['path']; old=row['fields']; current=observe(path)
        if len(old)!=7 or len(current)!=7 or old[1:]!=current[1:]:
            raise ValueError('nondevice receipt metadata drift: '+path)
        if path in accepted and accepted[path]!=old:
            raise ValueError('conflicting historical receipt binding: '+path)
        accepted[path]=old
        if old[0]!=current[0]:
            pair=[old[0],current[0]]
            if mapping is not None and mapping!=pair:
                raise ValueError('inconsistent receipt device mapping')
            mapping=pair
    if mapping is None:
        raise ValueError('no device transition to admit')
    # All audited bindings must describe the same old/new filesystem, including
    # otherwise unchanged records; a partial transition is not coherent.
    for path,old in accepted.items():
        current=observe(path)
        if old[0]!=mapping[0] or current!=[mapping[1],*old[1:]]:
            raise ValueError('inconsistent receipt device mapping: '+path)
    for path,expected in entries.items():
        if path not in accepted or read(path)!=expected:
            raise ValueError('accepted entry declaration drift: '+path)
    for root in roots:
        path=Path(root)
        if not path.is_absolute() or path.resolve(strict=True)!=path:
            raise ValueError('noncanonical retained snapshot root')
    return dict(scope=SCOPE,previous_commit=previous,target_commit=target,
        old_device=mapping[0],new_device=mapping[1],bindings=accepted,
        snapshot_roots=sorted(set(roots)),embedded_entries_compared=sorted(entries),
        limits='No historical full VIEW or volume UUID proof. Other immutable entries retain exact nondevice metadata evidence; no payload reverification.')


def load(path):
    path=Path(path); before=metadata(path)
    if before[2]&0o222 or before[4]>128*1024*1024:
        raise ValueError('device transition receipt must be bounded and immutable')
    value=json.loads(path.read_text())
    if metadata(path)!=before or value.get('scope')!=SCOPE:
        raise ValueError('device transition receipt changed or has invalid scope')
    prior=value.get('prior_transition')
    if prior is not None and metadata(prior['path'])!=prior['fields']:
        raise ValueError('prior device transition audit changed')
    return value



def active():
    name=os.environ.get(ENV)
    return load(name) if name else None


def successor(path,previous,target):
    value=load(path)
    if value['target_commit']!=previous or previous==target:
        raise ValueError('device audit continuation requires the exact prior consumer')
    return dict(value,previous_commit=previous,target_commit=target,
                prior_transition={'path':str(path),'fields':metadata(path)})


def fields_match(path,current,expected, *, transition=None, snapshot_root=None):
    if current==expected:return True
    value=transition if transition is not None else active()
    if value is None or len(current)!=7 or len(expected)!=7:return False
    path=Path(path)
    if path.resolve(strict=True)!=path:return False
    if snapshot_root is None:
        if value['bindings'].get(str(path))!=expected:return False
    else:
        root=Path(snapshot_root)
        if str(root) not in value['snapshot_roots'] or not path.is_relative_to(root):return False
    return (expected[0]==value['old_device'] and current[0]==value['new_device']
            and current[1:]==expected[1:])


def snapshots_match(root,current,expected):
    if current.keys()!=expected.keys():return False
    transition=active()
    for relative,old in expected.items():
        new=current[relative]
        if isinstance(old,dict):
            if old.get('link')!=new.get('link'):return False
            old,new=old['fields'],new['fields']
        path=Path(root)/relative
        # Contained symlinks keep their literal target and inode metadata. The
        # snapshot producer already enforces containment; never resolve the leaf.
        if stat.S_ISLNK(old[2]):
            if new==old:continue
            if (transition is None or str(root) not in transition['snapshot_roots']
                    or old[0]!=transition['old_device'] or new[0]!=transition['new_device']
                    or old[1:]!=new[1:]):return False
        elif not fields_match(path,new,old,transition=transition,snapshot_root=root):return False
    return True
