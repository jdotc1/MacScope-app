#!/usr/bin/env python3
"""Offline verification and source-linking for the governed MachOKit closure."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


SCHEMA_VERSION = 3
MAX_TREE_FILES = 75_000
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TREE_BYTES = 384 * 1024 * 1024
MACHOKIT_VERSION = "0.52.2"
MACHOKIT_REVISION = "773e10797abc53914b94c2ee8c6f40f5da0b06eb"
MACHOKIT_ARCHIVE_SHA256 = "2e6d429f248ac3f01b896379c3c77518858a2213ef3da0d89939d112de9fd945"
MACHOKIT_UPSTREAM_TREE_SHA256 = "0a0bdc104b7f20c3f34ef595e113152cfc78ec496e96e14cb4957cf4d81dd038"
GOVERNED_SOURCE_IDENTITY = "b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea"
MATERIALIZATION_TREE_SHA256 = "e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950"
LOCAL_MANIFEST_PATCH = "ThirdParty/MachOKit/PATCHES.md"
OMITTED_MACHOKIT_SUBTREES = ("Benchmarks",)
REVIEWED_REMOTE_PACKAGE_DEPENDENCIES: frozenset[tuple[str, str]] = frozenset()
BUILD_IDENTITY_RELATIVE_PATH = (
    "MachOKit/Sources/MachOKit/MacScopeMachOKitBuildIdentity.swift"
)
BUILD_IDENTITY_PREFIX = "MACSCOPE_MACHOKIT_BUILD_ID"
GOVERNED_SOURCE_EXCLUSIONS = frozenset(
    {"MATERIALIZATION.json", BUILD_IDENTITY_RELATIVE_PATH}
)
REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class ComponentIdentity:
    name: str
    repository: str
    revision: str
    git_tree: str
    materialized_tree_sha256: str


COMPONENTS = (
    ComponentIdentity(
        "swift-fileio",
        "https://github.com/p-x9/swift-fileio.git",
        "d589ff3966f9f064574780f527449a946736b989",
        "71314646e1831c21a9480f566396c6a77b7b6d32",
        "07d7a1b2821566423aee3677c7f1fc066621dcd0dbe4c9b608c092040a304da4",
    ),
    ComponentIdentity(
        "swift-fileio-extra",
        "https://github.com/p-x9/swift-fileio-extra.git",
        "8d83506dd4dff737807d90dbf2264096ed98c7a7",
        "95164a7178898951a246c4ce618de91989f8da7a",
        "3556201836c8410c92f069c8212e1429b83d37b165f8db9aa6e7289dca7f9c5b",
    ),
    ComponentIdentity(
        "swift-binary-parse-support",
        "https://github.com/p-x9/swift-binary-parse-support.git",
        "5fb96b503672ea4752eded6b4e301fd87214b03b",
        "5815e8dafb8899121841b11451502773a9a8fa96",
        "202d95c8aaca323d1f47db470e7a451a66f1d125711cd13c5a928da0f474eeb3",
    ),
)

EXPECTED_ROOT_ENTRIES = frozenset(
    {"MachOKit", "MATERIALIZATION.json", *(component.name for component in COMPONENTS)}
)


class MachOKitSourceIdentityError(RuntimeError):
    pass


def _ordinary_files(root: Path) -> list[Path]:
    files: list[Path] = []
    total_bytes = 0
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part.lower().endswith(".xcframework") for part in relative.parts):
            raise MachOKitSourceIdentityError(
                f"XCFramework content violates the direct-source contract: {relative}"
            )
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise MachOKitSourceIdentityError(
                f"materialized tree contains a symbolic link: {relative}"
            )
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise MachOKitSourceIdentityError(
                f"materialized tree contains a nonordinary file: {relative}"
            )
        if metadata.st_nlink != 1:
            raise MachOKitSourceIdentityError(
                f"materialized tree contains a multiply linked file: {relative}"
            )
        if metadata.st_size > MAX_FILE_BYTES:
            raise MachOKitSourceIdentityError(
                f"materialized file exceeds the size bound: {relative}"
            )
        total_bytes += metadata.st_size
        if total_bytes > MAX_TREE_BYTES:
            raise MachOKitSourceIdentityError("materialized tree exceeds the total-byte bound")
        files.append(path)
        if len(files) > MAX_TREE_FILES:
            raise MachOKitSourceIdentityError("materialized tree exceeds the file-count bound")
    return sorted(files, key=lambda item: os.fsencode(item.relative_to(root).as_posix()))


def tree_digest(root: Path, *, excluded: frozenset[str] = frozenset()) -> str:
    digest = hashlib.sha256()
    for path in _ordinary_files(root):
        relative_text = path.relative_to(root).as_posix()
        if relative_text in excluded:
            continue
        relative = relative_text.encode("utf-8")
        payload = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def governed_source_identity(root: Path) -> str:
    return tree_digest(root, excluded=GOVERNED_SOURCE_EXCLUSIONS)


def compiled_build_marker(identity: str) -> str:
    return f"{BUILD_IDENTITY_PREFIX}:{MACHOKIT_REVISION}:{identity}"


def compiled_identity_source(identity: str) -> str:
    marker = compiled_build_marker(identity)
    return (
        "// Generated deterministically by MacScope's reviewed MachOKit materializer.\n"
        "// Do not edit this file in a published materialization.\n\n"
        "public enum MacScopeMachOKitBuildIdentity {\n"
        f'    public static let marker = "{marker}"\n'
        "}\n"
    )


def verify_compiled_build_identity(
    root: Path,
    manifest: dict[str, object],
    *,
    enforce_reviewed_digest: bool = True,
) -> None:
    identity = governed_source_identity(root)
    if enforce_reviewed_digest and identity != GOVERNED_SOURCE_IDENTITY:
        raise MachOKitSourceIdentityError(
            "governed MachOKit source differs from reviewed input"
        )
    if manifest.get("governed_source_identity") != identity:
        raise MachOKitSourceIdentityError("governed MachOKit source identity mismatch")
    marker = compiled_build_marker(identity)
    if manifest.get("compiled_build_marker") != marker:
        raise MachOKitSourceIdentityError("compiled MachOKit build marker receipt mismatch")
    path = root / BUILD_IDENTITY_RELATIVE_PATH
    if path.is_symlink() or not path.is_file():
        raise MachOKitSourceIdentityError(
            "compiled MachOKit build identity source is missing or unsafe"
        )
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise MachOKitSourceIdentityError(
            f"compiled MachOKit build identity source is unreadable: {error}"
        ) from error
    if source != compiled_identity_source(identity) or source.count(marker) != 1:
        raise MachOKitSourceIdentityError("compiled MachOKit build identity source drifted")


def verify_read_only_shape(root: Path) -> None:
    for path in [root, *root.rglob("*")]:
        metadata = path.lstat()
        if metadata.st_mode & 0o222:
            relative = "." if path == root else path.relative_to(root).as_posix()
            raise MachOKitSourceIdentityError(
                f"published materialization path is writable: {relative}"
            )


def _read_manifest(root: Path) -> dict[str, object]:
    path = root / "MATERIALIZATION.json"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise MachOKitSourceIdentityError("MATERIALIZATION.json is missing, unsafe, or oversized")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MachOKitSourceIdentityError(f"invalid MATERIALIZATION.json: {error}") from error
    if not isinstance(payload, dict):
        raise MachOKitSourceIdentityError("MATERIALIZATION.json must contain an object")
    return payload


def _verify_root(
    root: Path,
    *,
    quiet: bool = False,
    enforce_read_only: bool,
) -> Path:
    requested = root.expanduser()
    if requested.is_symlink():
        raise MachOKitSourceIdentityError("MachOKit materialization root is not a safe directory")
    root = requested.resolve(strict=True)
    if not root.is_dir():
        raise MachOKitSourceIdentityError("MachOKit materialization root is not a safe directory")
    observed_entries = {item.name for item in root.iterdir()}
    extra = sorted(observed_entries - EXPECTED_ROOT_ENTRIES)
    missing = sorted(EXPECTED_ROOT_ENTRIES - observed_entries)
    if extra:
        raise MachOKitSourceIdentityError(f"unexpected root entry: {extra[0]}")
    if missing:
        raise MachOKitSourceIdentityError(f"missing root entry: {missing[0]}")
    _ordinary_files(root)
    manifest = _read_manifest(root)
    if set(manifest) != {
        "schema_version",
        "integration_form",
        "provider",
        "local_manifest_patch",
        "components",
        "governed_source_identity",
        "compiled_build_marker",
        "tree_sha256",
    } or manifest.get("schema_version") != SCHEMA_VERSION:
        raise MachOKitSourceIdentityError("unsupported or malformed MachOKit materialization schema")
    if manifest.get("integration_form") != "direct-source":
        raise MachOKitSourceIdentityError("MachOKit integration form must be direct-source")
    if manifest.get("provider") != {
        "id": "p-x9/MachOKit",
        "version": MACHOKIT_VERSION,
        "revision": MACHOKIT_REVISION,
        "source_archive_sha256": MACHOKIT_ARCHIVE_SHA256,
        "upstream_tree_sha256": MACHOKIT_UPSTREAM_TREE_SHA256,
    }:
        raise MachOKitSourceIdentityError(
            "MachOKit provider identity does not match the reviewed contract"
        )
    if manifest.get("local_manifest_patch") != LOCAL_MANIFEST_PATCH:
        raise MachOKitSourceIdentityError("MachOKit local-manifest patch identity is incorrect")
    verify_compiled_build_identity(root, manifest)
    components = manifest.get("components")
    if not isinstance(components, list) or len(components) != len(COMPONENTS):
        raise MachOKitSourceIdentityError("materialized transitive component set is incomplete")
    expected_record_keys = {
        "name",
        "repository",
        "revision",
        "git_tree",
        "acquisition",
        "tree_sha256",
    }
    for expected, record in zip(COMPONENTS, components):
        if not isinstance(record, dict) or set(record) != expected_record_keys:
            raise MachOKitSourceIdentityError("materialized transitive component record is malformed")
        if (
            record.get("name") != expected.name
            or record.get("repository") != expected.repository
            or record.get("revision") != expected.revision
            or record.get("git_tree") != expected.git_tree
            or record.get("acquisition") != "local-clean-git-checkout"
        ):
            raise MachOKitSourceIdentityError(
                f"materialized identity mismatch: {expected.name}"
            )
        component_root = root / expected.name
        if component_root.is_symlink() or not component_root.is_dir():
            raise MachOKitSourceIdentityError(
                f"materialized component is missing or unsafe: {expected.name}"
            )
        actual_component_tree = tree_digest(component_root)
        if record.get("tree_sha256") != actual_component_tree:
            raise MachOKitSourceIdentityError(
                f"materialized tree checksum mismatch: {expected.name}"
            )
        if actual_component_tree != expected.materialized_tree_sha256:
            raise MachOKitSourceIdentityError(
                f"materialized tree differs from reviewed output: {expected.name}"
            )
    if not (root / "MachOKit" / "Package.swift").is_file():
        raise MachOKitSourceIdentityError("MachOKit direct-source package manifest is missing")
    for relative in OMITTED_MACHOKIT_SUBTREES:
        candidate = root / "MachOKit" / relative
        if candidate.exists() or candidate.is_symlink():
            raise MachOKitSourceIdentityError(
                f"unadmitted MachOKit subtree remains: MachOKit/{relative}"
            )
    for package_manifest in sorted(root.rglob("Package.swift")):
        relative = package_manifest.relative_to(root).as_posix()
        text = package_manifest.read_text(encoding="utf-8")
        for match in re.finditer(
            r"\.package\s*\(\s*url\s*:\s*[\"']([^\"']+)[\"']",
            text,
            flags=re.IGNORECASE,
        ):
            dependency = (relative, match.group(1))
            if dependency not in REVIEWED_REMOTE_PACKAGE_DEPENDENCIES:
                raise MachOKitSourceIdentityError(
                    f"unreviewed URL package dependency remains in {relative}: {match.group(1)}"
                )
        if re.search(r"\.binaryTarget\s*\(", text, flags=re.IGNORECASE):
            raise MachOKitSourceIdentityError(
                f"unreviewed binary package dependency remains in {relative}"
            )
        if re.search(r"\.xcframework(?:\b|[/\"'])", text, flags=re.IGNORECASE):
            raise MachOKitSourceIdentityError(
                f"XCFramework package dependency remains in {relative}"
            )
    actual = tree_digest(root, excluded=frozenset({"MATERIALIZATION.json"}))
    if manifest.get("tree_sha256") != actual:
        raise MachOKitSourceIdentityError("materialization tree checksum mismatch")
    if actual != MATERIALIZATION_TREE_SHA256:
        raise MachOKitSourceIdentityError("materialization tree differs from the reviewed output")
    if enforce_read_only:
        verify_read_only_shape(root)
    if not quiet:
        print(f"verified MachOKit {MACHOKIT_VERSION} direct-source materialization: {root}")
    return root


def _admission_identity(root: Path) -> dict[str, object]:
    """Bind a pinned read-only view without reading any dependency payload bytes.

    ctime catches write/chmod-and-restore, inode catches replacement, and the
    complete metadata list catches added/deleted entries and unsafe links. This
    is the same metadata-bound trust boundary as the developer cache VIEW.json.
    """
    records = []
    for path in [root, *sorted(root.rglob("*"))]:
        metadata = path.lstat()
        if (not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode))
                or metadata.st_mode & 0o222 or metadata.st_uid != os.getuid()
                or (stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1)):
            raise MachOKitSourceIdentityError("MachOKit admission view is not owner-controlled read-only ordinary content")
        records.append([path.relative_to(root).as_posix(), metadata.st_dev,
                        metadata.st_ino, metadata.st_mode, metadata.st_size,
                        metadata.st_mtime_ns, metadata.st_ctime_ns])
    return {
        "schema_version": 1,
        "root": str(root),
        "materialization_schema": SCHEMA_VERSION,
        "version": MACHOKIT_VERSION,
        "revision": MACHOKIT_REVISION,
        "archive_sha256": MACHOKIT_ARCHIVE_SHA256,
        "upstream_tree_sha256": MACHOKIT_UPSTREAM_TREE_SHA256,
        "tree_sha256": MATERIALIZATION_TREE_SHA256,
        "governed_source_identity": GOVERNED_SOURCE_IDENTITY,
        "components": [vars(component) for component in COMPONENTS],
        "metadata_sha256": hashlib.sha256(
            json.dumps(records, separators=(",", ":")).encode()
        ).hexdigest(),
    }


def _admission_receipt(root: Path) -> Path:
    return root.parent / f".{root.name}.admission.json"


def _write_admission(root: Path, identity: dict[str, object]) -> None:
    receipt = _admission_receipt(root)
    descriptor, name = tempfile.mkstemp(prefix=".machokit-admission-", dir=root.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(identity, stream, sort_keys=True)
            stream.write("\n")
        temporary.chmod(0o444)
        os.replace(temporary, receipt)
    finally:
        temporary.unlink(missing_ok=True)


def _canonical_admission_root(root: Path) -> Path:
    requested = root.expanduser().absolute()
    # Reject indirect roots, including an ancestor symlink, before resolving.
    for path in [requested, *requested.parents]:
        if path.is_symlink():
            raise MachOKitSourceIdentityError("MachOKit admission root is indirect")
    root = requested.resolve(strict=True)
    if not root.is_dir():
        raise MachOKitSourceIdentityError("MachOKit materialization root is not a safe directory")
    parent = root.parent.stat()
    if parent.st_uid != os.getuid() or parent.st_mode & 0o022:
        raise MachOKitSourceIdentityError("MachOKit admission parent must be owner-controlled")
    return root


def verify_root(root: Path, *, quiet: bool = False) -> Path:
    root = _canonical_admission_root(root)
    receipt = _admission_receipt(root)
    # Publication and concurrent bootstrap consumers share the admission lock.
    descriptor = os.open(root.parent / f".{root.name}.admission.lock",
                         os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        identity = _admission_identity(root)
        valid = False
        try:
            metadata = receipt.lstat()
        except FileNotFoundError:
            metadata = None
        try:
            if (metadata is not None and stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1
                    and metadata.st_uid == os.getuid() and not metadata.st_mode & 0o222
                    and metadata.st_size <= 65536):
                valid = json.loads(receipt.read_text()) == identity
        except (FileNotFoundError, UnicodeError, json.JSONDecodeError):
            pass
        if not valid:
            if metadata is not None:
                raise MachOKitSourceIdentityError(
                    "existing MachOKit admission receipt is invalid; ordinary reuse "
                    "will not reverify payloads or replace the receipt"
                )
            _verify_root(root, quiet=True, enforce_read_only=True)
            if _admission_identity(root) != identity:
                raise MachOKitSourceIdentityError("MachOKit view changed during verification")
            _write_admission(root, identity)
        if not quiet:
            print(f"{'reused receipt for' if valid else 'verified'} MachOKit {MACHOKIT_VERSION} direct-source materialization: {root}")
        return root
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _freeze_tree(root: Path) -> None:
    entries = [root, *root.rglob("*")]
    for path in reversed(entries):
        metadata = path.lstat()
        path.chmod(stat.S_IMODE(metadata.st_mode) & ~0o222)


def _remove_private_staging(root: Path) -> None:
    if not root.exists() or root.is_symlink():
        return
    entries = [root, *root.rglob("*")]
    for path in entries:
        if path.is_dir() and not path.is_symlink():
            path.chmod(stat.S_IMODE(path.lstat().st_mode) | 0o700)
    shutil.rmtree(root)


def _external_work_root(work_root: Path) -> Path:
    if not work_root.is_absolute():
        raise MachOKitSourceIdentityError(
            "MachOKit materialization work root must be absolute"
        )
    repository = REPOSITORY_ROOT.resolve(strict=True)
    candidate = Path(os.path.realpath(work_root.expanduser()))
    if candidate in {Path("/"), Path.home().resolve(), repository} or repository in candidate.parents:
        raise MachOKitSourceIdentityError(
            "MachOKit materialization work root must be a dedicated path outside the repository"
        )
    candidate.mkdir(mode=0o700, parents=True, exist_ok=True)
    if candidate.is_symlink() or not candidate.is_dir() or candidate.resolve(strict=True) != candidate:
        raise MachOKitSourceIdentityError(
            "MachOKit materialization work root is not a canonical directory"
        )
    metadata = candidate.lstat()
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
        raise MachOKitSourceIdentityError(
            "MachOKit materialization work root must be owner-controlled "
            "(owned by the current user, not group/world writable)"
        )
    return candidate


def publish_read_only_view(source_root: Path, work_root: Path, *, quiet: bool = False) -> Path:
    work = _external_work_root(work_root)
    if source_root.expanduser().is_symlink():
        raise MachOKitSourceIdentityError("MachOKit source root is indirect")
    source = source_root.expanduser().resolve(strict=True)
    if source == work or source in work.parents or work in source.parents:
        raise MachOKitSourceIdentityError(
            "MachOKit source and external work roots must not contain one another"
        )
    destination = work / f"MachOKit-{MACHOKIT_VERSION}-{MATERIALIZATION_TREE_SHA256[:16]}"
    if destination.exists() or destination.is_symlink():
        verified = verify_root(destination, quiet=True)
        if not quiet:
            print(f"reused read-only MachOKit materialization: {verified}")
        return verified

    staging = Path(tempfile.mkdtemp(prefix=".MachOKit-staging-", dir=work))
    try:
        shutil.copytree(
            source,
            staging,
            copy_function=shutil.copy2,
            dirs_exist_ok=True,
            symlinks=True,
        )
        _ordinary_files(staging)  # Reject copied links before chmod can follow one.
        _freeze_tree(staging)
        # Verify the consumed copy once. Re-checking the mutable source, then
        # the same staging bytes before/after chmod/rename repeats the work.
        _verify_root(staging, quiet=True, enforce_read_only=True)
        try:
            staging.rename(destination)
        except FileExistsError:
            verified = verify_root(destination, quiet=True)
            _remove_private_staging(staging)
            if not quiet:
                print(f"reused read-only MachOKit materialization: {verified}")
            return verified
        # Rename preserves the verified files; record their final path identity.
        # A later bootstrap/link checks this metadata and the current full pins.
        _write_admission(destination, _admission_identity(destination))
        verified = destination
        if not quiet:
            print(f"published read-only MachOKit materialization: {verified}")
        return verified
    except Exception:
        _remove_private_staging(staging)
        raise


def link_root(root: Path, macscope_directory: Path, *, quiet: bool = False) -> Path:
    root = verify_root(root, quiet=True).resolve(strict=True)
    macscope = macscope_directory.expanduser().resolve(strict=True)
    if macscope.name != "MacScope" or not (macscope / "project.yml").is_file():
        raise MachOKitSourceIdentityError(
            "--macscope-directory must identify the MacScope source directory"
        )
    repository_root = macscope.parent
    if root == repository_root or repository_root in root.parents:
        raise MachOKitSourceIdentityError(
            "MachOKit materialization must remain outside the repository"
        )
    link = macscope / "LocalPackages"
    if link.is_symlink():
        current = link.resolve(strict=False)
        if current == root:
            if not quiet:
                print(f"MacScope local package link already current: {link} -> {root}")
            return link
        # A dangling link (e.g. its old $TMPDIR work root was wiped by a
        # restart) or one naming another verified MachOKit view (an earlier
        # default work root) is replaced atomically; anything else is refused.
        replaceable = not current.exists()
        if not replaceable:
            try:
                verify_root(current, quiet=True)
                replaceable = True
            except Exception:
                replaceable = False
        if not replaceable:
            raise MachOKitSourceIdentityError(
                f"MacScope local package link targets another root: {link} -> {current}"
            )
        staging = link.with_name(f".LocalPackages-relink-{os.getpid()}")
        if staging.is_symlink():
            staging.unlink()
        staging.symlink_to(root, target_is_directory=True)
        os.replace(staging, link)
        if not quiet:
            print(f"relinked MacScope local packages: {link} -> {root} (was {current})")
        return link
    if link.exists():
        raise MachOKitSourceIdentityError(
            f"MacScope local package path is not a symlink: {link}"
        )
    link.symlink_to(root, target_is_directory=True)
    if not quiet:
        print(f"linked MacScope local packages: {link} -> {root}")
    return link


def parse_arguments(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--materialization-root", type=Path, required=True)
    verify_parser.add_argument("--quiet", action="store_true")
    publish_parser = commands.add_parser("publish-read-only")
    publish_parser.add_argument("--source-root", type=Path, required=True)
    publish_parser.add_argument("--work-root", type=Path, required=True)
    publish_parser.add_argument("--quiet", action="store_true")
    link_parser = commands.add_parser("link")
    link_parser.add_argument("--materialization-root", type=Path, required=True)
    link_parser.add_argument("--macscope-directory", type=Path, required=True)
    link_parser.add_argument("--quiet", action="store_true")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.command == "verify":
            verify_root(arguments.materialization_root, quiet=arguments.quiet)
        elif arguments.command == "publish-read-only":
            root = publish_read_only_view(
                arguments.source_root,
                arguments.work_root,
                quiet=arguments.quiet,
            )
            print(f"MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT={root}")
        elif arguments.command == "link":
            link_root(
                arguments.materialization_root,
                arguments.macscope_directory,
                quiet=arguments.quiet,
            )
        else:
            raise AssertionError(arguments.command)
    except (MachOKitSourceIdentityError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
