#!/usr/bin/env python3
"""WS-15 Objective-C arm64 call-argument oracle.

This reduced oracle compiles an Objective-C fixture with the active Xcode
toolchain, runs its sentinels, and independently decodes the resulting Mach-O.
It deliberately separates typed canonical ``objc_msgSend`` calls from normal
selector-stub lowering. All placement evidence is fixture-specific: neither a
selector's arity nor this fixture supplies authoritative per-call method ABI.
The object-only x2/x3 and mixed d0+x2 observations therefore support product
abstention, not runtime type classification.
"""

from __future__ import annotations

import argparse
import copy
import errno
import hashlib
import json
import os
import platform
import re
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Set, Tuple
from unittest import mock


FIXTURE = (
    Path(__file__).resolve().parent
    / "fixtures/call-arguments/objc_call_arguments.m"
)
TARGET = "arm64-apple-macos26.4"
SCHEMA = "objc-call-argument-oracle-v1"
RUNTIME_SENTINEL = "objc-call-argument-sentinels-ok"

ROOT_KEYS = {
    "schema", "toolchain", "artifacts", "proofs", "cases",
    "policy_boundaries", "build_bindings", "artifact_directory",
}
TOOLCHAIN_KEYS = {
    "developer_dir", "xcode_version", "clang", "clang_version", "sdk",
    "sdk_version", "target", "host_architecture", "object_file_description",
    "executable_file_description", "decoder", "decoder_version",
    "decoder_sha256", "clang_sha256", "sdk_settings_path",
    "sdk_settings_sha256",
}
ARTIFACT_KEYS = {
    "fixture_source", "fixture_object", "executable", "object_disassembly",
    "executable_disassembly",
}
ARTIFACT_RECORD_KEYS = {"path", "size", "sha256"}
ARTIFACT_FILENAMES = {
    "fixture_source": "objc_call_arguments.m",
    "fixture_object": "objc_call_arguments.o",
    "executable": "objc_call_argument_fixture",
    "object_disassembly": "objc_call_arguments.object.txt",
    "executable_disassembly": "objc_call_arguments.executable.txt",
}
BUILD_BINDING_KEYS = {
    "compile_inputs", "link_inputs", "object_decode_inputs",
    "executable_decode_inputs", "runtime_inputs",
}
BINDING_RECORD_KEYS = {"artifact", "path", "size", "sha256"}
PROOF_KEYS = {
    "canonical_objc_msgsend_direct", "canonical_receiver_x0",
    "canonical_selector_x1", "canonical_object_carriers_observed",
    "normal_selector_stub_lowering", "normal_object_carriers_observed",
    "mixed_simd_and_object_observed", "mixed_requires_abstention",
    "runtime_sentinels", "artifact_hashes_verified",
}
POLICY_KEYS = {
    "typed_canonical_does_not_certify_stub",
    "selector_arity_does_not_certify_bank",
    "fixture_placement_does_not_authorize_runtime_recovery",
    "mixed_bank_must_abstain",
}
CASE_KEYS = {
    "name", "classification", "selector", "selector_colon_count", "dispatch",
    "target", "selector_transport", "must_abstain", "arguments",
    "decoded_instructions", "function_symbol", "function_start_address",
    "function_end_address", "function_slice_sha256",
}
ARGUMENT_KEYS = {
    "role", "source_position", "tail_ordinal", "type_class", "location",
    "input_origin",
}


class OracleError(Exception):
    """Unavailable toolchain, invalid artifact, or incomplete ABI evidence."""


def _argument(
    role: str,
    source_position: int,
    tail_ordinal: Optional[int],
    type_class: str,
    location: str,
    input_origin: str,
) -> Dict[str, object]:
    return {
        "role": role,
        "source_position": source_position,
        "tail_ordinal": tail_ordinal,
        "type_class": type_class,
        "location": location,
        "input_origin": input_origin,
    }


EXPECTED_CASES: Dict[str, Dict[str, object]] = {
    "canonical_zero": {
        "classification": "canonical-objc-msgsend",
        "selector": "zero",
        "selector_colon_count": 0,
        "dispatch": "direct",
        "target": "_objc_msgSend",
        "selector_transport": "explicit-x1",
        # Production anonymous-tail recovery: zero keywords have no tail.
        "must_abstain": False,
        "arguments": [
            _argument("receiver", 0, None, "object", "x0", "x1"),
            _argument("selector", 1, None, "selector", "x1", "x0"),
        ],
    },
    "canonical_one": {
        "classification": "canonical-objc-msgsend",
        "selector": "one:",
        "selector_colon_count": 1,
        "dispatch": "direct",
        "target": "_objc_msgSend",
        "selector_transport": "explicit-x1",
        # Typed lowering is proven, but cannot authorize production tail recovery.
        "must_abstain": True,
        "arguments": [
            _argument("receiver", 0, None, "object", "x0", "x1"),
            _argument("selector", 1, None, "selector", "x1", "x2"),
            _argument("explicit", 2, 0, "object", "x2", "x0"),
        ],
    },
    "canonical_two": {
        "classification": "canonical-objc-msgsend",
        "selector": "first:second:",
        "selector_colon_count": 2,
        "dispatch": "direct",
        "target": "_objc_msgSend",
        "selector_transport": "explicit-x1",
        # Typed lowering is proven, but cannot authorize production tail recovery.
        "must_abstain": True,
        "arguments": [
            _argument("receiver", 0, None, "object", "x0", "x1"),
            _argument("selector", 1, None, "selector", "x1", "x3"),
            _argument("explicit", 2, 0, "object", "x2", "x0"),
            _argument("explicit", 3, 1, "object", "x3", "x2"),
        ],
    },
    "normal_zero": {
        "classification": "normal-objc-stub-lowering",
        "selector": "zero",
        "selector_colon_count": 0,
        "dispatch": "direct",
        "target": "_objc_msgSend$zero",
        "selector_transport": "selector-specific-stub",
        "must_abstain": True,
        "arguments": [
            _argument("receiver", 0, None, "object", "x0", "x1"),
        ],
    },
    "normal_one": {
        "classification": "normal-objc-stub-lowering",
        "selector": "one:",
        "selector_colon_count": 1,
        "dispatch": "direct",
        "target": "_objc_msgSend$one:",
        "selector_transport": "selector-specific-stub",
        "must_abstain": True,
        "arguments": [
            _argument("receiver", 0, None, "object", "x0", "x1"),
            _argument("explicit", 2, 0, "object", "x2", "x0"),
        ],
    },
    "normal_two": {
        "classification": "normal-objc-stub-lowering",
        "selector": "first:second:",
        "selector_colon_count": 2,
        "dispatch": "direct",
        "target": "_objc_msgSend$first:second:",
        "selector_transport": "selector-specific-stub",
        "must_abstain": True,
        "arguments": [
            _argument("receiver", 0, None, "object", "x0", "x1"),
            _argument("explicit", 2, 0, "object", "x2", "x2"),
            _argument("explicit", 3, 1, "object", "x3", "x0"),
        ],
    },
    "normal_mixed": {
        "classification": "normal-objc-stub-lowering",
        "selector": "mixed:object:",
        "selector_colon_count": 2,
        "dispatch": "direct",
        "target": "_objc_msgSend$mixed:object:",
        "selector_transport": "selector-specific-stub",
        "must_abstain": True,
        "arguments": [
            _argument("receiver", 0, None, "object", "x0", "x1"),
            _argument("explicit", 2, 0, "floating", "d0", "d1"),
            _argument("explicit", 3, 1, "object", "x2", "x0"),
        ],
    },
}

FUNCTION_SYMBOLS = {
    name: "_ws15_{}".format(name) for name in EXPECTED_CASES
}
CASE_ORDER = list(EXPECTED_CASES)
SUBPROCESS_TIMEOUT_SECONDS = 60
XCODE_SELECT = "/usr/bin/xcode-select"
XCODEBUILD = "/usr/bin/xcodebuild"
XCRUN = "/usr/bin/xcrun"
FILE_TOOL = "/usr/bin/file"
CODESIGN = "/usr/bin/codesign"
CANONICAL_EXECUTABLE_UUID = bytes.fromhex("5b90f18fc26a4f72a207b42872be7a15")


@dataclass
class StableFileSnapshot:
    path: Path
    descriptor: int
    device: int
    inode: int
    size: int
    sha256: str

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


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


