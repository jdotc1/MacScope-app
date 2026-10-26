#!/usr/bin/env python3
"""Own staging and one native golden execution beneath a fresh campaign leaf."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


SCRIPT_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_ROOT.parents[1]


def _load(name):
    spec = importlib.util.spec_from_file_location("macscope_" + name, SCRIPT_ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_STAGE = _load("stage_xcode_resources")
_IDENTITY = _load("native_decompiler_source_identity")
_EVIDENCE = _load("native_golden_evidence")
RESOURCE_SUBPATH = Path("NativeGate/Contents/Resources")


class GoldenProducerError(RuntimeError):
    """The owner cannot establish an unchanged physical golden outcome."""


def _directory(path, label):
    path = Path(path)
    if (not path.is_absolute() or ".." in path.parts or path.resolve(strict=True) != path
            or any(c in str(path) for c in ("\r", "\n", "\0"))):
        raise GoldenProducerError(f"{label} must be an absolute canonical ordinary directory")
    return _STAGE._ordinary_directory(path, label)


def _file(path, label, maximum=1024 * 1024 * 1024):
    path = Path(path)
    _directory(path.parent, label + " parent")
    before = _STAGE._stable_file_fields(path.lstat())
    payload = _STAGE._read_stable_bytes(path, maximum, label)
    if _STAGE._stable_file_fields(path.lstat()) != before:
        raise GoldenProducerError(f"{label} changed across its bounded read")
    return before, hashlib.sha256(payload).hexdigest()


def _tool_file(path, target_name):
    """Allow only Xcode's declared same-directory compiler aliases."""
    _directory(path.parent, "selected compiler parent")
    before = path.lstat()
    if not stat.S_ISLNK(before.st_mode):
        return _file(path, "selected compiler")
    if before.st_nlink != 1 or os.readlink(path) != target_name:
        raise GoldenProducerError("selected compiler has an undeclared alias")
    executable = _file(path.parent / target_name, "selected compiler executable")
    if (_STAGE._stable_file_fields(path.lstat()) != _STAGE._stable_file_fields(before)
            or os.readlink(path) != target_name):
        raise GoldenProducerError("selected compiler alias changed during observation")
    return _STAGE._stable_file_fields(before), target_name, executable


def _revalidate_directories(anchors):
    for directory, descriptor, identity in anchors:
        _STAGE._STAGER._revalidate_directory_anchor(directory, descriptor, identity, "golden owner")


def _anchor_ancestors(paths, anchors):
    directories = set()
    for path in paths:
        directories.update((path, *path.parents))
    for directory in sorted(directories, key=lambda path: (len(path.parts), str(path))):
        canonical, descriptor, metadata = _STAGE._STAGER._open_anchored_directory(directory, "golden input ancestor")
        if canonical != directory:
            os.close(descriptor)
            raise GoldenProducerError("golden input ancestor changed its canonical path")
        anchors.append((directory, descriptor, (metadata.st_dev, metadata.st_ino)))
    _revalidate_directories(anchors)


def _reserve_directory(parent_anchor, name, anchors):
    parent, parent_fd, _identity = parent_anchor
    _revalidate_directories(anchors)
    os.mkdir(name, mode=0o700, dir_fd=parent_fd)
    entry = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
    try:
        opened = os.fstat(descriptor)
        after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        identity = entry.st_dev, entry.st_ino
        if (not stat.S_ISDIR(entry.st_mode) or stat.S_IMODE(entry.st_mode) != 0o700
                or (opened.st_dev, opened.st_ino) != identity
                or (after.st_dev, after.st_ino) != identity or os.listdir(descriptor)):
            raise GoldenProducerError("new golden directory changed before ownership anchoring")
        anchor = (parent / name, descriptor, identity)
        _revalidate_directories([*anchors, anchor])
        anchors.append(anchor)
        return anchor
    except Exception:
        os.close(descriptor)
        raise


def _result_snapshot(result):
    _directory(result.parent, "golden result parent")
    before = _STAGE._stable_file_fields(result.lstat())
    payload = _STAGE._read_stable_bytes(result, 64 * 1024, "golden result")
    if _STAGE._stable_file_fields(result.lstat()) != before:
        raise GoldenProducerError("golden result changed across its bounded read")
    return before, payload


def _require_layout(arguments):
    source = _directory(arguments.source_materialization_root, "source materialization")
    normal = _directory(arguments.native_archive_root, "native archive root")
    developer = _directory(arguments.developer_dir, "developer directory")
    sdk = _directory(arguments.sdk_root, "SDK root")
    work = arguments.work_root
    if (not work.is_absolute() or ".." in work.parts or work.name != "golden"
            or any(c in str(work) for c in ("\r", "\n", "\0"))):
        raise GoldenProducerError("work root must be the absent canonical golden leaf")
    parent = _directory(work.parent, "native-work parent")
    if parent.name != "native-work" or normal != parent / "normal":
        raise GoldenProducerError("normal and golden must be fixed siblings under native-work")
    if os.path.lexists(work):
        raise GoldenProducerError("golden work root must be absent and exclusively owned")
    if source == parent or source.is_relative_to(parent) or parent.is_relative_to(source):
        raise GoldenProducerError("source materialization and campaign work roots must be separate")
    if not sdk.is_relative_to(developer) or not re.fullmatch(r"macosx27(?:\.\d+){1,2}", arguments.sdk_name):
        raise GoldenProducerError("SDK must belong to selected Xcode 27 and have an explicit name")
    if work.is_relative_to(REPOSITORY_ROOT):
        raise GoldenProducerError("golden outputs must be outside the repository")
    return source, normal, developer, sdk, parent


