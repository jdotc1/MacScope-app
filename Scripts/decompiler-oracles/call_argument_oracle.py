#!/usr/bin/env python3
"""WS-15 Darwin arm64 call-argument oracle.

The reduced proof compiles a C caller and an assembly entry-capture harness with
the active Xcode clang. It independently checks decoded call-site instructions,
decoded callee entry observations, runtime sentinels, and the exact identities
of every source, object, and executable artifact retained for later sweeps.

The closed ``call-argument-oracle-v2`` payload deliberately keeps Darwin C fixed
and Darwin C variadic evidence separate. In particular, anonymous C variadic
arguments are proven on the outgoing call stack and never reclassified as a
dense GPR tail.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import ctypes
import hashlib
import io
import json
import os
import platform
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Mapping, Optional, Sequence, Set, Tuple


FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures/call-arguments"
TARGET = "arm64-apple-macos26.4"
SCHEMA = "call-argument-oracle-v2"

ROOT_KEYS = {
    "schema",
    "toolchain",
    "artifacts",
    "artifact_directory",
    "build_bindings",
    "proofs",
    "cases",
    "x8_negative_control",
}
TOOLCHAIN_KEYS = {
    "developer_dir",
    "clang",
    "clang_size",
    "clang_sha256",
    "clang_version",
    "decoder",
    "decoder_size",
    "decoder_sha256",
    "decoder_version",
    "sdk",
    "sdk_version",
    "sdk_settings_path",
    "sdk_settings_size",
    "sdk_settings_sha256",
    "target",
    "host_architecture",
}

FD_TOKEN_PREFIX = "@bound-fd:"
GROUP_KILL_GRACE_SECONDS = 0.25
EXPECTED_SELF_TEST_CLASS_COUNTS = (
    ("ArtifactBindingTests", 6),
    ("ClaimedToolExecutionTests", 1),
    ("ClosedOracleValidationTests", 26),
    ("LiveProductionHelperTests", 1),
    ("OtoolParsingTests", 4),
    ("ProcessIsolationTests", 2),
    ("ToolchainCoherenceTests", 1),
)
ARTIFACT_KEYS = {
    "fixture_source",
    "entry_capture_source",
    "fixture_object",
    "entry_capture_object",
    "executable",
    "runtime_image",
}
ARTIFACT_FILENAMES = {
    "fixture_source": "call_arguments.c",
    "entry_capture_source": "entry_capture.s",
    "fixture_object": "call_arguments.o",
    "entry_capture_object": "entry_capture.o",
    "executable": "call_argument_fixture",
    "runtime_image": "call_argument_fixture.dylib",
}
BINDING_RECORD_KEYS = {"artifact", "path", "size", "sha256"}
BUILD_BINDING_KEYS = {
    "fixture_compile_inputs",
    "entry_compile_inputs",
    "executable_link_inputs",
    "runtime_image_link_inputs",
    "fixture_object_decode_inputs",
    "entry_object_decode_inputs",
    "executable_decode_inputs",
    "runtime_inputs",
}
EXPECTED_BUILD_BINDINGS = {
    "fixture_compile_inputs": ["fixture_source"],
    "entry_compile_inputs": ["entry_capture_source"],
    "executable_link_inputs": ["fixture_object", "entry_capture_object"],
    "runtime_image_link_inputs": ["fixture_object", "entry_capture_object"],
    "fixture_object_decode_inputs": ["fixture_object"],
    "entry_object_decode_inputs": ["entry_capture_object"],
    "executable_decode_inputs": ["executable"],
    "runtime_inputs": ["runtime_image"],
}
MACHO_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MACHO_FILE_TYPES = {
    "fixture_object": 1,  # MH_OBJECT
    "entry_capture_object": 1,  # MH_OBJECT
    "executable": 2,  # MH_EXECUTE
    "runtime_image": 6,  # MH_DYLIB
}
CANONICAL_PRODUCT_UUIDS = {
    "executable": bytes.fromhex("d0a6a54a56c24a7a9f0c7f32987a7cb1"),
    "runtime_image": bytes.fromhex("c1320b4fb57e4acbb57e6231e61c51df"),
}
CANONICAL_LINK_INPUT_MTIME_NS = 946684800_000_000_000
PROOF_KEYS = {
    "decoded_call_sites",
    "entry_state_capture",
    "runtime_sentinels",
    "artifact_hashes_verified",
}
CASE_KEYS = {
    "name",
    "convention",
    "dispatch",
    "callsite_symbol",
    "entry_capture_symbol",
    "decoded_call",
    "arguments",
}
DECODED_CALL_KEYS = {"mnemonic", "target", "control_register"}
ARGUMENT_KEYS = {
    "role",
    "source_position",
    "tail_ordinal",
    "promoted_type",
    "location",
    "sentinel",
}
LOCATION_KEYS = {
    "kind",
    "index",
    "carrier_width",
    "scalar_width",
    "byte_offset",
    "size",
    "alignment",
}


class OracleError(Exception):
    """Invalid schema, stale artifact, unavailable tool, or failed proof."""


def _gpr(index: int, width: int = 64) -> Dict[str, object]:
    return {
        "kind": "gpr",
        "index": index,
        "carrier_width": width,
        "scalar_width": None,
        "byte_offset": None,
        "size": None,
        "alignment": None,
    }


def _simd(index: int, width: int = 64) -> Dict[str, object]:
    return {
        "kind": "simd",
        "index": index,
        "carrier_width": None,
        "scalar_width": width,
        "byte_offset": None,
        "size": None,
        "alignment": None,
    }


def _call_stack(offset: int) -> Dict[str, object]:
    return {
        "kind": "call-stack",
        "index": None,
        "carrier_width": None,
        "scalar_width": None,
        "byte_offset": offset,
        "size": 8,
        "alignment": 8,
    }


def _fixed(
    source_position: int,
    promoted_type: str,
    location: Dict[str, object],
    sentinel: str,
) -> Dict[str, object]:
    return {
        "role": "fixed",
        "source_position": source_position,
        "tail_ordinal": None,
        "promoted_type": promoted_type,
        "location": location,
        "sentinel": sentinel,
    }


def _anonymous(
    tail_ordinal: int,
    promoted_type: str,
    location: Dict[str, object],
    sentinel: str,
) -> Dict[str, object]:
    return {
        "role": "anonymous-variadic",
        "source_position": None,
        "tail_ordinal": tail_ordinal,
        "promoted_type": promoted_type,
        "location": location,
        "sentinel": sentinel,
    }


FIXED_ARGUMENTS_DIRECT = [
    _fixed(0, "uint64_t", _gpr(0), "0x1112131415161718"),
    _fixed(1, "double", _simd(0), "19.5"),
    _fixed(2, "const void *", _gpr(1), "runtime-pointer"),
]
FIXED_ARGUMENTS_INDIRECT = [
    _fixed(0, "uint64_t", _gpr(0), "0x2122232425262728"),
    _fixed(1, "double", _simd(0), "-41.25"),
    _fixed(2, "const void *", _gpr(1), "runtime-pointer"),
]
VARIADIC_ARGUMENTS_DIRECT = [
    _fixed(0, "uint64_t", _gpr(0), "0x3132333435363738"),
    _fixed(1, "double", _simd(0), "91.5"),
    _anonymous(0, "int", _call_stack(0), "-91"),
    _anonymous(1, "double", _call_stack(8), "-6.25"),
    _anonymous(2, "const void *", _call_stack(16), "runtime-pointer"),
]
VARIADIC_ARGUMENTS_INDIRECT = [
    _fixed(0, "uint64_t", _gpr(0), "0x4142434445464748"),
    _fixed(1, "double", _simd(0), "-202.25"),
    _anonymous(0, "int", _call_stack(0), "73"),
    _anonymous(1, "double", _call_stack(8), "12.75"),
    _anonymous(2, "const void *", _call_stack(16), "runtime-pointer"),
]

ORACLE_CASES: List[Dict[str, object]] = [
    {
        "name": "fixed_direct",
        "convention": "darwin-c-fixed",
        "dispatch": "direct",
        "callsite_symbol": "callsite_fixed_direct",
        "entry_capture_symbol": "capture_fixed_direct",
        "decoded_call": {
            "mnemonic": "bl",
            "target": "_capture_fixed_direct",
            "control_register": None,
        },
        "arguments": FIXED_ARGUMENTS_DIRECT,
    },
    {
        "name": "fixed_indirect",
        "convention": "darwin-c-fixed",
        "dispatch": "indirect",
        "callsite_symbol": "callsite_fixed_indirect",
        "entry_capture_symbol": "capture_fixed_indirect",
        "decoded_call": {
            "mnemonic": "blr",
            "target": None,
            "control_register": "x8",
        },
        "arguments": FIXED_ARGUMENTS_INDIRECT,
    },
    {
        "name": "variadic_direct",
        "convention": "darwin-c-variadic",
        "dispatch": "direct",
        "callsite_symbol": "callsite_variadic_direct",
        "entry_capture_symbol": "capture_variadic_direct",
        "decoded_call": {
            "mnemonic": "bl",
            "target": "_capture_variadic_direct",
            "control_register": None,
        },
        "arguments": VARIADIC_ARGUMENTS_DIRECT,
    },
    {
        "name": "variadic_indirect",
        "convention": "darwin-c-variadic",
        "dispatch": "indirect",
        "callsite_symbol": "callsite_variadic_indirect",
        "entry_capture_symbol": "capture_variadic_indirect",
        "decoded_call": {
            "mnemonic": "blr",
            "target": None,
            "control_register": "x8",
        },
        "arguments": VARIADIC_ARGUMENTS_INDIRECT,
    },
]

X8_NEGATIVE_CONTROL = {
    "observed_as_control": True,
    "ordinary_argument_location": False,
    "case_names": ["fixed_indirect", "variadic_indirect"],
}


def _require_exact_keys(value: object, expected: Set[str], context: str) -> Dict[str, object]:
    if not isinstance(value, dict):
        raise OracleError("{} must be an object".format(context))
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise OracleError(
            "{} keys are not closed (missing {}; unknown {})".format(
                context, missing, unknown
            )
        )
    return value


def _require_string(value: object, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise OracleError("{} must be a nonempty string".format(context))
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise OracleError("{} contains a control character".format(context))
    return value


def _require_integer(
    value: object,
    context: str,
    minimum: Optional[int] = None,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise OracleError("{} must be a JSON integer, never a boolean".format(context))
    if minimum is not None and value < minimum:
        raise OracleError("{} must be at least {}".format(context, minimum))
    return value


def _require_digest(value: object, context: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise OracleError("{} must be 64 lowercase SHA-256 hex digits".format(context))
    return value


def _require_canonical_descendant(
    child_text: str,
    ancestor_text: str,
    context: str,
) -> None:
    child = Path(child_text)
    ancestor = Path(ancestor_text)
    if str(child.resolve()) != child_text:
        raise OracleError("{} must be canonical and absolute".format(context))
    try:
        child.relative_to(ancestor)
    except ValueError:
        raise OracleError(
            "{} must remain under the frozen developer directory".format(context)
        )


def _validated_developer_dir(selected_text: str, inherited_text: Optional[str]) -> str:
    selected = Path(selected_text).resolve()
    selected_string = str(selected)
    if (
        selected.name != "Developer"
        or selected.parent.name != "Contents"
        or selected.parent.parent.suffix != ".app"
        or not selected_string.startswith("/Applications/Xcode")
    ):
        raise OracleError(
            "active developer directory is not a canonical Xcode app: {}".format(
                selected_string
            )
        )
    if inherited_text:
        inherited = str(Path(inherited_text).resolve())
        if inherited != selected_string:
            raise OracleError(
                "DEVELOPER_DIR mismatch: environment {!r}, xcode-select {!r}".format(
                    inherited, selected_string
                )
            )
    return selected_string


def _sha256_fd(file_descriptor: int) -> str:
    """Hash an already-open regular file without changing its shared offset."""
    digest = hashlib.sha256()
    offset = 0
    while True:
        block = os.pread(file_descriptor, 1024 * 1024, offset)
        if not block:
            break
        digest.update(block)
        offset += len(block)
    return digest.hexdigest()


def _metadata_identity(metadata: os.stat_result) -> Tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _lstat_regular_identity(
    path: Path, context: str
) -> Tuple[int, int, int, int, int]:
    if not path.is_absolute() or os.path.realpath(str(path)) != str(path):
        raise OracleError("{} path is not canonical absolute".format(context))
    try:
        metadata = os.lstat(str(path))
    except OSError as error:
        raise OracleError("{} is missing: {}".format(context, error)) from error
    if not stat.S_ISREG(metadata.st_mode):
        raise OracleError("{} is not a regular file".format(context))
    return _metadata_identity(metadata)


def _fd_identity(file_descriptor: int) -> Tuple[int, int, int, int, int]:
    return _metadata_identity(os.fstat(file_descriptor))


def _same_snapshot_metadata(
    observed: Tuple[int, int, int, int, int],
    expected: Tuple[int, int, int, int, int],
    shared_toolchain: bool,
) -> bool:
    # Xcode tools are shared with parallel test hosts and builds. Their ctime
    # also changes for inode metadata (for example xattrs), without a byte or
    # mtime change. It is not a tool content identity. Keep device, inode, size
    # and mtime bound; callers still require SHA-256 before AND after use and
    # execute a descriptor-cloned private replica. Owned artifacts remain strict.
    return observed[:4] == expected[:4] if shared_toolchain else observed == expected


def _open_descriptor_snapshot(
    path: Path, context: str, *, shared_toolchain: bool = False
) -> Tuple[int, Tuple[int, int, int, int, int], str]:
    """Open one canonical path without following links and snapshot one inode."""
    path_before = _lstat_regular_identity(path, context)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        file_descriptor = os.open(str(path), flags)
    except OSError as error:
        raise OracleError("{} cannot open bound file: {}".format(context, error)) from error
    try:
        descriptor_before = _fd_identity(file_descriptor)
        if not _same_snapshot_metadata(descriptor_before, path_before, shared_toolchain):
            raise OracleError("{} changed before descriptor open".format(context))
        digest = _sha256_fd(file_descriptor)
        descriptor_after = _fd_identity(file_descriptor)
        if not _same_snapshot_metadata(descriptor_after, descriptor_before, shared_toolchain):
            raise OracleError("{} changed metadata while hashing".format(context))
        path_after = _lstat_regular_identity(path, context)
        if not _same_snapshot_metadata(path_after, descriptor_after, shared_toolchain):
            raise OracleError("{} changed metadata while hashing".format(context))
        return file_descriptor, descriptor_after, digest
    except Exception:
        os.close(file_descriptor)
        raise


def _assert_descriptor_snapshot_unchanged(
    path: Path,
    file_descriptor: int,
    identity: Tuple[int, int, int, int, int],
    digest: str,
    context: str,
    *, shared_toolchain: bool = False,
) -> None:
    descriptor_before = _fd_identity(file_descriptor)
    if not _same_snapshot_metadata(descriptor_before, identity, shared_toolchain):
        raise OracleError("{} changed metadata while in use".format(context))
    current_digest = _sha256_fd(file_descriptor)
    descriptor_after = _fd_identity(file_descriptor)
    if not _same_snapshot_metadata(descriptor_after, descriptor_before, shared_toolchain):
        raise OracleError("{} changed metadata while hashing".format(context))
    if current_digest != digest:
        raise OracleError("{} changed hash while in use".format(context))
    path_after = _lstat_regular_identity(path, context)
    if not _same_snapshot_metadata(path_after, descriptor_after, shared_toolchain):
        raise OracleError("{} changed metadata while in use".format(context))


def _artifact_record(
    path: Path, *, shared_toolchain: bool = False
) -> Dict[str, object]:
    canonical = Path(os.path.realpath(str(path)))
    file_descriptor, identity, digest = _open_descriptor_snapshot(
        canonical, "artifact {}".format(canonical), shared_toolchain=shared_toolchain
    )
    try:
        _assert_descriptor_snapshot_unchanged(
            canonical,
            file_descriptor,
            identity,
            digest,
            "artifact {}".format(canonical),
            shared_toolchain=shared_toolchain,
        )
        return {"path": str(canonical), "size": identity[2], "sha256": digest}
    finally:
        os.close(file_descriptor)


def _require_bound_artifact(
    expected: Dict[str, object],
    context: str,
) -> None:
    with _open_bound_artifacts({"artifact": expected}, context):
        pass


def _require_bound_artifacts(
    artifacts: Dict[str, Dict[str, object]],
    context: str,
) -> None:
    with _open_bound_artifacts(artifacts, context):
        pass


def _snapshot_source(source: Path, destination: Path) -> Dict[str, object]:
    source_before = _artifact_record(source)
    shutil.copyfile(str(source), str(destination))
    destination.chmod(0o444)
    source_after = _artifact_record(source)
    if source_after != source_before:
        raise OracleError("fixture source changed while snapshotting: {}".format(source))

    snapshot = _artifact_record(destination)
    if (
        snapshot["size"] != source_before["size"]
        or snapshot["sha256"] != source_before["sha256"]
    ):
        raise OracleError("fixture snapshot does not match its source: {}".format(source))
    return snapshot


def _is_canonical_absolute(path: Path) -> bool:
    return path.is_absolute() and str(path) == os.path.realpath(str(path))


def _is_within(path: Path, root: Path) -> bool:
    try:
        return os.path.commonpath([str(path), str(root)]) == str(root)
    except ValueError:
        return False


def _create_fresh_artifact_directory(requested: Path) -> Path:
    absolute = Path(os.path.abspath(str(requested)))
    if os.path.lexists(str(absolute)):
        raise OracleError(
            "artifact directory must be fresh and absent: {}".format(absolute)
        )
    parent = Path(os.path.realpath(str(absolute.parent)))
    if not parent.is_dir():
        raise OracleError("artifact directory parent does not exist: {}".format(parent))
    root = parent / absolute.name
    try:
        root.mkdir(mode=0o700, exist_ok=False)
    except OSError as error:
        raise OracleError(
            "could not create fresh artifact directory: {}".format(root)
        ) from error
    return root


def _validate_artifacts(
    artifacts: Dict[str, object], artifact_directory: Path, source: str
) -> None:
    if not _is_canonical_absolute(artifact_directory) or not artifact_directory.is_dir():
        raise OracleError("{}.artifact_directory must be a canonical directory".format(source))
    entries = list(os.scandir(str(artifact_directory)))
    if (
        {entry.name for entry in entries} != set(ARTIFACT_FILENAMES.values())
        or any(not entry.is_file(follow_symlinks=False) for entry in entries)
    ):
        raise OracleError(
            "{}.artifact_directory does not have the exact closed entry set".format(source)
        )

    for name in sorted(ARTIFACT_KEYS):
        context = "{}.artifacts.{}".format(source, name)
        record = _require_exact_keys(
            artifacts.get(name), {"path", "size", "sha256"}, context
        )
        path_text = _require_string(record.get("path"), context + ".path")
        path = Path(path_text)
        if not _is_canonical_absolute(path):
            raise OracleError("{}.path must be canonical and absolute".format(context))
        if path.name != ARTIFACT_FILENAMES[name]:
            raise OracleError("{} filename is not frozen".format(context))
        if path.parent != artifact_directory or not _is_within(path, artifact_directory):
            raise OracleError("{} escaped the artifact directory".format(context))
        expected_size = _require_integer(record.get("size"), context + ".size", 1)
        expected_digest = _require_digest(record.get("sha256"), context + ".sha256")
        try:
            metadata = os.lstat(str(path))
        except OSError as error:
            raise OracleError("{} is missing: {}".format(context, error)) from error
        if not stat.S_ISREG(metadata.st_mode):
            raise OracleError("{} is not a regular file".format(context))
        actual = _artifact_record(path)
        if actual["size"] != expected_size:
            raise OracleError("{} has a stale artifact size".format(context))
        if actual["sha256"] != expected_digest:
            raise OracleError("{} has a stale artifact hash".format(context))

    bound_artifacts = {
        name: artifacts[name] for name in sorted(ARTIFACT_KEYS)
    }
    with _open_bound_artifacts(
        bound_artifacts, source + ".descriptor-coherent artifact set"
    ) as descriptors:
        identities: Set[Tuple[int, int]] = set()
        for name, descriptor in descriptors.items():
            metadata = os.fstat(descriptor)
            identity = (metadata.st_dev, metadata.st_ino)
            if identity in identities:
                raise OracleError(
                    "{}.artifacts.{} aliases another artifact inode".format(
                        source, name
                    )
                )
            identities.add(identity)


def _binding_record(name: str, artifact: Mapping[str, object]) -> Dict[str, object]:
    return {
        "artifact": name,
        "path": artifact["path"],
        "size": artifact["size"],
        "sha256": artifact["sha256"],
    }


def _build_bindings(
    artifacts: Mapping[str, Mapping[str, object]]
) -> Dict[str, object]:
    return {
        stage: [_binding_record(name, artifacts[name]) for name in artifact_names]
        for stage, artifact_names in EXPECTED_BUILD_BINDINGS.items()
    }


def _validate_build_bindings(
    raw_bindings: object,
    artifacts: Mapping[str, Mapping[str, object]],
    source: str,
) -> None:
    bindings = _require_exact_keys(
        raw_bindings, BUILD_BINDING_KEYS, source + ".build_bindings"
    )
    for stage, artifact_names in EXPECTED_BUILD_BINDINGS.items():
        records = bindings.get(stage)
        if not isinstance(records, list) or len(records) != len(artifact_names):
            raise OracleError(
                "{}.build_bindings.{} binding order/count mismatch".format(source, stage)
            )
        for index, artifact_name in enumerate(artifact_names):
            context = "{}.build_bindings.{}[{}]".format(source, stage, index)
            record = _require_exact_keys(records[index], BINDING_RECORD_KEYS, context)
            if record != _binding_record(artifact_name, artifacts[artifact_name]):
                raise OracleError("{} is stale or bound to the wrong artifact".format(context))


def _require_macho_role(
    name: str, artifact: Dict[str, object], source: str
) -> None:
    with _open_bound_artifacts({name: artifact}, source + ".Mach-O role") as descriptors:
        header = os.pread(descriptors[name], 32, 0)
    if len(header) != 32:
        raise OracleError("{}.{} has a truncated Mach-O header".format(source, name))
    magic, cpu_type, _, file_type, _, _, _, _ = struct.unpack("<8I", header)
    if magic != MACHO_MAGIC_64 or cpu_type != CPU_TYPE_ARM64:
        raise OracleError("{}.{} is not little-endian arm64 Mach-O 64".format(source, name))
    if file_type != MACHO_FILE_TYPES[name]:
        raise OracleError(
            "{}.{} has the wrong Mach-O file type for its linked product role".format(
                source, name
            )
        )


def _fd_token(name: str) -> str:
    return FD_TOKEN_PREFIX + name


def _is_call_mnemonic(mnemonic: str) -> bool:
    return mnemonic == "bl" or mnemonic.startswith("blr")


@contextlib.contextmanager
def _open_bound_artifacts(
    artifacts: Mapping[str, Dict[str, object]],
    context: str,
    *, shared_toolchain: bool = False,
) -> Iterator[Dict[str, int]]:
    """Open and validate every command input, then keep that exact inode pinned.

    Commands receive only ``/dev/fd/N`` paths for these inputs. A concurrent
    pathname replacement therefore cannot redirect the compiler, linker,
    decoder, or runtime to unvalidated bytes.
    """
    descriptors: Dict[str, int] = {}
    identities: Dict[str, Tuple[int, int, int, int, int]] = {}
    digests: Dict[str, str] = {}
    paths: Dict[str, Path] = {}
    try:
        for name in sorted(artifacts):
            record = artifacts[name]
            path = Path(str(record["path"]))
            file_descriptor, identity, digest = _open_descriptor_snapshot(
                path, "{}.{}".format(context, name), shared_toolchain=shared_toolchain
            )
            descriptors[name] = file_descriptor
            paths[name] = path
            if identity[2] != record["size"]:
                raise OracleError("{}.{} changed size before use".format(context, name))
            if digest != record["sha256"]:
                raise OracleError("{}.{} changed hash before use".format(context, name))
            identities[name] = identity
            digests[name] = digest

        # The whole input set is pinned simultaneously. Recheck earlier paths
        # after opening the final member so no sequential validation gap remains.
        for name, file_descriptor in descriptors.items():
            _assert_descriptor_snapshot_unchanged(
                paths[name],
                file_descriptor,
                identities[name],
                digests[name],
                "{}.{}".format(context, name),
                shared_toolchain=shared_toolchain,
            )

        yield descriptors

        for name, file_descriptor in descriptors.items():
            _assert_descriptor_snapshot_unchanged(
                paths[name],
                file_descriptor,
                identities[name],
                digests[name],
                "{}.{}".format(context, name),
                shared_toolchain=shared_toolchain,
            )
    finally:
        for file_descriptor in descriptors.values():
            try:
                os.close(file_descriptor)
            except OSError:
                pass


def _validate_location(value: object, context: str) -> Tuple[object, ...]:
    location = _require_exact_keys(value, LOCATION_KEYS, context)
    kind = location.get("kind")
    if kind == "gpr":
        index = _require_integer(location.get("index"), context + ".index", 0)
        if index > 7:
            raise OracleError("{}.index must be in 0...7".format(context))
        width = _require_integer(
            location.get("carrier_width"), context + ".carrier_width"
        )
        if width not in {32, 64}:
            raise OracleError("{}.carrier_width must be 32 or 64".format(context))
        null_fields = ["scalar_width", "byte_offset", "size", "alignment"]
        key: Tuple[object, ...] = ("gpr", index)
    elif kind == "simd":
        index = _require_integer(location.get("index"), context + ".index", 0)
        if index > 7:
            raise OracleError("{}.index must be in 0...7".format(context))
        width = _require_integer(location.get("scalar_width"), context + ".scalar_width")
        if width not in {32, 64}:
            raise OracleError("{}.scalar_width must be 32 or 64".format(context))
        null_fields = ["carrier_width", "byte_offset", "size", "alignment"]
        key = ("simd", index)
    elif kind == "call-stack":
        offset = _require_integer(location.get("byte_offset"), context + ".byte_offset", 0)
        size = _require_integer(location.get("size"), context + ".size", 1)
        alignment = _require_integer(location.get("alignment"), context + ".alignment", 1)
        if alignment & (alignment - 1):
            raise OracleError("{}.alignment must be a power of two".format(context))
        if offset % alignment:
            raise OracleError("{} is misaligned".format(context))
        null_fields = ["index", "carrier_width", "scalar_width"]
        key = ("call-stack", offset)
        if offset + size <= offset:
            raise OracleError("{} stack range overflows".format(context))
    else:
        raise OracleError("{}.kind is unsupported: {!r}".format(context, kind))
    for field in null_fields:
        if location.get(field) is not None:
            raise OracleError("{}.{} must be null".format(context, field))
    return key


def validate_oracle_payload(
    payload: object,
    source: str,
    verify_files: bool = True,
    *,
    rebuild_callback: Optional[Callable[..., Dict[str, Dict[str, object]]]] = None,
    decode_callback: Optional[Callable[..., Dict[str, str]]] = None,
    runtime_callback: Optional[Callable[..., str]] = None,
    expected_artifact_directory: Optional[Path] = None,
) -> None:
    if not verify_files:
        raise OracleError("{}: artifact verification cannot be disabled".format(source))
    root = _require_exact_keys(payload, ROOT_KEYS, source)
    if root.get("schema") != SCHEMA:
        raise OracleError(
            "{}: unsupported schema {!r}".format(source, root.get("schema"))
        )

    toolchain = _require_exact_keys(
        root.get("toolchain"), TOOLCHAIN_KEYS, source + ".toolchain"
    )
    for key in (
        "developer_dir",
        "clang",
        "clang_version",
        "decoder",
        "decoder_version",
        "sdk",
        "sdk_version",
        "sdk_settings_path",
        "target",
        "host_architecture",
    ):
        _require_string(toolchain.get(key), source + ".toolchain." + key)
    for key in ("clang_size", "decoder_size", "sdk_settings_size"):
        _require_integer(toolchain.get(key), source + ".toolchain." + key, 1)
    for key in ("clang_sha256", "decoder_sha256", "sdk_settings_sha256"):
        _require_digest(toolchain.get(key), source + ".toolchain." + key)
    if toolchain.get("target") != TARGET:
        raise OracleError("{}: unexpected compiler target".format(source))
    if toolchain.get("host_architecture") != "arm64":
        raise OracleError("{}: oracle requires an arm64 host".format(source))
    developer_dir = str(toolchain["developer_dir"])
    if str(Path(developer_dir).resolve()) != developer_dir:
        raise OracleError("{}.toolchain.developer_dir must be canonical".format(source))
    for key in ("clang", "decoder", "sdk", "sdk_settings_path"):
        _require_canonical_descendant(
            str(toolchain[key]),
            developer_dir,
            "{}.toolchain.{}".format(source, key),
        )
    if Path(str(toolchain["sdk_settings_path"])) != Path(
        str(toolchain["sdk"])
    ) / "SDKSettings.json":
        raise OracleError(
            "{}.toolchain.sdk_settings_path is not the canonical SDKSettings.json".format(
                source
            )
        )

    artifacts = _require_exact_keys(
        root.get("artifacts"), ARTIFACT_KEYS, source + ".artifacts"
    )
    artifact_directory_text = _require_string(
        root.get("artifact_directory"), source + ".artifact_directory"
    )
    artifact_directory = Path(artifact_directory_text)
    if expected_artifact_directory is not None:
        expected_directory = Path(os.path.realpath(str(expected_artifact_directory)))
        if artifact_directory != expected_directory:
            raise OracleError(
                "{}.artifact_directory does not match the requested directory".format(source)
            )
    _validate_artifacts(artifacts, artifact_directory, source)
    _validate_build_bindings(root.get("build_bindings"), artifacts, source)

    proofs = _require_exact_keys(root.get("proofs"), PROOF_KEYS, source + ".proofs")
    for proof in sorted(PROOF_KEYS):
        if type(proofs.get(proof)) is not bool or proofs.get(proof) is not True:
            raise OracleError("{}.{} must be the boolean true".format(source + ".proofs", proof))

    cases = root.get("cases")
    if not isinstance(cases, list):
        raise OracleError("{}.cases must be an array".format(source))
    if not cases:
        raise OracleError("{}.cases has zero positive cases".format(source))
    case_names: Set[str] = set()
    conventions: Set[str] = set()
    indirect_names: List[str] = []
    for case_index, raw_case in enumerate(cases):
        context = "{}.cases[{}]".format(source, case_index)
        case = _require_exact_keys(raw_case, CASE_KEYS, context)
        name = _require_string(case.get("name"), context + ".name")
        if name in case_names:
            raise OracleError("{} duplicates case name {!r}".format(context, name))
        case_names.add(name)
        convention = case.get("convention")
        if convention not in {"darwin-c-fixed", "darwin-c-variadic"}:
            raise OracleError("{} has unsupported convention {!r}".format(context, convention))
        conventions.add(str(convention))
        dispatch = case.get("dispatch")
        if dispatch not in {"direct", "indirect"}:
            raise OracleError("{} has unsupported dispatch {!r}".format(context, dispatch))
        callsite = _require_string(case.get("callsite_symbol"), context + ".callsite_symbol")
        capture = _require_string(
            case.get("entry_capture_symbol"), context + ".entry_capture_symbol"
        )
        if callsite == capture:
            raise OracleError("{} must separate caller and entry-capture symbols".format(context))

        decoded = _require_exact_keys(
            case.get("decoded_call"), DECODED_CALL_KEYS, context + ".decoded_call"
        )
        if dispatch == "direct":
            if decoded != {
                "mnemonic": "bl",
                "target": "_" + capture,
                "control_register": None,
            }:
                raise OracleError("{} has an invalid direct-call proof".format(context))
        else:
            if decoded != {
                "mnemonic": "blr",
                "target": None,
                "control_register": "x8",
            }:
                raise OracleError("{} has an invalid indirect-call proof".format(context))
            indirect_names.append(name)

        arguments = case.get("arguments")
        if not isinstance(arguments, list) or not arguments:
            raise OracleError("{}.arguments must contain positive evidence".format(context))
        locations: Set[Tuple[object, ...]] = set()
        fixed_positions: List[int] = []
        tail_ordinals: List[int] = []
        for argument_index, raw_argument in enumerate(arguments):
            argument_context = "{}.arguments[{}]".format(context, argument_index)
            argument = _require_exact_keys(raw_argument, ARGUMENT_KEYS, argument_context)
            role = argument.get("role")
            if role == "fixed":
                source_position = _require_integer(
                    argument.get("source_position"),
                    argument_context + ".source_position",
                    0,
                )
                if argument.get("tail_ordinal") is not None:
                    raise OracleError("{}.tail_ordinal must be null".format(argument_context))
                fixed_positions.append(source_position)
            elif role == "anonymous-variadic":
                if argument.get("source_position") is not None:
                    raise OracleError("{}.source_position must be null".format(argument_context))
                tail_ordinal = _require_integer(
                    argument.get("tail_ordinal"),
                    argument_context + ".tail_ordinal",
                    0,
                )
                tail_ordinals.append(tail_ordinal)
            else:
                raise OracleError("{} has unsupported role {!r}".format(argument_context, role))
            _require_string(argument.get("promoted_type"), argument_context + ".promoted_type")
            _require_string(argument.get("sentinel"), argument_context + ".sentinel")
            location_key = _validate_location(argument.get("location"), argument_context + ".location")
            if location_key in locations:
                raise OracleError("{} has duplicate evidence for location {}".format(context, location_key))
            locations.add(location_key)
            if role == "anonymous-variadic" and location_key[0] != "call-stack":
                raise OracleError(
                    "{} violates Darwin C variadic convention separation: anonymous values "
                    "must remain on the call stack".format(argument_context)
                )

        if fixed_positions != list(range(len(fixed_positions))):
            raise OracleError("{} has a compacted or noncanonical fixed-position gap".format(context))
        if tail_ordinals != list(range(len(tail_ordinals))):
            raise OracleError("{} has a compacted gap in anonymous tail ordinals".format(context))
        if convention == "darwin-c-fixed" and tail_ordinals:
            raise OracleError("{} violates convention separation: fixed case has anonymous rows".format(context))
        if convention == "darwin-c-variadic" and not tail_ordinals:
            raise OracleError("{} violates convention separation: variadic case has no anonymous proof".format(context))

    if conventions != {"darwin-c-fixed", "darwin-c-variadic"}:
        raise OracleError("{} does not keep both C conventions separately proven".format(source))

    negative = _require_exact_keys(
        root.get("x8_negative_control"),
        {"observed_as_control", "ordinary_argument_location", "case_names"},
        source + ".x8_negative_control",
    )
    if type(negative.get("observed_as_control")) is not bool or negative.get("observed_as_control") is not True:
        raise OracleError("{} does not prove x8 as a control".format(source))
    if type(negative.get("ordinary_argument_location")) is not bool or negative.get("ordinary_argument_location") is not False:
        raise OracleError("{} incorrectly treats x8 as an ordinary argument".format(source))
    if negative.get("case_names") != indirect_names:
        raise OracleError("{} x8 negative-control cases do not match indirect proofs".format(source))

    if cases != ORACLE_CASES:
        raise OracleError("{} has a wrong location or other drift from frozen oracle cases".format(source))
    if negative != X8_NEGATIVE_CONTROL:
        raise OracleError("{} x8 negative control drifted".format(source))

    _validate_artifact_proofs(
        artifacts,
        toolchain,
        source,
        rebuild_callback=rebuild_callback,
        decode_callback=decode_callback,
        runtime_callback=runtime_callback,
    )


def _fatal_inner_command_timeout(command: Sequence[str]) -> None:
    """Terminate this oracle's entire isolated group, including this leader.

    The watchdog first leaves the group in a new session, acknowledges that it
    is safe from the pending SIGTERM, and then guarantees SIGKILL escalation.
    This function never returns.
    """
    process_group = os.getpgrp()
    diagnostic = "inner command timed out; terminating oracle process group {}: {}\n".format(
        process_group, " ".join(command)
    )
    try:
        os.write(2, diagnostic.encode("utf-8", errors="replace")[:4000])
    except OSError:
        pass

    try:
        ready_read, ready_write = os.pipe()
        watchdog = os.fork()
    except OSError:
        os.killpg(process_group, signal.SIGKILL)
        os._exit(124)

    if watchdog == 0:
        try:
            os.close(ready_read)
            os.setsid()
            os.write(ready_write, b"1")
            os.close(ready_write)
            time.sleep(GROUP_KILL_GRACE_SECONDS)
            try:
                os.killpg(process_group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        finally:
            os._exit(0)

    os.close(ready_write)
    try:
        watchdog_ready = os.read(ready_read, 1)
    finally:
        os.close(ready_read)
    if watchdog_ready != b"1":
        os.killpg(process_group, signal.SIGKILL)
        os._exit(124)
    os.killpg(process_group, signal.SIGTERM)
    os._exit(124)


def _run_checked(
    command: Sequence[str],
    cwd: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
    pass_fds: Sequence[int] = (),
    timeout_seconds: float = 60,
    executable: Optional[str] = None,
) -> subprocess.CompletedProcess:
    try:
        process = subprocess.Popen(
            list(command),
            executable=executable,
            cwd=str(cwd) if cwd is not None else None,
            env=dict(env) if env is not None else None,
            pass_fds=tuple(pass_fds),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise OracleError("cannot run {}: {}".format(" ".join(command), error))
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        _fatal_inner_command_timeout(command)
        raise AssertionError("fatal timeout handler returned")
    result = subprocess.CompletedProcess(
        args=list(command),
        returncode=process.returncode,
        stdout=stdout,
        stderr=stderr,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        if len(detail) > 4000:
            detail = detail[:4000] + "\n[output truncated]"
        raise OracleError(
            "command failed ({}): {}{}".format(
                result.returncode,
                " ".join(command),
                "\n" + detail if detail else "",
            )
        )
    return result


def _run_bound_checked(
    command: Sequence[str],
    bound_inputs: Dict[str, Dict[str, object]],
    context: str,
    env: Optional[Mapping[str, str]] = None,
    executable: Optional[str] = None,
) -> subprocess.CompletedProcess:
    expected_tokens = {_fd_token(name) for name in bound_inputs}
    actual_tokens = {argument for argument in command if argument.startswith(FD_TOKEN_PREFIX)}
    if actual_tokens != expected_tokens:
        raise OracleError(
            "{} command input tokens drifted (expected {}; actual {})".format(
                context, sorted(expected_tokens), sorted(actual_tokens)
            )
        )
    for name in bound_inputs:
        token = _fd_token(name)
        if list(command).count(token) != 1:
            raise OracleError("{} must consume {} exactly once".format(context, token))
        if str(bound_inputs[name]["path"]) in command:
            raise OracleError(
                "{} attempted to consume {} by pathname".format(context, name)
            )

    with _open_bound_artifacts(bound_inputs, context) as descriptors:
        substitutions = {
            _fd_token(name): "/dev/fd/{}".format(file_descriptor)
            for name, file_descriptor in descriptors.items()
        }
        concrete_command = [substitutions.get(argument, argument) for argument in command]
        return _run_checked(
            concrete_command,
            env=env,
            pass_fds=tuple(descriptors.values()),
            executable=executable,
        )


def _xcrun_find(tool: str, env: Mapping[str, str], developer_dir: str) -> str:
    raw_path = _run_checked(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--find", tool],
        env=env,
    ).stdout.strip()
    path = str(Path(raw_path).resolve())
    if not raw_path or not os.access(path, os.X_OK):
        raise OracleError("active Xcode tool is unavailable: {}".format(tool))
    _require_canonical_descendant(path, developer_dir, "active Xcode tool " + tool)
    return path


def parse_otool_functions(text: str) -> Dict[str, List[Tuple[str, str]]]:
    functions: Dict[str, List[Tuple[str, str]]] = {}
    current: Optional[str] = None
    for line in text.splitlines():
        label = re.match(r"^_([A-Za-z0-9_.$]+):\s*$", line)
        if label:
            current = label.group(1)
            functions.setdefault(current, [])
            continue
        if current is None:
            continue
        instruction = re.match(
            r"^\s*[0-9a-fA-F]+\s+([A-Za-z][A-Za-z0-9.]*)\s*(.*?)\s*$",
            line,
        )
        if instruction:
            functions[current].append((instruction.group(1), instruction.group(2)))
    return functions


def _normalized_instructions(
    functions: Dict[str, List[Tuple[str, str]]],
    function: str,
) -> List[Tuple[str, str]]:
    instructions = functions.get(function)
    if not instructions:
        raise OracleError("otool is missing fixture function {}".format(function))
    return [
        (mnemonic.lower(), re.sub(r"\s+", "", operands.lower()))
        for mnemonic, operands in instructions
    ]


def _require_ordered_anchors(
    instructions: Sequence[Tuple[str, str]],
    function: str,
    anchors: Sequence[Tuple[str, str]],
    slice_name: str,
) -> None:
    previous_index = -1
    for mnemonic, operand_fragment in anchors:
        normalized_mnemonic = mnemonic.lower()
        fragment = re.sub(r"\s+", "", operand_fragment.lower())
        indices = [
            index
            for index, (actual_mnemonic, operands) in enumerate(instructions)
            if actual_mnemonic == normalized_mnemonic and fragment in operands
        ]
        if len(indices) != 1:
            raise OracleError(
                "otool: {} {} has multiplicity {} for {} operand anchor {!r}".format(
                    function,
                    slice_name,
                    len(indices),
                    mnemonic,
                    operand_fragment,
                )
            )
        if indices[0] <= previous_index:
            raise OracleError(
                "otool: {} {} setup anchors are out of order".format(
                    function, slice_name
                )
            )
        previous_index = indices[0]


def _require_exact_fixture_call(
    functions: Dict[str, List[Tuple[str, str]]],
    function: str,
    expected_mnemonic: str,
    expected_operand: str,
    setup_anchors: Sequence[Tuple[str, str]],
) -> None:
    instructions = _normalized_instructions(functions, function)
    calls = [
        (index, mnemonic, operands)
        for index, (mnemonic, operands) in enumerate(instructions)
        if _is_call_mnemonic(mnemonic)
    ]
    if len(calls) != 1:
        raise OracleError(
            "otool: {} must contain exactly one call, found {}".format(
                function, len(calls)
            )
        )
    call_index, actual_mnemonic, actual_operand = calls[0]
    normalized_operand = re.sub(r"\s+", "", expected_operand.lower())
    if (actual_mnemonic, actual_operand) != (
        expected_mnemonic.lower(),
        normalized_operand,
    ):
        raise OracleError(
            "otool: {} call must be exactly {} {}, got {} {}".format(
                function,
                expected_mnemonic,
                expected_operand,
                actual_mnemonic,
                actual_operand,
            )
        )

    pre_call = instructions[:call_index]
    post_call = instructions[call_index + 1 :]
    _require_ordered_anchors(pre_call, function, setup_anchors, "pre-call slice")
    for mnemonic, operand_fragment in setup_anchors:
        fragment = re.sub(r"\s+", "", operand_fragment.lower())
        if any(
            actual_mnemonic == mnemonic.lower() and fragment in operands
            for actual_mnemonic, operands in post_call
        ):
            raise OracleError(
                "otool: {} repeats setup anchor {} {!r} after the call".format(
                    function, mnemonic, operand_fragment
                )
            )


def _require_object_call_shape(
    functions: Dict[str, List[Tuple[str, str]]],
    function: str,
    expected_mnemonic: str,
    expected_operand: Optional[str],
) -> None:
    instructions = _normalized_instructions(functions, function)
    calls = [
        (mnemonic, operands)
        for mnemonic, operands in instructions
        if _is_call_mnemonic(mnemonic)
    ]
    if len(calls) != 1 or calls[0][0] != expected_mnemonic:
        raise OracleError(
            "otool: {} object must contain exactly one {} call".format(
                function, expected_mnemonic
            )
        )
    if expected_operand is not None and calls[0][1] != expected_operand:
        raise OracleError(
            "otool: {} object call operand must be exactly {}".format(
                function, expected_operand
            )
        )


def _verify_call_sites(object_text: str, executable_text: str) -> None:
    object_functions = parse_otool_functions(object_text)
    executable_functions = parse_otool_functions(executable_text)
    call_shapes = {
        "callsite_fixed_direct": ("bl", None),
        "callsite_fixed_indirect": ("blr", "x8"),
        "callsite_variadic_direct": ("bl", None),
        "callsite_variadic_indirect": ("blr", "x8"),
    }
    for function, (mnemonic, operand) in call_shapes.items():
        _require_object_call_shape(object_functions, function, mnemonic, operand)

    _require_exact_fixture_call(
        executable_functions,
        "callsite_fixed_direct",
        "bl",
        "_capture_fixed_direct",
        [("ldr", "x1,"), ("mov", "x0,"), ("fmov", "d0,")],
    )
    _require_exact_fixture_call(
        executable_functions,
        "callsite_fixed_indirect",
        "blr",
        "x8",
        [("ldr", "x8,"), ("ldr", "x1,"), ("mov", "x0,"), ("fmov", "d0,")],
    )
    _require_exact_fixture_call(
        executable_functions,
        "callsite_variadic_direct",
        "bl",
        "_capture_variadic_direct",
        [
            ("mov", "x9,sp"),
            ("str", "x10,[x9]"),
            ("str", "d0,[x9,#0x8]"),
            ("str", "x8,[x9,#0x10]"),
            ("mov", "x0,"),
            ("fmov", "d0,x8"),
        ],
    )
    _require_exact_fixture_call(
        executable_functions,
        "callsite_variadic_indirect",
        "blr",
        "x8",
        [
            ("ldur", "x8,"),
            ("mov", "x10,sp"),
            ("str", "x11,[x10]"),
            ("str", "d0,[x10,#0x8]"),
            ("str", "x9,[x10,#0x10]"),
            ("mov", "x0,"),
            ("fmov", "d0,x9"),
        ],
    )


def _verify_entry_capture(object_text: str) -> None:
    functions = parse_otool_functions(object_text)
    for function in ("capture_fixed_direct", "capture_fixed_indirect"):
        instructions = _normalized_instructions(functions, function)
        anchors = [("str", "x0,"), ("str", "d0,"), ("str", "x1,")]
        if function == "capture_fixed_indirect":
            anchors.append(("str", "x8,"))
        _require_ordered_anchors(instructions, function, anchors, "entry body")

    for function in ("capture_variadic_direct", "capture_variadic_indirect"):
        instructions = _normalized_instructions(functions, function)
        anchors = [
            ("str", "x0,"),
            ("str", "d0,"),
            ("ldr", "w10,[sp]"),
            ("ldr", "d16,[sp,#0x8]"),
            ("str", "d16,"),
            ("ldr", "x10,[sp,#0x10]"),
        ]
        if function == "capture_variadic_indirect":
            anchors.append(("str", "x8,"))
        _require_ordered_anchors(instructions, function, anchors, "entry body")


def _controlled_tool_environment(developer_dir: str) -> Dict[str, str]:
    environment = {
        "DEVELOPER_DIR": developer_dir,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    temporary = os.environ.get("TMPDIR")
    if temporary and Path(temporary).is_dir():
        environment["TMPDIR"] = temporary
    home = os.environ.get("HOME")
    if home and Path(home).is_dir():
        environment["HOME"] = home
    return environment


def _claimed_tool_identity(
    toolchain: Mapping[str, object], name: str
) -> Dict[str, object]:
    path_key = "sdk_settings_path" if name == "sdk_settings" else name
    return {
        "path": toolchain[path_key],
        "size": toolchain[name + "_size"],
        "sha256": toolchain[name + "_sha256"],
    }


@contextlib.contextmanager
def _verified_executable_replica(
    source_descriptor: int,
    expected: Mapping[str, object],
    context: str,
) -> Iterator[str]:
    """Yield a private executable inode cloned from one verified descriptor.

    Darwin does not permit executing an open vnode through ``/dev/fd`` even
    when it was opened with ``O_EXEC``.  ``fclonefileat`` is the available
    descriptor-source primitive: it atomically creates a copy-on-write vnode
    from the already verified source descriptor, without reopening the claimed
    mutable pathname.  The clone is independently hashed, held open, and kept
    in a non-writable user-private directory for the entire child lifetime.
    ``subprocess`` still receives the canonical claimed path as ``argv[0]`` so
    compiler-driver resource discovery retains its normal Xcode identity.
    """
    expected_size = _require_integer(expected.get("size"), context + ".size", 1)
    expected_digest = _require_digest(
        expected.get("sha256"), context + ".sha256"
    )
    source_identity = _fd_identity(source_descriptor)
    if source_identity[2] != expected_size:
        raise OracleError("{} source descriptor has a stale size".format(context))
    if _sha256_fd(source_descriptor) != expected_digest:
        raise OracleError("{} source descriptor has a stale hash".format(context))
    if os.fstat(source_descriptor).st_mode & 0o111 == 0:
        raise OracleError("{} source descriptor is not executable".format(context))

    with tempfile.TemporaryDirectory(
        prefix="call-argument-oracle-pinned-tool-"
    ) as temporary:
        directory = Path(temporary).resolve()
        if stat.S_IMODE(directory.stat().st_mode) != 0o700:
            directory.chmod(0o700)
        directory_flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            directory_descriptor = os.open(str(directory), directory_flags)
        except OSError as error:
            raise OracleError(
                "{} cannot open private executable directory: {}".format(
                    context, error
                )
            ) from error
        replica_name = "verified-tool"
        replica = directory / replica_name
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            fclonefileat = libc.fclonefileat
            fclonefileat.argtypes = [
                ctypes.c_int,
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_uint32,
            ]
            fclonefileat.restype = ctypes.c_int
            status = fclonefileat(
                source_descriptor,
                directory_descriptor,
                os.fsencode(replica_name),
                0,
            )
            if status != 0:
                error_number = ctypes.get_errno()
                raise OracleError(
                    "{} cannot clone verified executable descriptor: {}".format(
                        context, os.strerror(error_number)
                    )
                )
        finally:
            os.close(directory_descriptor)

        replica_descriptor, replica_identity, replica_digest = (
            _open_descriptor_snapshot(replica, context + ".replica")
        )
        try:
            if replica_identity[2] != expected_size or replica_digest != expected_digest:
                raise OracleError(
                    "{} executable replica does not match the claimed content identity".format(
                        context
                    )
                )
            if os.fstat(replica_descriptor).st_mode & 0o111 == 0:
                raise OracleError("{} executable replica is not executable".format(context))

            # The random parent is already user-private.  Removing write access
            # from this final directory prevents ordinary pathname replacement
            # while the kernel resolves the independently verified replica.
            directory.chmod(0o500)
            try:
                yield str(replica)
            finally:
                _assert_descriptor_snapshot_unchanged(
                    replica,
                    replica_descriptor,
                    replica_identity,
                    replica_digest,
                    context + ".replica",
                )
        finally:
            os.close(replica_descriptor)
            directory.chmod(0o700)


def _run_claimed_tool_checked(
    command: Sequence[str],
    tool_name: str,
    toolchain: Mapping[str, object],
    context: str,
    env: Mapping[str, str],
    bound_inputs: Optional[Dict[str, Dict[str, object]]] = None,
) -> subprocess.CompletedProcess:
    if tool_name not in {"clang", "decoder"}:
        raise OracleError("{} requested unsupported claimed tool".format(context))
    tool_path = str(toolchain[tool_name])
    if not command or command[0] != tool_path:
        raise OracleError("{} command does not use the claimed tool path".format(context))
    developer_dir = str(toolchain["developer_dir"])
    if env.get("DEVELOPER_DIR") != developer_dir:
        raise OracleError("{} escaped the canonical DEVELOPER_DIR".format(context))
    _require_canonical_descendant(tool_path, developer_dir, context + " tool")
    sdk_settings_path = str(toolchain["sdk_settings_path"])
    _require_canonical_descendant(
        sdk_settings_path, developer_dir, context + " SDK settings"
    )
    identities = {
        tool_name: _claimed_tool_identity(toolchain, tool_name),
        "sdk_settings": _claimed_tool_identity(toolchain, "sdk_settings"),
    }
    with _open_bound_artifacts(
        identities, context + ".toolchain identities", shared_toolchain=True
    ) as descriptors:
        with _verified_executable_replica(
            descriptors[tool_name], identities[tool_name], context + ".tool"
        ) as executable:
            if bound_inputs is None:
                return _run_checked(command, env=env, executable=executable)
            return _run_bound_checked(
                command,
                bound_inputs,
                context + ".artifact inputs",
                env=env,
                executable=executable,
            )


def _tool_version(
    tool_name: str,
    toolchain: Mapping[str, object],
    arguments: Sequence[str],
    env: Mapping[str, str],
) -> str:
    tool = str(toolchain[tool_name])
    result = _run_claimed_tool_checked(
        [tool] + list(arguments),
        tool_name,
        toolchain,
        "read active {} version".format(tool_name),
        env,
    )
    lines = [line.strip() for line in (result.stdout + result.stderr).splitlines() if line.strip()]
    if not lines:
        raise OracleError("active Xcode tool returned no version: {}".format(tool))
    return lines[0]


def _toolchain() -> Tuple[Dict[str, object], Dict[str, str]]:
    selected = _run_checked(
        ["/usr/bin/xcode-select", "-p"],
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
    ).stdout.strip()
    developer_dir = _validated_developer_dir(selected, os.environ.get("DEVELOPER_DIR"))
    environment = _controlled_tool_environment(developer_dir)
    clang = _xcrun_find("clang", environment, developer_dir)
    # Claim the real decoder executable rather than the ``llvm-otool``
    # dispatcher, whose kernel path determines an otherwise unclaimed mutable
    # ``otool-classic`` helper.  Xcode exposes the classic decoder through
    # xcrun, so its own descriptor can be the executable content identity.
    decoder = _xcrun_find("otool-classic", environment, developer_dir)
    sdk_text = _run_checked(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
        env=environment,
    ).stdout.strip()
    sdk = str(Path(sdk_text).resolve())
    _require_canonical_descendant(sdk, developer_dir, "active macOS SDK")
    sdk_settings = str((Path(sdk) / "SDKSettings.json").resolve())
    _require_canonical_descendant(
        sdk_settings, developer_dir, "active macOS SDK settings"
    )
    sdk_version = _run_checked(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
        env=environment,
    ).stdout.strip()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise OracleError(
            "fixture execution requires arm64 macOS, got {} {}".format(
                platform.system(), platform.machine()
            )
        )
    if not Path(sdk).is_dir():
        raise OracleError("active macOS SDK is unavailable: {}".format(sdk))
    if not Path(sdk_settings).is_file():
        raise OracleError("active SDKSettings.json is unavailable: {}".format(sdk_settings))
    clang_identity = _artifact_record(Path(clang), shared_toolchain=True)
    decoder_identity = _artifact_record(Path(decoder), shared_toolchain=True)
    sdk_settings_identity = _artifact_record(Path(sdk_settings), shared_toolchain=True)
    toolchain: Dict[str, object] = {
        "developer_dir": developer_dir,
        "clang": clang,
        "clang_size": clang_identity["size"],
        "clang_sha256": clang_identity["sha256"],
        "clang_version": "pending",
        "decoder": decoder,
        "decoder_size": decoder_identity["size"],
        "decoder_sha256": decoder_identity["sha256"],
        "decoder_version": "pending",
        "sdk": sdk,
        "sdk_version": sdk_version,
        "sdk_settings_path": sdk_settings,
        "sdk_settings_size": sdk_settings_identity["size"],
        "sdk_settings_sha256": sdk_settings_identity["sha256"],
        "target": TARGET,
        "host_architecture": platform.machine(),
    }
    toolchain["clang_version"] = _tool_version(
        "clang", toolchain, ["--version"], environment
    )
    toolchain["decoder_version"] = _tool_version(
        "decoder", toolchain, ["--version"], environment
    )
    return toolchain, environment


def _zero_code_signature_padding(product: Path) -> None:
    descriptor = os.open(
        str(product), os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        metadata = os.fstat(descriptor)
        header = os.pread(descriptor, 32, 0)
        if len(header) != 32:
            raise OracleError("signed product Mach-O header is truncated")
        _, _, _, _, command_count, _, _, _ = struct.unpack("<8I", header)
        offset = 32
        signature_ranges: List[Tuple[int, int]] = []
        for _ in range(command_count):
            command_header = os.pread(descriptor, 16, offset)
            if len(command_header) < 8:
                raise OracleError("signed product load commands are truncated")
            command, command_size = struct.unpack_from("<2I", command_header, 0)
            if command_size < 8 or offset + command_size > metadata.st_size:
                raise OracleError("signed product load command is malformed")
            if command == 0x1D:  # LC_CODE_SIGNATURE
                if command_size != 16 or len(command_header) != 16:
                    raise OracleError("signed product LC_CODE_SIGNATURE is malformed")
                _, _, data_offset, data_size = struct.unpack("<4I", command_header)
                signature_ranges.append((data_offset, data_size))
            offset += command_size
        if len(signature_ranges) != 1:
            raise OracleError("signed product must contain one code signature")
        data_offset, data_size = signature_ranges[0]
        if data_offset + data_size > metadata.st_size or data_size < 12:
            raise OracleError("signed product code signature range is invalid")
        superblob_header = os.pread(descriptor, 12, data_offset)
        magic, used_size, _ = struct.unpack(">3I", superblob_header)
        if magic != 0xFADE0CC0 or used_size < 12 or used_size > data_size:
            raise OracleError("signed product superblob is malformed")
        padding_size = data_size - used_size
        if padding_size:
            os.pwrite(descriptor, b"\0" * padding_size, data_offset + used_size)
            os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _canonicalize_linked_product(
    product: Path,
    artifact_name: str,
    tool_environment: Mapping[str, str],
) -> None:
    descriptor = os.open(
        str(product), os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size < 32:
            raise OracleError("linked product is not a regular Mach-O")
        header = os.pread(descriptor, 32, 0)
        magic, cpu_type, _, file_type, command_count, _, _, _ = struct.unpack(
            "<8I", header
        )
        if (
            magic != MACHO_MAGIC_64
            or cpu_type != CPU_TYPE_ARM64
            or file_type != MACHO_FILE_TYPES[artifact_name]
        ):
            raise OracleError("linked product has the wrong Mach-O role")
        offset = 32
        uuid_offsets: List[int] = []
        for _ in range(command_count):
            command_header = os.pread(descriptor, 8, offset)
            if len(command_header) != 8:
                raise OracleError("linked product load commands are truncated")
            command, command_size = struct.unpack("<2I", command_header)
            if command_size < 8 or offset + command_size > metadata.st_size:
                raise OracleError("linked product load command is malformed")
            if command == 0x1B:  # LC_UUID
                if command_size != 24:
                    raise OracleError("linked product LC_UUID is malformed")
                uuid_offsets.append(offset + 8)
            offset += command_size
        if len(uuid_offsets) != 1:
            raise OracleError("linked product must contain one LC_UUID")
        os.pwrite(descriptor, CANONICAL_PRODUCT_UUIDS[artifact_name], uuid_offsets[0])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

    identifier = "com.macscope.ws15.call-argument-oracle.{}".format(
        "executable" if artifact_name == "executable" else "runtime-image"
    )
    _run_checked(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            "-",
            "--identifier",
            identifier,
            str(product),
        ],
        env=tool_environment,
    )
    _zero_code_signature_padding(product)
    _run_checked(
        ["/usr/bin/codesign", "--verify", str(product)], env=tool_environment
    )


def _canonicalize_link_input_mtime(path: Path) -> None:
    descriptor = os.open(
        str(path), os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OracleError("link input is not a regular file")
        os.utime(
            descriptor,
            ns=(CANONICAL_LINK_INPUT_MTIME_NS, CANONICAL_LINK_INPUT_MTIME_NS),
        )
    finally:
        os.close(descriptor)


def _build_products(
    source_artifacts: Mapping[str, Dict[str, object]],
    output_directory: Path,
    toolchain: Mapping[str, object],
    tool_environment: Mapping[str, str],
    context: str,
) -> Dict[str, Dict[str, object]]:
    clang = str(toolchain["clang"])
    sdk = str(toolchain["sdk"])
    paths = {
        name: output_directory / ARTIFACT_FILENAMES[name]
        for name in (
            "fixture_object",
            "entry_capture_object",
            "executable",
            "runtime_image",
        )
    }
    common = [clang, "-target", TARGET, "-isysroot", sdk]
    _run_claimed_tool_checked(
        common
        + [
            "-std=c17",
            "-g",
            "-O0",
            "-fno-omit-frame-pointer",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-c",
            "-x",
            "c",
            _fd_token("fixture_source"),
            "-o",
            str(paths["fixture_object"]),
        ],
        "clang",
        toolchain,
        context + " fixture compilation",
        tool_environment,
        {"fixture_source": source_artifacts["fixture_source"]},
    )
    _canonicalize_link_input_mtime(paths["fixture_object"])
    products: Dict[str, Dict[str, object]] = {
        "fixture_object": _artifact_record(paths["fixture_object"])
    }
    _run_claimed_tool_checked(
        common
        + [
            "-g",
            "-c",
            "-x",
            "assembler",
            _fd_token("entry_capture_source"),
            "-o",
            str(paths["entry_capture_object"]),
        ],
        "clang",
        toolchain,
        context + " entry-capture compilation",
        tool_environment,
        {"entry_capture_source": source_artifacts["entry_capture_source"]},
    )
    _canonicalize_link_input_mtime(paths["entry_capture_object"])
    products["entry_capture_object"] = _artifact_record(
        paths["entry_capture_object"]
    )
    link_inputs = {
        "fixture_object": products["fixture_object"],
        "entry_capture_object": products["entry_capture_object"],
    }
    _run_claimed_tool_checked(
        common
        + [
            _fd_token("fixture_object"),
            _fd_token("entry_capture_object"),
            "-o",
            str(paths["executable"]),
        ],
        "clang",
        toolchain,
        context + " executable link",
        tool_environment,
        link_inputs,
    )
    _canonicalize_linked_product(
        paths["executable"], "executable", tool_environment
    )
    products["executable"] = _artifact_record(paths["executable"])
    _run_claimed_tool_checked(
        common
        + [
            "-dynamiclib",
            _fd_token("fixture_object"),
            _fd_token("entry_capture_object"),
            "-Wl,-install_name,@rpath/" + ARTIFACT_FILENAMES["runtime_image"],
            "-o",
            str(paths["runtime_image"]),
        ],
        "clang",
        toolchain,
        context + " runtime-image link",
        tool_environment,
        link_inputs,
    )
    _canonicalize_linked_product(
        paths["runtime_image"], "runtime_image", tool_environment
    )
    products["runtime_image"] = _artifact_record(paths["runtime_image"])
    return products


def _rebuild_full_artifacts(
    artifacts: Mapping[str, Dict[str, object]],
    toolchain: Mapping[str, object],
) -> Dict[str, Dict[str, object]]:
    environment = _controlled_tool_environment(str(toolchain["developer_dir"]))
    with tempfile.TemporaryDirectory(prefix="ws15-call-argument-rebuild-") as temporary:
        root = Path(temporary).resolve()
        return _build_products(
            {
                "fixture_source": artifacts["fixture_source"],
                "entry_capture_source": artifacts["entry_capture_source"],
            },
            root,
            toolchain,
            environment,
            "rebuild proof",
        )


def _decode_bound_artifacts(
    artifacts: Mapping[str, Dict[str, object]],
    toolchain: Mapping[str, object],
) -> Dict[str, str]:
    decoder = str(toolchain["decoder"])
    environment = _controlled_tool_environment(str(toolchain["developer_dir"]))
    return {
        name: _run_claimed_tool_checked(
            [decoder, "-tvV", _fd_token(name)],
            "decoder",
            toolchain,
            "fresh {} decode proof".format(name),
            environment,
            {name: artifacts[name]},
        ).stdout
        for name in ("fixture_object", "entry_capture_object", "executable")
    }


def _run_bound_runtime_image(
    artifact: Dict[str, object], toolchain: Mapping[str, object]
) -> str:
    environment = _controlled_tool_environment(str(toolchain["developer_dir"]))
    return _run_bound_checked(
        [
            "/usr/bin/python3",
            "-c",
            (
                "import ctypes,sys; image=ctypes.CDLL(sys.argv[1]); "
                "image.main.restype=ctypes.c_int; raise SystemExit(image.main())"
            ),
            _fd_token("runtime_image"),
        ],
        {"runtime_image": artifact},
        "fresh descriptor-bound runtime-image proof",
        env=environment,
    ).stdout.strip()


def _validate_artifact_proofs(
    artifacts: Mapping[str, Dict[str, object]],
    toolchain: Mapping[str, object],
    source: str,
    *,
    rebuild_callback: Optional[Callable[..., Dict[str, Dict[str, object]]]],
    decode_callback: Optional[Callable[..., Dict[str, str]]],
    runtime_callback: Optional[Callable[..., str]],
) -> None:
    callbacks = (rebuild_callback, decode_callback, runtime_callback)
    if any(callback is not None for callback in callbacks) and not all(
        callback is not None for callback in callbacks
    ):
        raise OracleError("{}: proof callbacks must be supplied as one closed set".format(source))

    for name in sorted(MACHO_FILE_TYPES):
        _require_macho_role(name, artifacts[name], source)

    for name, repository_path in (
        ("fixture_source", FIXTURE_DIR / ARTIFACT_FILENAMES["fixture_source"]),
        (
            "entry_capture_source",
            FIXTURE_DIR / ARTIFACT_FILENAMES["entry_capture_source"],
        ),
    ):
        repository_record = _artifact_record(repository_path)
        if (
            artifacts[name]["size"] != repository_record["size"]
            or artifacts[name]["sha256"] != repository_record["sha256"]
        ):
            raise OracleError(
                "{}.{} is not bound to the repository fixture".format(source, name)
            )

    if rebuild_callback is None:
        live_toolchain, _ = _toolchain()
        if dict(toolchain) != live_toolchain:
            raise OracleError("{}: live toolchain identity drifted".format(source))
        rebuilt = _rebuild_full_artifacts(artifacts, toolchain)
        decoded = _decode_bound_artifacts(artifacts, toolchain)
        runtime_output = _run_bound_runtime_image(artifacts["runtime_image"], toolchain)
    else:
        assert decode_callback is not None and runtime_callback is not None
        rebuilt = rebuild_callback(artifacts, toolchain)
        decoded = decode_callback(artifacts, toolchain)
        runtime_output = runtime_callback(artifacts["runtime_image"], toolchain)

    expected_products = {
        "fixture_object",
        "entry_capture_object",
        "executable",
        "runtime_image",
    }
    if set(rebuilt) != expected_products:
        raise OracleError("{}: rebuild proof artifact set is not closed".format(source))
    for name in sorted(expected_products):
        rebuilt_record = _require_exact_keys(
            rebuilt[name], {"path", "size", "sha256"}, source + ".rebuild." + name
        )
        _require_integer(rebuilt_record.get("size"), source + ".rebuild." + name + ".size", 1)
        _require_digest(rebuilt_record.get("sha256"), source + ".rebuild." + name + ".sha256")
        if (
            rebuilt_record["size"] != artifacts[name]["size"]
            or rebuilt_record["sha256"] != artifacts[name]["sha256"]
        ):
            raise OracleError("{}.{} rebuild product mismatch".format(source, name))

    if set(decoded) != {"fixture_object", "entry_capture_object", "executable"}:
        raise OracleError("{}: decode proof artifact set is not closed".format(source))
    for name, text in decoded.items():
        if not isinstance(text, str):
            raise OracleError("{}.{} decode output must be text".format(source, name))
    _verify_call_sites(decoded["fixture_object"], decoded["executable"])
    _verify_entry_capture(decoded["entry_capture_object"])
    if runtime_output.strip() != "call-argument-sentinels-ok":
        raise OracleError("{}: descriptor-bound runtime sentinel failed".format(source))
    _require_bound_artifacts(dict(artifacts), source + ".post-proof artifacts")


def run_external_oracle(artifact_dir: Path) -> Dict[str, object]:
    source = FIXTURE_DIR / "call_arguments.c"
    assembly = FIXTURE_DIR / "entry_capture.s"
    for fixture in (source, assembly):
        if not fixture.is_file():
            raise OracleError("missing fixture source: {}".format(fixture))
    artifact_dir = _create_fresh_artifact_directory(artifact_dir)

    fixture_snapshot = artifact_dir / "call_arguments.c"
    entry_snapshot = artifact_dir / "entry_capture.s"
    bound_artifacts: Dict[str, Dict[str, object]] = {
        "fixture_source": _snapshot_source(source, fixture_snapshot),
        "entry_capture_source": _snapshot_source(assembly, entry_snapshot),
    }

    toolchain, tool_environment = _toolchain()
    bound_artifacts.update(
        _build_products(
            bound_artifacts,
            artifact_dir,
            toolchain,
            tool_environment,
            "oracle generation",
        )
    )

    # Darwin does not permit execve("/dev/fd/N") even when N was opened with
    # O_EXEC (the fdesc node itself returns EACCES). Retain the ordinary Mach-O
    # executable for exact linked call-site decoding, and link the same two
    # already-bound objects into a loadable image for descriptor-bound runtime
    # execution. dlopen consumes /dev/fd/N directly on macOS.
    _require_bound_artifacts(bound_artifacts, "pre-proof artifacts")
    runtime = _run_bound_checked(
        [
            "/usr/bin/python3",
            "-c",
            (
                "import ctypes,sys; image=ctypes.CDLL(sys.argv[1]); "
                "image.main.restype=ctypes.c_int; raise SystemExit(image.main())"
            ),
            _fd_token("runtime_image"),
        ],
        {"runtime_image": bound_artifacts["runtime_image"]},
        "runtime sentinel proof",
        env=tool_environment,
    )
    if runtime.stdout.strip() != "call-argument-sentinels-ok":
        raise OracleError("runtime harness returned without its exact success marker")

    decoded = _decode_bound_artifacts(bound_artifacts, toolchain)
    _verify_call_sites(decoded["fixture_object"], decoded["executable"])
    _verify_entry_capture(decoded["entry_capture_object"])
    _require_bound_artifacts(bound_artifacts, "post-proof artifacts")

    result: Dict[str, object] = {
        "schema": SCHEMA,
        "toolchain": toolchain,
        "artifacts": bound_artifacts,
        "artifact_directory": str(artifact_dir),
        "build_bindings": _build_bindings(bound_artifacts),
        "proofs": {
            "decoded_call_sites": True,
            "entry_state_capture": True,
            "runtime_sentinels": True,
            "artifact_hashes_verified": True,
        },
        "cases": copy.deepcopy(ORACLE_CASES),
        "x8_negative_control": copy.deepcopy(X8_NEGATIVE_CONTROL),
    }
    validate_oracle_payload(
        result,
        "generated oracle",
        verify_files=True,
        expected_artifact_directory=artifact_dir,
    )
    return result


def _self_test_payload(directory: Path) -> Dict[str, object]:
    directory = directory.resolve()
    source_paths = {
        "fixture_source": FIXTURE_DIR / ARTIFACT_FILENAMES["fixture_source"],
        "entry_capture_source": FIXTURE_DIR
        / ARTIFACT_FILENAMES["entry_capture_source"],
    }
    for name, source_path in source_paths.items():
        shutil.copyfile(str(source_path), str(directory / ARTIFACT_FILENAMES[name]))
    for name in MACHO_FILE_TYPES:
        header = struct.pack(
            "<8I",
            MACHO_MAGIC_64,
            CPU_TYPE_ARM64,
            0,
            MACHO_FILE_TYPES[name],
            0,
            0,
            0,
            0,
        )
        (directory / ARTIFACT_FILENAMES[name]).write_bytes(
            header + ("synthetic-" + name + "\n").encode("ascii")
        )
    artifact_records: Dict[str, Dict[str, object]] = {
        name: _artifact_record(directory / ARTIFACT_FILENAMES[name])
        for name in ARTIFACT_KEYS
    }
    clang_bytes = b"synthetic clang identity\n"
    decoder_bytes = b"synthetic decoder identity\n"
    sdk_settings_bytes = b'{"Version":"27.0","Build":"self-test"}\n'
    return {
        "schema": SCHEMA,
        "toolchain": {
            "developer_dir": "/Applications/Xcode-Oracle-Self-Test.app/Contents/Developer",
            "clang": "/Applications/Xcode-Oracle-Self-Test.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            "clang_size": len(clang_bytes),
            "clang_sha256": hashlib.sha256(clang_bytes).hexdigest(),
            "clang_version": "Apple clang test",
            "decoder": "/Applications/Xcode-Oracle-Self-Test.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/otool",
            "decoder_size": len(decoder_bytes),
            "decoder_sha256": hashlib.sha256(decoder_bytes).hexdigest(),
            "decoder_version": "LLVM test",
            "sdk": "/Applications/Xcode-Oracle-Self-Test.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            "sdk_version": "27.0",
            "sdk_settings_path": "/Applications/Xcode-Oracle-Self-Test.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.json",
            "sdk_settings_size": len(sdk_settings_bytes),
            "sdk_settings_sha256": hashlib.sha256(sdk_settings_bytes).hexdigest(),
            "target": TARGET,
            "host_architecture": "arm64",
        },
        "artifacts": artifact_records,
        "artifact_directory": str(directory),
        "build_bindings": _build_bindings(artifact_records),
        "proofs": {key: True for key in PROOF_KEYS},
        "cases": copy.deepcopy(ORACLE_CASES),
        "x8_negative_control": copy.deepcopy(X8_NEGATIVE_CONTROL),
    }


def _self_test_decode_outputs() -> Dict[str, str]:
    fixture_object = """
