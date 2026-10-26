#!/usr/bin/env python3
"""Typed renewal of a MachOKit metadata receipt, never generic binding drift."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import receipt_device_transition as devices

SCOPE='retained-machokit-receipt-renewal-v1'


def receipt_path(root):
    root=Path(root)
    return root.parent/('.'+root.name+'.admission.json')



def receipt_metadata(path):
    fields=devices.metadata(path)
    if fields[2]&0o222 or not 0<fields[4]<=65536:
        raise ValueError('MachOKit renewal receipt must be immutable and bounded')
    return fields


def root_metadata(root):
    root=Path(root)
    if not root.is_absolute() or root.resolve(strict=True)!=root:
        raise ValueError('MachOKit renewal root is not canonical')
    item=root.lstat()
    if not stat.S_ISDIR(item.st_mode) or item.st_uid!=os.getuid() or item.st_mode&0o222:
        raise ValueError('MachOKit renewal root must be owned and read-only')
    return [getattr(item,k) for k in devices.FIELDS]


def semantic_fields(module,root):
    # Every field comes from the same source blob the prior admission used.
    # Callers must establish that exact Git-blob equality before using this.
    return dict(schema_version=1,root=str(root),materialization_schema=module.SCHEMA_VERSION,
        version=module.MACHOKIT_VERSION,revision=module.MACHOKIT_REVISION,
        archive_sha256=module.MACHOKIT_ARCHIVE_SHA256,upstream_tree_sha256=module.MACHOKIT_UPSTREAM_TREE_SHA256,
        tree_sha256=module.MATERIALIZATION_TREE_SHA256,governed_source_identity=module.GOVERNED_SOURCE_IDENTITY,
        components=[vars(component) for component in module.COMPONENTS])


def prove(root,old_binding,new_binding,document,semantics,accepted,observed,root_fields,
          source_blobs,manifest_sha256):
    if len(source_blobs)!=2 or source_blobs[0]!=source_blobs[1] or not source_blobs[0]:
        raise ValueError('MachOKit semantic source differs from prior admission')
    fields=new_binding['fields']
    if (len(fields)!=7 or not stat.S_ISREG(fields[2]) or fields[2]&0o222
            or fields[3]!=1 or not 0<fields[4]<=65536):
        raise ValueError('MachOKit renewed receipt must be immutable ordinary bounded content')
    expected_path=str(receipt_path(root))
    if old_binding['path']!=expected_path or new_binding['path']!=expected_path:
        raise ValueError('MachOKit renewal receipt path differs')
    if document.keys()!=semantics.keys()|{'metadata_sha256'} or any(document[k]!=v for k,v in semantics.items()):
        raise ValueError('MachOKit receipt schema or pinned semantics differ')
    if semantics['root']!=str(root) or 'MATERIALIZATION.json' not in accepted:
        raise ValueError('MachOKit canonical manifest binding is missing')
    if not devices.snapshots_match(root,observed,accepted):
        raise ValueError('MachOKit admitted payload metadata differs')
    if len(root_fields)!=7 or not stat.S_ISDIR(root_fields[2]) or root_fields[2]&0o222:
        raise ValueError('MachOKit root metadata is not read-only directory metadata')
    # Domain identity omits link count; reuse the SAME observed metadata from
    # the normal lease pass, not a second traversal or a dependency payload hash.
    records=[['.',*root_fields[:3],*root_fields[4:]]]
    for relative in sorted(observed,key=PurePosixPath):
        path=PurePosixPath(relative);row=observed[relative];fields=row['fields']
        if path.is_absolute() or '..' in path.parts or path.as_posix()!=relative or row['link'] is not None:
            raise ValueError('MachOKit renewal snapshot contains an indirect path')
        if (len(fields)!=7 or fields[0]!=root_fields[0] or fields[2]&0o222
                or (stat.S_ISREG(fields[2]) and fields[3]!=1)
                or not(stat.S_ISDIR(fields[2]) or stat.S_ISREG(fields[2]))):
            raise ValueError('MachOKit renewal snapshot has invalid device or mode')
        records.append([relative,*fields[:3],*fields[4:]])
    digest=hashlib.sha256(json.dumps(records,separators=(',',':')).encode()).hexdigest()
    if document['metadata_sha256']!=digest:
        raise ValueError('MachOKit renewed metadata document digest differs')
    return dict(scope=SCOPE,root=str(root),old_binding=old_binding,new_binding=new_binding,
        document=document,root_fields=root_fields,semantic_source_blob=source_blobs[0],
        canonical_manifest_sha256=manifest_sha256,
        limits='Original full admission document and historical root stat were not retained. Semantic fields are reconstructed from unchanged previously admitted source; payload uses prior metadata lease. No payload hash or verification replay.')


def validate(proof,value,read):
    root=value['machokit_root']
    if (proof.get('scope')!=SCOPE or proof.get('root')!=root
            or proof.get('canonical_manifest_sha256')!=value['machokit_manifest_sha256']
            or proof['old_binding'] not in value['consulted']
            or proof['old_binding']['path']!=str(receipt_path(root))
            or proof['new_binding']['path']!=str(receipt_path(root))):
        raise ValueError('MachOKit renewal belongs to another admitted component')
    if receipt_metadata(Path(proof['new_binding']['path']))!=proof['new_binding']['fields']:
        raise ValueError('MachOKit renewed receipt binding changed')
    if read(proof['new_binding']['path'])!=proof['document'] or root_metadata(root)!=proof['root_fields']:
        raise ValueError('MachOKit renewal document or admitted root changed')
    return proof['old_binding']