def _tool_identity(developer, sdk, sdk_name, command_runner):
    env = {**os.environ, "DEVELOPER_DIR": str(developer)}
    xcode = developer / "usr/bin/xcodebuild"
    swift = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    def output(command):
        result = command_runner([str(part) for part in command], capture_output=True, text=True, env=env)
        if result.returncode != 0:
            raise GoldenProducerError("selected toolchain identity command failed")
        return result.stdout.strip()
    xcode_match = re.fullmatch(r"Xcode (27(?:\.\d+){1,2})\nBuild version ([A-Za-z0-9.]+)", output([xcode, "-version"]))
    swift_output = output([swift, "--version"])
    swift_match = re.search(r"Apple Swift version (6(?:\.\d+){1,2})\b", swift_output)
    target_match = re.search(r"(?m)^Target: (arm64-apple-macosx27(?:\.\d+){1,2})$", swift_output)
    version = output([xcode, "-version", "-sdk", sdk, "SDKVersion"])
    build = output([xcode, "-version", "-sdk", sdk, "ProductBuildVersion"])
    if (not xcode_match or not swift_match or not target_match or not build
            or not re.fullmatch(r"27(?:\.\d+){1,2}", version) or sdk_name != "macosx" + version):
        raise GoldenProducerError("selected Xcode/Swift/SDK identity is incomplete or mismatched")
    return {"xcodeVersion": xcode_match[1], "xcodeBuild": xcode_match[2],
            "swiftCompilerVersion": swift_match[1], "swiftTargetTriple": target_match[1],
            "sdkName": sdk_name, "sdkVersion": version, "sdkBuild": build}


def _input_snapshot(normal, developer, sdk):
    paths = set(REPOSITORY_ROOT / relative for relative in _IDENTITY.profile_paths(REPOSITORY_ROOT, "golden"))
    paths.update(SCRIPT_ROOT / relative for relative in (
        "run_gatef_native_golden.py", "native_golden_evidence.py", "stage_xcode_resources.py"))
    paths.update(normal / relative for relative in (
        "libmacscope_native_decompiler_contract.a", "CMakeCache.txt",
        "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp"))
    paths.add(developer / "usr/bin/xcodebuild")
    tool_root = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
    paths.add(tool_root / "lipo")
    settings = sdk / "SDKSettings.json"
    if not settings.exists(): settings = sdk / "SDKSettings.plist"
    paths.update((settings, sdk / "usr/lib/libz.tbd", sdk / "usr/lib/libc++.tbd"))
    snapshot = {path: _file(path, "golden input") for path in sorted(paths)}
    snapshot.update({tool_root / name: _tool_file(tool_root / name, target)
                     for name, target in (("clang++", "clang"), ("swiftc", "swift-frontend"))})
    return snapshot


