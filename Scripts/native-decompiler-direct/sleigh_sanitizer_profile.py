#!/usr/bin/env python3
"""Producer-only sanitizer build inspection; never imported by resource staging."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
from typing import Any

from sleigh_package import (
    DuplicateJSONKey,
    MAX_FILES,
    MAX_PATH_BYTES,
    MAX_TEXT_BYTES,
    PackageContractError,
    SANITIZER_ARCHIVES,
    SANITIZER_FLAGS,
    _json_without_duplicate_keys,
    _ordinary_file,
    _read_text,
    _sha256,
)


def _native_metadata(arguments: list[str]) -> str:
    try:
        result = subprocess.run(arguments, check=False, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PackageContractError("native archive evidence probe failed") from error
    if result.returncode or len(result.stdout.encode("utf-8")) > MAX_TEXT_BYTES:
        raise PackageContractError("native archive evidence probe failed or exceeded its output limit")
    return result.stdout


def _native_archive_member_digests(archive: Path) -> dict[str, str]:
    """Stream bounded Apple/BSD ar members without extracting hostile paths."""
    digests: dict[str, str] = {}
    size = archive.stat().st_size
    with archive.open("rb") as stream:
        if stream.read(8) != b"!<arch>\n":
            raise PackageContractError("native sanitizer archive is not an ordinary ar archive")
        while stream.tell() < size:
            header = stream.read(60)
            if len(header) != 60 or header[58:] != b"`\n":
                raise PackageContractError("native archive contains a malformed member header")
            try:
                label = header[:16].decode("ascii").rstrip()
                member_size = int(header[48:58].decode("ascii").strip())
            except (UnicodeError, ValueError) as error:
                raise PackageContractError("native archive has an invalid member name or size") from error
            if member_size < 0 or stream.tell() + member_size > size:
                raise PackageContractError("native archive member exceeds the archive bounds")
            payload_size = member_size
            if label.startswith("#1/"):
                try:
                    name_size = int(label[3:])
                except ValueError as error:
                    raise PackageContractError("native archive has an invalid extended name") from error
                if not 0 < name_size <= min(MAX_PATH_BYTES, member_size):
                    raise PackageContractError("native archive extended name exceeds its bounds")
                raw_name = stream.read(name_size).rstrip(b"\x00")
                try:
                    label = raw_name.decode("utf-8")
                except UnicodeError as error:
                    raise PackageContractError("native archive member name is not UTF-8") from error
                payload_size -= name_size
            else:
                label = label.removesuffix("/")
            if (not label or label in {".", ".."} or "/" in label or "\\" in label
                    or any(ord(character) < 32 for character in label)):
                raise PackageContractError("native archive member name is unsafe or unsupported")
            digest = hashlib.sha256()
            remaining = payload_size
            while remaining:
                block = stream.read(min(1024 * 1024, remaining))
                if not block:
                    raise PackageContractError("native archive member is truncated")
                digest.update(block)
                remaining -= len(block)
            if member_size % 2 and stream.read(1) != b"\n":
                raise PackageContractError("native archive member has invalid alignment padding")
            if label not in {"__.SYMDEF", "__.SYMDEF SORTED", "__.SYMDEF_64", "__.SYMDEF_64 SORTED"}:
                if label in digests or len(digests) >= MAX_FILES:
                    raise PackageContractError("native archive has duplicate or excessive members")
                digests[label] = digest.hexdigest()
    return digests


def admit_sanitizer_compile_commands(
    compile_commands: Path, compiler: Path, sdk_root: Path,
    sanitizer: str,
) -> dict[str, dict[str, Path]]:
    """Admit effective flags and object paths without writes or tool execution.

    Inspection and retained-report replay share this profile interpretation.
    Callers separately hash the admitted objects and inspect archive members;
    only producer inspection additionally observes native symbols with nm.
    """
    if sanitizer not in SANITIZER_FLAGS:
        raise PackageContractError("archive inspection requires one explicit sanitizer profile")
    commands_path = _ordinary_file(compile_commands, "compile commands", MAX_TEXT_BYTES)
    compiler_path = compiler.resolve(strict=True)
    sdk_path = sdk_root.resolve(strict=True)
    _ordinary_file(sdk_path / "SDKSettings.json", "SDK settings", MAX_TEXT_BYTES)
    try:
        commands = json.loads(_read_text(commands_path, "compile commands"),
                              object_pairs_hook=_json_without_duplicate_keys)
    except (ValueError, DuplicateJSONKey) as error:
        raise PackageContractError("compile commands are not valid unambiguous JSON") from error
    if not isinstance(commands, list) or not 0 < len(commands) <= MAX_FILES:
        raise PackageContractError("compile commands must be a bounded nonempty array")
    objects: dict[str, dict[str, Path]] = {target: {} for target in SANITIZER_ARCHIVES}
    object_root = commands_path.parent.resolve(strict=True)
    outputs: set[str] = set()
    for entry in commands:
        if not isinstance(entry, dict):
            raise PackageContractError("compile command must be an object")
        arguments = entry.get("arguments")
        if arguments is None:
            command = entry.get("command")
            if not isinstance(command, str):
                raise PackageContractError("compile command has no effective arguments")
            try:
                arguments = shlex.split(command)
            except ValueError as error:
                raise PackageContractError("compile command cannot be parsed") from error
        if (not isinstance(arguments, list) or not arguments
                or any(not isinstance(arg, str) for arg in arguments)):
            raise PackageContractError("compile command arguments must be strings")
        if arguments.count("-o") != 1 or arguments.index("-o") + 1 >= len(arguments):
            raise PackageContractError("compile command must name one output object")
        output = arguments[arguments.index("-o") + 1]
        matches = [target for target in objects if f"CMakeFiles/{target}.dir/" in output]
        if not matches:
            continue
        if len(matches) != 1 or output in outputs:
            raise PackageContractError("compile command has ambiguous or duplicate native object")
        outputs.add(output)
        try:
            same_compiler = Path(arguments[0]).resolve(strict=True) == compiler_path
        except OSError:
            same_compiler = False
        if not same_compiler:
            raise PackageContractError("native compile command uses a different compiler")
        if any(arg.startswith(("@", "-Xclang", "-mllvm", "-fno-sanitize=",
                               "-fno-sanitize-address", "-fsanitize-ignorelist",
                               "-fsanitize-blacklist")) or "_LIBCPP" in arg
               for arg in arguments):
            raise PackageContractError("native compile command contains an unchecked sanitizer override")
        sanitizer_args = [arg for arg in arguments if arg.startswith("-fsanitize=")]
        if sanitizer_args != ["-fsanitize=" + sanitizer]:
            raise PackageContractError("native compile command is missing or mixes sanitizer profiles")
        for required in (*SANITIZER_FLAGS[sanitizer], "-g", "-DNDEBUG", "-c"):
            if required not in arguments:
                raise PackageContractError("native compile command is missing a required profile flag")
        if [arg for arg in arguments if re.fullmatch(r"-O(?:[0-3sgz]|fast)", arg)][-1:] != ["-O1"]:
            raise PackageContractError("native compile command has unexpected effective optimization")
        if any(arg in arguments for arg in ("-fomit-frame-pointer", "-g0", "-UNDEBUG")):
            raise PackageContractError("native compile command negates a required profile flag")
        if sanitizer == "undefined" and any(arg.startswith("-fsanitize-recover") for arg in arguments):
            raise PackageContractError("native compile command enables sanitizer recovery")
        for option, expected in (("-isysroot", str(sdk_path)), ("-arch", "arm64")):
            if arguments.count(option) != 1 or arguments.index(option) + 1 >= len(arguments):
                raise PackageContractError("native compile command uses a different SDK or architecture")
            observed = arguments[arguments.index(option) + 1]
            if option == "-isysroot":
                observed = str(Path(observed).resolve())
            if observed != expected:
                raise PackageContractError("native compile command uses a different SDK or architecture")
        if [arg for arg in arguments if arg.startswith("-mmacosx-version-min=")] != ["-mmacosx-version-min=27.0"]:
            raise PackageContractError("native compile command has unexpected deployment target")
        # CMake output paths are relative to its build directory. After atomic
        # publication the recorded directory can be stale; relocate only that
        # directory, never the relative object suffix or an arbitrary source.
        output_path = Path(output)
        if output_path.is_absolute():
            directory = entry.get("directory")
            if not isinstance(directory, str) or not Path(directory).is_absolute():
                raise PackageContractError("absolute native object lacks its compile directory")
            try:
                output_path = output_path.relative_to(directory)
            except ValueError as error:
                raise PackageContractError("native object is outside its compile directory") from error
        if ".." in output_path.parts:
            raise PackageContractError("native object path contains parent traversal")
        admitted_path = object_root
        for component in output_path.parts:
            admitted_path = admitted_path / component
            if admitted_path.is_symlink():
                raise PackageContractError("compiled native object path contains a symlink")
        object_file = _ordinary_file(object_root / output_path, "compiled native object")
        object_file = object_file.resolve(strict=True)
        if object_root not in object_file.parents:
            raise PackageContractError("compiled native object escapes its build directory")
        member_name = output_path.name
        target_objects = objects[matches[0]]
        if member_name in target_objects:
            raise PackageContractError("native target has duplicate archive member names")
        target_objects[member_name] = object_file
    for target in SANITIZER_ARCHIVES:
        if not objects[target]:
            raise PackageContractError(f"compile commands are missing native target {target}")
    return objects


def inspect_sanitizer_build(
    package_root: Path, compile_commands: Path, compiler: Path, sdk_root: Path,
    sanitizer: str,
) -> dict[str, Any]:
    """Attest effective flags, member bytes and symbols for both native archives."""
    admitted = admit_sanitizer_compile_commands(compile_commands, compiler, sdk_root, sanitizer)
    objects = {target: {name: _sha256(path) for name, path in members.items()}
               for target, members in admitted.items()}
    commands_path = _ordinary_file(compile_commands, "compile commands", MAX_TEXT_BYTES)
    sdk_path = sdk_root.resolve(strict=True)
    sdk_settings = _ordinary_file(sdk_path / "SDKSettings.json", "SDK settings", MAX_TEXT_BYTES)
    archive_digests: dict[str, str] = {}
    for target, relative in SANITIZER_ARCHIVES.items():
        archive = _ordinary_file(package_root / relative, "native sanitizer archive")
        members = _native_archive_member_digests(archive)
        if members != objects[target]:
            raise PackageContractError(f"native archive member bytes do not match compiled objects: {target}")
        symbols = _native_metadata(["/usr/bin/nm", "-u", str(archive)])
        marker = "__asan_" if sanitizer == "address" else "__ubsan_"
        if marker not in symbols:
            raise PackageContractError(f"native archive has no {sanitizer} instrumentation: {target}")
        archive_digests[relative] = _sha256(archive)
    return {
        "profile": sanitizer,
        "compileCommandsSha256": _sha256(commands_path),
        "sdkRoot": str(sdk_path),
        "sdkSettingsSha256": _sha256(sdk_settings),
        "translationUnitCounts": {target: len(names) for target, names in objects.items()},
        "archiveSha256": archive_digests,
    }
