#!/usr/bin/env python3
"""Derive a developer SLEIGH cache view for a governed resource-only change.

The parent is admitted by its existing metadata-bound verification receipt.
Unchanged bytes are cloned and retain their recorded digests. Only new Git
blobs are read, and only changed language resources replace package members.
This is developer evidence, never qualification or Release evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev_dependency_cache as DEV

CACHE = DEV.CACHE
COMPONENT = "sleigh-native-source"
RESOURCE = "ThirdParty/SleighNative/AARCH64/"
PACKAGE = "materialization/package/"
LANGUAGE = "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"


def listing(repository: Path, ref: str) -> list[tuple[str, str, str]]:
    if ref.startswith("-"):
        raise DEV.DevCacheError("parent ref must name a Git commit")
    raw = DEV.git(repository, "ls-tree", "-rz", ref, "--", *DEV.COMPONENTS[COMPONENT]["prefixes"])
    result = []
    for item in raw.split(b"\0"):
        if not item:
            continue
        header, path = item.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise DEV.DevCacheError("derivation requires ordinary governed Git blobs")
        result.append((os.fsdecode(path), mode, oid))
    return sorted(result, key=lambda item: os.fsencode(item[0]))


METADATA_FIELDS = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")


def metadata(path: Path):
    return [getattr(path.lstat(), name) for name in METADATA_FIELDS]


def supplied_records(path: Path | None, repository: Path):
    if path is None:
        return {}
    value = DEV.read_memo(path)
    if not isinstance(value, dict) or value.get("schema_version") != 1 or not isinstance(value.get("records"), list):
        raise DEV.DevCacheError("new digest receipt is unsafe or malformed")
    result = {}
    for record in value["records"]:
        relative = CACHE.canonical_relative(record["path"], "new digest receipt path")
        if not relative.startswith("ThirdParty/SleighNative/"):
            raise DEV.DevCacheError("new digest receipt escapes governed dependency")
        identity = (relative, record["mode"], record["blob_oid"])
        if identity in result or CACHE.HEX64.fullmatch(record["sha256"]) is None:
            raise DEV.DevCacheError("new digest receipt has duplicate or malformed identity")
        if record.get("metadata") != metadata(repository / relative):
            raise DEV.DevCacheError(f"new digest receipt metadata is stale: {relative}")
        if record["size"] != (repository / relative).stat().st_size:
            raise DEV.DevCacheError(f"new digest receipt size is stale: {relative}")
        result[identity] = record
    return result


def prime_records(repository: Path, view_root: Path, entries: list[tuple[str, str, str]], *, allow_new: bool, supplied=None):
    known = {}
    for path in (view_root / ".memo").glob("records-*.json"):
        memo = DEV.read_memo(path)
        if isinstance(memo, dict) and memo.get("schema_version") == DEV.MEMO_SCHEMA_VERSION:
            for record in memo.get("records", []):
                identity = (record.get("path"), record.get("mode"), record.get("blob_oid"))
                if identity in known and known[identity] != record:
                    raise DEV.DevCacheError("canonical record memo identities disagree")
                known[identity] = record
    for identity, record in (supplied or {}).items():
        if identity in entries and identity not in known:
            known[identity] = {key: record[key] for key in ("path", "mode", "blob_oid", "size", "sha256")}
    missing = [item for item in entries if item not in known]
    if missing and not allow_new:
        raise DEV.Unavailable("parent source records are not retained; cannot reuse verification")
    for record in DEV.blob_records(repository, missing) if missing else []:
        known[(record["path"], record["mode"], record["blob_oid"])] = record
    records = [known[item] for item in entries]
    digest = DEV.sha256_bytes(DEV.canonical_json([list(item) for item in entries]))
    DEV.write_memo(DEV.memo_path(view_root, f"records-{digest}.json"),
                   {"schema_version": DEV.MEMO_SCHEMA_VERSION, "records": records})
    return records


def key_for(repository: Path, view_root: Path, records) -> str:
    original = DEV.source_records
    try:
        DEV.source_records = lambda *_: records
        return DEV.component_key(COMPONENT, repository, view_root)
    finally:
        DEV.source_records = original


def admit_delta(before, after):
    old, new = ({item[0]: item[1:] for item in entries} for entries in (before, after))
    changed = {path for path in old.keys() | new.keys() if old.get(path) != new.get(path)}
    # Admission is an allowlist: engine, archive, compiler, licensing and
    # baseline authority cannot inherit an earlier resource-build receipt.
    owned_documents = {"PATCHES.md", "README.md", "RX17_SEMANTICS.md",
                       "RX18_SME_DECODE.md", "T21_NATIVE_RECEIPTS.md"}
    for path in changed:
        relative = path.removeprefix("ThirdParty/SleighNative/")
        admitted = path.startswith("ThirdParty/SleighNative/") and (
            relative.startswith(("AARCH64/", "patches/aarch64/", "tests/"))
            or relative in owned_documents
            or relative == "PATCHED_RESOURCES.json"
            or ("/" not in relative and relative.endswith("_VALIDATION.json")
                and relative.startswith(("RX", "T", "CP")))
        )
        if not admitted:
            raise DEV.Unavailable(f"resource derivation cannot change native or baseline authority: {path}")
    if not any(path.startswith(RESOURCE) for path in changed):
        raise DEV.Unavailable("resource derivation requires a governed AARCH64 change")
    if {path for path in old if path.startswith(RESOURCE)} != {path for path in new if path.startswith(RESOURCE)}:
        raise DEV.Unavailable("resource derivation requires the same governed resource file set")
    return changed


def admit_pin_delta(before, after):
    mutable = {"cp1Status", "patchSeries", "patched"}
    if not isinstance(before, dict) or not isinstance(after, dict):
        raise DEV.Unavailable("resource pins must retain their authority object")
    if {key: value for key, value in before.items() if key not in mutable} != {
            key: value for key, value in after.items() if key not in mutable}:
        raise DEV.Unavailable("resource pins changed immutable compiler, engine or baseline authority")
    old_files = before.get("patched", {}).get("changedFiles", {})
    new_files = after.get("patched", {}).get("changedFiles", {})
    if any(path not in new_files or record.get("baselineSha256") != new_files[path].get("baselineSha256")
           for path, record in old_files.items()):
        raise DEV.Unavailable("resource pins changed an existing baseline file identity")


def records_with_evidence(payload: Path, prior, replacements):
    observed, _ = CACHE.payload_records(payload, hash_files=False)
    retained = {record["path"]: record for record in prior}
    result = []
    for record in observed:
        if record["kind"] == "file":
            previous = replacements.get(record["path"], retained.get(record["path"]))
            if previous is None or any(record[key] != previous[key] for key in ("kind", "size", "executable")):
                raise DEV.DevCacheError(f"derived payload metadata differs: {record['path']}")
            record["sha256"] = previous["sha256"]
        result.append(record)
    if {r["path"] for r in result} != {r["path"] for r in prior}:
        raise DEV.DevCacheError("derived payload member set changed")
    return result


def derive(arguments):
    repository = arguments.repository_root.resolve(strict=True)
    cache_root, view_root = DEV.roots(arguments)
    DEV.require_clean(repository, DEV.COMPONENTS[COMPONENT]["prefixes"])
    before = listing(repository, arguments.parent_ref)
    after = listing(repository, "HEAD")
    changed = admit_delta(before, after)
    pins = "ThirdParty/SleighNative/PATCHED_RESOURCES.json"
    if pins in changed:
        old_pins = json.loads(DEV.git(repository, "show", f"{arguments.parent_ref}:{pins}"))
        new_pins = json.loads(DEV.git(repository, "show", f"HEAD:{pins}"))
        admit_pin_delta(old_pins, new_pins)
    parent_records = prime_records(repository, view_root, before, allow_new=False)
    if key_for(repository, view_root, parent_records) != arguments.parent_key:
        raise DEV.Unavailable("parent key does not bind unchanged platform, tools and build settings")
    parent_entry = cache_root / "artifacts/v1" / COMPONENT / arguments.parent_key
    parent_directory = view_root / COMPONENT / arguments.parent_key
    parent_view = parent_directory / "SleighNativeSource"
    parent_receipt = parent_directory / "VIEW.json"
    accepted = DEV.view_receipt_valid(parent_receipt, parent_entry, parent_view, COMPONENT, arguments.parent_key)
    if accepted is None:
        raise DEV.Unavailable("parent verification receipt is missing or stale")
    parent_manifest = CACHE.load_entry_receipt(parent_entry, COMPONENT, arguments.parent_key)
    supplied = supplied_records(arguments.new_digest_receipt, repository)
    if any(identity not in after for identity in supplied):
        raise DEV.DevCacheError("new digest receipt is not bound to the current Git source")
    current_records = prime_records(repository, view_root, after, allow_new=True, supplied=supplied)
    key = key_for(repository, view_root, current_records)
    entry = cache_root / "artifacts/v1" / COMPONENT / key
    directory = view_root / COMPONENT / key
    view = directory / "SleighNativeSource"
    if entry.exists() or directory.exists():
        receipt = DEV.view_receipt_valid(directory / "VIEW.json", entry, view, COMPONENT, key)
        if receipt is None:
            raise DEV.DevCacheError("existing derivative has no reusable view; refusing verification")
        return {"key": key, "status": "view-reused", "view": view, "receipt": receipt}
    lock = cache_root / "locks/v1" / COMPONENT / f"{key}.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.mkdir()  # Never compete with another producer or silently steal its lock.
    staging = None
    view_staging = None
    try:
        staging = Path(tempfile.mkdtemp(prefix=f".{key}.derive.", dir=entry.parent))
        payload = staging / "payload"
        CACHE.clonefile_tree(parent_view, payload)
        for path in [payload, *payload.rglob("*")]:
            path.chmod(0o755 if path.is_dir() else (0o755 if path.stat().st_mode & 0o111 else 0o644))
        replacements = {}
        by_path = {record["path"]: record for record in current_records}
        for path in sorted(changed):
            if not path.startswith(RESOURCE):
                continue
            record = by_path[path]
            relative = PACKAGE + LANGUAGE + path.removeprefix(RESOURCE)
            destination = payload / relative
            # Canonical Git/LFS source records bind the copy. New resource bytes
            # are read once here; unchanged resources retain parent evidence.
            identity_key = (path, record["mode"], record["blob_oid"])
            observed_before = metadata(repository / path)
            data = (repository / path).read_bytes()
            if len(data) != record["size"] or metadata(repository / path) != observed_before:
                raise DEV.DevCacheError(f"changed resource metadata moved while copying: {path}")
            if identity_key in supplied:
                if supplied[identity_key]["metadata"] != observed_before:
                    raise DEV.DevCacheError(f"changed resource digest receipt is stale: {path}")
            elif hashlib.sha256(data).hexdigest() != record["sha256"]:
                raise DEV.DevCacheError(f"changed resource differs from canonical Git identity: {path}")
            destination.write_bytes(data)
            replacements[relative] = {"kind": "file", "path": relative, "size": len(data),
                                      "executable": False, "sha256": record["sha256"]}
        records = records_with_evidence(payload, parent_manifest["payload_records"], replacements)
        evidence = {r["path"].removeprefix(PACKAGE): (r["size"], r["sha256"])
                    for r in records if r["kind"] == "file" and r["path"].startswith(PACKAGE)}
        sys.path.insert(0, str(repository / "Scripts/native-decompiler-direct"))
        import sleigh_package as package_module
        identity_path = payload / "materialization/MATERIALIZATION.json"
        identity = json.loads(identity_path.read_bytes())
        package_identity = package_module.analyze_package(payload / PACKAGE, _digest_evidence=evidence)
        identity["package"] = {**package_identity, "relativeRoot": "package"}
        identity_path.write_bytes(DEV.canonical_json(identity))
        source_path = payload / "SOURCE_BUILD_MATERIALIZATION.json"
        source = json.loads(source_path.read_bytes())
        source["package"] = {key: package_identity[key] for key in ("fileCount", "totalBytes", "treeSha256")}
        source["criticalFileSha256"] = {path: evidence[path][1] for path in source["criticalFileSha256"]}
        source_path.write_text(json.dumps(source, sort_keys=True) + "\n")
        package_module.verify_materialization(payload / "materialization", _package_digest_evidence=evidence)
        for relative in ("materialization/MATERIALIZATION.json", "SOURCE_BUILD_MATERIALIZATION.json"):
            data = (payload / relative).read_bytes()
            replacements[relative] = {"kind": "file", "path": relative, "size": len(data),
                                      "executable": False, "sha256": hashlib.sha256(data).hexdigest()}
        records = records_with_evidence(payload, parent_manifest["payload_records"], replacements)
        if DEV.view_receipt_valid(parent_receipt, parent_entry, parent_view, COMPONENT, arguments.parent_key) != accepted:
            raise DEV.DevCacheError("parent evidence changed during derivation")
        document = {"component": COMPONENT, "key": key, "schema_version": CACHE.SCHEMA_VERSION,
                    "payload_records": records, "payload_tree_sha256": CACHE.payload_tree_digest(records),
                    "file_count": sum(r["kind"] == "file" for r in records),
                    "total_bytes": sum(r.get("size", 0) for r in records)}
        (staging / "ENTRY.json").write_bytes(DEV.canonical_json(document))
        CACHE.freeze_tree(staging)
        os.rename(staging, entry)
        staging = None
        view_staging = Path(tempfile.mkdtemp(prefix=f".{key}.derive.", dir=directory.parent))
        staged_view = view_staging / "SleighNativeSource"
        CACHE.clonefile_tree(entry / "payload", staged_view)
        receipt = {"component": COMPONENT, "key": key, "schema_version": DEV.VIEW_SCHEMA_VERSION,
                   "descriptors": {}, "entry": str(entry), "view": str(view),
                   "entry_receipt_sha256": CACHE.sha256(entry / "ENTRY.json"),
                   "entry_metadata_sha256": CACHE.entry_metadata_digest(entry),
                   "view_metadata_sha256": CACHE.entry_metadata_digest(staged_view),
                   "entry_status": "derived-resource-overlay",
                   "verification": "parent metadata-bound receipt + changed canonical resources + digest-evidence package validation",
                   "parent": {"key": arguments.parent_key, "ref": arguments.parent_ref,
                              "receipt": str(parent_receipt), "entry_receipt_sha256": accepted["entry_receipt_sha256"]},
                   "changed_resources": sorted(path for path in changed if path.startswith(RESOURCE))}
        temporary = view_staging / "VIEW.json"
        temporary.write_bytes(DEV.canonical_json(receipt))
        temporary.chmod(0o444)
        os.rename(view_staging, directory)
        view_staging = None
        return {"key": key, "status": "derived-resource-overlay", "view": view, "receipt": receipt}
    finally:
        if staging is not None:
            DEV.remove_tree(staging)
        if view_staging is not None:
            DEV.remove_tree(view_staging)
        lock.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--parent-ref", required=True)
    parser.add_argument("--parent-key", required=True)
    parser.add_argument("--new-digest-receipt", type=Path, help="owner-created new-leaf digest records bound to Git blobs and lstat metadata")
    parser.add_argument("--cache-root", type=Path)
    parser.add_argument("--view-root", type=Path)
    arguments = parser.parse_args()
    try:
        for line in DEV.contract(COMPONENT, derive(arguments)):
            print(line)
        return 0
    except (DEV.DevCacheError, DEV.Unavailable, CACHE.CacheError, OSError, ValueError) as error:
        print(f"SLEIGH resource derivation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
