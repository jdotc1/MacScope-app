#!/usr/bin/env python3
"""Materialize one exact local Gate F candidate from executed build products.

This is deliberately a post-build operation.  It consumes the two canonical
qualifier receipts plus their signed Release and Debug products; it never
manufactures product identities from project declarations or mutable branch
labels.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction.validate_qualification_product_identity import (  # noqa: E402
    PRODUCT_LAYOUTS,
    ProductIdentityError,
    _parse_text_manifest,
    validate_qualification_build,
    validate_products,
)
from Scripts.generate_release_build_provenance import (  # noqa: E402
    ProvenanceError,
    verified_sleigh_materialization,
)
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    canonical_bytes,
    canonical_sha256,
)
from Scripts.reconstruction_gate_f.artifact_validator import (  # noqa: E402
    read_descriptor_relative_bytes,
)
from Scripts.reconstruction_gate_f.scenario_compiler import (  # noqa: E402
    selector_catalog_identity_sha256,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CANDIDATE_SCHEMA_VERSION,
    candidate_identity_sha256,
    parse_candidate_identity,
)
from Scripts.qualification import generated_project_evidence  # noqa: E402


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_RE = re.compile(r"^[0-9a-f]{40}$")
GATE_F_COMPILER_SCHEMA_VERSION = 1
SEMANTIC_PREREQUISITE_IDS = frozenset({
    "task-6-remediation", "task-8", "task-9", "t10a", "t10c", "task-10",
})

# ``QUALIFICATION_INPUTS.json`` is written by the local qualifier.  Version 4
# deliberately seals more than the v2 receipt this materializer originally
# consumed: the source export, dependency cache/network state, and both
# materialized dependency manifests, including the full Ghostty surface that
# Xcode stages for compilation and linking. Keep this closed here so accepting the
# current canonical receipt does not turn into accepting arbitrary JSON.
QUALIFICATION_INPUTS_V4_FIELDS = frozenset(
    {
        "build_source_root",
        "dependency_cache_root",
        "dependency_network_allowed",
        "dependency_network_used",
        "ghostty_artifact_manifest_sha256",
        "ghostty_source_dir",
        "ghostty_surface_artifact_root",
        "ghostty_surface_manifest_sha256",
        "ghostty_surface_source_dir",
        "mode",
        "schema_version",
        "sleigh_materialization_manifest_sha256",
        "sleigh_materialization_root",
        "source_identity",
        "zig_executable",
    }
)
SOURCE_EXPORT_V2_FIELDS = frozenset(
    {
        "canonical_integration_commit",
        "canonical_integration_ref",
        "canonical_remote_url",
        "dependency_contract",
        "git_head_commit",
        "git_head_tree",
        "git_parent_commits",
        "repository_clean",
        "schema_version",
        "source_file_count",
        "source_files_sha256",
    }
)
SOURCE_EXPORT_V2_DEPENDENCY_FIELDS = frozenset(
    {
        "component_manifest_sha256",
        "component_pins",
        "notices_sha256",
        "source_export_package",
    }
)
SOURCE_EXPORT_PACKAGE_FIELDS = frozenset(
    {
        "commit_object_name",
        "commit_object_sha256",
        "commit_object_size",
        "version",
    }
)


class CandidateMaterializationError(RuntimeError):
    pass


def _gate_f_compiler_schema(content_sha256: str) -> dict[str, Any]:
    """Return the compiler schema identity on its independent version axis."""

    return {
        "schema_id": "gate-f-compiler",
        "version": GATE_F_COMPILER_SCHEMA_VERSION,
        "content_sha256": content_sha256,
    }


@dataclass(frozen=True)
class BundleDigests:
    content_sha256: str
    closed_tree_sha256: str


@dataclass(frozen=True)
class BundleSnapshot:
    """One descriptor-fenced physical bundle identity.

    A candidate record must not splice a tree digest from one bundle state with
    executable or signing fields observed from a later state.  This snapshot
    therefore records both the double-read tree identity and the root
    directory descriptor identity that fenced that read.
    """

    root: Path
    directory_identity: tuple[int, int, int, int]
    digests: BundleDigests
    # In-memory app-root fence only; the existing four-value wire identity is
    # retained verbatim. Generic directory snapshots have no relaxed policy.
    app_root_metadata: tuple[int, int, int] | None = None


@dataclass(frozen=True)
class FileSnapshot:
    """One descriptor-stable standalone file identity."""

    path: Path
    metadata: tuple[int, int, int, int, int, int]
    sha256: str
    # Explicit prerequisite inputs retain their no-alias path requirement all
    # the way to publication, not just their unchanged leaf identity.
    canonical_path_required: bool = False


@dataclass(frozen=True)
class SourceSnapshot:
    """One clean Git source identity captured around candidate materialization."""

    branch_label: str
    commit: str
    status: str
    tree: str


@dataclass(frozen=True)
class CandidatePublicationFence:
    """Physical inputs that must remain exact until candidate publication."""

    repository_root: Path
    source_snapshot: SourceSnapshot
    file_snapshots: tuple[FileSnapshot, ...]
    bundle_snapshots: tuple[BundleSnapshot, ...]


@dataclass(frozen=True)
class QualificationDependencyAuthority:
    """Exact qualifier dependency bytes bound to the signed Release product."""

    ghostty_manifest_snapshot: FileSnapshot
    ghostty_artifact_snapshot: FileSnapshot
    ghostty_surface_manifest_snapshot: FileSnapshot
    sleigh_manifest_snapshot: FileSnapshot
    sleigh_root_snapshot: BundleSnapshot
    ghostty_manifest_identity: dict[str, str]
    sleigh_identity: dict[str, Any]

    @property
    def file_snapshots(self) -> tuple[FileSnapshot, ...]:
        return (
            self.ghostty_manifest_snapshot,
            self.ghostty_artifact_snapshot,
            self.ghostty_surface_manifest_snapshot,
            self.sleigh_manifest_snapshot,
        )


def _run(
    argv: list[str],
    *,
    cwd: Path | None = None,
    text: bool = True,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[Any]:
    result = subprocess.run(
        argv,
        cwd=cwd,
        env=environment,
        capture_output=True,
        text=text,
        check=False,
    )
    if result.returncode != 0:
        stderr = result.stderr if text else result.stderr.decode("utf-8", "replace")
        raise CandidateMaterializationError(
            f"command failed ({result.returncode}): {' '.join(argv)}: {stderr.strip()}"
        )
    return result


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _stable_metadata(metadata: os.stat_result) -> tuple[int, int, int, int, int, int]:
    """Return the descriptor attributes that must not change during one read."""

    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _stable_file_bytes(path: Path) -> tuple[bytes, tuple[int, int, int, int, int, int]]:
    """Read one ordinary file through an ``O_NOFOLLOW`` descriptor.

    This is the same pre/post-``fstat`` fence used by the installed-product
    receipt.  It makes an in-place write observable instead of publishing a
    digest for bytes that changed while they were read.  Bundle tree reads use
    the stricter descriptor-relative helper below, because every path component
    inside a signed product is security-relevant too.
    """

    _ordinary_file(path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise CandidateMaterializationError(f"cannot safely open {path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise CandidateMaterializationError(f"required path is not an ordinary file: {path}")
        chunks: list[bytes] = []
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            chunks.append(block)
        after = os.fstat(descriptor)
        if _stable_metadata(before) != _stable_metadata(after):
            raise CandidateMaterializationError(f"file changed while it was read: {path}")
        return b"".join(chunks), _stable_metadata(before)
    except OSError as error:
        raise CandidateMaterializationError(f"cannot safely read {path}: {error}") from error
    finally:
        os.close(descriptor)


def _sha256_file(path: Path) -> str:
    payload, _ = _stable_file_bytes(path)
    return _sha256_bytes(payload)


def capture_file_snapshot(path: Path) -> FileSnapshot:
    """Capture a standalone file through the same no-follow read fence."""

    payload, metadata = _stable_file_bytes(path)
    return FileSnapshot(path=path, metadata=metadata, sha256=_sha256_bytes(payload))


def require_unchanged_file_snapshot(snapshot: FileSnapshot, *, phase: str) -> None:
    """Reject any replacement or in-place change after a file was recorded."""

    if snapshot.canonical_path_required:
        _prerequisite_file_path(snapshot.path)
    observed = capture_file_snapshot(snapshot.path)
    if snapshot.canonical_path_required:
        _prerequisite_file_path(snapshot.path)
    if observed.metadata != snapshot.metadata or observed.sha256 != snapshot.sha256:
        raise CandidateMaterializationError(
            f"file changed before {phase}: {snapshot.path}"
        )


def require_single_full_test_receipt(
    release_snapshot: FileSnapshot,
    debug_snapshot: FileSnapshot,
) -> None:
    """Bind candidate products to the qualifier's one authoritative run."""

    if (
        release_snapshot.path.resolve(strict=True)
        != debug_snapshot.path.resolve(strict=True)
        or release_snapshot.metadata != debug_snapshot.metadata
        or release_snapshot.sha256 != debug_snapshot.sha256
    ):
        raise CandidateMaterializationError(
            "Release and Debug products must use the same full-test qualification receipt"
        )


