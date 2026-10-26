#!/usr/bin/env python3
"""Explicit retained Release cache consumer, separate from native producer inputs."""
from dependency_cache import *

def load_retained_verification_receipt(arguments: argparse.Namespace) -> tuple[dict[str, Any], str]:
    """Reuse an accepted Ghostty verification by its content keys (D1).

    This path cannot produce dependencies or fall back to verification. The
    qualifier first proves unchanged Ghostty source/toolchain declarations; the
    verification receipt is then selected by component, cache key, entry,
    bindings and the ENTRY.json digest. Cache-entry metadata (device, inode,
    timestamps) is never compared across runs and no payload is re-hashed.
    """
    spec = importlib.util.spec_from_file_location(
        'cache_retained_toolchain_admission', Path(__file__).with_name('retained_toolchain_admission.py'))
    toolchain = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(toolchain)
    path = arguments.retained_toolchain_admission
    document = read_canonical_json(path, 'retained toolchain admission')
    if path != Path(document['source']).parent / 'RETAINED_TOOLCHAIN_ADMISSION.json':
        raise CacheError('retained toolchain admission is outside the current run')
    toolchain.revalidate(document)
    component = arguments.component
    domains = {'ghostty-vt': 'verify_ghostty_vt_view',
               'ghostty-surface': 'verify_ghostty_surface_view'}
    if component not in domains or document['component_keys'].get(component) != arguments.key:
        raise CacheError('retained Ghostty component/key differs from admitted source closure')
    prior = read_canonical_json(Path(document['retained_inputs']), 'retained qualification inputs')
    expected_entry = Path(prior['dependency_cache_root']) / 'artifacts/v1' / component / arguments.key
    if arguments.entry != expected_entry:
        raise CacheError('retained Ghostty cache path differs')
    expected = {'platform-toolchain': document['platform_identity'], 'domain-verifier': domains[component]}
    if verification_bindings(arguments.binding) != expected:
        raise CacheError('retained verification bindings differ')
    load_entry_receipt(arguments.entry, component, arguments.key)
    entry_receipt_sha256 = sha256(arguments.entry / 'ENTRY.json')
    candidates = sorted((arguments.verification_root / 'dependency-verifications/v1' / component).glob('*.json'))
    if len(candidates) > 4096:
        raise CacheError('retained verification lookup exceeds its bound')
    matches = []
    for candidate in candidates:
        if HEX64.fullmatch(candidate.stem) is None:
            continue
        value = read_canonical_json(candidate, 'retained verification receipt')
        if (set(value) == VERIFICATION_RECEIPT_FIELDS
                and value.get('schema_version') == VERIFICATION_SCHEMA_VERSION
                and value.get('component') == component and value.get('key') == arguments.key
                and value.get('entry') == str(expected_entry)
                and value.get('entry_receipt_sha256') == entry_receipt_sha256
                and candidate.stem == value.get('verification_key')
                and set(value.get('bindings', {})) == {*expected, 'native-tools'}
                and all(value['bindings'].get(k) == v for k, v in expected.items())
                and HEX64.fullmatch(str(value['bindings']['native-tools']))):
            matches.append(value)
    if len(matches) != 1:
        raise CacheError('retained verification receipt is missing or ambiguous')
    # Content-keyed reuse trusts an immutable entry (D1). A payload that has been made
    # writable may have been edited since verification, so it is not reusable.
    payload = arguments.entry / 'payload'
    if any(path.lstat().st_mode & 0o222 for path in [payload, *payload.rglob('*')] if not path.is_symlink()):
        raise NotReusableError('retained cache payload is writable; not reusable')
    # Within-run guard only: the clone below must not race an entry rewrite.
    arguments._reused_entry_metadata = entry_metadata_digest(arguments.entry)
    return matches[0], 'retained-verification-key:' + matches[0]['verification_key']


def reuse_verified_command(arguments: argparse.Namespace) -> int:
    destination = arguments.destination
    try:
        value, digest = load_retained_verification_receipt(arguments)
    except NotReusableError as error:
        print(str(error))
        return NOT_REUSABLE_STATUS
    document = load_entry_receipt(arguments.entry, arguments.component, arguments.key)
    if not destination.is_absolute() or destination in {Path("/"), Path.home().resolve()}:
        raise CacheError("cache destination must be a dedicated absolute path")
    if destination.exists() or destination.is_symlink():
        raise CacheError("cache destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination_parent = destination.parent.resolve(strict=True)
    if destination_parent == Path("/") or destination_parent != destination.parent:
        raise CacheError("cache destination parent is broad or indirect")
    try:
        clonefile_tree(arguments.entry / "payload", destination)
        if entry_metadata_digest(arguments.entry) != arguments._reused_entry_metadata:
            raise CacheError("cache entry metadata changed while it was cloned")
        records, total_bytes = payload_records(destination, hash_files=False)
        expected = [
            {name: field for name, field in record.items() if name != "sha256"}
            for record in document["payload_records"]
        ]
        if records != expected or total_bytes != document["total_bytes"]:
            raise NotReusableError("run-owned clone differs from the verified entry metadata")
        freeze_tree(destination)
    except NotReusableError as error:
        remove_view(destination)
        print(str(error))
        return NOT_REUSABLE_STATUS
    except BaseException:
        remove_view(destination)
        raise
    print(digest)
    return 0



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['reuse-verified'])
    for name in ('entry', 'verification-root', 'retained-toolchain-admission', 'destination'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('component', 'key'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--binding', action='append', required=True)
    arguments = parser.parse_args()
    try:
        return reuse_verified_command(arguments)
    except (CacheError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