def _require_integer(value: object, context: str, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise OracleError("{} must be an integer >= {}".format(context, minimum))
    return value


def _require_boolean(value: object, context: str) -> bool:
    if type(value) is not bool:
        raise OracleError("{} must be a boolean".format(context))
    return value


def _sha256_descriptor(descriptor: int) -> str:
    digest = hashlib.sha256()
    offset = 0
    while True:
        block = os.pread(descriptor, 1024 * 1024, offset)
        if not block:
            break
        digest.update(block)
        offset += len(block)
    return digest.hexdigest()


def _snapshot_file(path: Path, context: str) -> StableFileSnapshot:
    absolute = Path(os.path.abspath(str(path)))
    try:
        descriptor = os.open(
            str(absolute), os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        )
    except OSError as error:
        raise OracleError("{} is not a stable no-follow file: {}".format(context, path)) from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OracleError("{} is not a regular file: {}".format(context, path))
        path_metadata = os.lstat(str(absolute))
        if (
            not stat.S_ISREG(path_metadata.st_mode)
            or path_metadata.st_dev != metadata.st_dev
            or path_metadata.st_ino != metadata.st_ino
        ):
            raise OracleError("{} path identity is unstable: {}".format(context, path))
        return StableFileSnapshot(
            path=absolute,
            descriptor=descriptor,
            device=metadata.st_dev,
            inode=metadata.st_ino,
            size=metadata.st_size,
            sha256=_sha256_descriptor(descriptor),
        )
    except Exception:
        os.close(descriptor)
        raise


def _assert_snapshot_unchanged(snapshot: StableFileSnapshot, context: str) -> None:
    descriptor_metadata = os.fstat(snapshot.descriptor)
    if (
        descriptor_metadata.st_dev != snapshot.device
        or descriptor_metadata.st_ino != snapshot.inode
        or descriptor_metadata.st_size != snapshot.size
        or _sha256_descriptor(snapshot.descriptor) != snapshot.sha256
    ):
        raise OracleError("{} descriptor bytes changed during use".format(context))
    current = _snapshot_file(snapshot.path, context)
    try:
        if (
            current.device != snapshot.device
            or current.inode != snapshot.inode
            or current.size != snapshot.size
            or current.sha256 != snapshot.sha256
        ):
            raise OracleError("{} path changed during use".format(context))
    finally:
        current.close()


def _sha256(path: Path) -> str:
    snapshot = _snapshot_file(path, "hash input")
    try:
        return snapshot.sha256
    finally:
        snapshot.close()


def _artifact_record(path: Path) -> Dict[str, object]:
    snapshot = _snapshot_file(path, "artifact")
    try:
        return {
            "path": str(snapshot.path),
            "size": snapshot.size,
            "sha256": snapshot.sha256,
        }
    finally:
        snapshot.close()


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
        raise OracleError("artifact directory must be fresh and absent: {}".format(absolute))
    parent = Path(os.path.realpath(str(absolute.parent)))
    if not parent.is_dir():
        raise OracleError("artifact parent directory is missing: {}".format(parent))
    root = parent / absolute.name
    try:
        root.mkdir(mode=0o700, exist_ok=False)
    except OSError as error:
        raise OracleError("could not create fresh artifact directory: {}".format(root)) from error
    return root


def _write_new_regular(path: Path, data: bytes) -> None:
    try:
        descriptor = os.open(
            str(path),
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
    except OSError as error:
        raise OracleError("artifact output already exists or is unsafe: {}".format(path)) from error
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _validate_artifacts(
    artifacts: Dict[str, object], expected_root: Path
) -> None:
    if not _is_canonical_absolute(expected_root) or not expected_root.is_dir():
        raise OracleError("artifact directory is not canonical")
    entries = list(os.scandir(str(expected_root)))
    if (
        {entry.name for entry in entries} != set(ARTIFACT_FILENAMES.values())
        or any(not entry.is_file(follow_symlinks=False) for entry in entries)
    ):
        raise OracleError("artifact directory does not have the exact closed entry set")
    artifact_root: Optional[Path] = expected_root
    identities: Set[Tuple[int, int]] = set()
    for name in sorted(ARTIFACT_KEYS):
        record = _require_exact_keys(
            artifacts.get(name), ARTIFACT_RECORD_KEYS, "artifact {}".format(name)
        )
        path = Path(_require_string(record["path"], "artifact {} path".format(name)))
        if not _is_canonical_absolute(path):
            raise OracleError("artifact {} path is not canonical absolute".format(name))
        if path.name != ARTIFACT_FILENAMES[name]:
            raise OracleError("artifact {} filename is not frozen".format(name))
        if artifact_root is None:
            artifact_root = path.parent
        if path.parent != artifact_root or not _is_within(path, artifact_root):
            raise OracleError("artifact {} escaped the artifact directory".format(name))
        expected_size = _require_integer(
            record["size"], "artifact {} size".format(name), minimum=1
        )
        digest = _require_string(
            record["sha256"], "artifact {} sha256".format(name)
        )
        if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise OracleError("artifact {} sha256 is malformed".format(name))
        snapshot = _snapshot_file(path, "artifact {}".format(name))
        try:
            identity = (snapshot.device, snapshot.inode)
            if identity in identities:
                raise OracleError("artifact {} aliases another artifact".format(name))
            identities.add(identity)
            if snapshot.size != expected_size:
                raise OracleError("stale artifact size for {}".format(name))
            if snapshot.sha256 != digest:
                raise OracleError("stale artifact hash for {}".format(name))
        finally:
            snapshot.close()


def _argument_locations(oracle_case: Dict[str, object]) -> List[str]:
    arguments = oracle_case.get("arguments")
    if not isinstance(arguments, list):
        raise OracleError("case arguments must be an array")
    locations: List[str] = []
    for index, raw_argument in enumerate(arguments):
        argument = _require_exact_keys(
            raw_argument, ARGUMENT_KEYS, "argument {}".format(index)
        )
        locations.append(_require_string(argument["location"], "argument location"))
    return locations


def _binding_record(name: str, artifact: Dict[str, object]) -> Dict[str, object]:
    return {
        "artifact": name,
        "path": artifact["path"],
        "size": artifact["size"],
        "sha256": artifact["sha256"],
    }


def _validate_build_bindings(
    raw_bindings: object, artifacts: Dict[str, object]
) -> None:
    bindings = _require_exact_keys(raw_bindings, BUILD_BINDING_KEYS, "build_bindings")
    expected = {
        "compile_inputs": ["fixture_source"],
        "link_inputs": ["fixture_object"],
        "object_decode_inputs": ["fixture_object"],
        "executable_decode_inputs": ["executable"],
        "runtime_inputs": ["executable"],
    }
    for stage, artifact_names in expected.items():
        records = bindings[stage]
        if not isinstance(records, list) or len(records) != len(artifact_names):
            raise OracleError("{} binding order/count mismatch".format(stage))
        for index, artifact_name in enumerate(artifact_names):
            record = _require_exact_keys(
                records[index], BINDING_RECORD_KEYS, "{} binding {}".format(stage, index)
            )
            if record != _binding_record(artifact_name, artifacts[artifact_name]):
                raise OracleError("{} binding {} is stale".format(stage, index))


def _read_stable_bytes(path: Path, context: str) -> bytes:
    snapshot = _snapshot_file(path, context)
    try:
        data = bytearray()
        offset = 0
        while offset < snapshot.size:
            block = os.pread(snapshot.descriptor, min(1024 * 1024, snapshot.size - offset), offset)
            if not block:
                break
            data.extend(block)
            offset += len(block)
        _assert_snapshot_unchanged(snapshot, context)
        return bytes(data)
    finally:
        snapshot.close()


def _validate_toolchain_claim(
    toolchain: Dict[str, object], verify_live_identity: bool
) -> None:
    for key in TOOLCHAIN_KEYS:
        _require_string(toolchain[key], "toolchain {}".format(key))
    if toolchain["target"] != TARGET:
        raise OracleError("toolchain target is not frozen to {}".format(TARGET))
    if not str(toolchain["xcode_version"]).startswith("Xcode 27."):
        raise OracleError("toolchain Xcode version is not frozen")
    if "Apple clang version 21." not in str(toolchain["clang_version"]):
        raise OracleError("toolchain clang version is not frozen")
    if not str(toolchain["decoder_version"]).startswith("Apple LLVM version 21."):
        raise OracleError("toolchain decoder version is not frozen")
    decoder_sha256 = _require_string(
        toolchain["decoder_sha256"], "toolchain decoder_sha256"
    )
    clang_sha256 = _require_string(toolchain["clang_sha256"], "toolchain clang_sha256")
    sdk_settings_sha256 = _require_string(
        toolchain["sdk_settings_sha256"], "toolchain sdk_settings_sha256"
    )
    for name, digest in [
        ("decoder", decoder_sha256),
        ("clang", clang_sha256),
        ("SDK settings", sdk_settings_sha256),
    ]:
        if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise OracleError("toolchain {} identity is malformed".format(name))
    if not str(toolchain["sdk_version"]).startswith("27."):
        raise OracleError("toolchain SDK version is not frozen")
    if toolchain["host_architecture"] != "arm64":
        raise OracleError("toolchain host architecture is not arm64")

    developer_dir = Path(str(toolchain["developer_dir"]))
    if not _is_canonical_absolute(developer_dir) or not developer_dir.is_dir():
        raise OracleError("toolchain developer_dir is not canonical")
    for key, require_file in [("clang", True), ("decoder", True), ("sdk", False)]:
        path = Path(str(toolchain[key]))
        if not _is_canonical_absolute(path) or not _is_within(path, developer_dir):
            raise OracleError("toolchain {} escaped developer_dir".format(key))
        if require_file and not path.is_file():
            raise OracleError("toolchain {} is not a file".format(key))
        if not require_file and not path.is_dir():
            raise OracleError("toolchain SDK is not a directory")
    sdk_settings = Path(str(toolchain["sdk_settings_path"]))
    if (
        not _is_canonical_absolute(sdk_settings)
        or sdk_settings != Path(str(toolchain["sdk"])) / "SDKSettings.json"
        or not sdk_settings.is_file()
    ):
        raise OracleError("toolchain SDK settings identity is not canonical")
    if _sha256(Path(str(toolchain["clang"]))) != clang_sha256:
        raise OracleError("toolchain clang identity mismatch")
    if _sha256(Path(str(toolchain["decoder"]))) != decoder_sha256:
        raise OracleError("toolchain decoder identity mismatch")
    if _sha256(sdk_settings) != sdk_settings_sha256:
        raise OracleError("toolchain SDK settings identity mismatch")

    if verify_live_identity:
        current, _, _, _, _ = _collect_toolchain()
        identity_keys = {
            "developer_dir", "xcode_version", "clang", "clang_version", "decoder",
            "decoder_version", "sdk", "sdk_version", "target", "host_architecture",
            "decoder_sha256",
            "clang_sha256", "sdk_settings_path", "sdk_settings_sha256",
        }
        for key in identity_keys:
            if toolchain[key] != current[key]:
                raise OracleError("live toolchain identity mismatch for {}".format(key))


def _decode_artifact(
    path: Path,
    artifact_name: str,
    decoder: str,
    environment: Optional[Dict[str, str]],
) -> str:
    output = _run_with_stable_inputs(
        [decoder, "--macho", "--disassemble", "--reloc", "--symbolize-operands", str(path)],
        "freshly decode {}".format(artifact_name),
        [Path(decoder), path],
        environment,
        pin_executable=True,
    ).stdout.strip()
    return _normalized_disassembly(output, artifact_name)


def validate_payload(
    payload: object,
    decode_callback: Optional[Callable[[Path, str], str]] = None,
    runtime_callback: Optional[Callable[[Path], str]] = None,
    rebuild_callback: Optional[
        Callable[[Path], Dict[str, Dict[str, object]]]
    ] = None,
    expected_artifact_directory: Optional[Path] = None,
) -> None:
    root = _require_exact_keys(payload, ROOT_KEYS, "root")
    if root["schema"] != SCHEMA:
        raise OracleError("unsupported schema")

    toolchain = _require_exact_keys(root["toolchain"], TOOLCHAIN_KEYS, "toolchain")
    _validate_toolchain_claim(toolchain, verify_live_identity=decode_callback is None)

    artifacts = _require_exact_keys(root["artifacts"], ARTIFACT_KEYS, "artifacts")
    claimed_artifact_directory = Path(
        _require_string(root["artifact_directory"], "artifact_directory")
    )
    if expected_artifact_directory is not None:
        expected = Path(os.path.realpath(str(expected_artifact_directory)))
        if claimed_artifact_directory != expected:
            raise OracleError("artifact directory does not match requested directory")
    _validate_artifacts(artifacts, claimed_artifact_directory)
    _validate_build_bindings(root["build_bindings"], artifacts)

    source_record = artifacts["fixture_source"]
    canonical_source = _artifact_record(FIXTURE)
    if (
        source_record["size"] != canonical_source["size"]
        or source_record["sha256"] != canonical_source["sha256"]
    ):
        raise OracleError("fixture source is not bound to the repository fixture")

    source_path = Path(str(source_record["path"]))
    if rebuild_callback is None:
        rebuild_callback = lambda path: _rebuild_full_artifacts(path, toolchain)
    rebuilt = rebuild_callback(source_path)
    if set(rebuilt) != {"fixture_object", "executable"}:
        raise OracleError("rebuild proof artifact set is not closed")
    for artifact_name in ["fixture_object", "executable"]:
        rebuilt_record = _require_exact_keys(
            rebuilt[artifact_name], ARTIFACT_RECORD_KEYS,
            "rebuild {}".format(artifact_name),
        )
        declared_record = artifacts[artifact_name]
        if (
            rebuilt_record["size"] != declared_record["size"]
            or rebuilt_record["sha256"] != declared_record["sha256"]
        ):
            label = "object" if artifact_name == "fixture_object" else "executable"
            raise OracleError("rebuild {} mismatch".format(label))

    if decode_callback is None:
        decoder = str(toolchain["decoder"])
        environment = _tool_environment(str(toolchain["developer_dir"]))

        def decode_callback(path: Path, artifact_name: str) -> str:
            return _decode_artifact(path, artifact_name, decoder, environment)

        if runtime_callback is None:
            def runtime_callback(path: Path) -> str:
                return _run_with_stable_inputs(
                    [str(path)],
                    "revalidate Objective-C ABI sentinels",
                    [path],
                    environment,
                ).stdout.strip()

    assert decode_callback is not None
    object_path = Path(str(artifacts["fixture_object"]["path"]))
    executable_path = Path(str(artifacts["executable"]["path"]))
    fresh_object_text = decode_callback(object_path, object_path.name)
    fresh_executable_text = decode_callback(executable_path, executable_path.name)
    stored_object_text = _read_stable_bytes(
        Path(str(artifacts["object_disassembly"]["path"])),
        "stored object disassembly",
    ).decode("utf-8")
    stored_executable_text = _read_stable_bytes(
        Path(str(artifacts["executable_disassembly"]["path"])),
        "stored executable disassembly",
    ).decode("utf-8")
    if stored_object_text != fresh_object_text + "\n":
        raise OracleError("object bytes do not rebind to stored disassembly")
    if stored_executable_text != fresh_executable_text + "\n":
        raise OracleError("executable bytes do not rebind to stored disassembly")
    if runtime_callback is None or runtime_callback(executable_path) != RUNTIME_SENTINEL:
        raise OracleError("executable bytes do not rebind to runtime sentinels")
    executable_disassembly_record = _require_exact_keys(
        artifacts["executable_disassembly"],
        ARTIFACT_RECORD_KEYS,
        "artifact executable_disassembly",
    )
    executable_disassembly_path = Path(
        _require_string(
            executable_disassembly_record["path"],
            "artifact executable_disassembly path",
        )
    )
    try:
        executable_disassembly = stored_executable_text
    except (OSError, UnicodeError) as error:
        raise OracleError("executable disassembly is unreadable") from error

    proofs = _require_exact_keys(root["proofs"], PROOF_KEYS, "proofs")
    for key in sorted(PROOF_KEYS):
        if not _require_boolean(proofs[key], "proof {}".format(key)):
            raise OracleError("missing proof: {}".format(key))

    boundaries = _require_exact_keys(
        root["policy_boundaries"], POLICY_KEYS, "policy_boundaries"
    )
    if not _require_boolean(
        boundaries["typed_canonical_does_not_certify_stub"],
        "typed canonical boundary",
    ):
        raise OracleError("classification separation was not enforced")
    if not _require_boolean(
        boundaries["selector_arity_does_not_certify_bank"],
        "selector arity boundary",
    ):
        raise OracleError("selector arity is not bank proof")
    if not _require_boolean(
        boundaries["fixture_placement_does_not_authorize_runtime_recovery"],
        "fixture placement boundary",
    ):
        raise OracleError("fixture placement is not runtime method ABI")
    if not _require_boolean(
        boundaries["mixed_bank_must_abstain"], "mixed bank boundary"
    ):
        raise OracleError("mixed bank evidence must abstain")

    raw_cases = root["cases"]
    if not isinstance(raw_cases, list):
        raise OracleError("cases must be an array")
    cases: Dict[str, Dict[str, object]] = {}
    case_order: List[str] = []
    for index, raw_case in enumerate(raw_cases):
        oracle_case = _require_exact_keys(
            raw_case, CASE_KEYS, "case {}".format(index)
        )
        name = _require_string(oracle_case["name"], "case name")
        if name in cases:
            raise OracleError("duplicate case {}".format(name))
        cases[name] = oracle_case
        case_order.append(name)
    if set(cases) != set(EXPECTED_CASES):
        raise OracleError(
            "case set mismatch (missing {}; unknown {})".format(
                sorted(set(EXPECTED_CASES) - set(cases)),
                sorted(set(cases) - set(EXPECTED_CASES)),
            )
        )
    if case_order != CASE_ORDER:
        raise OracleError(
            "case order mismatch: {} != {}".format(case_order, CASE_ORDER)
        )

    prior_function_end = -1
    for name in CASE_ORDER:
        expected = EXPECTED_CASES[name]
        oracle_case = cases[name]
        selector = _require_string(oracle_case["selector"], "{} selector".format(name))
        colon_count = _require_integer(
            oracle_case["selector_colon_count"],
            "{} selector_colon_count".format(name),
        )
        if (
            selector.count(":") != colon_count
            or any(character in selector for character in "\\\"'\n\r")
        ):
            raise OracleError("malformed selector claim in {}".format(name))

        expected_classification = expected["classification"]
        if oracle_case["classification"] != expected_classification:
            raise OracleError("classification separation failed for {}".format(name))
        for key in [
            "selector", "selector_colon_count", "dispatch", "target",
            "selector_transport", "must_abstain",
        ]:
            if oracle_case[key] != expected[key]:
                raise OracleError("{} {} does not match frozen evidence".format(name, key))

        locations = _argument_locations(oracle_case)
        expected_arguments = expected["arguments"]
        assert isinstance(expected_arguments, list)
        expected_locations = [str(argument["location"]) for argument in expected_arguments]
        if name == "normal_mixed" and "d0" not in locations:
            raise OracleError("missing SIMD evidence in normal_mixed")
        if locations != expected_locations:
            raise OracleError(
                "wrong register evidence for {}: {} != {}".format(
                    name, locations, expected_locations
                )
            )
        if oracle_case["arguments"] != expected_arguments:
            raise OracleError("{} argument provenance mismatch".format(name))

        instructions = oracle_case["decoded_instructions"]
        if (
            not isinstance(instructions, list)
            or not instructions
            or any(not isinstance(item, str) or not item for item in instructions)
        ):
            raise OracleError("{} decoded instructions are missing".format(name))

        function_symbol = _require_string(
            oracle_case["function_symbol"], "{} function_symbol".format(name)
        )
        if function_symbol != FUNCTION_SYMBOLS[name]:
            raise OracleError("{} function symbol mismatch".format(name))
        function_start = _require_integer(
            oracle_case["function_start_address"],
            "{} function_start_address".format(name),
            minimum=1,
        )
        function_end = _require_integer(
            oracle_case["function_end_address"],
            "{} function_end_address".format(name),
            minimum=function_start + 4,
        )
        function_digest = _require_string(
            oracle_case["function_slice_sha256"],
            "{} function_slice_sha256".format(name),
        )
        if re.fullmatch(r"[0-9a-f]{64}", function_digest) is None:
            raise OracleError("{} function slice hash is malformed".format(name))
        rebound = _function_binding(executable_disassembly, function_symbol)
        for binding_key in [
            "decoded_instructions", "function_symbol", "function_start_address",
            "function_end_address", "function_slice_sha256",
        ]:
            if oracle_case[binding_key] != rebound[binding_key]:
                raise OracleError(
                    "{} is not bound to executable disassembly ({})".format(
                        name, binding_key
                    )
                )
        if function_start < prior_function_end:
            raise OracleError("function slice order/range overlap at {}".format(name))
        prior_function_end = function_end
        reproven = _prove_case(name, executable_disassembly)
        if oracle_case != reproven:
            raise OracleError(
                "{} case evidence does not reproduce from executable disassembly".format(
                    name
                )
            )

        classification = str(expected_classification)
        roles = [argument["role"] for argument in expected_arguments]
        if classification == "canonical-objc-msgsend":
            if oracle_case["target"] != "_objc_msgSend" or "selector" not in roles:
                raise OracleError("classification separation failed for {}".format(name))
        else:
            if (
                not str(oracle_case["target"]).startswith("_objc_msgSend$")
                or "selector" in roles
            ):
                raise OracleError("classification separation failed for {}".format(name))

    mixed = cases["normal_mixed"]
    if mixed["must_abstain"] is not True:
        raise OracleError("selector arity is not bank proof for mixed evidence")


def _run(
    command: Sequence[str],
    context: str,
    timeout_seconds: float = SUBPROCESS_TIMEOUT_SECONDS,
    environment: Optional[Dict[str, str]] = None,
    executable: Optional[str] = None,
) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(
        list(command),
        executable=executable,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=False,
        env=environment,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        timeout_message = (
            "{} exceeded {} seconds\ncommand: {}\n".format(
                context, timeout_seconds, " ".join(command)
            )
        )
        if os.getpgrp() == os.getpid():
            try:
                os.write(2, timeout_message.encode("utf-8", errors="replace"))
                os.killpg(os.getpgrp(), signal.SIGKILL)
            except OSError:
                pass
        process.terminate()
        try:
            stdout, stderr = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
        raise OracleError(
            "{}{}".format(timeout_message, (stderr or "").strip())
        ) from error
    result = subprocess.CompletedProcess(
        list(command), process.returncode, stdout, stderr
    )
    if result.returncode != 0:
        raise OracleError(
            "{} failed with status {}\ncommand: {}\n{}".format(
                context, result.returncode, " ".join(command), result.stderr.strip()
            )
        )
    return result


def _command_executable_snapshot(
    command: Sequence[str], snapshots: Sequence[StableFileSnapshot]
) -> Optional[StableFileSnapshot]:
    if not command or not os.path.isabs(command[0]):
        return None
    command_path = Path(os.path.abspath(command[0]))
    return next(
        (snapshot for snapshot in snapshots if snapshot.path == command_path),
        None,
    )


def _copy_descriptor_to_new_executable(
    snapshot: StableFileSnapshot, alias: Path, context: str
) -> None:
    try:
        descriptor = os.open(
            str(alias),
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o700,
        )
    except OSError as error:
        raise OracleError(
            "{} could not create a private executable image".format(context)
        ) from error
    try:
        offset = 0
        while offset < snapshot.size:
            block = os.pread(
                snapshot.descriptor,
                min(1024 * 1024, snapshot.size - offset),
                offset,
            )
            if not block:
                raise OracleError(
                    "{} executable descriptor ended before its frozen size".format(
                        context
                    )
                )
            written = 0
            while written < len(block):
                written += os.write(descriptor, block[written:])
            offset += len(block)
        source_mode = os.fstat(snapshot.descriptor).st_mode & 0o777
        os.fchmod(descriptor, source_mode)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _pin_executable_image(
    snapshot: StableFileSnapshot, directory: Path, context: str
) -> StableFileSnapshot:
    alias = directory / snapshot.path.name
    hard_linked = True
    try:
        os.link(str(snapshot.path), str(alias), follow_symlinks=False)
    except OSError as error:
        if error.errno not in {errno.EACCES, errno.EPERM, errno.EXDEV}:
            raise OracleError(
                "{} could not pin the executable vnode".format(context)
            ) from error
        hard_linked = False
        _copy_descriptor_to_new_executable(snapshot, alias, context)
    pinned = _snapshot_file(alias, "{} pinned executable".format(context))
    try:
        if (
            pinned.size != snapshot.size
            or pinned.sha256 != snapshot.sha256
            or (
                hard_linked
                and (
                    pinned.device != snapshot.device
                    or pinned.inode != snapshot.inode
                )
            )
        ):
            raise OracleError(
                "{} executable path changed before pinning".format(context)
            )
        _assert_snapshot_unchanged(snapshot, "{} executable".format(context))
    except Exception:
        pinned.close()
        raise
    return pinned


def _run_with_stable_inputs(
    command: Sequence[str],
    context: str,
    input_paths: Sequence[Path],
    environment: Optional[Dict[str, str]] = None,
    pin_executable: bool = False,
) -> subprocess.CompletedProcess[str]:
    snapshots = [
        _snapshot_file(path, "{} input {}".format(context, index))
        for index, path in enumerate(input_paths)
    ]
    pinned_executable: Optional[StableFileSnapshot] = None
    pinned_directory: Optional[tempfile.TemporaryDirectory[str]] = None
    try:
        executable_snapshot = (
            _command_executable_snapshot(command, snapshots)
            if pin_executable
            else None
        )
        executable: Optional[str] = None
        if executable_snapshot is not None:
            # ★ Insight: macOS refuses execve("/dev/fd/N") with EACCES, so an
            # inherited descriptor cannot be launched directly. A private,
            # inode-verified hard link pins that same vnode across the final
            # exec while the canonical public path remains argv[0] for Clang
            # and LLVM resource discovery. A sandbox may deny that hard link;
            # in that case the fallback copies only through the already-open
            # descriptor and requires an exact size/hash match before exec.
            # Neither path reopens the mutable public pathname for execution.
            pinned_directory = tempfile.TemporaryDirectory(
                prefix="ws15-objc-executable-pin-"
            )
            pinned_executable = _pin_executable_image(
                executable_snapshot,
                Path(pinned_directory.name),
                context,
            )
            executable = str(pinned_executable.path)
        result = _run(
            command,
            context,
            environment=environment,
            executable=executable,
        )
    finally:
        snapshot_error: Optional[Exception] = None
        if pinned_executable is not None:
            try:
                _assert_snapshot_unchanged(
                    pinned_executable, "{} pinned executable".format(context)
                )
            except Exception as error:
                snapshot_error = error
            finally:
                pinned_executable.close()
        for index, snapshot in enumerate(snapshots):
            try:
                _assert_snapshot_unchanged(
                    snapshot, "{} input {}".format(context, index)
                )
            except Exception as error:
                if snapshot_error is None:
                    snapshot_error = error
            finally:
                snapshot.close()
        if pinned_directory is not None:
            pinned_directory.cleanup()
        if snapshot_error is not None:
            raise snapshot_error
    return result


def _enter_isolated_process_group() -> None:
    try:
        os.setpgid(0, 0)
    except OSError as error:
        raise OracleError("could not create isolated process group") from error
    if os.getpgrp() != os.getpid():
        raise OracleError("isolated process group was not established")


def _tool_output(
    command: Sequence[str],
    context: str,
    environment: Optional[Dict[str, str]] = None,
) -> str:
    return _run(command, context, environment=environment).stdout.strip()


def _instruction_record(line: str) -> Optional[Tuple[int, str]]:
    match = re.match(
        r"^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{2}\s+){4}(.+?)\s*$",
        line,
    )
    if match is None:
        return None
    return (
        int(match.group(1), 16),
        re.sub(r"\s+", " ", match.group(2)).strip(),
    )


def _normalized_disassembly(text: str, artifact_name: str) -> str:
    """Remove only objdump's path-bearing header from hash-bound evidence."""
    lines = text.splitlines()
    if not lines or not lines[0].endswith(":"):
        raise OracleError("disassembly is missing its artifact header")
    lines[0] = "{}:".format(artifact_name)
    return "\n".join(lines)


def _function_records(disassembly: str, symbol: str) -> List[Tuple[int, str]]:
    lines = disassembly.splitlines()
    label = "{}:".format(symbol)
    label_indices = [index for index, line in enumerate(lines) if line == label]
    if len(label_indices) != 1:
        raise OracleError(
            "decoded symbol occurrence mismatch for {}: {}".format(
                symbol, len(label_indices)
            )
        )
    start = label_indices[0] + 1

    records: List[Tuple[int, str]] = []
    for line in lines[start:]:
        if line and not line[0].isspace() and line.endswith(":"):
            break
        record = _instruction_record(line)
        if record is not None:
            records.append(record)
    if not records:
        raise OracleError("decoded symbol has no instructions: {}".format(symbol))
    addresses = [address for address, _ in records]
    if any(next_address != address + 4 for address, next_address in zip(addresses, addresses[1:])):
        raise OracleError("decoded symbol is not a contiguous arm64 slice: {}".format(symbol))
    return records


def _function_slice_digest(symbol: str, records: Sequence[Tuple[int, str]]) -> str:
    canonical = [symbol]
    canonical.extend(
        "{:016x}\t{}".format(address, instruction)
        for address, instruction in records
    )
    return hashlib.sha256(("\n".join(canonical) + "\n").encode("utf-8")).hexdigest()


def _function_binding(disassembly: str, symbol: str) -> Dict[str, object]:
    records = _function_records(disassembly, symbol)
    return {
        "function_symbol": symbol,
        "function_start_address": records[0][0],
        "function_end_address": records[-1][0] + 4,
        "function_slice_sha256": _function_slice_digest(symbol, records),
        "decoded_instructions": [instruction for _, instruction in records],
    }


def _decoded_tail_branch_target(instruction: str) -> Optional[str]:
    match = re.fullmatch(r"b\s+(.+)", instruction.strip())
    if match is None:
        return None
    operand = match.group(1)
    stub_marker = "; symbol stub for:"
    if stub_marker in operand:
        target = operand.split(stub_marker, 1)[1].strip()
    else:
        target = operand.split(";", 1)[0].strip()
    if len(target) >= 2 and target[0] == '"' and target[-1] == '"':
        target = target[1:-1]
    if re.fullmatch(r"0x[0-9a-fA-F]+", target):
        return None
    return target or None


def _require_exact_final_dispatch(
    instructions: Sequence[str], expected_target: str
) -> Sequence[str]:
    if not instructions:
        raise OracleError("decoded function is empty")
    target = _decoded_tail_branch_target(instructions[-1])
    if target != expected_target:
        raise OracleError(
            "exact final dispatch target mismatch: expected {}; decoded {}".format(
                expected_target, target
            )
        )
    for instruction in instructions[:-1]:
        without_comment = instruction.split(";", 1)[0].strip().lower()
        mnemonic = without_comment.split(None, 1)[0] if without_comment else ""
        if (
            mnemonic in {
                "b", "bl", "br", "blr", "ret", "cbz", "cbnz", "tbz", "tbnz",
            }
            or mnemonic.startswith("b.")
        ):
            raise OracleError(
                "non-straight-line control flow before dispatch: {}".format(instruction)
            )
    return instructions[:-1]


def _register_origins(instructions: Sequence[str]) -> Tuple[Dict[str, str], Dict[str, str]]:
    gpr = {"x{}".format(index): "x{}".format(index) for index in range(9)}
    simd = {"d{}".format(index): "d{}".format(index) for index in range(8)}
    for instruction in instructions:
        without_comment = instruction.split(";", 1)[0].strip()
        gpr_move = re.fullmatch(r"mov\s+(x[0-8]),\s*(x[0-8])", without_comment)
        if gpr_move is not None:
            destination, source = gpr_move.groups()
            gpr[destination] = gpr[source]
            continue
        simd_move = re.fullmatch(
            r"(?:mov\.16b\s+v|mov\s+v)([0-7])(?:\.16b)?,\s*v([0-7])(?:\.16b)?",
            without_comment,
        )
        if simd_move is not None:
            destination, source = simd_move.groups()
            simd["d{}".format(destination)] = simd["d{}".format(source)]
            continue
        floating_move = re.fullmatch(r"fmov\s+d([0-7]),\s*d([0-7])", without_comment)
        if floating_move is not None:
            destination, source = floating_move.groups()
            simd["d{}".format(destination)] = simd["d{}".format(source)]
            continue
        raise OracleError(
            "unsupported instruction in proof prefix: {}".format(instruction)
        )
    return gpr, simd


def _prove_case(name: str, disassembly: str) -> Dict[str, object]:
    expected = EXPECTED_CASES[name]
    binding = _function_binding(disassembly, FUNCTION_SYMBOLS[name])
    raw_instructions = binding["decoded_instructions"]
    assert isinstance(raw_instructions, list)
    instructions = [str(instruction) for instruction in raw_instructions]
    target = str(expected["target"])
    prefix = _require_exact_final_dispatch(instructions, target)
    gpr_origins, simd_origins = _register_origins(prefix)
    expected_arguments = expected["arguments"]
    assert isinstance(expected_arguments, list)
    for argument in expected_arguments:
        location = str(argument["location"])
        expected_origin = str(argument["input_origin"])
        if location.startswith("x"):
            actual_origin = gpr_origins.get(location)
        elif location.startswith("d"):
            actual_origin = simd_origins.get(location)
        else:
            raise OracleError("unsupported frozen location {}".format(location))
        if actual_origin != expected_origin:
            if location.startswith("d"):
                raise OracleError(
                    "missing SIMD placement in {}: {} originated as {}".format(
                        name, location, actual_origin
                    )
                )
            raise OracleError(
                "wrong register placement in {}: {} originated as {} not {}".format(
                    name, location, actual_origin, expected_origin
                )
            )

    result: Dict[str, object] = {"name": name}
    result.update(copy.deepcopy(expected))
    result.update(binding)
    return result


def _tool_environment(developer_dir: str) -> Dict[str, str]:
    environment = dict(os.environ)
    environment["DEVELOPER_DIR"] = developer_dir
    return environment


def _canonicalize_clang_version_output(output: str, clang: str) -> str:
    lines = output.splitlines()
    installed_indices = [
        index for index, line in enumerate(lines) if line.startswith("InstalledDir: ")
    ]
    if len(installed_indices) != 1:
        raise OracleError("Clang version output has no unique InstalledDir")
    installed_index = installed_indices[0]
    reported_directory = lines[installed_index][len("InstalledDir: "):]
    if not os.path.isabs(reported_directory):
        raise OracleError("Clang version InstalledDir is not absolute")
    lines[installed_index] = "InstalledDir: {}".format(Path(clang).parent)
    return "\n".join(lines)


def _collect_toolchain() -> Tuple[Dict[str, object], str, str, str, Dict[str, str]]:
    selected = _tool_output([XCODE_SELECT, "-p"], "read active developer dir")
    developer_dir = os.path.realpath(selected)
    if not os.path.isabs(developer_dir) or not Path(developer_dir).is_dir():
        raise OracleError("active developer directory is not canonical")
    environment = _tool_environment(developer_dir)
    xcode_version = _tool_output(
        [XCODEBUILD, "-version"], "read Xcode version", environment
    )
    clang = os.path.realpath(_tool_output(
        [XCRUN, "--sdk", "macosx", "--find", "clang"],
        "find clang",
        environment,
    ))
    objdump = _tool_output(
        [XCRUN, "--sdk", "macosx", "--find", "llvm-objdump"],
        "find llvm-objdump",
        environment,
    )
    objdump = os.path.realpath(objdump)
    sdk = os.path.realpath(_tool_output(
        [XCRUN, "--sdk", "macosx", "--show-sdk-path"],
        "find SDK",
        environment,
    ))
    sdk_version = _tool_output(
        [XCRUN, "--sdk", "macosx", "--show-sdk-version"],
        "read SDK version",
        environment,
    )
    sdk_settings = os.path.realpath(str(Path(sdk) / "SDKSettings.json"))
    clang_version = _canonicalize_clang_version_output(_run_with_stable_inputs(
        [clang, "--version"],
        "read clang version",
        [Path(clang)],
        environment,
        pin_executable=True,
    ).stdout.strip(), clang)
    decoder_version = _run_with_stable_inputs(
        [objdump, "--version"],
        "read llvm-objdump version",
        [Path(objdump)],
        environment,
        pin_executable=True,
    ).stdout.strip()
    host_architecture = platform.machine()

    if not xcode_version.startswith("Xcode 27."):
        raise OracleError("active Xcode is not Xcode 27: {}".format(xcode_version))
    if "Apple clang version 21." not in clang_version:
        raise OracleError("active clang is not Apple clang 21: {}".format(clang_version))
    if host_architecture != "arm64":
        raise OracleError("host architecture is not arm64: {}".format(host_architecture))
    if not sdk_version.startswith("27."):
        raise OracleError("active macOS SDK is not 27.x: {}".format(sdk_version))
    if not Path(sdk_settings).is_file() or not _is_within(Path(sdk_settings), Path(sdk)):
        raise OracleError("active SDK settings identity is missing")
    developer_path = Path(developer_dir)
    for name, path, require_file in [
        ("clang", Path(clang), True),
        ("decoder", Path(objdump), True),
        ("SDK", Path(sdk), False),
    ]:
        if not _is_canonical_absolute(path) or not _is_within(path, developer_path):
            raise OracleError("{} is outside the effective developer directory".format(name))
        if require_file and not path.is_file():
            raise OracleError("{} tool is missing".format(name))
        if not require_file and not path.is_dir():
            raise OracleError("{} directory is missing".format(name))
    if not decoder_version.startswith("Apple LLVM version 21."):
        raise OracleError("active decoder is not Apple LLVM 21: {}".format(decoder_version))

    toolchain: Dict[str, object] = {
        "developer_dir": developer_dir,
        "xcode_version": xcode_version.replace("\n", " / "),
        "clang": clang,
        "clang_version": clang_version.replace("\n", " / "),
        "decoder": objdump,
        "decoder_version": decoder_version.replace("\n", " / "),
        "decoder_sha256": _sha256(Path(objdump)),
        "clang_sha256": _sha256(Path(clang)),
        "sdk": sdk,
        "sdk_settings_path": sdk_settings,
        "sdk_settings_sha256": _sha256(Path(sdk_settings)),
        "sdk_version": sdk_version,
        "target": TARGET,
        "host_architecture": host_architecture,
        "object_file_description": "pending",
        "executable_file_description": "pending",
    }
    return toolchain, clang, objdump, sdk, environment


def _clang_resource_directory(clang: str) -> Path:
    resource_directory = Path(clang).parent.parent / "lib/clang/21"
    builtin_stdarg = resource_directory / "include/stdarg.h"
    if (
        not _is_canonical_absolute(resource_directory)
        or not resource_directory.is_dir()
        or not builtin_stdarg.is_file()
    ):
        raise OracleError("canonical Clang 21 resource directory is unavailable")
    return resource_directory


def _common_compile_flags(sdk: str, resource_directory: Path) -> List[str]:
    return [
        "-target", TARGET,
        "-resource-dir", str(resource_directory),
        "-isysroot", sdk,
        "-fobjc-arc",
        "-O2",
        "-g0",
        "-fno-inline-functions",
        "-Wall",
        "-Wextra",
        "-Werror",
    ]


def _compile_fixture_object(
    clang: str,
    sdk: str,
    sdk_settings: Path,
    resource_directory: Path,
    source: Path,
    output: Path,
    environment: Dict[str, str],
    context: str,
) -> None:
    _run_with_stable_inputs(
        [clang]
        + _common_compile_flags(sdk, resource_directory)
        + ["-c", str(source), "-o", str(output)],
        context,
        [Path(clang), sdk_settings, source],
        environment,
        pin_executable=True,
    )


def _link_fixture_executable(
    clang: str,
    sdk: str,
    sdk_settings: Path,
    resource_directory: Path,
    object_file: Path,
    output: Path,
    environment: Dict[str, str],
    context: str,
) -> None:
    _run_with_stable_inputs(
        [
            clang, "-target", TARGET,
            "-resource-dir", str(resource_directory),
            "-isysroot", sdk, str(object_file),
            "-framework", "Foundation", "-o", str(output),
        ],
        context,
        [Path(clang), sdk_settings, object_file],
        environment,
        pin_executable=True,
    )
    _canonicalize_linked_executable(output, environment)


def _canonicalize_linked_executable(
    executable: Path, environment: Dict[str, str]
) -> None:
    try:
        descriptor = os.open(
            str(executable), os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW
        )
    except OSError as error:
        raise OracleError("linked executable is not safely writable") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size < 32:
            raise OracleError("linked executable is not a regular Mach-O")
        header = os.pread(descriptor, 32, 0)
        magic, _, _, _, command_count, _, _, _ = struct.unpack("<8I", header)
        if magic != 0xFEEDFACF:
            raise OracleError("linked executable is not little-endian Mach-O 64")
        offset = 32
        uuid_offsets: List[int] = []
        for _ in range(command_count):
            command_header = os.pread(descriptor, 8, offset)
            if len(command_header) != 8:
                raise OracleError("linked executable load commands are truncated")
            command, command_size = struct.unpack("<2I", command_header)
            if command_size < 8 or offset + command_size > metadata.st_size:
                raise OracleError("linked executable load command is malformed")
            if command == 0x1B:
                if command_size != 24:
                    raise OracleError("linked executable LC_UUID is malformed")
                uuid_offsets.append(offset + 8)
            offset += command_size
        if len(uuid_offsets) != 1:
            raise OracleError("linked executable must contain one LC_UUID")
        os.pwrite(descriptor, CANONICAL_EXECUTABLE_UUID, uuid_offsets[0])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _run_with_stable_inputs(
        [
            CODESIGN, "--force", "--sign", "-", "--identifier",
            "com.macscope.ws15.objc-oracle", str(executable),
        ],
        "deterministically ad-hoc sign Objective-C oracle executable",
        [Path(CODESIGN)],
        environment,
    )
    _zero_code_signature_padding(executable)
    _run_with_stable_inputs(
        [CODESIGN, "--verify", str(executable)],
        "verify deterministic Objective-C oracle signature",
        [Path(CODESIGN), executable],
        environment,
    )


def _zero_code_signature_padding(executable: Path) -> None:
    descriptor = os.open(
        str(executable), os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW
    )
    try:
        metadata = os.fstat(descriptor)
        header = os.pread(descriptor, 32, 0)
        _, _, _, _, command_count, _, _, _ = struct.unpack("<8I", header)
        offset = 32
        signature_ranges: List[Tuple[int, int]] = []
        for _ in range(command_count):
            command_header = os.pread(descriptor, 16, offset)
            if len(command_header) < 8:
                raise OracleError("signed executable load commands are truncated")
            command, command_size = struct.unpack_from("<2I", command_header, 0)
            if command_size < 8 or offset + command_size > metadata.st_size:
                raise OracleError("signed executable load command is malformed")
            if command == 0x1D:
                if command_size != 16 or len(command_header) != 16:
                    raise OracleError("signed executable LC_CODE_SIGNATURE is malformed")
                _, _, data_offset, data_size = struct.unpack("<4I", command_header)
                signature_ranges.append((data_offset, data_size))
            offset += command_size
        if len(signature_ranges) != 1:
            raise OracleError("signed executable must contain one code signature")
        data_offset, data_size = signature_ranges[0]
        if data_offset + data_size > metadata.st_size or data_size < 12:
            raise OracleError("signed executable code signature range is invalid")
        superblob_header = os.pread(descriptor, 12, data_offset)
        magic, used_size, _ = struct.unpack(">3I", superblob_header)
        if magic != 0xFADE0CC0 or used_size < 12 or used_size > data_size:
            raise OracleError("signed executable superblob is malformed")
        padding_size = data_size - used_size
        if padding_size:
            os.pwrite(
                descriptor,
                b"\0" * padding_size,
                data_offset + used_size,
            )
            os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _rebuild_full_artifacts(
    source: Path, toolchain: Dict[str, object]
) -> Dict[str, Dict[str, object]]:
    clang = str(toolchain["clang"])
    sdk = str(toolchain["sdk"])
    sdk_settings = Path(str(toolchain["sdk_settings_path"]))
    resource_directory = _clang_resource_directory(clang)
    environment = _tool_environment(str(toolchain["developer_dir"]))
    with tempfile.TemporaryDirectory(prefix="ws15-objc-rebuild-") as temporary:
        root = Path(temporary).resolve()
        object_file = root / "verify-object.o"
        executable = root / "verify-executable"
        _compile_fixture_object(
            clang, sdk, sdk_settings, resource_directory,
            source, object_file, environment,
            "rebuild Objective-C oracle object",
        )
        _link_fixture_executable(
            clang, sdk, sdk_settings, resource_directory,
            object_file, executable, environment,
            "relink Objective-C oracle executable",
        )
        return {
            "fixture_object": _artifact_record(object_file),
            "executable": _artifact_record(executable),
        }


def build_oracle(artifact_directory: Path) -> Dict[str, object]:
    if not FIXTURE.is_file():
        raise OracleError("Objective-C fixture is missing: {}".format(FIXTURE))
    artifact_directory = _create_fresh_artifact_directory(artifact_directory)
    toolchain, clang, objdump, sdk, environment = _collect_toolchain()

    paths = {
        name: artifact_directory / filename
        for name, filename in ARTIFACT_FILENAMES.items()
    }
    source = paths["fixture_source"]
    object_file = paths["fixture_object"]
    executable = paths["executable"]
    object_disassembly = paths["object_disassembly"]
    executable_disassembly = paths["executable_disassembly"]
    _write_new_regular(
        source, _read_stable_bytes(FIXTURE, "repository Objective-C fixture")
    )

    sdk_settings = Path(str(toolchain["sdk_settings_path"]))
    resource_directory = _clang_resource_directory(clang)
    _compile_fixture_object(
        clang, sdk, sdk_settings, resource_directory,
        source, object_file, environment,
        "compile Objective-C oracle fixture",
    )
    _link_fixture_executable(
        clang, sdk, sdk_settings, resource_directory,
        object_file, executable, environment,
        "link Objective-C oracle fixture",
    )

    object_description = _run_with_stable_inputs(
        [FILE_TOOL, str(object_file)],
        "inspect Objective-C object",
        [object_file],
    ).stdout.strip()
    executable_description = _run_with_stable_inputs(
        [FILE_TOOL, str(executable)],
        "inspect Objective-C executable",
        [executable],
    ).stdout.strip()
    if "Mach-O 64-bit object arm64" not in object_description:
        raise OracleError("fixture object is not arm64 Mach-O: {}".format(object_description))
    if "Mach-O 64-bit executable arm64" not in executable_description:
        raise OracleError(
            "fixture executable is not arm64 Mach-O: {}".format(executable_description)
        )
    toolchain["object_file_description"] = object_description
    toolchain["executable_file_description"] = executable_description

    object_text = _decode_artifact(
        object_file, object_file.name, objdump, environment
    )
    executable_text = _decode_artifact(
        executable, executable.name, objdump, environment
    )
    _write_new_regular(object_disassembly, (object_text + "\n").encode("utf-8"))
    _write_new_regular(
        executable_disassembly, (executable_text + "\n").encode("utf-8")
    )

    runtime = _run_with_stable_inputs(
        [str(executable)],
        "run Objective-C ABI sentinels",
        [executable],
        environment,
    )
    if runtime.stdout.strip() != RUNTIME_SENTINEL:
        raise OracleError(
            "runtime sentinel mismatch: {!r}".format(runtime.stdout.strip())
        )

    cases = [
        _prove_case(name, executable_text)
        for name in [
            "canonical_zero", "canonical_one", "canonical_two",
            "normal_zero", "normal_one", "normal_two", "normal_mixed",
        ]
    ]
    artifacts: Dict[str, object] = {
        "fixture_source": _artifact_record(source),
        "fixture_object": _artifact_record(object_file),
        "executable": _artifact_record(executable),
        "object_disassembly": _artifact_record(object_disassembly),
        "executable_disassembly": _artifact_record(executable_disassembly),
    }
    _validate_artifacts(artifacts, artifact_directory)
    build_bindings = {
        "compile_inputs": [_binding_record("fixture_source", artifacts["fixture_source"])],
        "link_inputs": [_binding_record("fixture_object", artifacts["fixture_object"])],
        "object_decode_inputs": [_binding_record("fixture_object", artifacts["fixture_object"])],
        "executable_decode_inputs": [_binding_record("executable", artifacts["executable"])],
        "runtime_inputs": [_binding_record("executable", artifacts["executable"])],
    }

    payload: Dict[str, object] = {
        "schema": SCHEMA,
        "toolchain": toolchain,
        "artifacts": artifacts,
        "proofs": {key: True for key in PROOF_KEYS},
        "cases": cases,
        "policy_boundaries": {key: True for key in POLICY_KEYS},
        "build_bindings": build_bindings,
        "artifact_directory": str(artifact_directory),
    }
    validate_payload(payload, expected_artifact_directory=artifact_directory)
    return payload


def _synthetic_payload(directory: Path, sdk_version: str = "27.0") -> Dict[str, object]:
    directory = directory.resolve()
    synthetic_instructions = {
        "canonical_zero": [
            "mov x8, x0", "mov x0, x1", "mov x1, x8", "b _objc_msgSend",
        ],
        "canonical_one": [
            "mov x8, x0", "mov x0, x1", "mov x1, x2", "mov x2, x8",
            "b _objc_msgSend",
        ],
        "canonical_two": [
            "mov x8, x2", "mov x2, x0", "mov x0, x1", "mov x1, x3",
            "mov x3, x8", "b _objc_msgSend",
        ],
        "normal_zero": ["mov x0, x1", "b _objc_msgSend$zero"],
        "normal_one": [
            "mov x2, x0", "mov x0, x1", 'b "_objc_msgSend$one:"',
        ],
        "normal_two": [
            "mov x3, x0", "mov x0, x1",
            'b "_objc_msgSend$first:second:"',
        ],
        "normal_mixed": [
            "mov.16b v0, v1", "mov x2, x0", "mov x0, x1",
            'b "_objc_msgSend$mixed:object:"',
        ],
    }
    disassembly_lines = ["synthetic-executable:"]
    address = 0x1000
    for name in CASE_ORDER:
        disassembly_lines.append("{}:".format(FUNCTION_SYMBOLS[name]))
        for instruction in synthetic_instructions[name]:
            disassembly_lines.append(
                "{:x}:\t00 00 00 00\t{}".format(address, instruction)
            )
            address += 4
    executable_disassembly_text = "\n".join(disassembly_lines) + "\n"
    object_disassembly_text = (
        "objc_call_arguments.o:\n(__TEXT,__text) section\n"
    )

    artifact_directory = directory / "artifacts"
    artifact_directory.mkdir()
    artifact_paths = {
        name: artifact_directory / ARTIFACT_FILENAMES[name]
        for name in ARTIFACT_KEYS
    }
    _write_new_regular(
        artifact_paths["fixture_source"],
        _read_stable_bytes(FIXTURE, "synthetic fixture source"),
    )
    _write_new_regular(artifact_paths["fixture_object"], b"synthetic-object-v1\n")
    _write_new_regular(artifact_paths["executable"], b"synthetic-executable-v1\n")
    _write_new_regular(
        artifact_paths["object_disassembly"],
        object_disassembly_text.encode("utf-8"),
    )
    _write_new_regular(
        artifact_paths["executable_disassembly"],
        executable_disassembly_text.encode("utf-8"),
    )
    artifacts = {
        name: _artifact_record(path) for name, path in artifact_paths.items()
    }
    cases = [_prove_case(name, executable_disassembly_text) for name in CASE_ORDER]
    developer_dir = directory / "Xcode.app/Contents/Developer"
    tool_bin = developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
    # Hermetic self-test data, not the production SDK selector. Production
    # _collect_toolchain resolves the selected developer's SDK through xcrun.
    sdk = developer_dir / "Platforms/MacOSX.platform/Developer/SDKs" / ("MacOSX" + sdk_version + ".sdk")
    tool_bin.mkdir(parents=True)
    sdk.mkdir(parents=True)
    clang = tool_bin / "clang"
    decoder = tool_bin / "llvm-objdump"
    sdk_settings = sdk / "SDKSettings.json"
    _write_new_regular(clang, b"synthetic clang\n")
    _write_new_regular(decoder, b"synthetic decoder\n")
    _write_new_regular(sdk_settings, json.dumps({"Version": sdk_version, "Build": "test"}).encode("utf-8") + b"\n")
    build_bindings = {
        "compile_inputs": [_binding_record("fixture_source", artifacts["fixture_source"])],
        "link_inputs": [_binding_record("fixture_object", artifacts["fixture_object"])],
        "object_decode_inputs": [_binding_record("fixture_object", artifacts["fixture_object"])],
        "executable_decode_inputs": [_binding_record("executable", artifacts["executable"])],
        "runtime_inputs": [_binding_record("executable", artifacts["executable"])],
    }
    return {
        "schema": SCHEMA,
        "toolchain": {
            "developer_dir": str(developer_dir),
            "xcode_version": "Xcode {} / Build version test".format(sdk_version),
            "clang": str(clang),
            "clang_version": "Apple clang version 21.0.0",
            "clang_sha256": _sha256(clang),
            "decoder": str(decoder),
            "decoder_version": "Apple LLVM version 21.0.0",
            "decoder_sha256": _sha256(decoder),
            "sdk": str(sdk),
            "sdk_settings_path": str(sdk_settings),
            "sdk_settings_sha256": _sha256(sdk_settings),
            "sdk_version": sdk_version,
            "target": TARGET,
            "host_architecture": "arm64",
            "object_file_description": "Mach-O 64-bit object arm64",
            "executable_file_description": "Mach-O 64-bit executable arm64",
        },
        "artifacts": artifacts,
        "proofs": {key: True for key in PROOF_KEYS},
        "cases": cases,
        "policy_boundaries": {key: True for key in POLICY_KEYS},
        "build_bindings": build_bindings,
        "artifact_directory": str(artifact_directory),
    }


class OracleContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ws15-objc-oracle-self-test-")
        self.addCleanup(self.temporary.cleanup)
        self.payload = _synthetic_payload(Path(self.temporary.name))
        self.expected_artifact_directory = Path(
            str(self.payload["artifact_directory"])
        )
        artifacts = self.payload["artifacts"]
        assert isinstance(artifacts, dict)
        object_record = artifacts["fixture_object"]
        executable_record = artifacts["executable"]
        object_disassembly = artifacts["object_disassembly"]
        executable_disassembly = artifacts["executable_disassembly"]
        assert isinstance(object_record, dict)
        assert isinstance(executable_record, dict)
        assert isinstance(object_disassembly, dict)
        assert isinstance(executable_disassembly, dict)
        self.synthetic_decodes = {
            (ARTIFACT_FILENAMES["fixture_object"], str(object_record["sha256"])):
                Path(str(object_disassembly["path"])).read_text(encoding="utf-8").rstrip("\n"),
            (ARTIFACT_FILENAMES["executable"], str(executable_record["sha256"])):
                Path(str(executable_disassembly["path"])).read_text(encoding="utf-8").rstrip("\n"),
        }
        self.synthetic_decode_by_name = {
            ARTIFACT_FILENAMES["fixture_object"]:
                Path(str(object_disassembly["path"])).read_text(encoding="utf-8").rstrip("\n"),
            ARTIFACT_FILENAMES["executable"]:
                Path(str(executable_disassembly["path"])).read_text(encoding="utf-8").rstrip("\n"),
        }
        self.synthetic_executable_sha256 = str(executable_record["sha256"])
        self.synthetic_rebuild = {
            "fixture_object": dict(object_record),
            "executable": dict(executable_record),
        }

    def _decode_synthetic(self, path: Path, artifact_name: str) -> str:
        digest = _sha256(path)
        return self.synthetic_decodes.get(
            (artifact_name, digest),
            "{}:\nmutated artifact bytes".format(artifact_name),
        )

    def _validate(self) -> None:
        validate_payload(
            self.payload,
            decode_callback=self._decode_synthetic,
            runtime_callback=lambda path: (
                RUNTIME_SENTINEL
                if _sha256(path) == self.synthetic_executable_sha256
                else "mutated-runtime"
            ),
            rebuild_callback=lambda _path: copy.deepcopy(self.synthetic_rebuild),
            expected_artifact_directory=self.expected_artifact_directory,
        )

    def _validate_with_invariant_decode_and_runtime(self) -> None:
        validate_payload(
            self.payload,
            decode_callback=lambda _path, name: self.synthetic_decode_by_name[name],
            runtime_callback=lambda _path: RUNTIME_SENTINEL,
            rebuild_callback=lambda _path: copy.deepcopy(self.synthetic_rebuild),
            expected_artifact_directory=self.expected_artifact_directory,
        )

    def _mutate_same_size_and_refresh_claim(self, artifact_name: str) -> None:
        artifacts = self.payload["artifacts"]
        bindings = self.payload["build_bindings"]
        assert isinstance(artifacts, dict)
        assert isinstance(bindings, dict)
        record = artifacts[artifact_name]
        assert isinstance(record, dict)
        path = Path(str(record["path"]))
        data = bytearray(_read_stable_bytes(path, "mutation input"))
        data[0] ^= 0x01
        descriptor = os.open(str(path), os.O_WRONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            os.pwrite(descriptor, bytes(data), 0)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        record.update(_artifact_record(path))
        for records in bindings.values():
            assert isinstance(records, list)
            for binding in records:
                assert isinstance(binding, dict)
                if binding["artifact"] == artifact_name:
                    binding.update(_binding_record(artifact_name, record))

    def _case(self, name: str) -> Dict[str, object]:
        cases = self.payload["cases"]
        assert isinstance(cases, list)
        return next(case for case in cases if case["name"] == name)

    def _disassembly(self, name: str, instructions: Sequence[str]) -> str:
        lines = ["{}:".format(FUNCTION_SYMBOLS[name])]
        for index, instruction in enumerate(instructions):
            lines.append(
                "{:x}:\t00 00 00 00\t{}".format(0x1000 + index * 4, instruction)
            )
        return "\n".join(lines)

    def test_valid_closed_payload_passes(self) -> None:
        self._validate()

    def test_disassembly_hash_input_is_path_independent(self) -> None:
        raw = "/private/tmp/random/fixture:\n(__TEXT,__text) section\n"
        self.assertEqual(
            _normalized_disassembly(raw, "fixture"),
            "fixture:\n(__TEXT,__text) section",
        )

    def test_lookalike_dispatch_target_is_rejected(self) -> None:
        disassembly = self._disassembly(
            "normal_one",
            [
                "mov x2, x0",
                "mov x0, x1",
                'b "_objc_msgSend$one:lookalike"',
            ],
        )
        with self.assertRaisesRegex(OracleError, "exact final dispatch target"):
            _prove_case("normal_one", disassembly)

    def test_non_move_overwrite_is_rejected(self) -> None:
        disassembly = self._disassembly(
            "normal_one",
            [
                "mov x2, x0",
                "add x2, x2, #0x1",
                "mov x0, x1",
                'b "_objc_msgSend$one:"',
            ],
        )
        with self.assertRaisesRegex(OracleError, "unsupported instruction"):
            _prove_case("normal_one", disassembly)

    def test_non_move_simd_overwrite_is_rejected(self) -> None:
        disassembly = self._disassembly(
            "normal_mixed",
            [
                "mov.16b v0, v1",
                "fadd d0, d0, d0",
                "mov x2, x0",
                "mov x0, x1",
                'b "_objc_msgSend$mixed:object:"',
            ],
        )
        with self.assertRaisesRegex(OracleError, "unsupported instruction"):
            _prove_case("normal_mixed", disassembly)

    def test_post_dispatch_instruction_is_rejected(self) -> None:
        disassembly = self._disassembly(
            "normal_one",
            [
                "mov x2, x0",
                "mov x0, x1",
                'b "_objc_msgSend$one:"',
                "mov x2, x3",
            ],
        )
        with self.assertRaisesRegex(OracleError, "exact final dispatch target"):
            _prove_case("normal_one", disassembly)

    def test_helper_call_before_dispatch_is_rejected(self) -> None:
        disassembly = self._disassembly(
            "normal_one",
            [
                "mov x2, x0",
                "bl _helper",
                "mov x0, x1",
                'b "_objc_msgSend$one:"',
            ],
        )
        with self.assertRaisesRegex(OracleError, "non-straight-line control flow"):
            _prove_case("normal_one", disassembly)

    def test_conditional_skip_before_dispatch_is_rejected(self) -> None:
        disassembly = self._disassembly(
            "normal_one",
            [
                "mov x2, x0",
                "cbz x8, 0x1010",
                "mov x0, x1",
                'b "_objc_msgSend$one:"',
            ],
        )
        with self.assertRaisesRegex(OracleError, "non-straight-line control flow"):
            _prove_case("normal_one", disassembly)

    def test_post_index_base_writeback_is_rejected(self) -> None:
        disassembly = self._disassembly(
            "normal_one",
            [
                "mov x2, x0",
                "ldr x8, [x4], #0x8",
                "mov x0, x1",
                'b "_objc_msgSend$one:"',
            ],
        )
        with self.assertRaisesRegex(OracleError, "unsupported instruction"):
            _prove_case("normal_one", disassembly)

    def test_composite_simd_lane_write_is_rejected(self) -> None:
        disassembly = self._disassembly(
            "normal_mixed",
            [
                "mov.16b v0, v1",
                "ins v0.d[1], v2.d[0]",
                "mov x2, x0",
                "mov x0, x1",
                'b "_objc_msgSend$mixed:object:"',
            ],
        )
        with self.assertRaisesRegex(OracleError, "unsupported instruction"):
            _prove_case("normal_mixed", disassembly)

    def test_missing_proof_is_rejected(self) -> None:
        proofs = self.payload["proofs"]
        assert isinstance(proofs, dict)
        proofs["mixed_requires_abstention"] = False
        with self.assertRaisesRegex(OracleError, "missing proof"):
            self._validate()

    def test_wrong_register_is_rejected(self) -> None:
        arguments = self._case("normal_one")["arguments"]
        assert isinstance(arguments, list)
        arguments[1]["location"] = "x3"
        with self.assertRaisesRegex(OracleError, "wrong register"):
            self._validate()

    def test_missing_simd_is_rejected(self) -> None:
        arguments = self._case("normal_mixed")["arguments"]
        assert isinstance(arguments, list)
        del arguments[1]
        with self.assertRaisesRegex(OracleError, "missing SIMD"):
            self._validate()

    def test_stale_artifact_hash_is_rejected(self) -> None:
        artifacts = self.payload["artifacts"]
        assert isinstance(artifacts, dict)
        fixture = artifacts["fixture_source"]
        assert isinstance(fixture, dict)
        fixture["sha256"] = "0" * 64
        with self.assertRaisesRegex(OracleError, "stale artifact hash"):
            self._validate()

    def test_case_instructions_must_rebind_to_hashed_disassembly(self) -> None:
        self._case("normal_one")["decoded_instructions"][0] = "mov x2, x3"
        with self.assertRaisesRegex(OracleError, "bound to executable disassembly"):
            self._validate()

    def test_updated_disassembly_hash_cannot_bypass_case_binding(self) -> None:
        artifacts = self.payload["artifacts"]
        assert isinstance(artifacts, dict)
        executable_disassembly = artifacts["executable_disassembly"]
        assert isinstance(executable_disassembly, dict)
        path = Path(str(executable_disassembly["path"]))
        text = path.read_text(encoding="utf-8").replace(
            "mov x2, x0", "mov x2, x3", 1
        )
        path.write_text(text, encoding="utf-8")
        executable_disassembly.update(_artifact_record(path))
        with self.assertRaisesRegex(OracleError, "rebind to stored disassembly"):
            self._validate()

    def test_same_size_source_mutation_with_refreshed_claim_is_rejected(self) -> None:
        self._mutate_same_size_and_refresh_claim("fixture_source")
        with self.assertRaisesRegex(OracleError, "repository fixture"):
            self._validate()

    def test_same_size_object_mutation_with_refreshed_claim_is_rejected(self) -> None:
        self._mutate_same_size_and_refresh_claim("fixture_object")
        with self.assertRaisesRegex(OracleError, "rebuild object mismatch"):
            self._validate()

    def test_same_size_executable_mutation_with_refreshed_claim_is_rejected(self) -> None:
        self._mutate_same_size_and_refresh_claim("executable")
        with self.assertRaisesRegex(OracleError, "rebuild executable mismatch"):
            self._validate()

    def test_object_metadata_mutation_cannot_hide_behind_same_decode(self) -> None:
        self._mutate_same_size_and_refresh_claim("fixture_object")
        with self.assertRaisesRegex(OracleError, "rebuild object mismatch"):
            self._validate_with_invariant_decode_and_runtime()

    def test_executable_metadata_mutation_cannot_hide_behind_same_decode_runtime(self) -> None:
        self._mutate_same_size_and_refresh_claim("executable")
        with self.assertRaisesRegex(OracleError, "rebuild executable mismatch"):
            self._validate_with_invariant_decode_and_runtime()

    def test_artifact_path_escape_with_refreshed_claim_is_rejected(self) -> None:
        artifacts = self.payload["artifacts"]
        assert isinstance(artifacts, dict)
        record = artifacts["executable"]
        assert isinstance(record, dict)
        original = Path(str(record["path"]))
        escape_directory = Path(self.temporary.name).resolve() / "escape"
        escape_directory.mkdir()
        escaped = escape_directory / ARTIFACT_FILENAMES["executable"]
        _write_new_regular(escaped, _read_stable_bytes(original, "escape source"))
        record.update(_artifact_record(escaped))
        with self.assertRaisesRegex(OracleError, "escaped the artifact directory"):
            self._validate()

    def test_existing_artifact_directory_is_rejected(self) -> None:
        existing = Path(self.temporary.name).resolve() / "already-exists"
        existing.mkdir()
        with self.assertRaisesRegex(OracleError, "fresh and absent"):
            _create_fresh_artifact_directory(existing)

    def test_artifact_directory_extra_entry_is_rejected(self) -> None:
        extra = self.expected_artifact_directory / "unexpected.txt"
        _write_new_regular(extra, b"unexpected\n")
        with self.assertRaisesRegex(OracleError, "closed entry set"):
            self._validate()

    def test_claimed_artifact_directory_mismatch_is_rejected(self) -> None:
        mismatched = Path(self.temporary.name).resolve() / "different-artifacts"
        mismatched.mkdir()
        self.payload["artifact_directory"] = str(mismatched)
        with self.assertRaisesRegex(OracleError, "does not match requested"):
            self._validate()

    def test_artifact_hardlink_alias_is_rejected(self) -> None:
        artifacts = self.payload["artifacts"]
        assert isinstance(artifacts, dict)
        source = artifacts["fixture_source"]
        object_record = artifacts["fixture_object"]
        assert isinstance(source, dict)
        assert isinstance(object_record, dict)
        object_path = Path(str(object_record["path"]))
        object_path.unlink()
        os.link(str(source["path"]), str(object_path))
        object_record.update(_artifact_record(object_path))
        with self.assertRaisesRegex(OracleError, "aliases another artifact"):
            self._validate()

    def test_decoder_outside_effective_developer_dir_is_rejected(self) -> None:
        external = Path(self.temporary.name).resolve() / "external-decoder"
        _write_new_regular(external, b"decoder\n")
        toolchain = self.payload["toolchain"]
        assert isinstance(toolchain, dict)
        toolchain["decoder"] = str(external)
        with self.assertRaisesRegex(OracleError, "decoder escaped developer_dir"):
            self._validate()

    def test_tool_selectors_are_frozen_absolute_system_paths(self) -> None:
        self.assertEqual(
            [XCODE_SELECT, XCODEBUILD, XCRUN, FILE_TOOL, CODESIGN],
            [
                "/usr/bin/xcode-select", "/usr/bin/xcodebuild",
                "/usr/bin/xcrun", "/usr/bin/file", "/usr/bin/codesign",
            ],
        )

    def test_clang_and_sdk_content_identities_are_closed(self) -> None:
        toolchain = self.payload["toolchain"]
        assert isinstance(toolchain, dict)
        self.assertIn("clang_sha256", toolchain)
        self.assertIn("sdk_settings_path", toolchain)
        self.assertIn("sdk_settings_sha256", toolchain)

    def test_production_selection_uses_current_minor_sdk_without_27_0_directory(self) -> None:
        root = Path(self.temporary.name).resolve() / "selected-sdk"
        root.mkdir()
        payload = _synthetic_payload(root, sdk_version="27.2")
        tools = payload["toolchain"]
        assert isinstance(tools, dict)
        outputs = {
            (XCODE_SELECT, "-p"): tools["developer_dir"],
            (XCODEBUILD, "-version"): "Xcode 27.2\nBuild version test",
            (XCRUN, "--sdk", "macosx", "--find", "clang"): tools["clang"],
            (XCRUN, "--sdk", "macosx", "--find", "llvm-objdump"): tools["decoder"],
            (XCRUN, "--sdk", "macosx", "--show-sdk-path"): tools["sdk"],
            (XCRUN, "--sdk", "macosx", "--show-sdk-version"): "27.2",
        }

        def tool_output(command, label, environment=None):
            if command[0] != XCODE_SELECT:
                self.assertEqual(environment["DEVELOPER_DIR"], tools["developer_dir"])
            return outputs[tuple(command)]

        def version(command, label, inputs, environment, **kwargs):
            self.assertEqual(environment["DEVELOPER_DIR"], tools["developer_dir"])
            text = ("Apple clang version 21.0.0\nInstalledDir: " + str(Path(tools["clang"]).parent)
                    if command[0] == tools["clang"] else "Apple LLVM version 21.0.0")
            return subprocess.CompletedProcess(command, 0, stdout=text, stderr="")

        with mock.patch(__name__ + "._tool_output", side_effect=tool_output), \
                mock.patch(__name__ + "._run_with_stable_inputs", side_effect=version), \
                mock.patch(__name__ + ".platform.machine", return_value="arm64"):
            collected, _, _, sdk, _ = _collect_toolchain()
            self.assertEqual(sdk, tools["sdk"])
            self.assertEqual(collected["sdk_version"], "27.2")
            self.assertEqual(collected["sdk_settings_sha256"], tools["sdk_settings_sha256"])
            self.assertFalse((Path(sdk).parent / "MacOSX27.0.sdk").exists())
            outputs[(XCRUN, "--sdk", "macosx", "--show-sdk-version")] = "26.4"
            with self.assertRaisesRegex(OracleError, "SDK is not 27.x"):
                _collect_toolchain()
            outputs[(XCRUN, "--sdk", "macosx", "--show-sdk-version")] = "27.2"
            foreign = root / "foreign-sdk"
            foreign.mkdir()
            _write_new_regular(foreign / "SDKSettings.json", b"{}\n")
            outputs[(XCRUN, "--sdk", "macosx", "--show-sdk-path")] = str(foreign)
            with self.assertRaisesRegex(OracleError, "SDK is outside the effective developer directory"):
                _collect_toolchain()

    def test_tool_execution_pins_snapshotted_vnode_across_transient_path_swap(
        self,
    ) -> None:
        root = Path(self.temporary.name).resolve() / "tool-execution-swap"
        root.mkdir()
        trusted = root / "clang"
        alternate = root / "alternate"
        parked = root / "parked"
        _write_new_regular(
            trusted,
            b"#!/bin/sh\nprintf 'pinned-vnode\\n'\n",
        )
        _write_new_regular(
            alternate,
            b"#!/bin/sh\nprintf 'alternate-bytes\\n'\n",
        )
        trusted.chmod(0o700)
        alternate.chmod(0o700)
        trusted_identity = os.lstat(str(trusted))
        production_run = _run

        def run_after_transient_swap(*args: object, **kwargs: object) -> object:
            os.rename(str(trusted), str(parked))
            os.rename(str(alternate), str(trusted))
            try:
                return production_run(*args, **kwargs)
            finally:
                os.rename(str(trusted), str(alternate))
                os.rename(str(parked), str(trusted))

        with mock.patch.object(
            sys.modules[__name__], "_run", side_effect=run_after_transient_swap
        ):
            try:
                result = _run_with_stable_inputs(
                    [str(trusted)],
                    "exercise descriptor-pinned tool",
                    [trusted],
                    pin_executable=True,
                )
            except OracleError as error:
                self.fail(
                    "transient path replacement executed alternate bytes: {}".format(
                        error
                    )
                )

        restored_identity = os.lstat(str(trusted))
        self.assertEqual(result.stdout.strip(), "pinned-vnode")
        self.assertEqual(restored_identity.st_dev, trusted_identity.st_dev)
        self.assertEqual(restored_identity.st_ino, trusted_identity.st_ino)

    def test_tool_execution_uses_descriptor_copy_when_hardlink_is_denied(
        self,
    ) -> None:
        trusted = Path(self.temporary.name).resolve() / "sandboxed-clang"
        _write_new_regular(
            trusted,
            b"#!/bin/sh\nprintf 'descriptor-copy\\n'\n",
        )
        trusted.chmod(0o700)
        with mock.patch.object(
            os,
            "link",
            side_effect=PermissionError(1, "sandbox denied hard link"),
        ):
            try:
                result = _run_with_stable_inputs(
                    [str(trusted)],
                    "exercise descriptor-copy fallback",
                    [trusted],
                    pin_executable=True,
                )
            except OracleError as error:
                self.fail("descriptor-copy fallback was unavailable: {}".format(error))
        self.assertEqual(result.stdout.strip(), "descriptor-copy")

    def test_clang_content_identity_drift_is_rejected(self) -> None:
        toolchain = self.payload["toolchain"]
        assert isinstance(toolchain, dict)
        toolchain["clang_sha256"] = "0" * 64
        with self.assertRaisesRegex(OracleError, "clang identity mismatch"):
            self._validate()

    def test_sdk_content_identity_drift_is_rejected(self) -> None:
        toolchain = self.payload["toolchain"]
        assert isinstance(toolchain, dict)
        toolchain["sdk_settings_sha256"] = "0" * 64
        with self.assertRaisesRegex(OracleError, "SDK settings identity mismatch"):
            self._validate()

    def test_decoder_version_mismatch_is_rejected(self) -> None:
        toolchain = self.payload["toolchain"]
        assert isinstance(toolchain, dict)
        toolchain["decoder_version"] = "Apple LLVM version 22.0.0"
        with self.assertRaisesRegex(OracleError, "decoder version"):
            self._validate()

    def test_developer_dir_mismatch_is_rejected(self) -> None:
        toolchain = self.payload["toolchain"]
        assert isinstance(toolchain, dict)
        mismatched = Path(self.temporary.name).resolve() / "Other.app/Contents/Developer"
        mismatched.mkdir(parents=True)
        toolchain["developer_dir"] = str(mismatched)
        with self.assertRaisesRegex(OracleError, "clang escaped developer_dir"):
            self._validate()

    def test_case_order_is_closed(self) -> None:
        cases = self.payload["cases"]
        assert isinstance(cases, list)
        cases[0], cases[1] = cases[1], cases[0]
        with self.assertRaisesRegex(OracleError, "case order mismatch"):
            self._validate()

    def test_unsupported_schema_is_rejected(self) -> None:
        self.payload["schema"] = "objc-call-argument-oracle-v0"
        with self.assertRaisesRegex(OracleError, "unsupported schema"):
            self._validate()

    def test_malformed_selector_is_rejected(self) -> None:
        self._case("normal_one")["selector"] = "one"
        with self.assertRaisesRegex(OracleError, "malformed selector"):
            self._validate()

    def test_classification_separation_is_enforced(self) -> None:
        self._case("normal_one")["classification"] = "canonical-objc-msgsend"
        with self.assertRaisesRegex(OracleError, "classification separation"):
            self._validate()

    def test_selector_arity_is_not_bank_proof(self) -> None:
        boundaries = self.payload["policy_boundaries"]
        assert isinstance(boundaries, dict)
        boundaries["selector_arity_does_not_certify_bank"] = False
        with self.assertRaisesRegex(OracleError, "selector arity is not bank proof"):
            self._validate()

    def test_fixture_placement_is_not_runtime_method_abi(self) -> None:
        boundaries = self.payload["policy_boundaries"]
        assert isinstance(boundaries, dict)
        boundaries["fixture_placement_does_not_authorize_runtime_recovery"] = False
        with self.assertRaisesRegex(
            OracleError, "fixture placement is not runtime method ABI"
        ):
            self._validate()

    def test_normal_stub_cases_require_runtime_abstention(self) -> None:
        for name in ["normal_zero", "normal_one", "normal_two", "normal_mixed"]:
            with self.subTest(name=name):
                self.assertIs(self._case(name)["must_abstain"], True)

    def test_canonical_and_stub_abstention_policy_is_exact(self) -> None:
        self.assertEqual(
            [self._case(name)["must_abstain"] for name in CASE_ORDER],
            [False, True, True, True, True, True, True],
        )
        self._case("canonical_one")["must_abstain"] = False
        with self.assertRaisesRegex(OracleError, "must_abstain"):
            self._validate()


SELF_TEST_GATES = [
    "missing proof",
    "wrong register",
    "missing SIMD",
    "stale artifact hash",
    "unsupported schema",
    "malformed selector",
    "classification separation",
    "selector arity is not bank proof",
    "lookalike target",
    "non-move overwrite",
    "post-dispatch prefix",
    "helper call",
    "conditional skip",
    "base writeback",
    "SIMD lane write",
    "executable slice binding",
    "case order",
    "fixture placement is not runtime method ABI",
    "normal stub abstention",
    "exact abstention policy",
    "same-size source mutation",
    "same-size object mutation",
    "same-size executable mutation",
    "artifact path escape",
    "fresh artifact directory",
    "claimed artifact directory",
    "artifact alias",
    "decoder provenance",
    "developer dir mismatch",
    "absolute tool selectors",
    "full-byte rebuild proof",
    "closed artifact entries",
    "clang content identity",
    "SDK content identity",
    "selected minor SDK provenance",
    "descriptor-pinned tool execution",
    "sandbox descriptor-copy execution",
]


def _run_self_tests() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(OracleContractTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        return 1
    for gate in SELF_TEST_GATES:
        print("guard: {}".format(gate))
    print("objc-call-argument-oracle self-test: {} tests passed".format(result.testsRun))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--isolated-process-group",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--process-test-mode",
        choices=["hang", "inner-timeout", "residual"],
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--process-test-ready-file",
        type=Path,
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--artifact-dir", type=Path)
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args()

    if (
        arguments.process_test_ready_file is not None
        and arguments.process_test_mode is None
    ):
        parser.error("--process-test-ready-file requires --process-test-mode hang")

    if arguments.isolated_process_group:
        try:
            _enter_isolated_process_group()
        except OracleError as error:
            print("objc-call-argument-oracle: {}".format(error), file=sys.stderr)
            return 1

    if arguments.process_test_mode is not None:
        if not arguments.isolated_process_group:
            parser.error("--process-test-mode requires --isolated-process-group")
        if arguments.self_test or arguments.artifact_dir is not None or arguments.json:
            parser.error("--process-test-mode cannot be combined with oracle modes")
        if (
            arguments.process_test_ready_file is not None
            and arguments.process_test_mode != "hang"
        ):
            parser.error("--process-test-ready-file is supported only for hang mode")
        if arguments.process_test_mode == "hang":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            if arguments.process_test_ready_file is not None:
                flags = (
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | os.O_CLOEXEC
                    | os.O_NOFOLLOW
                )
                descriptor = os.open(arguments.process_test_ready_file, flags, 0o600)
                try:
                    os.write(descriptor, b"ready\n")
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
            while True:
                time.sleep(60)
        if arguments.process_test_mode == "inner-timeout":
            _run(
                [sys.executable, "-c", "import time; time.sleep(300)"],
                "inner timeout probe",
                timeout_seconds=0.05,
            )
            return 99
        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import signal,time; "
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                    "print('ready', flush=True); time.sleep(300)"
                ),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=False,
        )
        if child.stdout is None or child.stdout.readline().strip() != "ready":
            child.kill()
            child.wait()
            return 1
        return 0

    if arguments.self_test:
        if arguments.artifact_dir is not None or arguments.json:
            parser.error("--self-test cannot be combined with live-oracle arguments")
        return _run_self_tests()
    if arguments.artifact_dir is None:
        parser.error("--artifact-dir is required for a live oracle run")

    try:
        payload = build_oracle(arguments.artifact_dir)
    except OracleError as error:
        print("objc-call-argument-oracle: {}".format(error), file=sys.stderr)
        return 1
    if arguments.json:
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print(
            "objc-call-argument-oracle: {} cases proven ({})".format(
                len(payload["cases"]), payload["schema"]
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