def _ordinary_file(path: Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CandidateMaterializationError(f"required file is unavailable: {path}: {error}") from error
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise CandidateMaterializationError(f"required path is not an ordinary file: {path}")


def _ordinary_directory(path: Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CandidateMaterializationError(
            f"required directory is unavailable: {path}: {error}"
        ) from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise CandidateMaterializationError(f"required path is not an ordinary directory: {path}")


def _canonical_dependency_artifact(path: Path, verified_directory: Path) -> Path:
    """Resolve one dependency-owned filename without weakening candidate trees.

    Zig deliberately publishes versioned dylibs through a short symlink chain.
    Each hop must remain a direct child of the already verified library
    directory, and the terminal member must be an ordinary file.  This helper
    is intentionally not used for signed bundles, receipts, manifests, or any
    other candidate input, all of which retain the stricter no-symlink rule.
    """

    _ordinary_directory(verified_directory)
    verified_root = Path(os.path.abspath(verified_directory))
    current = Path(os.path.abspath(path))
    visited: set[Path] = set()
    while True:
        if current.parent != verified_root:
            raise CandidateMaterializationError(
                f"dependency artifact escapes its verified dependency directory: {path}"
            )
        if current in visited:
            raise CandidateMaterializationError(
                f"dependency artifact symlink chain contains a cycle: {path}"
            )
        visited.add(current)
        try:
            metadata = current.lstat()
        except OSError as error:
            raise CandidateMaterializationError(
                f"required dependency artifact is unavailable: {current}: {error}"
            ) from error
        if stat.S_ISREG(metadata.st_mode):
            return current
        if not stat.S_ISLNK(metadata.st_mode):
            raise CandidateMaterializationError(
                f"dependency artifact does not resolve to an ordinary file: {path}"
            )
        try:
            target = Path(os.readlink(current))
        except OSError as error:
            raise CandidateMaterializationError(
                f"cannot read dependency artifact symlink: {current}: {error}"
            ) from error
        current = Path(
            os.path.abspath(target if target.is_absolute() else current.parent / target)
        )


def _read_json(path: Path) -> dict[str, Any]:
    try:
        payload, _ = _stable_file_bytes(path)
        value = json.loads(payload.decode("utf-8"))
    except (CandidateMaterializationError, UnicodeError, json.JSONDecodeError) as error:
        raise CandidateMaterializationError(f"cannot decode JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise CandidateMaterializationError(f"JSON root must be an object: {path}")
    return value


def _canonical_bundle_root(root: Path) -> Path:
    """Require an absolute, already-canonical, no-symlink bundle root."""

    if not root.is_absolute():
        raise CandidateMaterializationError(f"bundle root must be absolute: {root}")
    _ordinary_directory(root)
    try:
        resolved = root.resolve(strict=True)
    except OSError as error:
        raise CandidateMaterializationError(f"cannot resolve bundle root: {root}: {error}") from error
    _ordinary_directory(resolved)
    return resolved


def _directory_descriptor_identity(root: Path) -> tuple[int, int, int, int]:
    """Capture the no-follow root descriptor fence for one bundle tree read."""

    root = _canonical_bundle_root(root)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        descriptor = os.open(root, flags)
    except OSError as error:
        raise CandidateMaterializationError(
            f"cannot safely open bundle directory {root}: {error}"
        ) from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            raise CandidateMaterializationError(f"bundle root is not a directory: {root}")
        return (metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns, metadata.st_ctime_ns)
    finally:
        os.close(descriptor)


def _descriptor_relative_digest(
    root: Path,
    relative: str,
    expected: os.stat_result,
) -> tuple[str, os.stat_result]:
    """Hash one bundle file through the shared descriptor-relative reader.

    The artifact validator owns the root-to-leaf ``O_NOFOLLOW`` traversal and
    its pre/post-``fstat`` read fence.  Compare the inspected path state again
    after that read so a rename or symlink substitution cannot splice its
    digest into metadata collected for another filesystem entry.
    """

    path = root / relative
    try:
        _, size, digest = read_descriptor_relative_bytes(root, relative)
    except OSError as error:
        raise CandidateMaterializationError(
            f"bundle file cannot be safely read: {relative}: {error}"
        ) from error
    try:
        observed = path.lstat()
    except OSError as error:
        raise CandidateMaterializationError(
            f"bundle file disappeared while it was read: {relative}: {error}"
        ) from error
    if (
        not stat.S_ISREG(observed.st_mode)
        or stat.S_ISLNK(observed.st_mode)
        or observed.st_nlink != 1
        or _stable_metadata(observed) != _stable_metadata(expected)
        or observed.st_size != size
    ):
        raise CandidateMaterializationError(
            f"bundle file changed while it was read: {relative}"
        )
    return digest, observed


def bundle_tree_digests(root: Path) -> BundleDigests:
    """Return content-only and full closed-tree identities for a bundle."""

    root = _canonical_bundle_root(root)
    content_records: list[dict[str, object]] = []
    tree_records: list[dict[str, object]] = []
    file_inodes: set[tuple[int, int]] = set()
    def fail_closed_walk(error: OSError) -> None:
        raise CandidateMaterializationError(
            f"bundle traversal failed and cannot prove a closed tree: {error.filename}: {error}"
        ) from error

    for current_root, directories, files in os.walk(
        root,
        topdown=True,
        onerror=fail_closed_walk,
        followlinks=False,
    ):
        directories.sort()
        files.sort()
        current = Path(current_root)
        for name in tuple(directories) + tuple(files):
            path = current / name
            relative = path.relative_to(root).as_posix()
            try:
                metadata = path.lstat()
            except OSError as error:
                raise CandidateMaterializationError(
                    f"bundle entry became unavailable during traversal: {relative}: {error}"
                ) from error
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISLNK(metadata.st_mode):
                raise CandidateMaterializationError(
                    f"bundle contains a symbolic link and is not a closed ordinary tree: {relative}"
                )
            elif stat.S_ISDIR(metadata.st_mode):
                tree_records.append({"mode": mode, "path": relative, "type": "directory"})
            elif stat.S_ISREG(metadata.st_mode):
                inode = (metadata.st_dev, metadata.st_ino)
                if metadata.st_nlink != 1 or inode in file_inodes:
                    raise CandidateMaterializationError(
                        f"bundle contains a hardlinked or multiply linked file: {relative}"
                    )
                file_inodes.add(inode)
                digest, stable_metadata = _descriptor_relative_digest(root, relative, metadata)
                content_records.append({"path": relative, "sha256": digest, "type": "file"})
                tree_records.append(
                    {
                        "mode": mode,
                        "path": relative,
                        "sha256": digest,
                        "size": stable_metadata.st_size,
                        "type": "file",
                    }
                )
            else:
                raise CandidateMaterializationError(
                    f"bundle contains an unsupported filesystem entry: {relative}"
                )
    return BundleDigests(
        content_sha256=canonical_sha256(sorted(content_records, key=lambda item: str(item["path"]))),
        closed_tree_sha256=canonical_sha256(sorted(tree_records, key=lambda item: str(item["path"]))),
    )


def app_root_directory_identity_matches(
    observed: tuple[int, int, int, int], expected: tuple[int, int, int, int]
) -> bool:
    """Keep object/mtime exact while allowing app-root ctime to advance."""
    return observed[:3] == expected[:3] and observed[3] >= expected[3]


def _app_root_metadata(root: Path) -> tuple[int, int, int]:
    metadata = root.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise CandidateMaterializationError(f"app root is not an ordinary directory: {root}")
    return metadata.st_mode, metadata.st_nlink, metadata.st_size


def bundle_snapshots_match(observed: BundleSnapshot, expected: BundleSnapshot) -> bool:
    """Compare snapshots under their explicitly captured root policy."""
    same_directory = (
        observed.directory_identity == expected.directory_identity
        if expected.app_root_metadata is None
        else app_root_directory_identity_matches(observed.directory_identity, expected.directory_identity)
    )
    return (observed.root == expected.root and same_directory
            and observed.app_root_metadata == expected.app_root_metadata
            and observed.digests == expected.digests)


def capture_bundle_snapshot(root: Path, *, app_root: bool = False) -> BundleSnapshot:
    """Capture a double-read, descriptor-fenced closed bundle tree identity."""

    root = _canonical_bundle_root(root)
    before = _directory_descriptor_identity(root)
    root_metadata = _app_root_metadata(root) if app_root else None
    first = bundle_tree_digests(root)
    second = bundle_tree_digests(root)
    after = _directory_descriptor_identity(root)
    observed_metadata = _app_root_metadata(root) if app_root else None
    same_directory = (app_root_directory_identity_matches(after, before)
                      if app_root else before == after)
    if not same_directory or root_metadata != observed_metadata or first != second:
        # Fixed-size identities only: diagnose the failed fence without exposing
        # bundle contents or weakening the double-read admission condition.
        diagnostic = json.dumps(
            {
                "root_changed": not same_directory or root_metadata != observed_metadata,
                "content_changed": first.content_sha256 != second.content_sha256,
                "closed_tree_changed": first.closed_tree_sha256 != second.closed_tree_sha256,
                "root_identity_fields": ["device", "inode", "mtime_ns", "ctime_ns"],
                "root_before": before,
                "root_after": after,
                "content_before": first.content_sha256,
                "content_after": second.content_sha256,
                "closed_tree_before": first.closed_tree_sha256,
                "closed_tree_after": second.closed_tree_sha256,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        raise CandidateMaterializationError(
            f"bundle tree changed during descriptor-fenced snapshot: {root}; "
            f"diagnostic={diagnostic}"
        )
    return BundleSnapshot(root=root, directory_identity=before, digests=first,
                          app_root_metadata=root_metadata)


def require_unchanged_bundle_snapshot(snapshot: BundleSnapshot, *, phase: str) -> None:
    """Require a bundle to remain exactly the stable tree captured earlier."""

    observed = capture_bundle_snapshot(snapshot.root, app_root=snapshot.app_root_metadata is not None)
    if not bundle_snapshots_match(observed, snapshot):
        raise CandidateMaterializationError(
            f"bundle tree changed before {phase}: {snapshot.root}"
        )


def _tree_manifest_sha256(paths: list[Path], root: Path) -> str:
    records = []
    for path in sorted(paths):
        _ordinary_file(path)
        records.append(
            {
                "path": path.relative_to(root).as_posix(),
                "sha256": _sha256_file(path),
            }
        )
    if not records:
        raise CandidateMaterializationError("identity file manifest must not be empty")
    return canonical_sha256(records)


def _plist(path: Path) -> dict[str, Any]:
    try:
        payload, _ = _stable_file_bytes(path)
        value = plistlib.loads(payload)
    except (CandidateMaterializationError, plistlib.InvalidFileException, ValueError) as error:
        raise CandidateMaterializationError(f"cannot decode plist {path}: {error}") from error
    if not isinstance(value, dict):
        raise CandidateMaterializationError(f"plist root must be an object: {path}")
    return value


def _bundle_executable(bundle: Path) -> tuple[str, Path]:
    info = _plist(bundle / "Contents/Info.plist")
    bundle_id = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise CandidateMaterializationError(f"bundle lacks CFBundleIdentifier: {bundle}")
    if not isinstance(executable_name, str) or not executable_name or "/" in executable_name:
        raise CandidateMaterializationError(f"bundle lacks a safe CFBundleExecutable: {bundle}")
    executable = bundle / "Contents/MacOS" / executable_name
    _ordinary_file(executable)
    if not os.access(executable, os.X_OK):
        raise CandidateMaterializationError(f"bundle executable is not executable: {executable}")
    return bundle_id, executable


def _codesign_identity(app: Path) -> dict[str, object]:
    _run(["/usr/bin/codesign", "--verify", "--strict", "--deep", "--verbose=2", str(app)])
    verbose = _run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)]).stderr
    authorities = [line.removeprefix("Authority=") for line in verbose.splitlines() if line.startswith("Authority=")]
    teams = [line.removeprefix("TeamIdentifier=") for line in verbose.splitlines() if line.startswith("TeamIdentifier=")]
    flags = [line for line in verbose.splitlines() if line.startswith("CodeDirectory ")]
    if not authorities or len(teams) != 1 or len(flags) != 1:
        raise CandidateMaterializationError("codesign display lacks one closed signing identity")
    # Xcode 27's codesign writes the designated requirement to stdout while
    # writing its Executable= diagnostic to stderr.  Treating stderr as the
    # requirement would reject every valid product and is therefore covered by
    # the installed-product smoke check for this helper.
    requirement_output = _run(["/usr/bin/codesign", "-d", "-r-", str(app)]).stdout
    requirements = [
        line.removeprefix("designated => ")
        for line in requirement_output.splitlines()
        if line.startswith("designated => ")
    ]
    if len(requirements) != 1:
        raise CandidateMaterializationError("codesign did not emit one designated requirement")
    entitlements = _run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)],
        text=False,
    ).stdout
    with tempfile.TemporaryDirectory(prefix="macscope-gate-f-cert-") as temporary:
        prefix = Path(temporary) / "certificate"
        _run(
            [
                "/usr/bin/codesign",
                "-d",
                f"--extract-certificates={prefix}",
                str(app),
            ]
        )
        leaf = Path(f"{prefix}0")
        _ordinary_file(leaf)
        certificate_sha256 = _sha256_file(leaf)
    return {
        "designated_requirement_sha256": _sha256_bytes(requirements[0].encode("utf-8")),
        "entitlements_sha256": _sha256_bytes(entitlements),
        "hardened_runtime": "(runtime)" in flags[0],
        "signing_certificate_sha256": certificate_sha256,
        "signing_subject_sha256": _sha256_bytes(authorities[0].encode("utf-8")),
        "team_identifier": teams[0],
    }