_callsite_fixed_direct:
0000000000001000 bl 0x2000
_callsite_fixed_indirect:
0000000000001010 blr x8
_callsite_variadic_direct:
0000000000001020 bl 0x2020
_callsite_variadic_indirect:
0000000000001030 blr x8
"""
    executable = """
_callsite_fixed_direct:
0000000000002000 ldr x1, [sp]
0000000000002004 mov x0, x2
0000000000002008 fmov d0, x3
000000000000200c bl _capture_fixed_direct
_callsite_fixed_indirect:
0000000000002010 ldr x8, [sp]
0000000000002014 ldr x1, [sp, #0x8]
0000000000002018 mov x0, x2
000000000000201c fmov d0, x3
0000000000002020 blr x8
_callsite_variadic_direct:
0000000000002030 mov x9, sp
0000000000002034 str x10, [x9]
0000000000002038 str d0, [x9, #0x8]
000000000000203c str x8, [x9, #0x10]
0000000000002040 mov x0, x1
0000000000002044 fmov d0, x8
0000000000002048 bl _capture_variadic_direct
_callsite_variadic_indirect:
0000000000002050 ldur x8, [x29, #-0x8]
0000000000002054 mov x10, sp
0000000000002058 str x11, [x10]
000000000000205c str d0, [x10, #0x8]
0000000000002060 str x9, [x10, #0x10]
0000000000002064 mov x0, x1
0000000000002068 fmov d0, x9
000000000000206c blr x8
"""
    entry_object = """
_capture_fixed_direct:
0000000000003000 str x0, [x9]
0000000000003004 str d0, [x9, #0x8]
0000000000003008 str x1, [x9, #0x10]
_capture_fixed_indirect:
0000000000003010 str x0, [x9]
0000000000003014 str d0, [x9, #0x8]
0000000000003018 str x1, [x9, #0x10]
000000000000301c str x8, [x9, #0x18]
_capture_variadic_direct:
0000000000003020 str x0, [x9]
0000000000003024 str d0, [x9, #0x8]
0000000000003028 ldr w10, [sp]
000000000000302c ldr d16, [sp, #0x8]
0000000000003030 str d16, [x9, #0x10]
0000000000003034 ldr x10, [sp, #0x10]
_capture_variadic_indirect:
0000000000003040 str x0, [x9]
0000000000003044 str d0, [x9, #0x8]
0000000000003048 ldr w10, [sp]
000000000000304c ldr d16, [sp, #0x8]
0000000000003050 str d16, [x9, #0x10]
0000000000003054 ldr x10, [sp, #0x10]
0000000000003058 str x8, [x9, #0x18]
"""
    return {
        "fixture_object": fixture_object,
        "entry_capture_object": entry_object,
        "executable": executable,
    }


class ClosedOracleValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="call-argument-oracle-self-test-")
        self.payload = _self_test_payload(Path(self.temporary.name))
        self.rebuilt = {
            name: copy.deepcopy(self.payload["artifacts"][name])
            for name in MACHO_FILE_TYPES
        }
        self.decoded = _self_test_decode_outputs()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def validate(self) -> None:
        validate_oracle_payload(
            self.payload,
            "self-test",
            verify_files=True,
            rebuild_callback=lambda _artifacts, _toolchain: copy.deepcopy(
                self.rebuilt
            ),
            decode_callback=lambda _artifacts, _toolchain: copy.deepcopy(
                self.decoded
            ),
            runtime_callback=lambda _artifact, _toolchain: (
                "call-argument-sentinels-ok"
            ),
            expected_artifact_directory=Path(self.payload["artifact_directory"]),
        )

    def assert_rejected(self, phrase: str) -> None:
        with self.assertRaisesRegex(OracleError, phrase):
            self.validate()

    def refresh_artifact_claim(self, name: str) -> None:
        record = _artifact_record(Path(self.payload["artifacts"][name]["path"]))
        self.payload["artifacts"][name] = record
        for bindings in self.payload["build_bindings"].values():
            for binding in bindings:
                if binding["artifact"] == name:
                    binding.update(_binding_record(name, record))

    def test_valid_payload(self) -> None:
        self.validate()

    def test_contract_requires_v2_artifact_directory_and_build_bindings(self) -> None:
        self.assertEqual(self.payload["schema"], "call-argument-oracle-v2")
        self.assertIn("artifact_directory", self.payload)
        self.assertIn("build_bindings", self.payload)

    def test_toolchain_content_identity_fields_are_closed(self) -> None:
        self.assertEqual(set(self.payload["toolchain"]), TOOLCHAIN_KEYS)
        for prefix in ("clang", "decoder"):
            self.assertGreater(self.payload["toolchain"][prefix + "_size"], 0)
            _require_digest(
                self.payload["toolchain"][prefix + "_sha256"],
                "self-test " + prefix,
            )
        self.assertTrue(
            self.payload["toolchain"]["sdk_settings_path"].endswith(
                "/SDKSettings.json"
            )
        )
        self.assertGreater(self.payload["toolchain"]["sdk_settings_size"], 0)
        _require_digest(
            self.payload["toolchain"]["sdk_settings_sha256"],
            "self-test SDK settings",
        )

    def test_swapped_linked_product_roles_are_rejected(self) -> None:
        executable = Path(self.payload["artifacts"]["executable"]["path"])
        runtime_image = Path(self.payload["artifacts"]["runtime_image"]["path"])
        executable_bytes = executable.read_bytes()
        runtime_image_bytes = runtime_image.read_bytes()
        executable.write_bytes(runtime_image_bytes)
        runtime_image.write_bytes(executable_bytes)
        self.refresh_artifact_claim("executable")
        self.refresh_artifact_claim("runtime_image")
        self.assert_rejected("linked product role|Mach-O file type")

    def test_missing_linked_product_is_rejected(self) -> None:
        Path(self.payload["artifacts"]["runtime_image"]["path"]).unlink()
        self.assert_rejected("exact closed entry set|missing")

    def test_hard_linked_artifact_alias_is_rejected(self) -> None:
        executable = Path(self.payload["artifacts"]["executable"]["path"])
        runtime_image = Path(self.payload["artifacts"]["runtime_image"]["path"])
        runtime_image.unlink()
        os.link(executable, runtime_image)
        self.refresh_artifact_claim("runtime_image")
        self.assert_rejected("aliases another artifact inode")

    def test_refreshed_linked_product_mutation_is_rejected(self) -> None:
        executable = Path(self.payload["artifacts"]["executable"]["path"])
        original = executable.read_bytes()
        executable.write_bytes(b"X" * len(original))
        self.refresh_artifact_claim("executable")
        self.assert_rejected("Mach-O|rebuild|product")

    def test_ordered_executable_link_binding_drift_is_rejected(self) -> None:
        self.payload["build_bindings"]["executable_link_inputs"].reverse()
        self.assert_rejected("wrong artifact|binding")

    def test_runtime_and_executable_link_object_sets_must_match(self) -> None:
        runtime_inputs = self.payload["build_bindings"]["runtime_image_link_inputs"]
        runtime_inputs[1] = copy.deepcopy(runtime_inputs[0])
        self.assert_rejected("wrong artifact|binding")

    def test_valid_macho_object_mutation_with_refreshed_claim_is_rejected(self) -> None:
        fixture_object = Path(self.payload["artifacts"]["fixture_object"]["path"])
        data = bytearray(fixture_object.read_bytes())
        data[-1] ^= 0x01
        fixture_object.write_bytes(data)
        self.refresh_artifact_claim("fixture_object")
        self.assert_rejected("rebuild product mismatch")

    def test_repository_source_binding_is_required(self) -> None:
        source = Path(self.payload["artifacts"]["fixture_source"]["path"])
        data = bytearray(source.read_bytes())
        data[-1] ^= 0x01
        source.chmod(0o644)
        source.write_bytes(data)
        self.refresh_artifact_claim("fixture_source")
        self.assert_rejected("repository fixture")

    def test_artifact_directory_extra_entry_is_rejected(self) -> None:
        (Path(self.payload["artifact_directory"]) / "unexpected.txt").write_text(
            "not closed", encoding="utf-8"
        )
        self.assert_rejected("exact closed entry set")

    def test_wrong_decode_artifact_set_is_rejected(self) -> None:
        wrong_decoded = copy.deepcopy(self.decoded)
        wrong_decoded["runtime_image"] = wrong_decoded.pop("executable")
        with self.assertRaisesRegex(OracleError, "decode proof artifact set"):
            validate_oracle_payload(
                self.payload,
                "self-test",
                rebuild_callback=lambda _artifacts, _toolchain: copy.deepcopy(
                    self.rebuilt
                ),
                decode_callback=lambda _artifacts, _toolchain: wrong_decoded,
                runtime_callback=lambda _artifact, _toolchain: (
                    "call-argument-sentinels-ok"
                ),
            )

    def test_wrong_decode_binding_role_is_rejected(self) -> None:
        executable_decode = self.payload["build_bindings"][
            "executable_decode_inputs"
        ]
        executable_decode[0] = _binding_record(
            "runtime_image", self.payload["artifacts"]["runtime_image"]
        )
        self.assert_rejected("wrong artifact|binding")

    def test_wrong_runtime_binding_role_is_rejected(self) -> None:
        runtime_inputs = self.payload["build_bindings"]["runtime_inputs"]
        runtime_inputs[0] = _binding_record(
            "executable", self.payload["artifacts"]["executable"]
        )
        self.assert_rejected("wrong artifact|binding")

    def test_runtime_callback_receives_only_bound_dylib_role(self) -> None:
        observed: List[str] = []

        def runtime(artifact: Dict[str, object], _toolchain: object) -> str:
            observed.append(str(artifact["path"]))
            return "call-argument-sentinels-ok"

        validate_oracle_payload(
            self.payload,
            "self-test",
            rebuild_callback=lambda _artifacts, _toolchain: copy.deepcopy(
                self.rebuilt
            ),
            decode_callback=lambda _artifacts, _toolchain: copy.deepcopy(
                self.decoded
            ),
            runtime_callback=runtime,
        )
        self.assertEqual(
            observed,
            [str(self.payload["artifacts"]["runtime_image"]["path"])],
        )

    def test_post_proof_artifact_mutation_is_rejected(self) -> None:
        executable = Path(self.payload["artifacts"]["executable"]["path"])

        def runtime(_artifact: object, _toolchain: object) -> str:
            data = bytearray(executable.read_bytes())
            data[-1] ^= 0x01
            executable.write_bytes(data)
            return "call-argument-sentinels-ok"

        with self.assertRaisesRegex(OracleError, "changed hash"):
            validate_oracle_payload(
                self.payload,
                "self-test",
                rebuild_callback=lambda _artifacts, _toolchain: copy.deepcopy(
                    self.rebuilt
                ),
                decode_callback=lambda _artifacts, _toolchain: copy.deepcopy(
                    self.decoded
                ),
                runtime_callback=runtime,
            )

    def test_boolean_integer(self) -> None:
        self.payload["cases"][0]["arguments"][0]["source_position"] = True
        self.assert_rejected("never a boolean")

    def test_wrong_location(self) -> None:
        self.payload["cases"][0]["arguments"][0]["location"] = _gpr(2)
        self.assert_rejected("wrong location")

    def test_stale_artifact_hash(self) -> None:
        self.payload["artifacts"]["fixture_object"]["sha256"] = "0" * 64
        self.assert_rejected("stale artifact hash")

    def test_zero_positive_cases(self) -> None:
        self.payload["cases"] = []
        self.assert_rejected("zero positive cases")

    def test_convention_separation(self) -> None:
        self.payload["cases"][2]["convention"] = "darwin-c-fixed"
        self.assert_rejected("convention separation")

    def test_duplicate_evidence(self) -> None:
        self.payload["cases"][0]["arguments"][2]["location"] = _gpr(0)
        self.assert_rejected("duplicate evidence")

    def test_compacted_gap(self) -> None:
        self.payload["cases"][2]["arguments"][3]["tail_ordinal"] = 2
        self.assert_rejected("compacted gap")

    def test_unsupported_schema(self) -> None:
        self.payload["schema"] = "call-argument-oracle-v0"
        self.assert_rejected("unsupported schema")

    def test_missing_proof(self) -> None:
        del self.payload["proofs"]["entry_state_capture"]
        self.assert_rejected("keys are not closed")


class ArtifactBindingTests(unittest.TestCase):
    def test_shared_toolchain_accepts_ctime_churn_at_every_snapshot_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = (Path(temporary) / "tool").resolve()
            source.write_bytes(b"trusted!")
            record = _artifact_record(source)
            real_fd_identity = _fd_identity
            real_path_identity = _lstat_regular_identity
            observations = 0

            def churn(identity: Tuple[int, int, int, int, int]) -> Tuple[int, int, int, int, int]:
                nonlocal observations
                observations += 1
                return identity[:4] + (identity[4] + observations,)

            # Deterministic interleaving: each stat observes another metadata-only
            # update, including both sides of open/hash and the command lifetime.
            with mock.patch(__name__ + "._fd_identity", side_effect=lambda fd: churn(real_fd_identity(fd))), \
                 mock.patch(__name__ + "._lstat_regular_identity", side_effect=lambda path, context: churn(real_path_identity(path, context))):
                self.assertEqual(_artifact_record(source, shared_toolchain=True), record)
                with _open_bound_artifacts({"tool": record}, "ctime churn", shared_toolchain=True) as descriptors:
                    self.assertEqual(os.pread(descriptors["tool"], 8, 0), b"trusted!")
            self.assertGreater(observations, 12)

    def test_shared_toolchain_rejects_changed_bytes_with_restored_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = (Path(temporary) / "tool").resolve()
            source.write_bytes(b"trusted!")
            record = _artifact_record(source)
            before = source.stat()
            with self.assertRaisesRegex(OracleError, "changed hash while in use"):
                with _open_bound_artifacts({"tool": record}, "tool mutation", shared_toolchain=True):
                    source.write_bytes(b"mutated!")
                    os.utime(source, ns=(before.st_atime_ns, before.st_mtime_ns))

    def test_owned_artifacts_still_reject_ctime_only_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = (Path(temporary) / "input").resolve()
            source.write_bytes(b"trusted!")
            descriptor, identity, digest = _open_descriptor_snapshot(source, "owned artifact")
            try:
                with mock.patch(__name__ + "._fd_identity", return_value=identity[:4] + (identity[4] + 1,)):
                    with self.assertRaisesRegex(OracleError, "changed metadata while in use"):
                        _assert_descriptor_snapshot_unchanged(source, descriptor, identity, digest, "owned artifact")
            finally:
                os.close(descriptor)

    def test_artifact_record_rejects_pre_open_path_swap(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="call-argument-oracle-pre-open-swap-test-"
        ) as temporary:
            directory = Path(temporary)
            source = directory / "input.bin"
            displaced = directory / "trusted.bin"
            source.write_bytes(b"trusted!")
            canonical_source = Path(os.path.realpath(str(source)))
            canonical_displaced = Path(os.path.realpath(str(displaced)))
            real_open = os.open
            swapped = False

            def swap_before_open(path: object, flags: int, *args: object) -> int:
                nonlocal swapped
                if not swapped and str(path) == str(canonical_source):
                    swapped = True
                    canonical_source.rename(canonical_displaced)
                    canonical_source.write_bytes(b"attacker")
                return real_open(path, flags, *args)

            with mock.patch(__name__ + ".os.open", side_effect=swap_before_open):
                with self.assertRaisesRegex(
                    OracleError, "changed before descriptor open"
                ):
                    _artifact_record(source)

    def test_snapshot_is_read_only_and_detects_same_size_mutation(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="call-argument-oracle-binding-test-"
        ) as temporary:
            directory = Path(temporary)
            source = directory / "source.c"
            snapshot = directory / "snapshot.c"
            source.write_bytes(b"original")

            record = _snapshot_source(source, snapshot)
            self.assertEqual(snapshot.stat().st_mode & 0o222, 0)
            _require_bound_artifact(record, "self-test snapshot")

            snapshot.chmod(0o644)
            snapshot.write_bytes(b"mutated!")
            with self.assertRaisesRegex(OracleError, "changed hash"):
                _require_bound_artifact(record, "self-test snapshot")

    def test_path_swap_cannot_redirect_bound_subprocess_input(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="call-argument-oracle-path-swap-test-"
        ) as temporary:
            directory = Path(temporary)
            source = directory / "input.bin"
            displaced = directory / "trusted.bin"
            source.write_bytes(b"trusted!")
            record = _artifact_record(source)
            observed: List[str] = []
            real_run_checked = _run_checked

            def swap_path_then_run(*args: object, **kwargs: object) -> object:
                source.rename(displaced)
                source.write_bytes(b"attacker")
                result = real_run_checked(*args, **kwargs)
                observed.append(str(result.stdout))
                return result

            with mock.patch(
                __name__ + "._run_checked", side_effect=swap_path_then_run
            ):
                with self.assertRaisesRegex(OracleError, "changed (metadata|hash)"):
                    _run_bound_checked(
                        ["/bin/cat", _fd_token("input")],
                        {"input": record},
                        "path-swap self-test",
                    )
            self.assertEqual(observed, ["trusted!"])


class ClaimedToolExecutionTests(unittest.TestCase):
    def test_claimed_tool_path_swap_cannot_redirect_kernel_executable(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="call-argument-oracle-tool-exec-swap-test-"
        ) as temporary:
            root = Path(temporary).resolve()
            developer_dir = root / "Xcode-Self-Test.app/Contents/Developer"
            tool_path = (
                developer_dir
                / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
            )
            displaced_tool = tool_path.with_name("trusted-clang")
            sdk_settings = (
                developer_dir
                / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.json"
            )
            tool_path.parent.mkdir(parents=True)
            sdk_settings.parent.mkdir(parents=True)
            tool_path.write_text("#!/bin/sh\nprintf 'trusted-tool\\n'\n")
            tool_path.chmod(0o755)
            sdk_settings.write_text('{"Version":"self-test"}\n')

            tool_identity = _artifact_record(tool_path)
            sdk_identity = _artifact_record(sdk_settings)
            toolchain = {
                "developer_dir": str(developer_dir),
                "clang": str(tool_path),
                "clang_size": tool_identity["size"],
                "clang_sha256": tool_identity["sha256"],
                "sdk_settings_path": str(sdk_settings),
                "sdk_settings_size": sdk_identity["size"],
                "sdk_settings_sha256": sdk_identity["sha256"],
            }
            environment = _controlled_tool_environment(str(developer_dir))
            observed: List[str] = []
            real_run_checked = _run_checked
            swapped = False

            def swap_path_then_run(*args: object, **kwargs: object) -> object:
                nonlocal swapped
                if not swapped:
                    swapped = True
                    tool_path.rename(displaced_tool)
                    tool_path.write_text("#!/bin/sh\nprintf 'attacker-tool\\n'\n")
                    tool_path.chmod(0o755)
                result = real_run_checked(*args, **kwargs)
                observed.append(str(result.stdout))
                return result

            with mock.patch(
                __name__ + "._run_checked", side_effect=swap_path_then_run
            ):
                with self.assertRaisesRegex(OracleError, "changed metadata while in use"):
                    _run_claimed_tool_checked(
                        [str(tool_path)],
                        "clang",
                        toolchain,
                        "claimed-tool swap self-test",
                        environment,
                    )
            self.assertEqual(observed, ["trusted-tool\n"])


class LiveProductionHelperTests(unittest.TestCase):
    def test_real_rebuild_decode_runtime_and_tool_identity_mutation(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="call-argument-oracle-live-helper-test-"
        ) as temporary:
            artifact_directory = _create_fresh_artifact_directory(
                Path(temporary) / "artifacts"
            )
            artifacts: Dict[str, Dict[str, object]] = {
                "fixture_source": _snapshot_source(
                    FIXTURE_DIR / ARTIFACT_FILENAMES["fixture_source"],
                    artifact_directory / ARTIFACT_FILENAMES["fixture_source"],
                ),
                "entry_capture_source": _snapshot_source(
                    FIXTURE_DIR / ARTIFACT_FILENAMES["entry_capture_source"],
                    artifact_directory
                    / ARTIFACT_FILENAMES["entry_capture_source"],
                ),
            }
            toolchain, environment = _toolchain()
            artifacts.update(
                _build_products(
                    artifacts,
                    artifact_directory,
                    toolchain,
                    environment,
                    "live-helper self-test",
                )
            )

            rebuilt = _rebuild_full_artifacts(artifacts, toolchain)
            for name in MACHO_FILE_TYPES:
                self.assertEqual(rebuilt[name]["size"], artifacts[name]["size"])
                self.assertEqual(rebuilt[name]["sha256"], artifacts[name]["sha256"])

            decoded = _decode_bound_artifacts(artifacts, toolchain)
            _verify_call_sites(decoded["fixture_object"], decoded["executable"])
            _verify_entry_capture(decoded["entry_capture_object"])
            self.assertEqual(
                _run_bound_runtime_image(artifacts["runtime_image"], toolchain),
                "call-argument-sentinels-ok",
            )

            mutated_toolchain = dict(toolchain)
            mutated_toolchain["decoder_sha256"] = "0" * 64
            with self.assertRaisesRegex(OracleError, "changed hash before use"):
                _decode_bound_artifacts(artifacts, mutated_toolchain)

            mutated_toolchain = dict(toolchain)
            mutated_toolchain["clang_sha256"] = "0" * 64
            with self.assertRaisesRegex(OracleError, "changed hash before use"):
                _run_claimed_tool_checked(
                    [str(toolchain["clang"]), "--version"],
                    "clang",
                    mutated_toolchain,
                    "mutated clang identity self-test",
                    environment,
                )

            mutated_toolchain = dict(toolchain)
            mutated_toolchain["sdk_settings_sha256"] = "0" * 64
            with self.assertRaisesRegex(OracleError, "changed hash before use"):
                _run_claimed_tool_checked(
                    [str(toolchain["clang"]), "--version"],
                    "clang",
                    mutated_toolchain,
                    "mutated SDK settings identity self-test",
                    environment,
                )


class OtoolParsingTests(unittest.TestCase):
    def test_extracts_function_instructions(self) -> None:
        text = """
_callsite_fixed_indirect:
0000000000001000\tldr\tx8, [sp]
0000000000001004\tblr\tx8
_capture_fixed_indirect:
0000000000001008\tstr\tx0, [x9]
"""
        functions = parse_otool_functions(text)
        self.assertEqual(
            functions["callsite_fixed_indirect"],
            [("ldr", "x8, [sp]"), ("blr", "x8")],
        )

    def test_rejects_lookalike_call_operand(self) -> None:
        functions = {
            "callsite": [
                ("mov", "x0, #1"),
                ("bl", "_capture_fixed_direct_lookalike"),
            ]
        }
        with self.assertRaisesRegex(OracleError, "call must be exactly"):
            _require_exact_fixture_call(
                functions,
                "callsite",
                "bl",
                "_capture_fixed_direct",
                [("mov", "x0,")],
            )

    def test_rejects_setup_anchor_only_after_call(self) -> None:
        functions = {
            "callsite": [
                ("bl", "_capture_fixed_direct"),
                ("mov", "x0, #1"),
            ]
        }
        with self.assertRaisesRegex(OracleError, "multiplicity 0"):
            _require_exact_fixture_call(
                functions,
                "callsite",
                "bl",
                "_capture_fixed_direct",
                [("mov", "x0,")],
            )

    def test_rejects_duplicate_intended_calls(self) -> None:
        functions = {
            "callsite": [
                ("mov", "x0, #1"),
                ("bl", "_capture_fixed_direct"),
                ("bl", "_capture_fixed_direct"),
            ]
        }
        with self.assertRaisesRegex(OracleError, "exactly one call"):
            _require_exact_fixture_call(
                functions,
                "callsite",
                "bl",
                "_capture_fixed_direct",
                [("mov", "x0,")],
            )


class ToolchainCoherenceTests(unittest.TestCase):
    def test_rejects_developer_dir_mismatch(self) -> None:
        with self.assertRaisesRegex(OracleError, "DEVELOPER_DIR mismatch"):
            _validated_developer_dir(
                "/Applications/Xcode-A.app/Contents/Developer",
                "/Applications/Xcode-B.app/Contents/Developer",
            )


class ProcessIsolationTests(unittest.TestCase):
    def test_self_test_process_owns_its_process_group(self) -> None:
        self.assertEqual(os.getpgrp(), os.getpid())

    def test_inner_timeout_terminates_nested_oracle_group(self) -> None:
        nested = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--self-test-inner-timeout"],
            start_new_session=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        process_group = nested.pid
        stdout, stderr = nested.communicate(timeout=5)
        self.assertEqual(stdout, "")
        self.assertIn(nested.returncode, {-signal.SIGTERM, -signal.SIGKILL})
        self.assertIn("inner command timed out", stderr)

        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.killpg(process_group, 0)
            except ProcessLookupError:
                break
            time.sleep(0.01)
        else:
            self.fail("nested timeout left a member in its isolated process group")
        # Allow the out-of-group escalation watchdog to perform its final check
        # and exit before the surrounding self-test reports success.
        time.sleep(GROUP_KILL_GRACE_SECONDS + 0.1)


def _self_test_class_counts(suite: unittest.TestSuite) -> Dict[str, int]:
    counts: Dict[str, int] = {}

    def visit(node: object) -> None:
        if isinstance(node, unittest.TestSuite):
            for child in node:
                visit(child)
            return
        if isinstance(node, unittest.TestCase):
            name = type(node).__name__
            counts[name] = counts.get(name, 0) + 1

    visit(suite)
    return counts


def run_self_tests() -> int:
    stream = io.StringIO()
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    expected_counts = dict(EXPECTED_SELF_TEST_CLASS_COUNTS)
    actual_counts = _self_test_class_counts(suite)
    if actual_counts != expected_counts:
        print(
            "call-argument oracle self-test inventory drifted: expected {}; actual {}".format(
                expected_counts, actual_counts
            ),
            file=sys.stderr,
        )
        return 1
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    print(stream.getvalue(), end="")
    if result.wasSuccessful():
        print(
            "self-test inventory: {} tests; {}".format(
                sum(expected_counts.values()),
                "; ".join(
                    "{}={}".format(name, count)
                    for name, count in EXPECTED_SELF_TEST_CLASS_COUNTS
                ),
            )
        )
        print(
            "false-pass gates exercised: boolean integer; wrong location; "
            "stale artifact hash; zero positive cases; convention separation; "
            "duplicate evidence; compacted gap; unsupported schema; missing proof; "
            "path swap; lookalike call; post-call setup; duplicate call; "
            "developer dir mismatch; process isolation; inner timeout group cleanup; "
            "missing or swapped products; Mach-O roles; ordered binding drift; "
            "wrong decode role; wrong runtime role; post-proof mutation; "
            "pre-open swap; tool content identities; live helper mutation; "
            "claimed tool executable swap; shared toolchain metadata churn"
        )
    return 0 if result.wasSuccessful() else 1


def _isolate_process_group() -> None:
    """Make this driver the leader of a dedicated process group.

    Foundation ``Process`` can launch the child with ``PGID == PID`` already.
    Such a process is a group leader and therefore cannot call ``setsid()``;
    requiring a new session would reject the already-safe XCTest launch path.
    The cleanup contract uses exact negative-PGID signals, so a dedicated group
    is the required invariant.  The fatal-timeout watchdog still calls
    ``setsid()`` after ``fork()`` because that child must escape this group
    before it signals the group.
    """
    process_id = os.getpid()
    if os.getpgrp() != process_id:
        try:
            os.setpgid(0, 0)
        except OSError as error:
            raise OracleError("cannot create isolated process group: {}".format(error))
    if os.getpgrp() != process_id:
        raise OracleError("oracle process did not become its own process-group leader")


def main() -> int:
    try:
        _isolate_process_group()
    except OracleError as error:
        print("call-argument oracle: {}".format(error), file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(
        description="Compile and verify the reduced WS-15 Darwin arm64 call ABI fixture."
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--self-test-inner-timeout",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--self-test-leaked-descendant",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--artifact-dir", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.self_test_inner_timeout:
        _run_checked(
            ["/bin/sh", "-c", "/bin/sleep 30 & wait"],
            timeout_seconds=0.05,
        )
        raise AssertionError("inner timeout exercise unexpectedly returned")
    if args.self_test_leaked_descendant:
        subprocess.Popen(
            ["/bin/sleep", "30"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
        time.sleep(0.1)
        return 0
    if args.self_test:
        if args.artifact_dir is not None:
            parser.error("--self-test and --artifact-dir are mutually exclusive")
        return run_self_tests()
    if args.artifact_dir is None:
        parser.error("the external proof requires a fresh --artifact-dir")

    try:
        result = run_external_oracle(args.artifact_dir)
    except OracleError as error:
        print("call-argument oracle: {}".format(error), file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print("call-argument oracle passed")
        print("  compiler: {}".format(result["toolchain"]["clang_version"]))
        print("  cases:    {}".format(len(result["cases"])))
        print("  proofs:   decoded caller + entry capture + runtime sentinels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
