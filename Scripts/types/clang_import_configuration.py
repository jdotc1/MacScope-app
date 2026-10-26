#!/usr/bin/env python3
"""Explicit local Clang configuration for data-only type archives.

No compilation database, shell command, arbitrary compiler flags, implicit host
include environment or directory traversal is accepted. Discovery interrogates
only the selected toolchain and SDK metadata; it never enumerates SDK headers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Callable

EXTRACTOR_VERSION = "macscope-clang-types-1"
MAX_OUTPUT = 4 * 1024 * 1024
CLEAN_ENV = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
PROFILE_KEYS = {"target", "architecture", "deployment_target", "language", "dialect",
                "objc_runtime", "arc", "blocks", "modules", "include_roots",
                "framework_roots", "defines", "undefines"}


class ConfigurationError(ValueError):
    pass


def run_tool(argv: list[str], *, input_bytes: bytes = b"") -> str:
    result = subprocess.run(argv, input=input_bytes, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=CLEAN_ENV, timeout=20, check=False)
    if len(result.stdout) > MAX_OUTPUT or len(result.stderr) > MAX_OUTPUT:
        raise ConfigurationError("tool discovery output exceeds bound")
    if result.returncode:
        raise ConfigurationError(f"{argv[0]} discovery failed ({result.returncode}): "
                                 + result.stderr.decode("utf-8", "replace")[:16384])
    return result.stdout.decode("utf-8", "strict").strip()


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode("utf-8")


def configuration_id(configuration: dict) -> str:
    payload = {key: value for key, value in configuration.items() if key != "configurationID"}
    return hashlib.sha256(canonical_json(payload)).hexdigest()


def load_profile(path: Path) -> dict:
    if path.stat().st_size > 64 * 1024:
        raise ConfigurationError("profile exceeds bound")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ConfigurationError("duplicate profile key")
            result[key] = value
        return result
    return validate_profile(json.loads(path.read_text(), object_pairs_hook=unique))


def validate_profile(profile: dict) -> dict:
    if not isinstance(profile, dict) or set(profile) != PROFILE_KEYS:
        raise ConfigurationError("profile must use only the typed configuration keys; arbitrary flags/commands are unsupported")
    for key in ("target", "architecture", "deployment_target", "language", "dialect", "objc_runtime", "modules"):
        if not isinstance(profile[key], str) or len(profile[key]) > 128:
            raise ConfigurationError(f"invalid {key}")
    match = re.fullmatch(r"(arm64e?)-apple-macosx([0-9]+(?:\.[0-9]+){0,2})", profile["target"])
    if not match or match.groups() != (profile["architecture"], profile["deployment_target"]):
        raise ConfigurationError("target, architecture and deployment target must agree explicitly")
    if profile["language"] not in ("c", "objective-c") or profile["dialect"] not in ("c11", "c17", "gnu11", "gnu17"):
        raise ConfigurationError("unsupported language/dialect")
    if any(type(profile[key]) is not bool for key in ("arc", "blocks")):
        raise ConfigurationError("ARC and blocks must be booleans")
    if profile["modules"] != "disabled":
        raise ConfigurationError("implicit modules are unsupported in this initial importer")
    if profile["language"] == "c":
        if profile["arc"] or profile["objc_runtime"] != "none":
            raise ConfigurationError("C profile cannot inherit Objective-C settings")
    elif profile["objc_runtime"] != "macosx-" + profile["deployment_target"]:
        raise ConfigurationError("Objective-C runtime must match the explicit deployment target")
    for key in ("include_roots", "framework_roots", "defines", "undefines"):
        values = profile[key]
        if not isinstance(values, list) or len(values) > 128:
            raise ConfigurationError(f"invalid {key} list")
        for value in values:
            if not isinstance(value, str) or not value or len(value) > 4096 or any(c in value for c in "\r\n\0"):
                raise ConfigurationError(f"invalid {key} value")
            if key in ("defines", "undefines"):
                pattern = r"[A-Za-z_][A-Za-z0-9_]*(?:=.*)?" if key == "defines" else r"[A-Za-z_][A-Za-z0-9_]*"
                if not re.fullmatch(pattern, value):
                    raise ConfigurationError("invalid macro override")
    return json.loads(json.dumps(profile))


def _root(value: str, sdk: Path, source_root: Path) -> str:
    if value.startswith("sdk:"):
        base, relative = sdk, value[4:]
    elif value.startswith("input:"):
        base, relative = source_root, value[6:]
    else:
        raise ConfigurationError("search roots must explicitly use sdk: or input:")
    if Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise ConfigurationError("search root escapes its selected origin")
    path = (base / relative).resolve(strict=True)
    if not path.is_dir() or not path.is_relative_to(base):
        raise ConfigurationError("search root is not a directory inside its selected origin")
    return str(path)


def resolve_configuration(profile: dict, source_root: Path,
                          run: Callable[..., str] = run_tool) -> dict:
    profile = validate_profile(profile)
    source_root = source_root.resolve(strict=True)
    if not source_root.is_dir():
        raise ConfigurationError("source root must be a directory")
    compiler = Path(run(["/usr/bin/xcrun", "--find", "clang"])).resolve(strict=True)
    sdk = Path(run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"])).resolve(strict=True)
    resource = Path(run([str(compiler), "-print-resource-dir"])).resolve(strict=True)
    if not compiler.is_file() or not os.access(compiler, os.X_OK) or not sdk.is_dir() or not resource.is_dir():
        raise ConfigurationError("compiler/SDK/resource discovery is not usable")
    compiler_version = run([str(compiler), "--version"])
    sdk_version = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"])
    sdk_build = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"])
    if any(not value or len(value.encode()) > 16384 for value in (compiler_version, sdk_version, sdk_build)):
        raise ConfigurationError("missing or oversized toolchain identity")
    includes = [_root(value, sdk, source_root) for value in profile["include_roots"]]
    frameworks = [_root(value, sdk, source_root) for value in profile["framework_roots"]]
    arguments = ["--no-default-config", "-target", profile["target"], "-x", profile["language"],
                 "-std=" + profile["dialect"], "-isysroot", str(sdk), "-resource-dir", str(resource),
                 "-nostdinc", "-fno-modules", "-fno-implicit-modules",
                 "-fblocks" if profile["blocks"] else "-fno-blocks"]
    if profile["language"] == "objective-c":
        arguments += ["-fobjc-runtime=" + profile["objc_runtime"], "-fobjc-arc" if profile["arc"] else "-fno-objc-arc"]
    for path in includes:
        arguments += ["-I", path]
    for path in frameworks:
        arguments += ["-F", path]
    arguments += ["-D" + value for value in profile["defines"]]
    arguments += ["-U" + value for value in profile["undefines"]]
    macro_text = run([str(compiler), *arguments, "-dM", "-E", "-"], input_bytes=b"")
    if len(macro_text.encode()) > MAX_OUTPUT:
        raise ConfigurationError("builtin macro output exceeds bound")
    macros = "\n".join(sorted(line.rstrip() for line in macro_text.splitlines() if line.strip())) + "\n"
    configuration = {
        "schema": "macscope.clang-import-configuration", "version": 1,
        "extractorVersion": EXTRACTOR_VERSION, "compiler": str(compiler),
        "compilerVersion": compiler_version, "sdkPath": str(sdk), "sdkVersion": sdk_version,
        "sdkBuild": sdk_build, "resourceDirectory": str(resource),
        "sourceRoot": str(source_root), "profile": profile, "arguments": arguments,
        "builtinMacrosSHA256": hashlib.sha256(macros.encode()).hexdigest(),
        "environment": CLEAN_ENV.copy(),
    }
    configuration["configurationID"] = configuration_id(configuration)
    return configuration


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(resolve_configuration(load_profile(args.profile), args.source_root), sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