def _git(root: Path, *arguments: str) -> str:
    return _run(["/usr/bin/git", *arguments], cwd=root).stdout.strip()


def _capture_source_snapshot(root: Path) -> SourceSnapshot:
    """Capture every Git fact that makes one local source snapshot authoritative.

    ``--untracked-files=all`` is intentional.  The default porcelain rendering
    can coalesce an untracked directory into one entry; the Gate F source fence
    must account for every untracked build input instead of merely noticing a
    parent directory happens to be present.
    """

    status = _git(root, "status", "--porcelain=v1", "--untracked-files=all")
    return SourceSnapshot(
        branch_label=_git(root, "branch", "--show-current"),
        commit=_require_git_object(_git(root, "rev-parse", "HEAD"), label="candidate commit"),
        status=status,
        tree=_require_git_object(
            _git(root, "rev-parse", "HEAD^{tree}"), label="candidate tree"
        ),
    )


def _require_clean_source_snapshot(root: Path) -> SourceSnapshot:
    snapshot = _capture_source_snapshot(root)
    if snapshot.status:
        raise CandidateMaterializationError(
            "candidate source repository must be clean, including all untracked files"
        )
    if not snapshot.branch_label:
        raise CandidateMaterializationError("candidate source branch is empty")
    return snapshot


def _require_unchanged_source_snapshot(
    root: Path,
    expected: SourceSnapshot,
    *,
    phase: str,
) -> None:
    observed = _capture_source_snapshot(root)
    if observed != expected:
        raise CandidateMaterializationError(
            f"candidate source identity drifted before {phase}; "
            "HEAD, tree, branch, and clean status must remain exact"
        )