def run_golden(arguments, *, command_runner):
    source, normal, developer, sdk, parent = _require_layout(arguments)
    source_anchor = None
    staged_state = None
    directory_anchors = []
    try:
        _anchor_ancestors((source, normal, developer, sdk, parent), directory_anchors)
        source_anchor = _STAGE._STAGER._open_verified_materialization(source, "source materialization")
        before = _input_snapshot(normal, developer, sdk)
        tools = _tool_identity(developer, sdk, arguments.sdk_name, command_runner)
        wrapper = _IDENTITY.profile_digest(REPOSITORY_ROOT, "wrapper")
        golden = _IDENTITY.profile_digest(REPOSITORY_ROOT, "golden")
        # Reserve through an anchored parent. Retain failed residue; never clean
        # an ambiguous path or repurpose somebody else's preexisting directory.
        parent_anchor = next(anchor for anchor in directory_anchors if anchor[0] == parent)
        work_anchor = _reserve_directory(parent_anchor, "golden", directory_anchors)
        products_anchor = _reserve_directory(work_anchor, "products", directory_anchors)
        metadata_anchor = _reserve_directory(work_anchor, "metadata", directory_anchors)
        products, metadata = products_anchor[0], metadata_anchor[0]
        stage_dir = _reserve_directory(metadata_anchor, "stage", directory_anchors)[0]
        stage_command = [sys.executable, "-B", str(SCRIPT_ROOT / "stage_xcode_resources.py"),
            "--source-materialization-root", str(source), "--target-build-dir", str(products),
            "--unlocalized-resources-folder-path", RESOURCE_SUBPATH.as_posix(),
            "--metadata-directory", str(stage_dir)]
        _revalidate_directories(directory_anchors)
        _STAGE._STAGER._revalidate_anchored_materialization(*source_anchor[:4], "source materialization")
        if _input_snapshot(normal, developer, sdk) != before:
            raise GoldenProducerError("golden inputs changed before staging")
        if command_runner(stage_command).returncode != 0:
            raise GoldenProducerError("native package staging failed")
        _revalidate_directories(directory_anchors)
        materialization = products / RESOURCE_SUBPATH / _STAGE.DESTINATION_NAME
        stamp = stage_dir / _STAGE.STAMP_NAME
        input_list, output_list = stage_dir / _STAGE.INPUT_LIST_NAME, stage_dir / _STAGE.OUTPUT_LIST_NAME
        staged_state = _STAGE._existing_owned_state(materialization, input_list, output_list, stamp)
        if staged_state is None or staged_state[3] is None:
            raise GoldenProducerError("staging lacks a physically verified complete publication")
        if staged_state[0]["materialization"] != source_anchor[4]:
            raise GoldenProducerError("staged materialization differs from verified source")
        expected_lists = _STAGE._expected_file_list_payloads(source_anchor, materialization)
        if (staged_state[2][input_list][3], staged_state[2][output_list][3]) != expected_lists:
            raise GoldenProducerError("staging file lists differ from exact source and product paths")
        observed_identity = {**_EVIDENCE.PINNED_IDENTITY, **tools,
            "wrapperGitRevision": wrapper, "goldenSourceSHA256": golden,
            "contractArchiveSHA256": before[normal / "libmacscope_native_decompiler_contract.a"][1],
            "contractBuildIdentitySHA256": before[normal / "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp"][1],
            "stageStampSHA256": hashlib.sha256(staged_state[2][stamp][3]).hexdigest(),
            "materializationManifestSHA256": _file(materialization / "MATERIALIZATION.json", "staged manifest")[1],
            "materializationTreeSHA256": staged_state[0]["materialization"]["package"]["treeSha256"],
            "decompilerArchiveSHA256": _file(materialization / "package/lib/libdecomp.a", "staged archive")[1],
            "sleighArchiveSHA256": _file(materialization / "package/lib/libsla.a", "staged archive")[1]}
        result = products / "NativeDecompilerBridgeGolden.json"
        if os.path.lexists(result):
            raise GoldenProducerError("golden result must be absent before execution")
        command = ["/bin/bash", str(SCRIPT_ROOT / "run_native_bridge_golden.sh"),
            "--build-root", str(metadata / "build"), "--materialization-root", str(materialization),
            "--native-archive-root", str(normal), "--stage-stamp", str(stamp),
            "--developer-dir", str(developer), "--sdk-root", str(sdk), "--sdk-name", arguments.sdk_name,
            "--target-build-dir", str(products), "--project-temp-dir", str(parent), "--result", str(result)]
        _revalidate_directories(directory_anchors)
        _STAGE._revalidate_owned_state(staged_state, materialization, input_list, output_list, stamp, label="golden stage")
        _STAGE._STAGER._revalidate_anchored_materialization(*source_anchor[:4], "source materialization")
        if _input_snapshot(normal, developer, sdk) != before:
            raise GoldenProducerError("golden inputs changed before execution")
        completed = command_runner(command)
        if completed.returncode != 0:
            raise GoldenProducerError(f"native golden process failed with exit {completed.returncode}")
        _revalidate_directories(directory_anchors)
        result_identity, payload = _result_snapshot(result)
        _EVIDENCE.validate_golden_payload(payload, expected_identity=observed_identity)
        _STAGE._revalidate_owned_state(staged_state, materialization, input_list, output_list, stamp, label="golden stage")
        _STAGE._STAGER._revalidate_anchored_materialization(*source_anchor[:4], "source materialization")
        if (_tool_identity(developer, sdk, arguments.sdk_name, command_runner) != tools
                or _input_snapshot(normal, developer, sdk) != before
                or _IDENTITY.profile_digest(REPOSITORY_ROOT, "wrapper") != wrapper
                or _IDENTITY.profile_digest(REPOSITORY_ROOT, "golden") != golden):
            raise GoldenProducerError("golden source, product, or toolchain changed during execution")
        _revalidate_directories(directory_anchors)
        if _result_snapshot(result) != (result_identity, payload):
            raise GoldenProducerError("golden result changed before publication")
        _revalidate_directories(directory_anchors)
        return result, stamp, materialization
    finally:
        _STAGE._close_owned_state(staged_state)
        if source_anchor is not None: os.close(source_anchor[1])
        for _, descriptor, _ in directory_anchors: os.close(descriptor)


def main(argv=None, *, command_runner=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-materialization-root", "native-archive-root", "work-root", "developer-dir", "sdk-root"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--sdk-name", required=True)
    arguments = parser.parse_args(argv)
    try:
        paths = run_golden(arguments, command_runner=command_runner or subprocess.run)
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    for key, path in zip(("RESULT", "STAGE_STAMP", "MATERIALIZATION"), paths):
        print(f"MACSCOPE_NATIVE_GOLDEN_{key}={path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
