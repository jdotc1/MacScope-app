#!/usr/bin/env python3
"""Stage the attested native package into one XPC product, safely replacing ours."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import stat
import sys
from pathlib import Path, PurePosixPath


SCRIPT_ROOT = Path(__file__).resolve().parent
STAGER_PATH = SCRIPT_ROOT / "stage_verified_package.py"
STAMP_NAME = "NativeDecompilerPackage.stage.json"
INPUT_LIST_NAME = "NativeDecompilerPackage.inputs.xcfilelist"
OUTPUT_LIST_NAME = "NativeDecompilerPackage.outputs.xcfilelist"
DESTINATION_NAME = "NativeDecompilerPackage"
LINK_INPUT_RELATIVE_PATHS = (
    PurePosixPath("package/lib/libdecomp.a"),
    PurePosixPath("package/lib/libsla.a"),
)
STAMP_SCHEMA_VERSION = 2
MAXIMUM_STAMP_BYTES = 64 * 1024


class XcodeResourceStageError(RuntimeError):
    """Raised when an Xcode product resource cannot be replaced safely."""


class PackageAdmissionError(XcodeResourceStageError):
    """Existing package state is inadmissible and must remain untouched."""


class UnattestedOwnedPackageError(XcodeResourceStageError):
    """The stamp and file lists prove ownership; only the package lacks attestation."""



def _load_stager():
    specification = importlib.util.spec_from_file_location(
        "macscope_stage_verified_package",
        STAGER_PATH,
    )
    if specification is None or specification.loader is None:
        raise XcodeResourceStageError("verified package stager is unavailable")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


_STAGER = _load_stager()
verify_materialization = _STAGER.verify_materialization


def _ordinary_directory(path: Path, label: str) -> Path:
    try:
        resolved, descriptor, _metadata = _STAGER._open_anchored_directory(path, label)
    except Exception as error:
        raise XcodeResourceStageError(f"{label} is missing or unsafe: {error}") from error
    os.close(descriptor)
    return resolved


def _ordinary_file_identity(path: Path, label: str) -> tuple[int, int]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise XcodeResourceStageError(f"{label} is missing or unsafe: {error}") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        raise XcodeResourceStageError(f"{label} must be an ordinary singly linked file")
    return metadata.st_dev, metadata.st_ino


def _ordinary_directory_identity(path: Path, label: str) -> tuple[int, int]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise XcodeResourceStageError(f"{label} is missing or unsafe: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise XcodeResourceStageError(f"{label} must be an ordinary directory")
    return metadata.st_dev, metadata.st_ino


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise XcodeResourceStageError("owned metadata must be an ordinary singly linked file")
        stable = _stable_file_fields(metadata)
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            while block := stream.read(1024 * 1024):
                digest.update(block)
            after_descriptor = os.fstat(stream.fileno())
        try:
            after_path = path.lstat()
        except OSError as error:
            raise XcodeResourceStageError(f"owned metadata changed while it was hashed: {error}") from error
        if (
            not stat.S_ISREG(after_path.st_mode)
            or stat.S_ISLNK(after_path.st_mode)
            or after_path.st_nlink != 1
            or _stable_file_fields(after_descriptor) != stable
            or _stable_file_fields(after_path) != stable
        ):
            raise XcodeResourceStageError("owned metadata changed while it was hashed")
    except OSError as error:
        raise XcodeResourceStageError(f"owned metadata cannot be read: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def _stable_file_fields(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _open_owned_file_anchor(path: Path, label: str):
    descriptor = -1
    try:
        before = path.lstat()
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
        ):
            raise XcodeResourceStageError(f"{label} must be an ordinary singly linked file")
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        fields = _stable_file_fields(before)
        if _stable_file_fields(opened) != fields:
            raise XcodeResourceStageError(f"{label} changed before descriptor anchoring")
        payload = bytearray()
        while block := os.read(descriptor, 1024 * 1024):
            payload.extend(block)
        after = os.fstat(descriptor)
        after_path = path.lstat()
        if (
            _stable_file_fields(after) != fields
            or _stable_file_fields(after_path) != fields
        ):
            raise XcodeResourceStageError(f"{label} changed during descriptor anchoring")
        return path, descriptor, fields, bytes(payload)
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise XcodeResourceStageError(f"{label} cannot be descriptor-anchored: {error}") from error
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def _close_file_anchors(anchors) -> None:
    for anchor in anchors.values():
        os.close(anchor[1])


def _read_stable_bytes(path: Path, maximum_bytes: int, label: str) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise XcodeResourceStageError(f"{label} is missing or unsafe: {error}") from error
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size > maximum_bytes
    ):
        raise XcodeResourceStageError(f"{label} must be a bounded ordinary singly linked file")
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        if _stable_file_fields(opened) != _stable_file_fields(before):
            raise XcodeResourceStageError(f"{label} changed before it was read")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            payload = stream.read(maximum_bytes + 1)
            after_descriptor = os.fstat(stream.fileno())
        after_path = path.lstat()
    except OSError as error:
        raise XcodeResourceStageError(f"{label} cannot be read safely: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(payload) > maximum_bytes:
        raise XcodeResourceStageError(f"{label} exceeds its fixed bound")
    expected = _stable_file_fields(before)
    if (
        _stable_file_fields(after_descriptor) != expected
        or _stable_file_fields(after_path) != expected
    ):
        raise XcodeResourceStageError(f"{label} changed while it was read")
    return payload


def _link_input_records(destination: Path) -> list[dict[str, str]]:
    if os.environ.get("MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE") == "shared-view":
        anchor = _STAGER._open_verified_materialization(destination, "newly staged package")
        try:
            return _link_input_records_from_snapshot(anchor[3])
        finally:
            os.close(anchor[1])
    return [
        {
            "relativePath": relative.as_posix(),
            "sha256": _sha256(destination / Path(relative.as_posix())),
        }
        for relative in LINK_INPUT_RELATIVE_PATHS
    ]


def _link_input_records_from_snapshot(snapshot) -> list[dict[str, str]]:
    digests = {
        relative: digest
        for relative, kind, _fields, digest in snapshot
        if kind == "file" and digest is not None
    }
    records = []
    for relative in LINK_INPUT_RELATIVE_PATHS:
        relative_text = relative.as_posix()
        digest = digests.get(relative_text)
        if digest is None:
            raise XcodeResourceStageError(
                "verified package snapshot lacks an exact native link input"
            )
        records.append({"relativePath": relative_text, "sha256": digest})
    return records


def _canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _read_stamp(path: Path) -> dict[str, object]:
    payload = _read_stable_bytes(path, MAXIMUM_STAMP_BYTES, "ownership stamp")
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise XcodeResourceStageError("ownership stamp is malformed") from error
    required_keys = {
        "schemaVersion",
        "destinationName",
        "materialization",
        "inputFileListSHA256",
        "outputFileListSHA256",
        "linkInputs",
    }
    if not isinstance(value, dict) or set(value) != required_keys:
        raise XcodeResourceStageError("ownership stamp has an unsupported shape")
    if value["schemaVersion"] != STAMP_SCHEMA_VERSION:
        raise XcodeResourceStageError("ownership stamp has an unsupported schema")
    if value["destinationName"] != DESTINATION_NAME:
        raise XcodeResourceStageError("ownership stamp names another destination")
    for key in ("inputFileListSHA256", "outputFileListSHA256"):
        digest = value[key]
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise XcodeResourceStageError("ownership stamp has an invalid digest")
    if not isinstance(value["materialization"], dict):
        raise XcodeResourceStageError("ownership stamp lacks a materialization identity")
    link_inputs = value["linkInputs"]
    if not isinstance(link_inputs, list) or len(link_inputs) != len(LINK_INPUT_RELATIVE_PATHS):
        raise XcodeResourceStageError("ownership stamp lacks exact native link inputs")
    for expected, record in zip(LINK_INPUT_RELATIVE_PATHS, link_inputs):
        if not isinstance(record, dict) or set(record) != {"relativePath", "sha256"}:
            raise XcodeResourceStageError("ownership stamp has malformed native link input")
        digest = record["sha256"]
        if (
            record["relativePath"] != expected.as_posix()
            or not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise XcodeResourceStageError("ownership stamp has invalid native link input")
    return value


def _write_stamp_exclusively(
    path: Path,
    value: dict[str, object],
    metadata_parent_anchor: tuple[Path, int, tuple[int, int], str],
) -> tuple[int, int]:
    payload = _canonical_json(value)
    parent, parent_descriptor, parent_identity, _label = metadata_parent_anchor
    if path.parent != parent:
        raise XcodeResourceStageError("ownership stamp parent does not match retained metadata anchor")
    anchor = None
    try:
        _STAGER._revalidate_directory_anchor(
            parent,
            parent_descriptor,
            parent_identity,
            "ownership stamp parent",
        )
        anchor = _STAGER._write_bytes_exclusively(
            path,
            parent_descriptor,
            payload,
            "ownership stamp",
        )
        _STAGER._revalidate_anchored_file(anchor, "ownership stamp")
        _STAGER._revalidate_directory_anchor(
            parent,
            parent_descriptor,
            parent_identity,
            "ownership stamp parent",
        )
        return anchor[2][0], anchor[2][1]
    except Exception as error:
        if isinstance(error, XcodeResourceStageError):
            raise
        raise XcodeResourceStageError(
            f"ownership stamp cannot be created exclusively: {error}"
        ) from error
    finally:
        if anchor is not None:
            os.close(anchor[1])


def _resource_parent(
    target_build_directory: Path,
    resources_relative: PurePosixPath,
) -> tuple[Path, Path, list[tuple[Path, int, tuple[int, int], str]]]:
    if resources_relative.is_absolute() or not resources_relative.parts:
        raise XcodeResourceStageError("resource folder must be a nonempty relative path")
    if any(
        component in {"", ".", ".."}
        or any(character in component for character in ("\x00", "\r", "\n"))
        for component in resources_relative.parts
    ):
        raise XcodeResourceStageError("resource folder contains an unsafe component")
    try:
        target, directory_descriptor, _target_metadata = _STAGER._open_anchored_directory(
            target_build_directory,
            "target build directory",
        )
    except Exception as error:
        raise XcodeResourceStageError(f"target build directory is missing or unsafe: {error}") from error
    requested_parent = target
    target_anchor_descriptor = -1
    resource_anchor_descriptor = -1
    target_identity = None
    opened = None
    try:
        target_anchor_descriptor = os.dup(directory_descriptor)
        target_identity = os.fstat(target_anchor_descriptor)
        for component in resources_relative.parts:
            try:
                os.mkdir(component, mode=0o755, dir_fd=directory_descriptor)
            except FileExistsError:
                pass
            except OSError as error:
                raise XcodeResourceStageError(
                    f"XPC resource directory cannot be created: {error}"
                ) from error
            try:
                next_descriptor = os.open(
                    component,
                    _STAGER._directory_open_flags(),
                    dir_fd=directory_descriptor,
                )
            except OSError as error:
                raise XcodeResourceStageError(
                    "XPC resource path components must be ordinary directories"
                ) from error
            os.close(directory_descriptor)
            directory_descriptor = next_descriptor
            requested_parent /= component
        opened = os.fstat(directory_descriptor)
        parent = _ordinary_directory(requested_parent, "XPC resource directory")
        observed = requested_parent.lstat()
        if (observed.st_dev, observed.st_ino) != (opened.st_dev, opened.st_ino):
            raise XcodeResourceStageError("XPC resource directory changed during traversal")
        resource_anchor_descriptor = os.dup(directory_descriptor)
    except Exception as error:
        if target_anchor_descriptor >= 0:
            os.close(target_anchor_descriptor)
        if resource_anchor_descriptor >= 0:
            os.close(resource_anchor_descriptor)
        if isinstance(error, OSError):
            raise XcodeResourceStageError(
                f"XPC resource directory cannot be created: {error}"
            ) from error
        raise
    finally:
        if directory_descriptor >= 0:
            os.close(directory_descriptor)
    assert target_identity is not None
    assert opened is not None
    if not parent.is_relative_to(target):
        os.close(target_anchor_descriptor)
        if resource_anchor_descriptor >= 0:
            os.close(resource_anchor_descriptor)
        raise XcodeResourceStageError("XPC resource directory escaped TARGET_BUILD_DIR")
    return target, parent, [
        (
            target,
            target_anchor_descriptor,
            (target_identity.st_dev, target_identity.st_ino),
            "target build directory",
        ),
        (
            parent,
            resource_anchor_descriptor,
            (opened.st_dev, opened.st_ino),
            "resource parent",
        ),
    ]


def _require_exact_output_identity(
    path: Path,
    identity: tuple[int, int],
    *,
    is_directory: bool,
    label: str,
) -> None:
    observed = (
        _ordinary_directory_identity(path, label)
        if is_directory
        else _ordinary_file_identity(path, label)
    )
    if observed != identity:
        raise XcodeResourceStageError(f"{label} changed identity")


def _existing_owned_state(
    destination: Path,
    input_list: Path,
    output_list: Path,
    stamp_path: Path,
) -> tuple[
    dict[str, object],
    dict[Path, tuple[int, int]],
    dict[Path, tuple],
    tuple[
        Path,
        int,
        tuple[int, ...],
        tuple[tuple[str, str, tuple[int, ...], str | None], ...],
        dict[str, object],
    ] | None,
] | None:
    paths = (destination, input_list, output_list, stamp_path)
    present = tuple(os.path.lexists(path) for path in paths)
    if not any(present):
        return None
    metadata_paths = (input_list, output_list, stamp_path)
    if not present[0] and all(present[1:]):
        identities = {
            path: _ordinary_file_identity(path, "existing owned metadata")
            for path in metadata_paths
        }
    elif all(present):
        identities = {
            destination: _ordinary_directory_identity(destination, "existing package resource"),
            input_list: _ordinary_file_identity(input_list, "existing input file list"),
            output_list: _ordinary_file_identity(output_list, "existing output file list"),
            stamp_path: _ordinary_file_identity(stamp_path, "existing ownership stamp"),
        }
    else:
        raise XcodeResourceStageError("existing resource state is not an owned complete staging set")

    metadata_anchors = {}
    materialization_anchor = None
    try:
        for path, label in (
            (input_list, "existing input file list"),
            (output_list, "existing output file list"),
            (stamp_path, "existing ownership stamp"),
        ):
            metadata_anchors[path] = _open_owned_file_anchor(path, label)
        stamp = _read_stamp(stamp_path)
        metadata_digests = {
            path: hashlib.sha256(anchor[3]).hexdigest()
            for path, anchor in metadata_anchors.items()
        }
        if stamp["inputFileListSHA256"] != metadata_digests[input_list]:
            raise XcodeResourceStageError(
                "existing input file list does not match its ownership stamp"
            )
        if stamp["outputFileListSHA256"] != metadata_digests[output_list]:
            raise XcodeResourceStageError(
                "existing output file list does not match its ownership stamp"
            )
        if _canonical_json(stamp) != metadata_anchors[stamp_path][3]:
            raise XcodeResourceStageError("existing ownership stamp changed during anchoring")
        if destination in identities:
            try:
                materialization_anchor = _STAGER._open_verified_materialization(
                    destination,
                    "existing package resource",
                    require_staged_receipt=True,
                )
            except _STAGER.MissingStagedReceiptError as error:
                if error.root_fields[:2] != identities[destination]:
                    raise PackageAdmissionError("existing package changed during admission") from error
                missing = UnattestedOwnedPackageError("owned staged package receipt is absent")
                missing.receipt_evidence = error
                missing.stamp = stamp
                missing.metadata_evidence = {
                    path: (anchor[2], anchor[3]) for path, anchor in metadata_anchors.items()
                }
                raise missing from error
            except Exception as error:
                raise PackageAdmissionError(
                    f"existing package resource admission refused: {error}"
                ) from error
            materialization = materialization_anchor[4]
            if stamp["materialization"] != materialization:
                raise XcodeResourceStageError(
                    "existing package resource does not match its ownership stamp"
                )
            if stamp["linkInputs"] != _link_input_records_from_snapshot(
                materialization_anchor[3]
            ):
                raise XcodeResourceStageError(
                    "existing native link inputs do not match their ownership stamp"
                )
    except Exception as error:
        if materialization_anchor is not None:
            os.close(materialization_anchor[1])
        _close_file_anchors(metadata_anchors)
        if isinstance(error, XcodeResourceStageError):
            raise
        raise XcodeResourceStageError(
            f"existing package resource is not an owned attested copy: {error}"
        ) from error
    return stamp, identities, metadata_anchors, materialization_anchor


def _require_owned_staging_set(
    destination: Path,
    input_list: Path,
    output_list: Path,
    stamp_path: Path,
) -> None:
    """Re-prove ownership just before retirement: real directory plus stamp-bound lists."""
    if not stat.S_ISDIR(destination.lstat().st_mode):
        raise XcodeResourceStageError("existing package resource is not an ordinary directory")
    anchors = {}
    try:
        for path, label in (
            (input_list, "existing input file list"),
            (output_list, "existing output file list"),
            (stamp_path, "existing ownership stamp"),
        ):
            anchors[path] = _open_owned_file_anchor(path, label)
        stamp = _read_stamp(stamp_path)
        if (stamp["inputFileListSHA256"] != hashlib.sha256(anchors[input_list][3]).hexdigest()
                or stamp["outputFileListSHA256"] != hashlib.sha256(anchors[output_list][3]).hexdigest()
                or stamp["destinationName"] != DESTINATION_NAME):
            raise XcodeResourceStageError("existing file lists do not match their ownership stamp")
    finally:
        _close_file_anchors(anchors)


def _validate_absent_receipt_recovery(
    missing, source_anchor, destination, input_list, output_list, stamp_path, parent_anchors,
) -> None:
    """Validate the entire recovery input before the first retirement write."""
    descriptor = -1
    anchors = {}
    try:
        evidence = missing.receipt_evidence
        canonical, descriptor, metadata = _STAGER._open_anchored_directory(
            destination, "unattested package"
        )
        if (canonical != evidence.canonical
                or _STAGER._stable_tree_fields(metadata) != evidence.root_fields):
            raise PackageAdmissionError("unattested package changed before recovery")
        if missing.stamp["materialization"] != source_anchor[4]:
            raise PackageAdmissionError("unattested package identity differs from source")
        files = {relative: (fields[4], digest)
                 for relative, kind, fields, digest in source_anchor[3] if kind == "file"}
        snapshot = _STAGER._closed_tree_snapshot(descriptor, digest_evidence=files)
        if (tuple(record[:3] for record in snapshot)
                != tuple(record[:3] for record in evidence.snapshot)):
            raise PackageAdmissionError("unattested package changed before recovery")
        directories = {r[0] for r in snapshot if r[1] == "directory"}
        source_directories = {r[0] for r in source_anchor[3] if r[1] == "directory"}
        if directories != source_directories:
            raise PackageAdmissionError("unattested package directory set differs from source")
        expected = _expected_file_list_payloads(source_anchor, destination)
        for path in (input_list, output_list, stamp_path):
            anchor = _open_owned_file_anchor(path, "unattested package metadata")
            anchors[path] = anchor
            if (anchor[2], anchor[3]) != missing.metadata_evidence[path]:
                raise PackageAdmissionError("unattested package metadata changed before recovery")
        if (anchors[input_list][3], anchors[output_list][3]) != expected:
            raise PackageAdmissionError("unattested package lists differ from source")
        if missing.stamp["linkInputs"] != _link_input_records_from_snapshot(snapshot):
            raise PackageAdmissionError("unattested package link inputs differ from source")
        for parent, parent_fd, identity, label in parent_anchors:
            _STAGER._revalidate_directory_anchor(parent, parent_fd, identity, label)
        for anchor in anchors.values():
            _STAGER._revalidate_anchored_file(anchor, "unattested package metadata")
        _STAGER._revalidate_anchored_materialization(
            source_anchor[0], source_anchor[1], source_anchor[2], source_anchor[3], "source package"
        )
        _STAGER._revalidate_anchored_materialization(
            canonical, descriptor, evidence.root_fields, snapshot, "unattested package"
        )
        # Receipt appearance or an I/O failure is not permission to retire.
        roots = [None]
        prior_root = os.environ.get("MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT")
        if prior_root:
            roots.append(prior_root)
        for root in roots:
            receipt = _STAGER._staged_receipt_path(canonical, root)
            if _STAGER._receipt_metadata(receipt) is not None:
                raise PackageAdmissionError("staged package receipt appeared before recovery")
    except PackageAdmissionError:
        raise
    except Exception as error:
        raise PackageAdmissionError(f"absent receipt recovery admission refused: {error}") from error
    finally:
        _close_file_anchors(anchors)
        if descriptor >= 0:
            os.close(descriptor)


def _retire_owned_state(
    destination: Path,
    input_list: Path,
    output_list: Path,
    stamp_path: Path,
) -> None:
    """Remove a complete staging set this stager published for another package.

    The package tree goes first, so an interruption leaves owned metadata that
    the metadata-only path recognises and retires on the next build.
    """
    if os.path.lexists(destination):
        for directory, directories, files in os.walk(destination, topdown=False):
            os.chmod(directory, stat.S_IRWXU)
            for name in files:
                os.unlink(os.path.join(directory, name))
            for name in directories:
                child = os.path.join(directory, name)
                if os.path.islink(child):
                    os.unlink(child)
                else:
                    os.rmdir(child)
        os.chmod(destination, stat.S_IRWXU)
        os.rmdir(destination)
    for path in (input_list, output_list, stamp_path):
        if os.path.lexists(path):
            os.unlink(path)


def _close_owned_state(state) -> None:
    if state is not None:
        _close_file_anchors(state[2])
        if state[3] is not None:
            os.close(state[3][1])


def _revalidate_owned_state(
    state,
    destination: Path,
    input_list: Path,
    output_list: Path,
    stamp_path: Path,
    *,
    label: str,
) -> None:
    stamp, identities, metadata_anchors, materialization_anchor = state
    for path in (destination, input_list, output_list, stamp_path):
        if path not in identities:
            continue
        _require_exact_output_identity(
            path,
            identities[path],
            is_directory=path == destination,
            label=f"{label} {path.name}",
        )
    for path, description in (
        (input_list, "input file list"),
        (output_list, "output file list"),
        (stamp_path, "ownership stamp"),
    ):
        try:
            _STAGER._revalidate_anchored_file(
                metadata_anchors[path],
                f"{label} {description}",
            )
        except Exception as error:
            raise XcodeResourceStageError(f"{label} metadata content changed") from error
    if _canonical_json(stamp) != metadata_anchors[stamp_path][3]:
        raise XcodeResourceStageError(f"{label} ownership stamp changed")
    if materialization_anchor is not None:
        try:
            observed_snapshot = _STAGER._revalidate_anchored_materialization(
                materialization_anchor[0],
                materialization_anchor[1],
                materialization_anchor[2],
                materialization_anchor[3],
                label,
            )
        except Exception as error:
            raise XcodeResourceStageError(f"{label} package changed after verification") from error
        if stamp["linkInputs"] != _link_input_records_from_snapshot(observed_snapshot):
            raise XcodeResourceStageError(f"{label} native link inputs changed")


def _revalidate_publication_set(
    state,
    destination: Path,
    input_list: Path,
    output_list: Path,
    stamp_path: Path,
    parent_anchors,
    *,
    label: str,
) -> None:
    _revalidate_owned_state(
        state,
        destination,
        input_list,
        output_list,
        stamp_path,
        label=label,
    )
    for canonical, descriptor, identity, description in parent_anchors:
        try:
            _STAGER._revalidate_directory_anchor(
                canonical,
                descriptor,
                identity,
                description,
            )
        except Exception as error:
            raise XcodeResourceStageError(f"{description} parent changed") from error


def _expected_file_list_payloads(source_anchor, destination: Path) -> tuple[bytes, bytes]:
    relative_files = tuple(
        PurePosixPath(relative)
        for relative, kind, _fields, _digest in source_anchor[3]
        if kind == "file"
    )
    source_values = _STAGER._file_list_paths(source_anchor[0], relative_files)
    destination_values = _STAGER._file_list_paths(destination, relative_files)
    return (
        ("\n".join(source_values) + "\n").encode("utf-8"),
        ("\n".join(destination_values) + "\n").encode("utf-8"),
    )


def _stage_xcode_resources_anchored(
    source_materialization_root: Path,
    resource_parent: Path,
    metadata: Path,
    parent_anchors,
    *,
    reuse_identical: bool = True,
) -> dict[str, object]:
    """Publish once, reuse exact state, and preserve every ambiguous existing object."""
    del reuse_identical
    destination = resource_parent / DESTINATION_NAME
    input_list = metadata / INPUT_LIST_NAME
    output_list = metadata / OUTPUT_LIST_NAME
    stamp_path = metadata / STAMP_NAME
    previous = None
    source_anchor = None
    predeclared_anchors = {}
    try:
        # Xcode needs these lists before its first resource phase executes.
        # They confer no package ownership; require exact current paths below.
        predeclared = (
            not os.path.lexists(destination) and not os.path.lexists(stamp_path)
            and os.path.lexists(input_list) and os.path.lexists(output_list)
        )
        if predeclared:
            for path in (input_list, output_list):
                predeclared_anchors[path] = _open_owned_file_anchor(
                    path, "predeclared file list"
                )
        previous_error = None
        source_error = None
        # Retain destination evidence before source admission can observe changes.
        try:
            previous = None if predeclared else _existing_owned_state(
                destination, input_list, output_list, stamp_path
            )
        except Exception as error:
            previous_error = error
        try:
            source_anchor = _STAGER._open_verified_materialization(
                Path(source_materialization_root), "source package"
            )
        except Exception as error:
            source_error = error
        if isinstance(previous_error, UnattestedOwnedPackageError) and source_error is None:
            # This stager's own complete set whose package copy cannot be
            # attested (no staged receipt): retire it and publish a freshly
            # attested copy from the verified source instead of demanding a
            # DerivedData Clean. Unowned or partial state still fails closed.
            try:
                _validate_absent_receipt_recovery(
                    previous_error, source_anchor, destination, input_list,
                    output_list, stamp_path, parent_anchors,
                )
                _retire_owned_state(destination, input_list, output_list, stamp_path)
            except PackageAdmissionError:
                raise
            except (OSError, XcodeResourceStageError) as error:
                raise XcodeResourceStageError(
                    f"unattested owned staging state could not be retired ({error}); "
                    "run Xcode Clean or use a fresh build root"
                ) from error
            print(f"==> replaced unattested staged package: {destination}", file=sys.stderr)
            previous_error = None
        if previous_error is not None:
            if isinstance(previous_error, PackageAdmissionError):
                raise previous_error
            raise XcodeResourceStageError(
                "existing staging state is not a complete owned attested set "
                f"({previous_error}); run Xcode Clean or use a fresh build root"
            ) from previous_error
        if source_error is not None:
            raise XcodeResourceStageError(
                f"source package is not an attested materialization: {source_error}"
            ) from source_error
        assert source_anchor is not None
        source_identity = source_anchor[4]
        if predeclared:
            expected = _expected_file_list_payloads(source_anchor, destination)
            for path, payload in zip((input_list, output_list), expected):
                if predeclared_anchors[path][3] != payload:
                    raise XcodeResourceStageError(
                        "predeclared file list does not describe the current package"
                    )
                _STAGER._revalidate_anchored_file(
                    predeclared_anchors[path], "predeclared file list"
                )

        if previous is not None:
            expected_input_payload, expected_output_payload = _expected_file_list_payloads(
                source_anchor,
                destination,
            )
            if (
                previous[0]["materialization"] != source_identity
                or previous[2][input_list][3] != expected_input_payload
                or previous[2][output_list][3] != expected_output_payload
            ):
                # A complete, stamp-attested set this stager published for another
                # package or source root (a lane's DerivedData reused across
                # branches) is ours: replace it. Partial or unowned state above
                # still fails closed.
                _revalidate_publication_set(
                    previous,
                    destination,
                    input_list,
                    output_list,
                    stamp_path,
                    parent_anchors,
                    label="stale owned state",
                )
                _close_owned_state(previous)
                previous = None
                try:
                    _retire_owned_state(destination, input_list, output_list, stamp_path)
                except OSError as error:
                    raise XcodeResourceStageError(
                        f"stale owned staging state could not be retired ({error}); "
                        "run Xcode Clean or use a fresh build root"
                    ) from error
        if previous is not None:
            if destination in previous[1]:
                _revalidate_publication_set(
                    previous,
                    destination,
                    input_list,
                    output_list,
                    stamp_path,
                    parent_anchors,
                    label="existing owned state",
                )
                try:
                    _STAGER._revalidate_anchored_materialization(
                        source_anchor[0],
                        source_anchor[1],
                        source_anchor[2],
                        source_anchor[3],
                        "source package",
                    )
                except Exception as error:
                    raise XcodeResourceStageError(
                        "source package changed before exact-state reuse completed"
                    ) from error
                return source_identity

            _revalidate_publication_set(
                previous,
                destination,
                input_list,
                output_list,
                stamp_path,
                parent_anchors,
                label="existing owned state",
            )

            try:
                materialization = _STAGER._stage_verified_package_anchored(
                    source_anchor,
                    destination,
                    input_list,
                    output_list,
                    (parent_anchors[1], parent_anchors[-1], parent_anchors[-1]),
                    publish_file_lists=False,
                )
                if materialization != source_identity:
                    raise XcodeResourceStageError(
                        "recovered package does not match the retained source identity"
                    )
            except Exception as error:
                raise XcodeResourceStageError(
                    "metadata-only recovery could not publish the package; existing state was "
                    "preserved, so run Xcode Clean or use a fresh build root"
                ) from error
        else:
            try:
                materialization = _STAGER._stage_verified_package_anchored(
                    source_anchor,
                    destination,
                    input_list,
                    output_list,
                    (parent_anchors[1], parent_anchors[-1], parent_anchors[-1]),
                    publish_file_lists=not predeclared,
                )
                if materialization != source_identity:
                    raise XcodeResourceStageError(
                        "published package does not match the retained source identity"
                    )
                for anchor in predeclared_anchors.values():
                    _STAGER._revalidate_anchored_file(anchor, "predeclared file list")
                stamp = {
                    "schemaVersion": STAMP_SCHEMA_VERSION,
                    "destinationName": DESTINATION_NAME,
                    "materialization": materialization,
                    "inputFileListSHA256": _sha256(input_list),
                    "outputFileListSHA256": _sha256(output_list),
                    "linkInputs": _link_input_records(destination),
                }
                _write_stamp_exclusively(stamp_path, stamp, parent_anchors[-1])
            except Exception as error:
                raise XcodeResourceStageError(
                    "resource publication failed and partial state was preserved; "
                    "run Xcode Clean or use a fresh build root"
                ) from error

        final_state = None
        try:
            final_state = _existing_owned_state(
                destination,
                input_list,
                output_list,
                stamp_path,
            )
            if final_state is None or destination not in final_state[1]:
                raise XcodeResourceStageError("complete publication state is missing")
            if final_state[0]["materialization"] != materialization:
                raise XcodeResourceStageError("published package identity changed")
            _revalidate_publication_set(
                final_state,
                destination,
                input_list,
                output_list,
                stamp_path,
                parent_anchors,
                label="final owned state",
            )
        except Exception as error:
            raise XcodeResourceStageError(
                "published state failed final validation and was preserved; "
                "run Xcode Clean or use a fresh build root"
            ) from error
        finally:
            _close_owned_state(final_state)
        return materialization
    finally:
        if source_anchor is not None:
            os.close(source_anchor[1])
        _close_owned_state(previous)
        _close_file_anchors(predeclared_anchors)


def stage_xcode_resources(
    source_materialization_root: Path,
    target_build_directory: Path,
    unlocalized_resources_folder_path: PurePosixPath,
    metadata_directory: Path,
    *,
    reuse_identical: bool = True,
) -> dict[str, object]:
    target, resource_parent, parent_anchors = _resource_parent(
        Path(target_build_directory),
        PurePosixPath(unlocalized_resources_folder_path),
    )
    del target
    try:
        metadata, metadata_descriptor, metadata_metadata = _STAGER._open_anchored_directory(
            Path(metadata_directory),
            "metadata directory",
        )
    except Exception:
        for _path, descriptor, _identity, _label in parent_anchors:
            os.close(descriptor)
        raise
    parent_anchors.append(
        (
            metadata,
            metadata_descriptor,
            (metadata_metadata.st_dev, metadata_metadata.st_ino),
            "metadata",
        )
    )
    try:
        return _stage_xcode_resources_anchored(
            Path(source_materialization_root),
            resource_parent,
            metadata,
            parent_anchors,
            reuse_identical=reuse_identical,
        )
    finally:
        for _path, descriptor, _identity, _label in parent_anchors:
            os.close(descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-materialization-root", type=Path, required=True)
    parser.add_argument("--target-build-dir", type=Path, required=True)
    parser.add_argument("--unlocalized-resources-folder-path", type=PurePosixPath, required=True)
    parser.add_argument("--metadata-directory", type=Path, required=True)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        stage_xcode_resources(
            arguments.source_materialization_root,
            arguments.target_build_dir,
            arguments.unlocalized_resources_folder_path,
            arguments.metadata_directory,
        )
    except XcodeResourceStageError as error:
        messages: list[str] = []
        current: BaseException | None = error
        while current is not None and len(messages) < 6:
            message = " ".join(str(current).split())
            if message and message not in messages:
                messages.append(message[:512])
            current = current.__cause__ or current.__context__
        print(f"ERROR: {' <- '.join(messages)}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