def _require_ancestor(root: Path, ancestor: str, descendant: str, *, label: str) -> None:
    result = subprocess.run(
        ["/usr/bin/git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return
    if result.returncode == 1:
        raise CandidateMaterializationError(
            f"{label} is not an ancestor of the exact candidate"
        )
    raise CandidateMaterializationError(
        f"cannot prove {label} ancestry ({result.returncode}): {result.stderr.strip()}"
    )


def _require_git_object(value: str, *, label: str) -> str:
    if GIT_RE.fullmatch(value) is None:
        raise CandidateMaterializationError(f"{label} is not one full Git object identity")
    return value


def _require_sha256(value: object, *, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise CandidateMaterializationError(f"{label} is not one lowercase SHA-256")
    return value


def _qualification_source(
    receipt: dict[str, Any],
    *,
    expected_mode: str,
    commit: str,
    tree: str,
) -> None:
    if set(receipt) != QUALIFICATION_INPUTS_V4_FIELDS:
        raise CandidateMaterializationError(
            "qualification receipt does not satisfy the closed schema v4 field set"
        )
    if receipt.get("schema_version") != 4 or receipt.get("mode") != expected_mode:
        raise CandidateMaterializationError(
            f"qualification receipt is not schema v4 mode {expected_mode}"
        )
    for field in ("dependency_network_allowed", "dependency_network_used"):
        if not isinstance(receipt.get(field), bool):
            raise CandidateMaterializationError(
                f"qualification receipt {field} is not Boolean"
            )
    if receipt["dependency_network_used"] and not receipt["dependency_network_allowed"]:
        raise CandidateMaterializationError(
            "qualification receipt used dependency network without authorization"
        )
    for field in (
        "build_source_root",
        "dependency_cache_root",
        "ghostty_source_dir",
        "ghostty_surface_artifact_root",
        "ghostty_surface_source_dir",
        "sleigh_materialization_root",
        "zig_executable",
    ):
        value = receipt.get(field)
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise CandidateMaterializationError(
                f"qualification receipt {field} is not an absolute path"
            )
    for field in (
        "ghostty_artifact_manifest_sha256",
        "ghostty_surface_manifest_sha256",
        "sleigh_materialization_manifest_sha256",
    ):
        _require_sha256(receipt.get(field), label=f"qualification receipt {field}")
    source = receipt.get("source_identity")
    if not isinstance(source, dict):
        raise CandidateMaterializationError("qualification receipt lacks source identity")
    if set(source) != SOURCE_EXPORT_V2_FIELDS or source.get("schema_version") != 2:
        raise CandidateMaterializationError(
            "qualification receipt source identity does not satisfy the closed "
            "source-export schema v2 field set"
        )
    if (
        source.get("git_head_commit") != commit
        or source.get("git_head_tree") != tree
        or source.get("canonical_integration_commit") != commit
        or source.get("repository_clean") is not True
    ):
        raise CandidateMaterializationError(
            f"{expected_mode} qualifier receipt is not bound to the exact clean candidate"
        )
    parents = source.get("git_parent_commits")
    if not isinstance(parents, list) or any(
        not isinstance(parent, str) or GIT_RE.fullmatch(parent) is None
        for parent in parents
    ):
        raise CandidateMaterializationError(
            "qualification receipt source identity has malformed parent commits"
        )
    for field, maximum_length in (
        ("canonical_integration_ref", 256),
        ("canonical_remote_url", 2048),
    ):
        value = source.get(field)
        if (
            not isinstance(value, str)
            or not value
            or len(value) > maximum_length
            or any(ord(character) < 0x20 for character in value)
        ):
            raise CandidateMaterializationError(
                f"qualification receipt source identity has malformed {field}"
            )
    source_file_count = source.get("source_file_count")
    if (
        isinstance(source_file_count, bool)
        or not isinstance(source_file_count, int)
        or source_file_count < 1
    ):
        raise CandidateMaterializationError(
            "qualification receipt source identity has an invalid source file count"
        )
    _require_sha256(
        source.get("source_files_sha256"),
        label="qualification receipt source file manifest",
    )
    dependency_contract = source.get("dependency_contract")
    if (
        not isinstance(dependency_contract, dict)
        or set(dependency_contract) != SOURCE_EXPORT_V2_DEPENDENCY_FIELDS
    ):
        raise CandidateMaterializationError(
            "qualification receipt source identity has a malformed dependency contract"
        )
    _require_sha256(
        dependency_contract.get("component_manifest_sha256"),
        label="qualification receipt third-party component manifest",
    )
    _require_sha256(
        dependency_contract.get("notices_sha256"),
        label="qualification receipt third-party notices",
    )
    source_export_package = dependency_contract.get("source_export_package")
    if (
        not isinstance(source_export_package, dict)
        or set(source_export_package) != SOURCE_EXPORT_PACKAGE_FIELDS
        or source_export_package.get("commit_object_name") != "SOURCE_COMMIT_OBJECT"
        # v3 binds ordinary Git blobs; v4 additionally binds the two governed
        # offline LFS payloads to their canonical pointer blobs. The source
        # verifier still proves the exact representation and physical bytes.
        # v5 additionally binds flattened submodule files to their Git commits.
        or type(source_export_package.get("version")) is not int
        or source_export_package.get("version") not in {3, 4, 5}
        or isinstance(source_export_package.get("commit_object_size"), bool)
        or not isinstance(source_export_package.get("commit_object_size"), int)
        or source_export_package["commit_object_size"] < 1
    ):
        raise CandidateMaterializationError(
            "qualification receipt source export package is malformed"
        )
    _require_sha256(
        source_export_package.get("commit_object_sha256"),
        label="qualification receipt source commit object",
    )
    pins = dependency_contract.get("component_pins")
    if not isinstance(pins, list):
        raise CandidateMaterializationError(
            "qualification receipt source identity has malformed dependency pins"
        )
    previous_pin_id: bytes | None = None
    for pin_record in pins:
        if (
            not isinstance(pin_record, dict)
            or set(pin_record) != {"id", "pin"}
            or not isinstance(pin_record.get("id"), str)
            or not pin_record["id"]
            or not isinstance(pin_record.get("pin"), dict)
            or not pin_record["pin"]
        ):
            raise CandidateMaterializationError(
                "qualification receipt source identity has malformed dependency pins"
            )
        encoded_pin_id = os.fsencode(pin_record["id"])
        if previous_pin_id is not None and encoded_pin_id <= previous_pin_id:
            raise CandidateMaterializationError(
                "qualification receipt source identity has noncanonical dependency pins"
            )
        previous_pin_id = encoded_pin_id


def _require_qualification_dependency_hashes(
    qualification: dict[str, Any],
    authority: QualificationDependencyAuthority,
) -> None:
    expected = {
        "ghostty_artifact_manifest_sha256": authority.ghostty_manifest_snapshot.sha256,
        "ghostty_surface_manifest_sha256": authority.ghostty_surface_manifest_snapshot.sha256,
        "sleigh_materialization_manifest_sha256": authority.sleigh_manifest_snapshot.sha256,
    }
    for field, observed in expected.items():
        if qualification.get(field) != observed:
            raise CandidateMaterializationError(
                f"qualified dependency bytes differ from receipt field {field}"
            )


def _require_release_dependency_provenance(
    provenance: dict[str, Any],
    authority: QualificationDependencyAuthority,
) -> None:
    sleigh = authority.sleigh_identity
    package = sleigh["package"]
    expected = {
        "ghostty_surface_source_manifest_sha256": (
            authority.ghostty_surface_manifest_snapshot.sha256
        ),
        "sleigh_materialization_schema_version": sleigh["schemaVersion"],
        "sleigh_materialization_component_id": sleigh["componentId"],
        "sleigh_materialization_manifest_sha256": authority.sleigh_manifest_snapshot.sha256,
        "sleigh_materialization_tree_sha256": package["treeSha256"],
    }
    for field, observed in expected.items():
        if provenance.get(field) != observed:
            raise CandidateMaterializationError(
                f"Release provenance {field} differs from the qualified dependency"
            )


def _capture_qualification_dependency_authority(
    *,
    repository_root: Path,
    qualification_receipt_path: Path,
    qualification: dict[str, Any],
    release_app: Path,
    provenance: dict[str, Any],
    commit: str,
    tree: str,
) -> QualificationDependencyAuthority:
    """Bind current dependency bytes to the receipt and signed Release product."""

    ghostty_root = Path(str(qualification["ghostty_source_dir"]))
    ghostty_library_root = ghostty_root / "zig-out/lib"
    ghostty_manifest_path = ghostty_library_root / ".macscope-ghostty-vt-manifest"
    ghostty_manifest_payload, ghostty_manifest_metadata = _stable_file_bytes(
        ghostty_manifest_path
    )
    ghostty_manifest_snapshot = FileSnapshot(
        path=ghostty_manifest_path,
        metadata=ghostty_manifest_metadata,
        sha256=_sha256_bytes(ghostty_manifest_payload),
    )
    try:
        ghostty_manifest_identity = _parse_text_manifest(
            ghostty_manifest_payload,
            label="qualified Ghostty VT manifest",
        )
    except ProductIdentityError as error:
        raise CandidateMaterializationError(str(error)) from error
    ghostty_artifact = _canonical_dependency_artifact(
        ghostty_library_root / "libghostty-vt.dylib",
        ghostty_library_root,
    )
    ghostty_artifact_snapshot = capture_file_snapshot(ghostty_artifact)
    ghostty_surface_manifest_snapshot = capture_file_snapshot(
        Path(str(qualification["ghostty_surface_source_dir"]))
        / "macos/.macscope-ghostty-surface-manifest"
    )
    sleigh_root = Path(str(qualification["sleigh_materialization_root"])).resolve(
        strict=True
    )
    sleigh_manifest_snapshot = capture_file_snapshot(
        sleigh_root / "MATERIALIZATION.json"
    )
    sleigh_root_snapshot = capture_bundle_snapshot(sleigh_root)
    try:
        sleigh_identity = verified_sleigh_materialization(
            argparse.Namespace(
                repository_root=repository_root,
                sleigh_materialization_root=sleigh_root,
                sleigh_materialization_verifier=None,
            ),
            materialization_root=sleigh_root,
        )
    except ProvenanceError as error:
        raise CandidateMaterializationError(str(error)) from error
    authority = QualificationDependencyAuthority(
        ghostty_manifest_snapshot=ghostty_manifest_snapshot,
        ghostty_artifact_snapshot=ghostty_artifact_snapshot,
        ghostty_surface_manifest_snapshot=ghostty_surface_manifest_snapshot,
        sleigh_manifest_snapshot=sleigh_manifest_snapshot,
        sleigh_root_snapshot=sleigh_root_snapshot,
        ghostty_manifest_identity=ghostty_manifest_identity,
        sleigh_identity=sleigh_identity,
    )
    _require_qualification_dependency_hashes(qualification, authority)

    source = qualification["source_identity"]
    run_root = qualification_receipt_path.parent
    validator_arguments = argparse.Namespace(
        receipt=qualification_receipt_path,
        run_root=run_root,
        derived_data_root=run_root / "DerivedData",
        build_source_root=Path(str(qualification["build_source_root"])),
        dependency_cache_root=Path(str(qualification["dependency_cache_root"])),
        expected_mode="full-test",
        expected_integration_ref=str(source["canonical_integration_ref"]),
        expected_integration_commit=commit,
        expected_integration_tree=tree,
        dependency_network_authorized=qualification["dependency_network_allowed"],
        app_bundle=release_app,
    )
    try:
        validate_qualification_build(validator_arguments)
    except ProductIdentityError as error:
        raise CandidateMaterializationError(
            f"strict qualification dependency/product validation failed: {error}"
        ) from error

    for snapshot in authority.file_snapshots:
        require_unchanged_file_snapshot(
            snapshot,
            phase="strict qualification dependency/product validation",
        )
    require_unchanged_bundle_snapshot(
        sleigh_root_snapshot,
        phase="strict qualification dependency/product validation",
    )
    _require_release_dependency_provenance(provenance, authority)
    return authority


def validate_native_preparation_authority(
    receipt: dict[str, Any],
    *,
    expected_source: dict[str, object],
    expected_toolchain: dict[str, str] | None = None,
) -> None:
    if receipt.get("source") != expected_source:
        raise CandidateMaterializationError(
            "native live preparation source is not the exact clean candidate"
        )
    if expected_toolchain is not None and receipt.get("toolchain") != expected_toolchain:
        raise CandidateMaterializationError(
            "native live preparation toolchain differs from the exact candidate toolchain"
        )


def _validate_native_preparation_artifacts(
    *,
    helper: Path,
    receipt_path: Path,
    xctestrun: Path,
    candidate_app: Path,
    test_bundle: Path,
    receipt_snapshot: FileSnapshot,
    xctestrun_snapshot: FileSnapshot,
    app_snapshot: BundleSnapshot,
) -> None:
    """Run the independent validator inside one receipt/product snapshot fence."""

    _run(
        [
            "/usr/bin/python3",
            "-B",
            str(helper),
            "validate-artifacts",
            "--receipt",
            str(receipt_path),
            "--xctestrun",
            str(xctestrun),
            "--candidate-app",
            str(candidate_app),
            "--test-bundle",
            str(test_bundle),
        ]
    )
    for snapshot in (receipt_snapshot, xctestrun_snapshot):
        require_unchanged_file_snapshot(
            snapshot,
            phase="native preparation subprocess validation",
        )
    require_unchanged_bundle_snapshot(
        app_snapshot,
        phase="native preparation subprocess validation",
    )


def _tool(
    tool_id: str,
    executable_or_identity_file: Path,
    version_argv: list[str],
) -> dict[str, str]:
    _ordinary_file(executable_or_identity_file)
    version = _run(version_argv).stdout.strip().replace("\n", " | ")
    if not version:
        raise CandidateMaterializationError(f"tool version is empty: {tool_id}")
    return {
        "tool_id": tool_id,
        "version": version,
        "identity_sha256": _sha256_file(executable_or_identity_file),
    }


def _embedded_executables(app: Path) -> list[dict[str, str]]:
    root = app / "Contents/XPCServices"
    _ordinary_directory(root)
    known = {
        "AIAgentWorkerXPCService": "ai-agent-worker",
        "AnalysisWorkerXPCService": "analysis-worker",
        "NativeDecompilerXPCService": "native-decompiler",
        "ShellBrokerXPCService": "shell-broker",
    }
    values: list[dict[str, str]] = []
    for bundle in sorted(root.glob("*.xpc")):
        bundle_id, executable = _bundle_executable(bundle)
        name = executable.name
        identity_id = known.get(name)
        if identity_id is None:
            raise CandidateMaterializationError(
                f"embedded executable lacks a frozen identity ID: {bundle_id} ({name})"
            )
        values.append({"identity_id": identity_id, "sha256": _sha256_file(executable)})
    if not values:
        raise CandidateMaterializationError("Release app contains no embedded XPC executables")
    return sorted(values, key=lambda item: item["identity_id"])


def _qualification_executables(
    debug_app: Path,
    native_live_app: Path,
) -> list[dict[str, str]]:
    values: list[dict[str, str]] = []
    for identity_id in sorted(PRODUCT_LAYOUTS):
        layout = PRODUCT_LAYOUTS[identity_id]
        product_root = (
            native_live_app
            if identity_id in {"native-live-app", "native-decompiler"}
            else debug_app
        )
        bundle = (
            product_root
            if layout.bundle_relative_path == "."
            else product_root / layout.bundle_relative_path
        )
        bundle_id, executable = _bundle_executable(bundle)
        values.append(
            {
                "bundle_identifier": bundle_id,
                "identity_id": identity_id,
                "sha256": _sha256_file(executable),
            }
        )
    return values


def _sleigh_source_pin_evidence(
    repository_root: Path, pin: dict[str, Any], manifest: dict[str, Any]
) -> tuple[FileSnapshot, ...]:
    """Bind the historical package pin and current source closure separately."""
    snapshots = []
    documents = []
    for relative in (
        "ThirdParty/SleighNative/MATERIALIZATION.json",
        "ThirdParty/SleighNative/Source/MATERIALIZATION.json",
    ):
        snapshot = capture_file_snapshot(repository_root / relative)
        payload, _ = _stable_file_bytes(snapshot.path)
        if hashlib.sha256(payload).hexdigest() != snapshot.sha256:
            raise CandidateMaterializationError("SLEIGH governed manifest changed during admission")
        try:
            document = json.loads(payload)
        except (ValueError, UnicodeError) as error:
            raise CandidateMaterializationError("invalid SLEIGH governed manifest") from error
        if not isinstance(document, dict):
            raise CandidateMaterializationError("SLEIGH governed manifest must be an object")
        snapshots.append(snapshot)
        documents.append(document)
    legacy, source = documents
    package = legacy.get("package")
    artifact = legacy.get("artifact")
    if (
        legacy.get("schemaVersion") != 1
        or legacy.get("componentId") != "sleigh-native-dcp03b4"
        or not isinstance(package, dict)
        or not isinstance(artifact, dict)
        or legacy.get("sleighGitRevision") != pin.get("git_revision")
        or package.get("treeSha256") != _require_sha256(pin.get("source_tree_sha256"), label="SLEIGH historical package pin")
        or artifact.get("sha256") != _require_sha256(pin.get("selected_artifact_sha256"), label="SLEIGH historical artifact pin")
    ):
        raise CandidateMaterializationError("SLEIGH historical package differs from its frozen inventory pin")
    build = manifest.get("sourceBuild")
    if (
        source.get("schemaVersion") != 1
        or source.get("componentId") != "sleigh-native-source-dcp03b4"
        or not isinstance(build, dict)
        or build.get("sourceManifestSha256") != snapshots[1].sha256
    ):
        raise CandidateMaterializationError("SLEIGH source manifest binding differs")
    for component in ("sleigh", "ghidra"):
        governed = source.get(component)
        if (
            not isinstance(governed, dict)
            or manifest.get(component + "GitRevision") != governed.get("revision")
            or not governed.get("revision")
            or build.get(component + "GitTree") != governed.get("gitTree")
            or not governed.get("gitTree")
            or build.get(component + "TreeSha256") != _require_sha256(governed.get("treeSha256"), label=component + " governed source tree")
        ):
            raise CandidateMaterializationError("SLEIGH governed source closure differs: " + component)
    if not isinstance(source.get("patches"), list) or build.get("patches") != source["patches"]:
        raise CandidateMaterializationError("SLEIGH governed source patches differ")
    for snapshot in snapshots:
        require_unchanged_file_snapshot(snapshot, phase="SLEIGH source pin admission")
    return tuple(snapshots)


def _materialization_dependency(
    qualification: dict[str, Any],
    repository_root: Path,
    authority: QualificationDependencyAuthority,
    *,
    governed_snapshots: list[FileSnapshot] | None = None,
) -> tuple[dict[str, str], dict[str, str]]:
    sleigh_manifest = authority.sleigh_identity
    source = qualification.get("source_identity")
    contract = source.get("dependency_contract") if isinstance(source, dict) else None
    pins = contract.get("component_pins") if isinstance(contract, dict) else None
    if not isinstance(pins, list):
        raise CandidateMaterializationError("qualification receipt lacks dependency pins")
    by_id = {
        item.get("id"): item.get("pin")
        for item in pins
        if isinstance(item, dict) and isinstance(item.get("pin"), dict)
    }
    ghostty_pin = by_id.get("ghostty-vt")
    sleigh_pin = by_id.get("sleigh-native-dcp03b4")
    if not isinstance(ghostty_pin, dict) or not isinstance(sleigh_pin, dict):
        raise CandidateMaterializationError("qualification receipt lacks Ghostty or SLEIGH pin")
    package = sleigh_manifest.get("package")
    source_build = sleigh_manifest.get("sourceBuild")
    if not isinstance(package, dict) or not isinstance(source_build, dict):
        raise CandidateMaterializationError(
            "SLEIGH materialization lacks package or source-build identity"
        )
    ghostty = {
        "dependency_id": "ghostty-vt",
        "source_revision": str(ghostty_pin.get("git_revision", "")),
        "source_tree_sha256": _require_sha256(
            ghostty_pin.get("source_tree_sha256"),
            label="Ghostty source tree",
        ),
        "manifest_sha256": _sha256_file(repository_root / "Scripts/ghostty-vt-source.contract"),
        "artifact_sha256": authority.ghostty_artifact_snapshot.sha256,
    }
    sleigh = {
        "dependency_id": "sleigh-native",
        "source_revision": str(sleigh_manifest.get("sleighGitRevision", "")),
        "source_tree_sha256": _require_sha256(
            source_build.get("sleighTreeSha256"),
            label="SLEIGH verified source tree",
        ),
        "manifest_sha256": authority.sleigh_manifest_snapshot.sha256,
        "artifact_sha256": _require_sha256(
            package.get("treeSha256"),
            label="SLEIGH materialized package tree",
        ),
    }
    if ghostty["source_revision"] != ghostty_pin.get("git_revision"):
        raise CandidateMaterializationError("Ghostty source revision is inconsistent")
    if (
        authority.ghostty_manifest_identity.get("source_revision")
        != ghostty_pin.get("git_revision")
    ):
        raise CandidateMaterializationError(
            "qualified Ghostty source revision differs from its frozen source pin"
        )
    if (
        authority.ghostty_manifest_identity.get("source_tree_sha256")
        != ghostty_pin.get("source_tree_sha256")
    ):
        raise CandidateMaterializationError(
            "qualified Ghostty source tree differs from its frozen source pin"
        )
    if sleigh["source_revision"] != sleigh_pin.get("git_revision"):
        raise CandidateMaterializationError("SLEIGH source revision is inconsistent")
    snapshots = _sleigh_source_pin_evidence(repository_root, sleigh_pin, sleigh_manifest)
    if governed_snapshots is not None:
        governed_snapshots.extend(snapshots)
    return ghostty, sleigh


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--release-app", type=Path, required=True)
    parser.add_argument("--debug-app", type=Path, required=True)
    parser.add_argument("--native-live-preparation-receipt", type=Path, required=True)
    parser.add_argument("--release-qualification-inputs", type=Path, required=True)
    parser.add_argument("--debug-qualification-inputs", type=Path, required=True)
    parser.add_argument("--base-commit", required=True)
    parser.add_argument("--task10-commit", required=True)
    parser.add_argument("--task10-evidence", type=Path, required=True)
    parser.add_argument("--semantic-prerequisites", type=Path,
        help="optional closed v1 JSON manifest of all six prerequisite commit/tree/evidence_path identities; not gate acceptance")
    parser.add_argument("--repository-label", default="gitfox-local:MacScope")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def _prerequisite_file_path(value: str | Path) -> Path:
    if not isinstance(value, (str, Path)) or not str(value):
        raise CandidateMaterializationError("prerequisite input path must be an absolute ordinary file")
    path = Path(value)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise CandidateMaterializationError("prerequisite input path must be canonical and absolute without symlinks")
    _ordinary_file(path)
    return path


def _semantic_prerequisites(
    arguments: argparse.Namespace, root: Path, candidate_commit: str,
) -> tuple[list[dict[str, str]], tuple[FileSnapshot, ...]]:
    """Bind explicit source lineage and actual bytes, never prerequisite status."""
    task10_commit = _require_git_object(arguments.task10_commit, label="Task 10 commit")
    task10_tree = _require_git_object(
        _git(root, "rev-parse", f"{task10_commit}^{{tree}}"), label="Task 10 tree")
    _require_ancestor(root, task10_commit, candidate_commit, label="Task 10 prerequisite")
    task10_snapshot = capture_file_snapshot(arguments.task10_evidence)
    legacy = dict(prerequisite_id="task-10", commit=task10_commit, tree=task10_tree,
                  evidence_sha256=task10_snapshot.sha256)
    manifest = getattr(arguments, "semantic_prerequisites", None)
    if manifest is None:
        return [legacy], (task10_snapshot,)

    manifest = _prerequisite_file_path(manifest)
    payload, metadata = _stable_file_bytes(manifest)
    snapshots = [FileSnapshot(manifest, metadata, _sha256_bytes(payload), canonical_path_required=True)]

    def closed_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise CandidateMaterializationError("duplicate prerequisite JSON field")
            result[key] = value
        return result

    try:
        document = json.loads(payload.decode("utf-8"), object_pairs_hook=closed_pairs)
    except (ValueError, UnicodeError) as error:
        raise CandidateMaterializationError("cannot decode semantic prerequisite input") from error
    if (type(document) is not dict or set(document) != {"schema_version", "prerequisites"}
            or type(document["schema_version"]) is not int or document["schema_version"] != 1
            or type(document["prerequisites"]) is not list):
        raise CandidateMaterializationError("semantic prerequisite input requires the exact version 1 fields")
    entries = document["prerequisites"]
    fields = {"prerequisite_id", "commit", "tree", "evidence_path"}
    if (len(entries) != len(SEMANTIC_PREREQUISITE_IDS)
            or any(type(item) is not dict or set(item) != fields
                   or any(type(value) is not str for value in item.values()) for item in entries)
            or {item["prerequisite_id"] for item in entries} != SEMANTIC_PREREQUISITE_IDS):
        raise CandidateMaterializationError("semantic prerequisite input requires all six exact unique identities")
    records = []
    for item in sorted(entries, key=lambda entry: entry["prerequisite_id"]):
        identity = item["prerequisite_id"]
        commit = _require_git_object(item["commit"], label=f"{identity} commit")
        tree = _require_git_object(item["tree"], label=f"{identity} tree")
        if _git(root, "cat-file", "-t", commit) != "commit":
            raise CandidateMaterializationError(f"{identity} must name an actual commit object")
        if _git(root, "rev-parse", f"{commit}^{{tree}}") != tree:
            raise CandidateMaterializationError(f"{identity} declared tree differs from actual commit tree")
        _require_ancestor(root, commit, candidate_commit, label=f"{identity} prerequisite")
        snapshot = replace(capture_file_snapshot(_prerequisite_file_path(item["evidence_path"])),
                           canonical_path_required=True)
        record = dict(prerequisite_id=identity, commit=commit, tree=tree, evidence_sha256=snapshot.sha256)
        if identity == "task-10" and (record != legacy
                or snapshot.path != task10_snapshot.path.resolve(strict=True)
                or snapshot.metadata != task10_snapshot.metadata):
            raise CandidateMaterializationError("explicit Task 10 prerequisite differs from legacy authority")
        records.append(record)
        snapshots.append(snapshot)
    for snapshot in snapshots:
        require_unchanged_file_snapshot(snapshot, phase="semantic prerequisite admission")
    return records, tuple(snapshots)


def _qualified_generated_project_snapshots(
    run: Path, *, commit: str, tree: str, project_yml_sha256: str
) -> tuple[FileSnapshot, tuple[FileSnapshot, ...]]:
    try:
        arguments = dict(commit=commit, tree=tree, project_yml_sha256=project_yml_sha256)
        project = generated_project_evidence.validate(run, **arguments)
        snapshots = tuple(capture_file_snapshot(path) for path in generated_project_evidence.evidence_files(run))
        generated_project_evidence.validate(run, **arguments)
        for snapshot in snapshots:
            require_unchanged_file_snapshot(snapshot, phase="generated project evidence admission")
        return next(snapshot for snapshot in snapshots if snapshot.path == project), snapshots
    except generated_project_evidence.GeneratedProjectEvidenceError as error:
        raise CandidateMaterializationError(str(error)) from error


def materialize(
    arguments: argparse.Namespace,
    *,
    source_snapshot: SourceSnapshot | None = None,
    publication_fences: list[CandidatePublicationFence] | None = None,
) -> dict[str, Any]:
    root = arguments.repository_root.resolve(strict=True)
    release_app = arguments.release_app.resolve(strict=True)
    debug_app = arguments.debug_app.resolve(strict=True)
    native_receipt_path = arguments.native_live_preparation_receipt
    if not native_receipt_path.is_absolute():
        raise CandidateMaterializationError(
            "native live preparation receipt must be an absolute path"
        )
    native_receipt_snapshot = capture_file_snapshot(native_receipt_path)
    native_receipt = _read_json(native_receipt_path)
    native_artifacts = native_receipt.get("artifacts")
    native_app_record = (
        native_artifacts.get("app") if isinstance(native_artifacts, dict) else None
    )
    native_xctestrun_record = (
        native_artifacts.get("xctestrun") if isinstance(native_artifacts, dict) else None
    )
    native_core_tests_record = (
        native_artifacts.get("core_tests") if isinstance(native_artifacts, dict) else None
    )
    if (
        not isinstance(native_app_record, dict)
        or not isinstance(native_xctestrun_record, dict)
        or not isinstance(native_core_tests_record, dict)
    ):
        raise CandidateMaterializationError(
            "native live preparation receipt lacks its app, xctestrun, or CoreTests artifact"
        )
    native_app_value = native_app_record.get("path")
    native_xctestrun_value = native_xctestrun_record.get("path")
    native_core_tests_value = native_core_tests_record.get("path")
    if not isinstance(native_app_value, str) or not Path(native_app_value).is_absolute():
        raise CandidateMaterializationError(
            "native live preparation receipt app path is not absolute"
        )
    if not isinstance(native_xctestrun_value, str) or not Path(
        native_xctestrun_value
    ).is_absolute():
        raise CandidateMaterializationError(
            "native live preparation receipt xctestrun path is not absolute"
        )
    if not isinstance(native_core_tests_value, str) or not Path(
        native_core_tests_value
    ).is_absolute():
        raise CandidateMaterializationError(
            "native live preparation receipt CoreTests path is not absolute"
        )
    native_live_app = Path(native_app_value).resolve(strict=True)
    native_live_xctestrun = Path(native_xctestrun_value).resolve(strict=True)
    native_live_core_tests = Path(native_core_tests_value).resolve(strict=True)
    expected_native_core_tests = (
        debug_app / "Contents/PlugIns/CoreTests.xctest"
    ).resolve(strict=True)
    if native_live_core_tests != expected_native_core_tests:
        raise CandidateMaterializationError(
            "native live preparation receipt does not bind the exact Debug CoreTests product"
        )
    native_live_xctestrun_snapshot = capture_file_snapshot(native_live_xctestrun)
    native_live_bundle_snapshot = capture_bundle_snapshot(native_live_app, app_root=True)
    output = arguments.output
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise CandidateMaterializationError("output must be an absent absolute path")
    _ordinary_directory(output.parent)
    observed_snapshot = _require_clean_source_snapshot(root)
    if source_snapshot is not None and source_snapshot != observed_snapshot:
        raise CandidateMaterializationError(
            "candidate source identity drifted before candidate materialization"
        )
    source_snapshot = source_snapshot or observed_snapshot
    commit = source_snapshot.commit
    tree = source_snapshot.tree
    project_yml = root / "MacScope/project.yml"
    project_yml_snapshot = capture_file_snapshot(project_yml)
    generated_project_snapshot, project_evidence_snapshots = _qualified_generated_project_snapshots(
        arguments.release_qualification_inputs.parent,
        commit=commit, tree=tree, project_yml_sha256=project_yml_snapshot.sha256,
    )
    expected_native_source = {
        "repository": arguments.repository_label,
        "branch_label": source_snapshot.branch_label,
        "commit": commit,
        "tree": tree,
        "dirty": False,
        "project_yml_sha256": project_yml_snapshot.sha256,
        "generated_project_sha256": generated_project_snapshot.sha256,
    }
    validate_native_preparation_authority(
        native_receipt,
        expected_source=expected_native_source,
    )
    preparation_helper = (
        root
        / "Scripts/reconstruction/native_live_preparation_receipt.py"
    )
    _ordinary_file(preparation_helper)
    _validate_native_preparation_artifacts(
        helper=preparation_helper,
        receipt_path=native_receipt_path,
        xctestrun=native_live_xctestrun,
        candidate_app=native_live_app,
        test_bundle=native_live_core_tests,
        receipt_snapshot=native_receipt_snapshot,
        xctestrun_snapshot=native_live_xctestrun_snapshot,
        app_snapshot=native_live_bundle_snapshot,
    )
    base_commit = _require_git_object(arguments.base_commit, label="base commit")
    base_tree = _require_git_object(
        _git(root, "rev-parse", f"{base_commit}^{{tree}}"),
        label="base tree",
    )
    _require_ancestor(root, base_commit, commit, label="base commit")
    semantic_prerequisites, prerequisite_snapshots = _semantic_prerequisites(arguments, root, commit)
    release_inputs_snapshot = capture_file_snapshot(arguments.release_qualification_inputs)
    debug_inputs_snapshot = capture_file_snapshot(arguments.debug_qualification_inputs)
    require_single_full_test_receipt(
        release_inputs_snapshot,
        debug_inputs_snapshot,
    )
    release_inputs = _read_json(arguments.release_qualification_inputs)
    debug_inputs = _read_json(arguments.debug_qualification_inputs)
    _qualification_source(
        release_inputs,
        expected_mode="full-test",
        commit=commit,
        tree=tree,
    )
    _qualification_source(
        debug_inputs,
        expected_mode="full-test",
        commit=commit,
        tree=tree,
    )

    # Capture the three product trees before any provenance, executable, or
    # dependency, executable, or codesign query.  The matching final fence
    # below rejects a candidate assembled from a tree that changes during
    # those later observations.
    release_bundle_snapshot = capture_bundle_snapshot(release_app, app_root=True)
    debug_bundle_snapshot = capture_bundle_snapshot(debug_app, app_root=True)

    provenance_path = release_app / "Contents/Resources/MacScopeBuildProvenance.json"
    provenance = _read_json(provenance_path)
    if (
        provenance.get("configuration") != "Release"
        or provenance.get("qualification_eligible") is not True
        or provenance.get("git_head_commit") != commit
        or provenance.get("git_head_tree") != tree
    ):
        raise CandidateMaterializationError(
            "Release provenance is not eligible or bound to the exact candidate"
        )
    dependency_authority = _capture_qualification_dependency_authority(
        repository_root=root,
        qualification_receipt_path=release_inputs_snapshot.path,
        qualification=release_inputs,
        release_app=release_app,
        provenance=provenance,
        commit=commit,
        tree=tree,
    )
    governed_dependency_snapshots: list[FileSnapshot] = []
    release_dependencies = _materialization_dependency(
        release_inputs,
        root,
        dependency_authority,
        governed_snapshots=governed_dependency_snapshots,
    )

    release_bundle_id, release_executable = _bundle_executable(release_app)
    release_digests = release_bundle_snapshot.digests
    signing = _codesign_identity(release_app)
    qualification_values = _qualification_executables(debug_app, native_live_app)

    developer_dir_value = os.environ.get("DEVELOPER_DIR")
    if developer_dir_value is None:
        developer_dir_value = _run(["/usr/bin/xcode-select", "-p"]).stdout.strip()
    developer_dir = Path(developer_dir_value).resolve(strict=True)
    xcodebuild = developer_dir / "usr/bin/xcodebuild"
    swiftc = Path(_run(["/usr/bin/xcrun", "--find", "swiftc"]).stdout.strip()).resolve(strict=True)
    clang = Path(_run(["/usr/bin/xcrun", "--find", "clang"]).stdout.strip()).resolve(strict=True)
    sdk_root = Path(
        _run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
    ).resolve(strict=True)
    sdk_settings = sdk_root / "SDKSettings.json"
    cmake = Path("/opt/homebrew/bin/cmake").resolve(strict=True)
    ninja = Path("/opt/homebrew/bin/ninja").resolve(strict=True)
    python = Path("/usr/bin/python3").resolve(strict=True)
    zig = Path(str(debug_inputs.get("zig_executable", ""))).resolve(strict=True)
    tools = [
        _tool("xcode", xcodebuild, [str(xcodebuild), "-version"]),
        _tool("swift", swiftc, [str(swiftc), "--version"]),
        _tool(
            "sdk",
            sdk_settings,
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
        ),
        _tool("clang", clang, [str(clang), "--version"]),
        _tool("cmake", cmake, [str(cmake), "--version"]),
        _tool("ninja", ninja, [str(ninja), "--version"]),
        _tool("python", python, [str(python), "--version"]),
        _tool("zig", zig, [str(zig), "version"]),
    ]
    xcode_lines = _run([str(xcodebuild), "-version"]).stdout.splitlines()
    if len(xcode_lines) != 2:
        raise CandidateMaterializationError("Xcode did not emit one version/build pair")
    expected_native_toolchain = {
        "developer_dir": str(developer_dir),
        "xcodebuild_sha256": _sha256_file(xcodebuild),
        "xcode_version": xcode_lines[0].removeprefix("Xcode ").strip(),
        "xcode_build": xcode_lines[1].removeprefix("Build version ").strip(),
        "swiftc_sha256": _sha256_file(swiftc),
        "swift_version": _run([str(swiftc), "--version"]).stdout.strip(),
        "sdk_path": str(sdk_root),
        "sdk_settings_sha256": _sha256_file(sdk_settings),
        "sdk_version": _run(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]
        ).stdout.strip(),
        "sdk_build": _run(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
        ).stdout.strip(),
    }
    validate_native_preparation_authority(
        native_receipt,
        expected_source=expected_native_source,
        expected_toolchain=expected_native_toolchain,
    )

    ai_protocol_files = [
        path
        for path in (root / "MacScope/AIWorkerProtocol").rglob("*.swift")
        if path.is_file()
    ]
    gate_f_files = [
        path
        for path in (root / "Scripts/reconstruction_gate_f").glob("*.py")
        if path.is_file()
    ]
    sleigh_manifest = dependency_authority.sleigh_identity
    sleigh_package = sleigh_manifest["package"]
    if provenance.get("project_yml_sha256") != project_yml_snapshot.sha256:
        raise CandidateMaterializationError("Release provenance project.yml identity drifted")

    application: dict[str, Any] = {
        "bundle_identifier": release_bundle_id,
        "bundle_sha256": release_digests.content_sha256,
        "closed_tree_sha256": release_digests.closed_tree_sha256,
        "root_mode": stat.S_IMODE(release_app.stat().st_mode),
        "executable_sha256": _sha256_file(release_executable),
        "embedded_executables": _embedded_executables(release_app),
        "qualification_executables": qualification_values,
        **signing,
    }
    document: dict[str, Any] = {
        "schema_version": CANDIDATE_SCHEMA_VERSION,
        "subject_kind": "candidate",
        "source": {
            "repository": arguments.repository_label,
            "branch_label": source_snapshot.branch_label,
            "commit": commit,
            "tree": tree,
            "base_commit": base_commit,
            "base_tree": base_tree,
            "dirty": False,
            "project_yml_sha256": project_yml_snapshot.sha256,
            "generated_project_sha256": generated_project_snapshot.sha256,
            "semantic_prerequisites": semantic_prerequisites,
        },
        "tools": sorted(tools, key=lambda item: item["tool_id"]),
        "dependencies": sorted(release_dependencies, key=lambda item: item["dependency_id"]),
        "application": application,
        "protocols": [
            {
                "protocol_id": "reconstruction-round-output",
                "version": 8,
                "manifest_sha256": _tree_manifest_sha256(ai_protocol_files, root),
            }
        ],
        "packages": [
            {
                "package_id": "native-sleigh",
                "manifest_sha256": dependency_authority.sleigh_manifest_snapshot.sha256,
                "tree_sha256": _require_sha256(
                    sleigh_package.get("treeSha256"),
                    label="SLEIGH package tree",
                ),
            }
        ],
        "schemas": [
            _gate_f_compiler_schema(_tree_manifest_sha256(gate_f_files, root))
        ],
        "selector_catalog_sha256": selector_catalog_identity_sha256(),
        "prospective_merge_commit": None,
        "prospective_merge_tree": None,
        "accepted_postmerge_commit": None,
        "accepted_postmerge_tree": None,
    }
    candidate, issues = parse_candidate_identity(document)
    if candidate is None or issues:
        diagnostics = "; ".join(
            f"{issue.code} at {issue.path}: {issue.message}" for issue in issues
        )
        raise CandidateMaterializationError(
            f"materialized candidate does not satisfy its closed schema: {diagnostics}"
        )
    try:
        validate_products(
            candidate,
            debug_app,
            ("app", "ai-agent-worker"),
        )
        validate_products(
            candidate,
            native_live_app,
            ("native-live-app", "native-decompiler"),
        )
    except ProductIdentityError as error:
        raise CandidateMaterializationError(str(error)) from error
    require_unchanged_bundle_snapshot(
        release_bundle_snapshot,
        phase="candidate identity publication after executable and signing reads",
    )
    require_unchanged_bundle_snapshot(
        debug_bundle_snapshot,
        phase="candidate identity publication after qualification executable reads",
    )
    require_unchanged_bundle_snapshot(
        native_live_bundle_snapshot,
        phase="candidate identity publication after qualification executable reads",
    )
    _require_unchanged_source_snapshot(
        root,
        source_snapshot,
        phase="candidate identity publication",
    )
    for snapshot in prerequisite_snapshots:
        require_unchanged_file_snapshot(snapshot, phase="candidate identity publication")
    publication_fence = CandidatePublicationFence(
        repository_root=root,
        source_snapshot=source_snapshot,
        file_snapshots=(
            native_receipt_snapshot,
            native_live_xctestrun_snapshot,
            project_yml_snapshot,
            generated_project_snapshot,
            *project_evidence_snapshots,
            *prerequisite_snapshots,
            release_inputs_snapshot,
            debug_inputs_snapshot,
            *dependency_authority.file_snapshots,
            *governed_dependency_snapshots,
        ),
        bundle_snapshots=(
            release_bundle_snapshot,
            debug_bundle_snapshot,
            native_live_bundle_snapshot,
            dependency_authority.sleigh_root_snapshot,
        ),
    )
    if publication_fences is not None:
        publication_fences.append(publication_fence)
    return document


def write_candidate_identity(
    output: Path,
    document: dict[str, object],
    *,
    repository_root: Path | None = None,
    source_snapshot: SourceSnapshot | None = None,
    publication_fence: CandidatePublicationFence | None = None,
) -> None:
    """Publish one strict-canonical, create-only candidate identity."""
    if (repository_root is None) != (source_snapshot is None):
        raise CandidateMaterializationError(
            "candidate publication source fence requires both root and snapshot"
        )
    if publication_fence is not None:
        if repository_root is not None or source_snapshot is not None:
            raise CandidateMaterializationError(
                "candidate publication accepts either the complete publication fence or the legacy source fence"
            )
        for snapshot in publication_fence.file_snapshots:
            require_unchanged_file_snapshot(
                snapshot,
                phase="candidate identity create-only publication",
            )
        for snapshot in publication_fence.bundle_snapshots:
            require_unchanged_bundle_snapshot(
                snapshot,
                phase="candidate identity create-only publication",
            )
        _require_unchanged_source_snapshot(
            publication_fence.repository_root,
            publication_fence.source_snapshot,
            phase="candidate identity create-only publication",
        )
    elif repository_root is not None and source_snapshot is not None:
        _require_unchanged_source_snapshot(
            repository_root,
            source_snapshot,
            phase="candidate identity publication",
        )
    descriptor = os.open(
        output,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(canonical_bytes(document))
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        root = arguments.repository_root.resolve(strict=True)
        source_snapshot = _require_clean_source_snapshot(root)
        publication_fences: list[CandidatePublicationFence] = []
        document = materialize(
            arguments,
            source_snapshot=source_snapshot,
            publication_fences=publication_fences,
        )
        if len(publication_fences) != 1:
            raise CandidateMaterializationError(
                "candidate materialization did not produce one complete publication fence"
            )
        write_candidate_identity(
            arguments.output,
            document,
            publication_fence=publication_fences[0],
        )
    except (OSError, UnicodeError, ValueError, CandidateMaterializationError) as error:
        print(f"ERROR: candidate identity materialization failed: {error}", file=sys.stderr)
        return 1
    candidate, issues = parse_candidate_identity(document)
    if candidate is None or issues:  # defensive: materialize() already proved this
        print("ERROR: materialized candidate became invalid before publication", file=sys.stderr)
        return 1
    print(f"MACSCOPE_GATE_F_CANDIDATE_IDENTITY={arguments.output}")
    print(
        "MACSCOPE_GATE_F_CANDIDATE_IDENTITY_SHA256="
        f"{candidate_identity_sha256(candidate)}"
    )
    print(f"MACSCOPE_GATE_F_CANDIDATE_FILE_SHA256={_sha256_file(arguments.output)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
