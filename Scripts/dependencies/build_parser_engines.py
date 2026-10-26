#!/usr/bin/env python3
"""Build once, cache, and stage MacScope's native parser engines (RX-03).

The analysis worker links four static archives built from repository-owned,
pinned sources:

  parser-engine-pe-parse   ThirdParty/PEParse            (CMake)
  parser-engine-lief       ThirdParty/LIEF               (CMake, Mach-O + PE + COFF only)
  parser-engine-go-macho   ThirdParty/GoMachO + bridge   (go build -buildmode=c-archive)
  parser-engine-bridge     MacScope/ParserEngines        (CMake; C ABI + developer dump CLI)

Each archive is keyed by the SHA-256 of its source closure, this script, the
payload layout and the exact toolchain (clang++, macOS SDK, CMake, Ninja, Go).
A key is built at most once per machine and published as an immutable entry
in the shared content-addressed dependency cache
(<cache-root>/artifacts/v1/<component>/<key>, the layout and verifier of
Scripts/qualification/dependency_cache.py). Xcode never compiles these sources:
its pre-build phase runs `stage`, which

  * returns in milliseconds when the staged view, its sources and tools are
    unchanged (stat fingerprint);
  * otherwise recomputes the keys and, only for a changed key, clones the
    verified cache entry into the staging directory (dependency_cache.py
    materialize, full SHA-256 verification);
  * builds and publishes an entry only on a true cache miss (new pin, new
    bridge source or new toolchain).

Builds are offline: CMake extracts LIEF's vendored archives by URL_HASH from
the source tree, and Go runs with GOPROXY=off, GOTOOLCHAIN=local and replace
directives to the vendored modules. Standard library only; Python 3.9+.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).resolve()
CACHE_TOOL = ROOT / "Scripts/qualification/dependency_cache.py"
LAYOUT = "parser-engines-v1"
DEPLOYMENT_TARGET = "27.0"
STAMP_NAME = "STAGED.json"
BUILD_RECEIPT = "BUILD.json"

COMPONENTS: Dict[str, Dict[str, object]] = {
    "parser-engine-pe-parse": {
        "sources": ["ThirdParty/PEParse"],
        "tools": ["clang", "sdk", "cmake", "ninja"],
        "deps": [],
        "required": ["lib/libpe-parse.a", "include/pe-parse/parse.h"],
    },
    "parser-engine-lief": {
        "sources": ["ThirdParty/LIEF"],
        "tools": ["clang", "sdk", "cmake", "ninja"],
        "deps": [],
        "required": ["lib/libLIEF.a", "include/LIEF/LIEF.hpp"],
    },
    "parser-engine-go-macho": {
        "sources": ["ThirdParty/GoMachO", "MacScope/ParserEngines/gomacho"],
        "tools": ["clang", "sdk", "go"],
        "deps": [],
        "required": ["lib/libmacscope_gomacho.a"],
    },
    "parser-engine-bridge": {
        "sources": [
            "MacScope/ParserEngines/CMakeLists.txt",
            "MacScope/ParserEngines/include",
            "MacScope/ParserEngines/src",
            "MacScope/ParserEngines/tools",
        ],
        "tools": ["clang", "sdk", "cmake", "ninja"],
        "deps": ["parser-engine-pe-parse", "parser-engine-lief", "parser-engine-go-macho"],
        "required": [
            "lib/libmacscope_parser_engines.a",
            "include/MacScopeParserEngines.h",
            "include/module.modulemap",
            "bin/macscope-parser-dump",
        ],
    },
}
ORDER = ["parser-engine-pe-parse", "parser-engine-lief", "parser-engine-go-macho", "parser-engine-bridge"]

# Pinned upstream identities embedded into the bridge (and its dump CLI).
ENGINE_IDENTITY = {
    "lief": {"version": "1.0.0", "git_revision": "d05b3499b6934137e917c009a4df0a9dc8cb11c5"},
    "pe-parse": {"version": "2.1.1", "git_revision": "7888f1f8de2f6bc302c291a5b4519fad926c0133"},
    "go-macho": {"version": "1.1.283", "git_revision": "0b3c4a4cb4548a0d1284c1b5fc0de6f4422c0246"},
}

LIEF_CMAKE_OPTIONS = [
    "-DBUILD_SHARED_LIBS=OFF", "-DLIEF_C_API=OFF", "-DLIEF_EXAMPLES=OFF", "-DLIEF_TESTS=OFF",
    "-DLIEF_USE_CCACHE=OFF", "-DLIEF_LOGGING=OFF", "-DLIEF_LOGGING_DEBUG=OFF", "-DLIEF_ENABLE_JSON=OFF",
    "-DLIEF_ELF=OFF", "-DLIEF_DEX=OFF", "-DLIEF_ART=OFF", "-DLIEF_OAT=OFF", "-DLIEF_VDEX=OFF",
    "-DLIEF_PE=ON", "-DLIEF_COFF=ON", "-DLIEF_MACHO=ON", "-DLIEF_PYTHON_API=OFF",
    "-DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER",
]


class EngineBuildError(RuntimeError):
    pass


# --- identities ------------------------------------------------------------

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


def source_files(prefixes: List[str]) -> List[Path]:
    files: List[Path] = []
    for prefix in prefixes:
        path = ROOT / prefix
        if path.is_symlink():
            raise EngineBuildError(f"source path must not be a symlink: {prefix}")
        if path.is_file():
            files.append(path)
            continue
        if not path.is_dir():
            raise EngineBuildError(f"source path is missing: {prefix}")
        for candidate in path.rglob("*"):
            if candidate.name == ".DS_Store" or candidate.is_dir():
                continue
            if candidate.is_symlink() or not candidate.is_file():
                raise EngineBuildError(f"source tree holds a non-regular file: {candidate}")
            files.append(candidate)
    return sorted(set(files), key=lambda item: item.relative_to(ROOT).as_posix())


def source_digest(prefixes: List[str]) -> str:
    records = [
        [path.relative_to(ROOT).as_posix(), bool(path.stat().st_mode & 0o111), sha256_file(path)]
        for path in source_files(prefixes)
    ]
    return hashlib.sha256(canonical(records)).hexdigest()


def run(arguments: List[str], *, cwd: Optional[Path] = None, env: Optional[Dict[str, str]] = None,
        log: Optional[Path] = None, timeout: int = 7200) -> str:
    completed = subprocess.run(
        arguments, cwd=str(cwd) if cwd else None, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
    )
    output = completed.stdout.decode("utf-8", "replace")
    if log is not None:
        with log.open("a", encoding="utf-8") as stream:
            stream.write(f"$ {' '.join(arguments)}\n{output}\n")
    if completed.returncode != 0:
        raise EngineBuildError(f"command failed ({completed.returncode}): {' '.join(arguments)}\n{output[-4000:]}")
    return output


def find_tool(name: str, environment_key: str) -> Path:
    candidates = [os.environ.get(environment_key, "")]
    candidates += [str(Path(directory) / name) for directory in os.environ.get("PATH", "").split(":") if directory]
    candidates += [f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}", f"/usr/local/go/bin/{name}"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return Path(candidate).resolve()
    raise EngineBuildError(f"{name} is required to build the parser engines (set {environment_key})")


class Toolchain:
    """Exact build tools. Identities are SHA-256 of the resolved executables plus versions."""

    def __init__(self) -> None:
        self._paths: Dict[str, Path] = {}
        self._identities: Dict[str, Dict[str, str]] = {}
        self._sdk_path: Optional[str] = None

    def path(self, tool: str) -> Path:
        if tool not in self._paths:
            if tool == "clang":
                # Keep the clang++ driver name (it selects C++ and libc++); identity hashes the target.
                self._paths[tool] = Path(run(["/usr/bin/xcrun", "--find", "clang++"]).strip())
            elif tool == "cmake":
                self._paths[tool] = find_tool("cmake", "MACSCOPE_CMAKE")
            elif tool == "ninja":
                self._paths[tool] = find_tool("ninja", "MACSCOPE_NINJA")
            elif tool == "go":
                self._paths[tool] = find_tool("go", "MACSCOPE_GO")
            else:
                raise EngineBuildError(f"unknown tool {tool}")
        return self._paths[tool]

    def sdk_path(self) -> str:
        if self._sdk_path is None:
            self._sdk_path = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        return self._sdk_path

    def stat_paths(self, tools: List[str]) -> List[Path]:
        return [self.path(tool) for tool in tools if tool != "sdk"]

    def identity(self, tool: str) -> Dict[str, str]:
        if tool in self._identities:
            return self._identities[tool]
        if tool == "sdk":
            value = {
                "version": run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
                "build": run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"]).strip(),
            }
        elif tool == "go":
            go = self.path("go")
            goroot = Path(run([str(go), "env", "GOROOT"]).strip())
            tooldir = Path(run([str(go), "env", "GOTOOLDIR"]).strip())
            value = {
                "path": str(go), "sha256": sha256_file(go),
                "version": run([str(go), "version"]).strip(),
                "goroot": str(goroot),
                "compile_sha256": sha256_file(tooldir / "compile"),
                "link_sha256": sha256_file(tooldir / "link"),
            }
        else:
            path = self.path(tool)
            value = {"path": str(path), "sha256": sha256_file(path.resolve()),
                     "version": run([str(path), "--version"]).splitlines()[0].strip()}
        self._identities[tool] = value
        return value


def component_key(component: str, toolchain: Toolchain, keys: Dict[str, str]) -> Tuple[str, Dict[str, object]]:
    spec = COMPONENTS[component]
    inputs: Dict[str, object] = {
        "component": component,
        "layout": LAYOUT,
        "architecture": "arm64",
        "deployment_target": DEPLOYMENT_TARGET,
        "configuration": "Release",
        "builder_sha256": sha256_file(SCRIPT),
        "source_prefixes": spec["sources"],
        "source_sha256": source_digest(spec["sources"]),
        "tools": {tool: toolchain.identity(tool) for tool in spec["tools"]},
        "dependencies": {dependency: keys[dependency] for dependency in spec["deps"]},
    }
    if component == "parser-engine-lief":
        inputs["cmake_options"] = LIEF_CMAKE_OPTIONS
    if component == "parser-engine-bridge":
        inputs["engine_identity"] = ENGINE_IDENTITY
    return hashlib.sha256(canonical(inputs)).hexdigest(), inputs


# --- cache -------------------------------------------------------------------

def entry_path(cache_root: Path, component: str, key: str) -> Path:
    return cache_root / "artifacts" / "v1" / component / key


@contextmanager
def component_lock(cache_root: Path, component: str) -> Iterator[None]:
    locks = cache_root / "locks"
    locks.mkdir(parents=True, exist_ok=True)
    with (locks / f"{component}.lock").open("a") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def cache_tool(*arguments: str) -> None:
    run(["/usr/bin/python3", "-B", str(CACHE_TOOL), *arguments])


def build_environment(toolchain: Toolchain) -> Dict[str, str]:
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ.get("HOME", "/var/empty"),
        "LANG": "C", "LC_ALL": "C", "TZ": "UTC", "ZERO_AR_DATE": "1", "SOURCE_DATE_EPOCH": "946684800",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    }
    for key in ("DEVELOPER_DIR",):
        if os.environ.get(key):
            environment[key] = os.environ[key]
    return environment


def cmake_configure(toolchain: Toolchain, source: Path, build: Path, prefix: Path, extra: List[str],
                    env: Dict[str, str], log: Path) -> None:
    run([
        str(toolchain.path("cmake")), "-S", str(source), "-B", str(build), "-G", "Ninja",
        f"-DCMAKE_MAKE_PROGRAM={toolchain.path('ninja')}", "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_CXX_COMPILER={toolchain.path('clang')}",
        f"-DCMAKE_C_COMPILER={toolchain.path('clang').parent / 'clang'}",
        "-DCMAKE_OSX_ARCHITECTURES=arm64", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={DEPLOYMENT_TARGET}",
        f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DCMAKE_FIND_USE_PACKAGE_REGISTRY=FALSE",
        "-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=FALSE",
        f"-DCMAKE_CXX_FLAGS=-ffile-prefix-map={source}=/macscope-parser-engines/src",
        *extra,
    ], env=env, log=log)


def copy_sources(prefixes: List[str], destination: Path) -> None:
    for path in source_files(prefixes):
        target = destination / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)


def build_payload(component: str, toolchain: Toolchain, work: Path, payload: Path,
                  cache_root: Path, keys: Dict[str, str]) -> None:
    jobs = os.environ.get("MACSCOPE_NATIVE_SOURCE_JOBS", str(os.cpu_count() or 8))
    env = build_environment(toolchain)
    log = work / "build.log"
    source_root = work / "src"
    copy_sources(COMPONENTS[component]["sources"], source_root)
    if component == "parser-engine-pe-parse":
        build = work / "build"
        cmake_configure(toolchain, source_root / "ThirdParty/PEParse/pe-parser-library", build, payload, [], env, log)
        run([str(toolchain.path("cmake")), "--build", str(build), "--parallel", jobs], env=env, log=log)
        run([str(toolchain.path("cmake")), "--install", str(build)], env=env, log=log)
    elif component == "parser-engine-lief":
        build = work / "build"
        cmake_configure(toolchain, source_root / "ThirdParty/LIEF", build, payload, LIEF_CMAKE_OPTIONS, env, log)
        run([str(toolchain.path("cmake")), "--build", str(build), "--parallel", jobs], env=env, log=log)
        run([str(toolchain.path("cmake")), "--install", str(build)], env=env, log=log)
    elif component == "parser-engine-go-macho":
        go = toolchain.path("go")
        go_env = dict(env)
        go_env.update({
            "GOFLAGS": "-mod=mod", "GOPROXY": "off", "GOSUMDB": "off",
            "GOTOOLCHAIN": "local", "GOWORK": "off", "GOCACHE": str(work / "gocache"),
            "GOPATH": str(work / "gopath"), "GOENV": "off", "GOTELEMETRY": "off",
            "CGO_ENABLED": "1", "GOOS": "darwin", "GOARCH": "arm64",
            # CC is the toolchain's clang itself, not the xcrun shim, and the build
            # environment is scrubbed, so cgo needs the SDK named explicitly.
            "CC": str(toolchain.path("clang").parent / "clang"),
            "SDKROOT": toolchain.sdk_path(),
            "CGO_CFLAGS": f"-O2 -mmacosx-version-min={DEPLOYMENT_TARGET} -isysroot {toolchain.sdk_path()}",
            "CGO_LDFLAGS": f"-mmacosx-version-min={DEPLOYMENT_TARGET} -isysroot {toolchain.sdk_path()}",
        })
        (payload / "lib").mkdir(parents=True)
        (payload / "include").mkdir(parents=True)
        run([str(go), "build", "-buildmode=c-archive", "-trimpath", "-buildvcs=false",
             "-o", str(payload / "lib/libmacscope_gomacho.a"), "."],
            cwd=source_root / "MacScope/ParserEngines/gomacho", env=go_env, log=log)
        shutil.move(str(payload / "lib/libmacscope_gomacho.h"), str(payload / "include/libmacscope_gomacho.h"))
    elif component == "parser-engine-bridge":
        identity_file = work / "identity.json"
        identity_file.write_bytes(canonical({"engines": ENGINE_IDENTITY}))
        dependency_roots = {name: entry_path(cache_root, name, keys[name]) / "payload"
                            for name in COMPONENTS[component]["deps"]}
        build = work / "build"
        cmake_configure(toolchain, source_root / "MacScope/ParserEngines", build, payload, [
            f"-DLIEF_ROOT={dependency_roots['parser-engine-lief']}",
            f"-DPEPARSE_ROOT={dependency_roots['parser-engine-pe-parse']}",
            f"-DGOMACHO_ROOT={dependency_roots['parser-engine-go-macho']}",
            f"-DMACSCOPE_PARSER_ENGINES_IDENTITY_FILE={identity_file}",
        ], env, log)
        run([str(toolchain.path("cmake")), "--build", str(build), "--parallel", jobs], env=env, log=log)
        (payload / "lib").mkdir(parents=True)
        (payload / "bin").mkdir(parents=True)
        shutil.copytree(source_root / "MacScope/ParserEngines/include", payload / "include")
        shutil.copy2(build / "libmacscope_parser_engines.a", payload / "lib/libmacscope_parser_engines.a")
        shutil.copy2(build / "macscope-parser-dump", payload / "bin/macscope-parser-dump")
        shutil.copy2(identity_file, payload / "IDENTITY.json")
    for required in COMPONENTS[component]["required"]:
        if not (payload / required).is_file():
            raise EngineBuildError(f"{component} build did not produce {required}")


def ensure_entry(component: str, key: str, inputs: Dict[str, object], toolchain: Toolchain,
                 cache_root: Path, keys: Dict[str, str], report: Dict[str, object]) -> Path:
    entry = entry_path(cache_root, component, key)
    if entry.is_dir():
        report[component] = {"key": key, "cache": "hit"}
        return entry
    with component_lock(cache_root, component):
        if entry.is_dir():
            report[component] = {"key": key, "cache": "hit-after-wait"}
            return entry
        temporary = cache_root / "temporary"
        temporary.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix=f"{component}-{key[:12]}.", dir=temporary))
        payload = work / "payload"
        payload.mkdir()
        started = time.monotonic()
        print(f"==> building {component} {key[:12]} (cache miss; one-time per key)", file=sys.stderr)
        try:
            build_payload(component, toolchain, work, payload, cache_root, keys)
            seconds = round(time.monotonic() - started, 1)
            (payload / BUILD_RECEIPT).write_bytes(canonical({
                "component": component, "key": key, "key_inputs": inputs, "cold_build_seconds": seconds,
            }))
            cache_tool("publish", "--entry", str(entry), "--component", component, "--key", key,
                       "--payload", str(payload))
        finally:
            shutil.rmtree(work, ignore_errors=True)
        report[component] = {"key": key, "cache": "built", "cold_build_seconds": seconds}
        print(f"==> published {component} {key[:12]} after {seconds}s", file=sys.stderr)
        return entry


# --- staging -----------------------------------------------------------------

def fingerprint(toolchain: Toolchain, cache_root: Path) -> str:
    """Cheap stat-only fingerprint of every key input; it gates the warm no-op path."""
    records: List[object] = [str(cache_root), LAYOUT]
    paths: List[Path] = [SCRIPT, CACHE_TOOL]
    tools = sorted({tool for spec in COMPONENTS.values() for tool in spec["tools"]})
    paths += toolchain.stat_paths(tools)
    for component in ORDER:
        paths += source_files(COMPONENTS[component]["sources"])
    for path in paths:
        metadata = path.stat()
        records.append([str(path), metadata.st_size, metadata.st_mtime_ns, metadata.st_ino])
    developer_dir = os.environ.get("DEVELOPER_DIR", "")
    records.append(developer_dir)
    return hashlib.sha256(canonical(records)).hexdigest()


def make_writable(path: Path) -> None:
    for candidate in [path, *path.rglob("*")]:
        try:
            if not candidate.is_symlink():
                candidate.chmod(0o700 if candidate.is_dir() else 0o600)
        except OSError:
            pass


def refresh_staged_times(root: Path) -> None:
    """Give a newly staged component the current time.

    Cache materialization keeps the producer's timestamps, which can be older than
    products an incremental build already made from the previous component (for
    example a precompiled module of the bridge header). Xcode decides staleness by
    modification time, so a changed header with an old time would be ignored and the
    compile would fail against the stale module. Only newly staged components are
    touched; unchanged ones keep their times so warm builds stay no-ops.
    """
    for path in [root, *root.rglob("*")]:
        if not path.is_symlink():
            os.utime(path)


def stage(destination: Path, cache_root: Path, report: Dict[str, object]) -> None:
    if not destination.is_absolute() or not cache_root.is_absolute():
        raise EngineBuildError("--destination and --cache-root must be absolute")
    for path, label in ((destination, "destination"), (cache_root, "cache root")):
        resolved = path.resolve()
        if resolved == ROOT or ROOT in resolved.parents:
            raise EngineBuildError(f"{label} must be outside the repository")
    destination.mkdir(parents=True, exist_ok=True)
    stamp_path = destination / STAMP_NAME
    toolchain = Toolchain()
    current_fingerprint = fingerprint(toolchain, cache_root)
    stamp: Dict[str, object] = {}
    if stamp_path.is_file():
        try:
            stamp = json.loads(stamp_path.read_text(encoding="utf-8"))
        except ValueError:
            stamp = {}
    staged_keys = stamp.get("keys", {}) if isinstance(stamp.get("keys"), dict) else {}
    if (stamp.get("fingerprint") == current_fingerprint
            and all((destination / name).is_dir() for name in ORDER)):
        report["path"] = "warm-noop"
        return
    keys: Dict[str, str] = {}
    for component in ORDER:
        key, inputs = component_key(component, toolchain, keys)
        keys[component] = key
        entry = ensure_entry(component, key, inputs, toolchain, cache_root, keys, report)
        target = destination / component
        if staged_keys.get(component) == key and target.is_dir():
            report.setdefault(component, {})["staged"] = "unchanged"
            continue
        incoming = destination / f".{component}.incoming"
        if incoming.exists():
            make_writable(incoming)
            shutil.rmtree(incoming)
        cache_tool("materialize", "--entry", str(entry), "--component", component, "--key", key,
                   "--destination", str(incoming))
        if target.exists():
            make_writable(target)
            shutil.rmtree(target)
        refresh_staged_times(incoming)
        os.rename(incoming, target)
        report.setdefault(component, {})["staged"] = "materialized"
    stamp_path.write_bytes(canonical({"schema": LAYOUT, "keys": keys, "fingerprint": current_fingerprint,
                                      "cache_root": str(cache_root)}))
    report["path"] = "keyed"
    report["keys"] = keys


def default_cache_root() -> Optional[Path]:
    value = os.environ.get("MACSCOPE_DEPENDENCY_CACHE_ROOT")
    return Path(value) if value else None


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    stage_command = commands.add_parser("stage", help="ensure cached archives and stage them for Xcode")
    stage_command.add_argument("--destination", type=Path, required=True)
    stage_command.add_argument("--cache-root", type=Path, default=default_cache_root())
    stage_command.add_argument("--report", type=Path)
    keys_command = commands.add_parser("keys", help="print each component's cache key and key inputs")
    keys_command.add_argument("--inputs", action="store_true")
    args = parser.parse_args(argv)
    started = time.monotonic()
    if args.command == "keys":
        toolchain = Toolchain()
        keys: Dict[str, str] = {}
        for component in ORDER:
            key, inputs = component_key(component, toolchain, keys)
            keys[component] = key
            print(json.dumps({"component": component, "key": key, **({"inputs": inputs} if args.inputs else {})},
                             sort_keys=True))
        return 0
    if args.cache_root is None:
        parser.error("--cache-root or MACSCOPE_DEPENDENCY_CACHE_ROOT is required")
    report: Dict[str, object] = {}
    stage(args.destination, args.cache_root, report)
    report["seconds"] = round(time.monotonic() - started, 3)
    if args.report:
        args.report.write_bytes(canonical(report))
    print(f"parser engines staged ({report['path']}) in {report['seconds']}s", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EngineBuildError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
