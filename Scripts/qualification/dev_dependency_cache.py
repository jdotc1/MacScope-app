#!/usr/bin/env python3
"""Developer-loop consumer of the shared verified dependency cache.

The qualifier content-addresses the Ghostty VT build, the Ghostty surface
package and the source-built SLEIGH materialization in one shared cache
(``Scripts/qualification/dependency_cache.py``). Before this helper existed,
bootstrap and the Xcode Ghostty VT phase ignored that cache and rebuilt every
component from scratch for each new worktree, DerivedData root or purged
``$TMPDIR`` slot (about ten minutes for SLEIGH plus the surface, and about a
minute of Zig per DerivedData for VT).

This helper gives the developer loop the qualifier's exact cache contract:

* the cache key is computed by ``dependency_cache.py key`` from the same
  component prefixes, values and platform/toolchain identity the qualifier
  uses (``COMPONENTS`` and ``platform_identity`` mirror
  the qualification entrypoint; a governance test compares the
  two). Source records come from the canonical Git blobs of ``HEAD`` for those
  prefixes, exactly as the sealed export records them, and only when the
  prefixes are clean in the index and work tree (otherwise the component is
  *unavailable* and the caller keeps its legacy local build);
* a miss builds once with the qualifier's builders, verifies, strips the same
  transient state and publishes an immutable entry through
  ``dependency_cache.py publish`` under the shared per-key lock;
* consumers receive a read-only view that ``dependency_cache.py materialize``
  fully re-hashed against the entry, that the component's domain verifier then
  accepted, and that is bound by a view receipt. The receipt binds the entry
  receipt digest, the entry and view lstat-metadata digests and the consumer
  descriptors, so an unchanged view is reused without re-hashing (R9.3) and any
  change forces a full re-verification.

The ``native-bridge`` component is developer-loop only (the qualifier does not
key it): it caches the path-free native decompiler bridge archive keyed by the
wrapper sources, the SLEIGH key and the toolchain, and is served only when the
consumer's SLEIGH materialization is the shared view that key binds.

Iteration only: views are never qualification, Release or Gate F evidence. The
qualifier keeps its own run-owned views, verification receipts and provenance.

Exit status: 0 resolved (contract lines on stdout), 3 unavailable (disabled,
no cache root, or dirty governed sources; the caller builds locally), 1 error
(fail closed: a cache entry or view failed verification).
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402

sys.dont_write_bytecode = True

SCRIPT_PATH = Path(__file__).resolve()
SCRIPTS = SCRIPT_PATH.parents[1]
VIEW_SCHEMA_VERSION = 1
MEMO_SCHEMA_VERSION = 1
UNAVAILABLE_STATUS = 3
# The owner's shared verified cache: the same root CI passes to the qualifier
# (.github/workflows/ci.yml MACSCOPE_DEPENDENCY_CACHE_ROOT).
DEFAULT_CACHE_ROOT = macscope_work_root() / "MacScopeQualificationCache-20260920"
DEFAULT_VIEW_ROOT = macscope_work_root() / "MacScopeDevLoop.noindex/dependency-views"
LFS_HEADER = b"version https://git-lfs.github.com/spec/v1"
LFS_POINTER = re.compile(
    rb"version https://git-lfs.github.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize ([1-9][0-9]*)\n"
)
MAX_LFS_POINTER_BYTES = 1024
LOCK_TIMEOUT_SECONDS = int(os.environ.get("MACSCOPE_DEPENDENCY_CACHE_LOCK_TIMEOUT_SECONDS", "900"))
LOCK_OWNER_GRACE_SECONDS = 60

# Mirrors the qualification entrypoint's platform identity.
PLATFORM_FILES = (
    ("xcode-version", "@XCODE_VERSION_PLIST@"),
    ("macos-sdk-settings", "@SDK_SETTINGS@"),
    ("clang", "@CLANG@"),
    ("system-version", "/System/Library/CoreServices/SystemVersion.plist"),
    ("xcrun", "/usr/bin/xcrun"),
    ("ar", "/usr/bin/ar"),
    ("strip", "/usr/bin/strip"),
    ("lipo", "/usr/bin/lipo"),
    ("codesign", "/usr/bin/codesign"),
    ("otool", "/usr/bin/otool"),
    ("nm", "/usr/bin/nm"),
    ("git", "/usr/bin/git"),
    ("python", "/usr/bin/python3"),
    ("plist-buddy", "/usr/libexec/PlistBuddy"),
)
NATIVE_TOOL_FILES = (
    ("cmake", "@CMAKE@"),
    ("ninja", "@NINJA@"),
    ("rsync", "/usr/bin/rsync"),
    ("git", "/usr/bin/git"),
    ("python", "/usr/bin/python3"),
)

# Mirrors the GHOSTTY_VT/GHOSTTY_SURFACE/SLEIGH cache keys of the qualifier.
# "@NAME@" values are substituted at key time.
COMPONENTS: dict[str, dict[str, Any]] = {
    "ghostty-vt": {
        "prefixes": (
            "ThirdParty/GhosttyVT",
            "ThirdParty/Zig",
            "Scripts/build_ghostty_vt.sh",
            "Scripts/ghostty-vt-source.contract",
            "Scripts/prepare_zig_macos_sdk_overlay.py",
            "Scripts/dependencies/zig_toolchain_receipt.py",
        ),
        "values": (
            ("architecture", "arm64"),
            ("payload-layout", "vt-artifacts-no-transient-v1"),
            ("simd", "@SIMD@"),
            ("platform-toolchain", "@PLATFORM@"),
        ),
        "view_name": "ghostty-vt",
    },
    "ghostty-surface": {
        "prefixes": (
            "ThirdParty/GhosttySurface",
            "ThirdParty/Zig",
            "Scripts/dependencies/build_vendored_ghostty_surface.sh",
            "Scripts/dependencies/build_ghostty_surface.sh",
            "Scripts/dependencies/zig_toolchain_receipt.py",
            "Scripts/ghostty-surface-source.contract",
            "Scripts/ghostty-vt-source.contract",
        ),
        "values": (
            ("architecture", "arm64"),
            ("configuration", "ReleaseFast"),
            ("payload-layout", "surface-source-package-artifact-no-zig-state-v1"),
            ("platform-toolchain", "@PLATFORM@"),
        ),
        "view_name": "GhosttySurface",
    },
    "sleigh-native-source": {
        "prefixes": (
            "ThirdParty/SleighNative",
            "Scripts/dependencies/build_vendored_sleigh_native_source.sh",
            "Scripts/dependencies/verify_vendored_sleigh_source.py",
            "Scripts/native-decompiler-direct/sleigh_package.py",
            "Scripts/native-decompiler-direct/verify_sleigh_package.py",
        ),
        "values": (
            ("architecture", "arm64"),
            ("configuration", "Release"),
            ("deployment-target", "27.0"),
            ("jobs", "@JOBS@"),
            ("payload-layout", "sleigh-materialization-and-source-receipt-v1"),
            ("platform-toolchain", "@PLATFORM@"),
            ("native-tools", "@NATIVE_TOOLS@"),
        ),
        "view_name": "SleighNativeSource",
    },
    # Developer-loop only (R11.2): the qualifier, Release and Gate F build the
    # bridge from source and never consume this entry. The key binds the native
    # wrapper source identity (native_decompiler_source_identity.py --profile
    # wrapper covers exactly these prefixes), the SLEIGH cache key it compiled
    # against, and the platform/native toolchain. The payload is path-free:
    # CMakeCache.txt and the link-inputs list are regenerated per consumer by
    # native_bridge_cache_payload.py and never enter the key or the entry.
    "native-bridge": {
        "prefixes": (
            "Tools/NativeDecompilerBridge",
            "Scripts/native-decompiler-xpc/build_native_bridge.sh",
            "Scripts/native-decompiler-xpc/native_decompiler_source_identity.py",
            "Scripts/native-decompiler-xpc/native_bridge_cache_payload.py",
            "Scripts/qualification/dev_dependency_cache.py",
            "Scripts/qualification/dependency_cache.py",
            "Scripts/native-decompiler-direct/verify_sleigh_package.py",
            "Scripts/native-decompiler-direct/sleigh_package.py",
        ),
        "values": (
            ("architecture", "arm64"),
            ("configuration", "Release"),
            ("deployment-target", "27.0"),
            ("payload-layout", "native-bridge-contract-archive-path-free-v1"),
            ("sleigh-native-source", "@SLEIGH_KEY@"),
            ("platform-toolchain", "@PLATFORM@"),
            ("native-tools", "@NATIVE_TOOLS@"),
        ),
        "view_name": "NativeDecompilerBridge",
        "qualifier": False,
    },
}
# Components whose key the qualifier also computes (governance parity test).
QUALIFIER_COMPONENTS = tuple(name for name, spec in COMPONENTS.items() if spec.get("qualifier", True))
SURFACE_TOOL_ENVIRONMENT = {
    "MACSCOPE_GIT": "/usr/bin/git",
    "MACSCOPE_LIPO": "/usr/bin/lipo",
    "MACSCOPE_NM": "/usr/bin/nm",
    "MACSCOPE_PLIST_BUDDY": "/usr/libexec/PlistBuddy",
    "MACSCOPE_PYTHON": "/usr/bin/python3",
}


class Unavailable(RuntimeError):
    """The shared cache cannot serve this component; build locally instead."""


class DevCacheError(RuntimeError):
    """A cache entry, view or input violated its contract; fail closed."""


def log(message: str) -> None:
    print(f"==> dev dependency cache: {message}", file=sys.stderr, flush=True)


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise DevCacheError(f"{path.name} is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CACHE = load_module("macscope_dependency_cache", SCRIPTS / "qualification" / "dependency_cache.py")


def canonical_json(value: object) -> bytes:
    return CACHE.canonical_json(value)


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def admit_owner_directory(path: Path, label: str, *, create: bool) -> Path:
    if not path.is_absolute():
        raise DevCacheError(f"{label} must be absolute")
    if create and not path.exists() and not path.is_symlink():
        path.mkdir(mode=0o700, parents=True)
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except FileNotFoundError as error:
        raise Unavailable(f"{label} does not exist: {path}") from error
    if (
        resolved != path
        or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o022
    ):
        raise DevCacheError(f"{label} must be a canonical, owner-controlled directory: {path}")
    return path


def roots(arguments: argparse.Namespace) -> tuple[Path, Path]:
    if os.environ.get("MACSCOPE_DEV_DEPENDENCY_CACHE", "1") == "0":
        raise Unavailable("disabled by MACSCOPE_DEV_DEPENDENCY_CACHE=0")
    cache_value = arguments.cache_root or os.environ.get("MACSCOPE_DEPENDENCY_CACHE_ROOT")
    cache_root = Path(cache_value) if cache_value else DEFAULT_CACHE_ROOT
    if not cache_value and not cache_root.is_dir():
        raise Unavailable(f"no shared dependency cache at {cache_root}")
    cache_root = admit_owner_directory(cache_root, "dependency cache root", create=False)
    view_value = arguments.view_root or os.environ.get("MACSCOPE_DEPENDENCY_VIEW_ROOT")
    view_root = Path(view_value) if view_value else DEFAULT_VIEW_ROOT
    if not any(part.endswith(".noindex") for part in view_root.parts):
        raise DevCacheError("dependency view root must lie under a .noindex directory")
    view_root = admit_owner_directory(view_root, "dependency view root", create=True)
    if cache_root == view_root or cache_root in view_root.parents or view_root in cache_root.parents:
        raise DevCacheError("dependency view root and cache root must be disjoint")
    return cache_root, view_root


# ── Key computation ──────────────────────────────────────────────────────────


def git(repository: Path, *arguments: str, stdin: bytes | None = None) -> bytes:
    environment = dict(os.environ)
    environment.update(
        GIT_NO_REPLACE_OBJECTS="1",
        GIT_NO_LAZY_FETCH="1",
        GIT_OPTIONAL_LOCKS="0",
        GIT_TERMINAL_PROMPT="0",
    )
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(repository), *arguments],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
    )
    if result.returncode != 0:
        raise DevCacheError(
            f"git {' '.join(arguments[:2])} failed: {result.stderr.decode(errors='replace').strip()}"
        )
    return result.stdout


def require_git_checkout(repository: Path) -> None:
    # The qualifier builds Debug from a Git-less sealed source export (with
    # MACSCOPE_DEBUG_SOURCE_IDENTITY=runtime-only); there is no HEAD to key
    # against, so the consumer must keep its local build path (status 3).
    if not (repository / ".git").exists():
        raise Unavailable("repository root is not a Git checkout (sealed source export)")


def require_clean(repository: Path, prefixes: tuple[str, ...]) -> None:
    status = git(
        repository,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignored=matching",
        "--ignore-submodules=none",
        "--",
        *prefixes,
    )
    if status:
        first = status.split(b"\0", 1)[0].decode(errors="replace")
        raise Unavailable(f"governed inputs differ from HEAD (first: {first!r})")


def tree_listing(repository: Path, prefixes: tuple[str, ...]) -> list[tuple[str, str, str]]:
    output = git(repository, "ls-tree", "-r", "-z", "--full-tree", "HEAD", "--", *prefixes)
    entries: list[tuple[str, str, str]] = []
    for raw in output.split(b"\0"):
        if not raw:
            continue
        metadata, _, path = raw.partition(b"\t")
        mode, kind, object_id = metadata.decode("ascii").split(" ")
        relative = path.decode("utf-8")
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise Unavailable(f"governed input is not an ordinary blob: {relative}")
        entries.append((relative, mode, object_id))
    return entries


def blob_records(repository: Path, entries: list[tuple[str, str, str]]) -> list[dict[str, object]]:
    """Canonical SOURCE_FILES records for the selected blobs (LFS-aware)."""
    process = subprocess.Popen(
        ["/usr/bin/git", "-C", str(repository), "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1"),
    )
    assert process.stdin is not None and process.stdout is not None
    records: list[dict[str, object]] = []
    try:
        for relative, mode, object_id in entries:
            process.stdin.write(object_id.encode("ascii") + b"\n")
            process.stdin.flush()
            header = process.stdout.readline(512).rstrip(b"\n").split(b" ")
            if len(header) != 3 or header[0].decode() != object_id or header[1] != b"blob":
                raise DevCacheError(f"git cat-file returned an unexpected object for {relative}")
            size = int(header[2])
            digest = hashlib.sha256()
            blob = hashlib.sha1(f"blob {size}\0".encode("ascii"))
            prefix = b""
            remaining = size
            while remaining:
                block = process.stdout.read(min(1024 * 1024, remaining))
                if not block:
                    raise DevCacheError("git cat-file truncated a blob")
                remaining -= len(block)
                if len(prefix) < MAX_LFS_POINTER_BYTES:
                    prefix += block[: MAX_LFS_POINTER_BYTES - len(prefix)]
                digest.update(block)
                blob.update(block)
            if process.stdout.read(1) != b"\n" or blob.hexdigest() != object_id:
                raise DevCacheError(f"canonical blob bytes do not match {object_id}")
            physical_digest, physical_size = digest.hexdigest(), size
            if prefix.startswith(LFS_HEADER):
                match = LFS_POINTER.fullmatch(prefix)
                if match is None or len(prefix) != size:
                    raise Unavailable(f"noncanonical LFS pointer: {relative}")
                physical_digest, physical_size = match.group(1).decode("ascii"), int(match.group(2))
            records.append(
                {
                    "blob_oid": object_id,
                    "mode": mode,
                    "path": relative,
                    "sha256": physical_digest,
                    "size": physical_size,
                }
            )
    finally:
        process.stdin.close()
        process.wait()
    records.sort(key=lambda record: os.fsencode(str(record["path"])))
    return records


def memo_path(view_root: Path, name: str) -> Path:
    directory = view_root / ".memo"
    directory.mkdir(mode=0o700, exist_ok=True)
    return directory / name


def read_memo(path: Path) -> Any:
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
            return None
        return json.loads(path.read_bytes())
    except (OSError, ValueError):
        return None


def write_memo(path: Path, value: object) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    temporary.write_bytes(canonical_json(value))
    temporary.chmod(0o600)
    os.replace(temporary, path)


def source_records(repository: Path, prefixes: tuple[str, ...], view_root: Path) -> list[dict[str, object]]:
    require_clean(repository, prefixes)
    entries = tree_listing(repository, prefixes)
    for prefix in prefixes:
        if not any(path == prefix or path.startswith(prefix + "/") for path, _, _ in entries):
            raise Unavailable(f"governed prefix has no tracked input: {prefix}")
    # Records are a pure function of the blob identities: memoize by listing.
    listing_digest = sha256_bytes(canonical_json([list(entry) for entry in entries]))
    memo = memo_path(view_root, f"records-{listing_digest}.json")
    cached = read_memo(memo)
    if (
        isinstance(cached, dict)
        and cached.get("schema_version") == MEMO_SCHEMA_VERSION
        and isinstance(cached.get("records"), list)
        and [(r.get("path"), r.get("mode"), r.get("blob_oid")) for r in cached["records"]]
        == sorted(entries, key=lambda entry: os.fsencode(entry[0]))
    ):
        return cached["records"]
    records = blob_records(repository, entries)
    write_memo(memo, {"records": records, "schema_version": MEMO_SCHEMA_VERSION})
    return records


def developer_dir() -> Path:
    value = os.environ.get("DEVELOPER_DIR") or subprocess.run(
        ["/usr/bin/xcode-select", "-p"], stdout=subprocess.PIPE, check=True, text=True
    ).stdout.strip()
    path = Path(value).resolve(strict=True)
    if not path.is_dir():
        raise DevCacheError("selected Xcode developer authority is not a directory")
    return path


def external_identity(files: list[tuple[str, str]], view_root: Path) -> str:
    """dependency_cache.py external-identity, memoized by each file's lstat identity."""
    observed = []
    for name, raw in files:
        resolved = Path(raw).resolve(strict=True)
        metadata = resolved.stat()
        observed.append(
            [name, str(resolved), metadata.st_dev, metadata.st_ino, metadata.st_size,
             metadata.st_mtime_ns, metadata.st_ctime_ns]
        )
    memo = memo_path(view_root, f"identity-{sha256_bytes(canonical_json(observed))}.json")
    cached = read_memo(memo)
    if isinstance(cached, dict) and cached.get("observed") == observed and isinstance(cached.get("identity"), str):
        return cached["identity"]
    external = [CACHE.external_file_identity(f"{name}={raw}") for name, raw in files]
    external.sort(key=lambda item: str(item["name"]))
    identity = sha256_bytes(canonical_json(external))
    write_memo(memo, {"identity": identity, "observed": observed})
    return identity


def which(tool: str) -> str:
    found = shutil.which(tool)
    if not found:
        raise Unavailable(f"{tool} is required for this component's cache identity")
    return found


def platform_identity(view_root: Path) -> str:
    developer = developer_dir()
    substitutions = {
        "@XCODE_VERSION_PLIST@": str(developer.parent / "version.plist"),
        "@SDK_SETTINGS@": str(
            developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist"
        ),
        "@CLANG@": str(developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"),
    }
    files = [(name, substitutions.get(raw, raw)) for name, raw in PLATFORM_FILES]
    return external_identity(files, view_root)


def native_tools_identity(view_root: Path) -> str:
    substitutions = {"@CMAKE@": which("cmake"), "@NINJA@": which("ninja")}
    files = [(name, substitutions.get(raw, raw)) for name, raw in NATIVE_TOOL_FILES]
    return external_identity(files, view_root)


def component_key(component: str, repository: Path, view_root: Path) -> str:
    spec = COMPONENTS[component]
    records = source_records(repository, spec["prefixes"], view_root)
    substitutions: dict[str, Callable[[], str]] = {
        "@PLATFORM@": lambda: platform_identity(view_root),
        "@NATIVE_TOOLS@": lambda: native_tools_identity(view_root),
        "@SIMD@": lambda: os.environ.get("MACSCOPE_GHOSTTY_SIMD") or "false",
        "@JOBS@": lambda: os.environ.get("MACSCOPE_NATIVE_SOURCE_JOBS") or "8",
        "@SLEIGH_KEY@": lambda: component_key("sleigh-native-source", repository, view_root),
    }
    values = [
        f"{name}={substitutions[value]() if value in substitutions else value}"
        for name, value in spec["values"]
    ]
    with tempfile.TemporaryDirectory(prefix=".key-", dir=memo_path(view_root, "x").parent) as scratch:
        manifest = Path(scratch) / "SOURCE_FILES.json"
        manifest.write_bytes(canonical_json({"files": records, "schema_version": 2}))
        arguments = argparse.Namespace(
            source_files=manifest,
            component=component,
            prefix=list(spec["prefixes"]),
            value=values,
            external_file=[],
        )
        # Not key_command under redirect_stdout: that swaps the process-wide
        # sys.stdout, and the native stager admits source and staged copy in
        # two threads, so concurrent keys were lost ("key is malformed").
        key = CACHE.compute_key(arguments)
    if CACHE.HEX64.fullmatch(key) is None:
        raise DevCacheError("dependency cache key is malformed")
    return key


# ── Builders and domain verifiers (mirroring the qualifier callbacks) ────────


def run_tool(command: list[str], *, extra_environment: dict[str, str] | None = None) -> str:
    environment = dict(os.environ)
    environment.update(extra_environment or {})
    result = subprocess.run(command, stdout=subprocess.PIPE, env=environment, check=False, text=True)
    if result.returncode != 0:
        # A failed producer stays diagnosable: show its captured stdout (the
        # build and CTest log). Its stderr is not captured and already streamed.
        if result.stdout:
            print(result.stdout, end="" if result.stdout.endswith("\n") else "\n", file=sys.stderr)
        raise DevCacheError(f"{Path(command[0]).name} failed with exit {result.returncode}")
    return result.stdout


def remove_tree(path: Path) -> None:
    if path.is_symlink():
        path.unlink()
        return
    if not path.exists():
        return
    for item in [path, *path.rglob("*")]:
        try:
            if not item.is_symlink():
                item.chmod(0o700 if item.is_dir() else 0o600)
        except OSError:
            pass
    shutil.rmtree(path)


def native_bridge_payload_tool(repository: Path, *arguments: str) -> None:
    run_tool(["/usr/bin/python3", "-B",
              str(repository / "Scripts/native-decompiler-xpc/native_bridge_cache_payload.py"), *arguments])


def verify_view(component: str, repository: Path, view: Path, materialization: Path | None = None) -> None:
    scripts = repository / "Scripts"
    if component == "native-bridge":
        if materialization is None:
            raise DevCacheError("native-bridge verification requires the SLEIGH materialization root")
        native_bridge_payload_tool(repository, "verify", "--repository-root", str(repository),
                                   "--materialization-root", str(materialization), "--payload", str(view))
        return
    if component == "ghostty-vt":
        output = run_tool([str(scripts / "build_ghostty_vt.sh"), "--work-root", str(view), "--verify-only"])
        print(output, end="", file=sys.stderr)
        return
    if component == "ghostty-surface":
        # The cache view is a frozen copy of the producer output. Its .git
        # directory retains only the vendored-input identity, so the producer's
        # --verify-only mode (which needs Git HEAD) cannot verify this view.
        # materialize_command checks every copied byte against the immutable
        # entry; descriptors() then admits the actual consumed artifact leaves
        # and binds their digest to VIEW.json before this view is published.
        return
    output = run_tool(
        [str(scripts / "dependencies/build_vendored_sleigh_native_source.sh"),
         "--work-root", str(view.parent)]
    )
    expected = (
        f"MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT={view}\n"
        f"MACSCOPE_SLEIGH_MATERIALIZATION_ROOT={view}/materialization\n"
    )
    if output != expected:
        raise DevCacheError(f"{component} verifier returned an unexpected output contract")


def build_payload(component: str, repository: Path, temporary: Path, materialization: Path | None = None) -> Path:
    scripts = repository / "Scripts"
    if component == "native-bridge":
        if materialization is None:
            raise DevCacheError("native-bridge build requires the SLEIGH materialization root")
        build_root = temporary / "build"
        revision = run_tool(
            ["/usr/bin/python3", "-B", str(scripts / "native-decompiler-xpc/native_decompiler_source_identity.py"),
             "--repository-root", str(repository), "--profile", "wrapper"]
        ).strip()
        output = run_tool(
            [str(scripts / "native-decompiler-xpc/build_native_bridge.sh"),
             "--source-root", str(repository / "Tools/NativeDecompilerBridge"),
             "--build-root", str(build_root),
             "--materialization-root", str(materialization),
             "--wrapper-revision", revision,
             "--configuration", "Release"]
        )
        print(output, end="", file=sys.stderr)
        payload = temporary / "payload"
        native_bridge_payload_tool(repository, "extract", "--repository-root", str(repository),
                                   "--materialization-root", str(materialization),
                                   "--build-root", str(build_root), "--payload", str(payload))
        # The payload omits the build root, so carry the CTest log out before
        # it is removed; resolve() keeps it beside the published entry.
        test_log = build_root / "Testing/Temporary/LastTest.log"
        if test_log.is_file():
            (temporary / "test-log").mkdir()
            shutil.copy2(test_log, temporary / "test-log/LastTest.log")
        remove_tree(build_root)
        return payload
    if component == "ghostty-vt":
        payload = temporary / "payload"
        payload.mkdir()
        output = run_tool([str(scripts / "build_ghostty_vt.sh"), "--work-root", str(payload)])
        print(output, end="", file=sys.stderr)
        verify_view(component, repository, payload)
        for transient in ("cache", "global-cache", "sdk-compatibility"):
            if (payload / transient).is_dir() and not (payload / transient).is_symlink():
                remove_tree(payload / transient)
        (payload / "cache").mkdir()
        (payload / "global-cache").mkdir()
        return payload
    work = temporary / "work"
    work.mkdir()
    if component == "ghostty-surface":
        payload = work / "GhosttySurface"
        output = run_tool(
            [str(scripts / "dependencies/build_vendored_ghostty_surface.sh"), "--work-root", str(work)],
            extra_environment=SURFACE_TOOL_ENVIRONMENT,
        )
        expected = (
            f"GHOSTTY_SURFACE_SOURCE_DIR={payload}\n"
            f"GHOSTTY_SURFACE_ARTIFACT_ROOT={payload}/macos/GhosttyKit.xcframework\n"
        )
        if output != expected:
            raise DevCacheError("Ghostty surface producer returned an unexpected output contract")
        verify_view(component, repository, payload)
        transients = (".zig-cache", "zig-out")
    else:
        payload = work / "SleighNativeSource"
        output = run_tool(
            [str(scripts / "dependencies/build_vendored_sleigh_native_source.sh"), "--work-root", str(work)]
        )
        expected = (
            f"MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT={payload}\n"
            f"MACSCOPE_SLEIGH_MATERIALIZATION_ROOT={payload}/materialization\n"
        )
        if output != expected:
            raise DevCacheError("native SLEIGH producer returned an unexpected output contract")
        verify_view(component, repository, payload)
        transients = ("source", "build")
    for transient in transients:
        if (payload / transient).is_dir() and not (payload / transient).is_symlink():
            remove_tree(payload / transient)
    return payload


# Metadata publication/reclaim/release share a stable kernel lock. Never unlink
# these guard files: replacing one would split contenders between two inodes.
@contextlib.contextmanager
def entry_lock_guard(path: Path, *, blocking: bool = False):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise DevCacheError(f"dependency cache lock guard is not a regular file: {path}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def process_start_identity(pid: int) -> str | None:
    """Darwin's ps lstart field, in a fixed locale; uncertainty is not death."""
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"}, capture_output=True, text=True, timeout=5,
        )
        lines = result.stdout.strip().splitlines()
        if result.returncode != 0 or len(lines) != 1:
            return None
        identity = " ".join(lines[0].split())
        datetime.strptime(identity, "%a %b %d %H:%M:%S %Y")
        return identity
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def read_lock_owner(lock: Path) -> dict[str, str] | None:
    """None means unreadable/ambiguous; {} means absent, empty or partial."""
    try:
        descriptor = os.open(lock / "owner", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 4096:
                return None
            text = stream.read(4097)
            if len(text) > 4096:
                return None
    except FileNotFoundError:
        return {}
    except (OSError, UnicodeError):
        return None
    fields = {}
    for line in text.splitlines():
        if "=" not in line:
            return None
        name, value = line.split("=", 1)
        if name in fields or name not in {"pid", "hostname", "start", "token", "component", "key"}:
            return None
        fields[name] = value
    return fields


def lock_reclaim_reason(lock: Path, hostname: str) -> str | None:
    """Called only with the stable guard held; never infer death from an error."""
    try:
        metadata = lock.lstat()
    except OSError:
        return None
    if not stat.S_ISDIR(metadata.st_mode):
        return None
    owner = read_lock_owner(lock)
    if owner is None:
        return None
    # A named foreign host vetoes even an old, partial or dead-pid record.
    if owner.get("hostname") not in (None, hostname):
        return None
    raw_pid = owner.get("pid")
    if raw_pid is None:
        # 60 seconds is much longer than an owner-file write. Publication is
        # additionally fenced by the guard, so even a paused writer is safe.
        if time.time() - metadata.st_mtime >= LOCK_OWNER_GRACE_SECONDS:
            return "owner-less lock past grace period"
        return None
    if not raw_pid.isdecimal() or int(raw_pid) <= 0:
        return None
    pid = int(raw_pid)
    # Ruling 350: legacy pid/component/key records belong to this host because
    # the admitted cache is a per-user LOCAL root, never a network/shared root.
    # Filesystem admission enforces ownership/canonicality, not locality itself.
    legacy = "hostname" not in owner and set(owner) <= {"pid", "component", "key"}
    if owner.get("hostname") != hostname and not legacy:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return f"dead pid {pid}"
    except (OSError, OverflowError):
        return None
    current_start = process_start_identity(pid)
    if current_start is None or current_start != owner.get("start"):
        # A reused pid is distinguishable, but still live: conservatively wait.
        return None
    return None


def release_entry_lock(lock: Path, guard: Path, token: str, identity: tuple[int, int]) -> None:
    """A former owner cannot unlink a replacement, even after an ABA rename."""
    waited = 0
    while True:
        try:
            with entry_lock_guard(guard) as guarded:
                if guarded:
                    try:
                        metadata = lock.lstat()
                    except FileNotFoundError:
                        return
                    if (metadata.st_dev, metadata.st_ino) != identity or not stat.S_ISDIR(metadata.st_mode):
                        return
                    owner = read_lock_owner(lock)
                    if owner is None or owner.get("token") != token:
                        return
                    (lock / "owner").unlink()
                    lock.rmdir()
                    return
        except (OSError, DevCacheError) as error:
            # Never hide a build failure or remove a lock without its fence.
            log(f"leaving dependency cache lock {lock}: release failed: {error}")
            return
        if waited >= LOCK_TIMEOUT_SECONDS:
            log(f"leaving dependency cache lock {lock}: release guard timed out")
            return
        time.sleep(1)
        waited += 1


def ensure_entry(
    component: str, key: str, repository: Path, cache_root: Path, build: bool, materialization: Path | None = None
) -> tuple[Path, str]:
    entry = cache_root / "artifacts/v1" / component / key
    if entry.exists() or entry.is_symlink():
        return entry, "verified-hit"
    if not build:
        raise Unavailable(f"{component} {key} is not in the shared cache")
    cache_root = admit_owner_directory(cache_root, "dependency cache root", create=False)
    lock_parent = cache_root / "locks/v1" / component
    lock_parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = lock_parent / f"{key}.lock"
    guard = cache_root / "lock-guards/v1" / component / f"{key}.guard"
    token = uuid.uuid4().hex
    hostname = socket.gethostname()
    waited = 0
    while True:
        acquired = False
        start_identity = process_start_identity(os.getpid())
        if start_identity is None:
            raise DevCacheError(
                f"/bin/ps failed to establish the current process start identity (pid {os.getpid()}); "
                "cannot safely acquire a dependency cache lock"
            )
        owner_text = (f"pid={os.getpid()}\nhostname={hostname}\nstart={start_identity}\n"
                      f"token={token}\ncomponent={component}\nkey={key}\n")
        with entry_lock_guard(guard) as guarded:
            if guarded and hostname:
                try:
                    lock.mkdir()
                except FileExistsError:
                    if entry.exists() or entry.is_symlink():
                        return entry, "verified-after-wait"
                    reason = lock_reclaim_reason(lock, hostname)
                    if reason is not None:
                        retired = lock_parent / f"{key}.retired-{uuid.uuid4().hex}"
                        lock.rename(retired)
                        log(f"reclaiming dependency cache lock {lock}: {reason}")
                        remove_tree(retired)
                        try:
                            lock.mkdir()
                        except FileExistsError:
                            # Older checkouts do not take the guard and can win
                            # this gap. Their lock is not ours: wait, never remove it.
                            pass
                        else:
                            acquired = True
                    else:
                        # Keep the existing polling/timeout contract below.
                        pass
                else:
                    acquired = True
                if acquired:
                    metadata = lock.stat()
                    identity = (metadata.st_dev, metadata.st_ino)
                    try:
                        (lock / "owner").write_text(owner_text, encoding="utf-8")
                    except BaseException:
                        # No successor can enter while this guard is held.
                        (lock / "owner").unlink(missing_ok=True)
                        lock.rmdir()
                        raise
        if acquired:
            break
        if entry.exists() or entry.is_symlink():
            return entry, "verified-after-wait"
        if waited >= LOCK_TIMEOUT_SECONDS:
            raise DevCacheError(f"timed out waiting for dependency cache lock: {lock}")
        time.sleep(1)
        waited += 1
    temporary = None
    try:
        if entry.exists() or entry.is_symlink():
            return entry, "verified-after-wait"
        temporary_parent = cache_root / "temporary/v1" / component
        temporary_parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = Path(tempfile.mkdtemp(prefix=f"{key}.", dir=temporary_parent))
        log(f"{component} {key[:12]}: miss; building once from the governed sources")
        started = time.monotonic()
        payload = (build_payload(component, repository, temporary) if materialization is None
                   else build_payload(component, repository, temporary, materialization))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            CACHE.publish_command(
                argparse.Namespace(entry=entry, component=component, key=key, payload=payload)
            )
        log(f"{component} {key[:12]}: published in {time.monotonic() - started:.1f}s")
        # Keep the passing build's test log; only the newest per component key.
        if (temporary / "test-log").is_dir():
            kept = cache_root / "test-logs/v1" / component / key
            kept.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if kept.exists() or kept.is_symlink():
                remove_tree(kept)
            (temporary / "test-log").rename(kept)
            log(f"{component} {key[:12]}: test log kept at {kept}")
        return entry, "published-miss"
    except Exception:
        # Keep the failed build root (e.g. Testing/Temporary/LastTest.log) for
        # diagnosis; only the newest failure per component key is retained.
        if temporary is not None and temporary.exists():
            kept = cache_root / "failed/v1" / component / key
            kept.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if kept.exists() or kept.is_symlink():
                remove_tree(kept)
            temporary.rename(kept)
            temporary = None
            log(f"{component} {key[:12]}: failed build kept at {kept}")
        raise
    finally:
        if temporary is not None and temporary.exists():
            remove_tree(temporary)
        release_entry_lock(lock, guard, token, identity)


# ── Views ─────────────────────────────────────────────────────────────────────


def descriptors(component: str, repository: Path, view: Path, directory: Path) -> dict[str, dict[str, str]]:
    scripts = repository / "Scripts"
    if component == "ghostty-vt":
        path = directory / "ghostty-vt-staging.json"
        digest = run_tool(
            ["/usr/bin/python3", "-B", str(scripts / "dependencies/stage_verified_ghostty_vt.py"),
             "--describe", "--artifact-root", str(view / "artifacts"), "--descriptor", str(path)]
        ).strip()
    elif component == "ghostty-surface":
        path = directory / "ghostty-surface-admission.json"
        digest = run_tool(
            ["/usr/bin/python3", "-B", str(scripts / "dependencies/verified_ghostty_surface_admission.py"),
             "--describe", "--source-root", str(view), "--descriptor", str(path)]
        ).strip()
    else:
        return {}
    if CACHE.HEX64.fullmatch(digest) is None or sha256_bytes(path.read_bytes()) != digest:
        raise DevCacheError(f"{component} consumer descriptor identity is malformed")
    return {"consumer": {"path": str(path), "sha256": digest}}


def view_receipt_valid(receipt: Path, entry: Path, view: Path, component: str, key: str) -> dict[str, Any] | None:
    """Admit a persisted view receipt on content identity only.

    The receipt binds the ENTRY.json SHA-256 (every payload path, kind, size
    and content digest) and the consumer descriptor digests. Across runs the
    read-only view is compared structurally (paths, kinds, sizes, executable
    bits, symlink targets; no rehash) with ENTRY.json. The recorded
    entry/view metadata digests are historical and never compared, so a
    reboot, copy or touch does not force a re-verification.
    """
    value = read_memo(receipt)
    if not isinstance(value, dict) or value.get("schema_version") != VIEW_SCHEMA_VERSION:
        return None
    try:
        manifest = CACHE.read_canonical_json(entry / "ENTRY.json", "cache entry receipt")
        expected = [
            {name: field for name, field in record.items() if name != "sha256"}
            for record in manifest["payload_records"]
        ]
        observed, observed_bytes = CACHE.payload_records(view, hash_files=False, allow_hardlinks=True)
        checks = (
            value.get("component") == component,
            value.get("key") == key,
            value.get("entry") == str(entry),
            value.get("view") == str(view),
            value.get("entry_receipt_sha256") == CACHE.sha256(entry / "ENTRY.json"),
            observed == expected,
            observed_bytes == manifest["total_bytes"],
            all(path.lstat().st_mode & 0o222 == 0
                for path in [view, *view.rglob("*")] if not path.is_symlink()),
            all(
                isinstance(item, dict) and CACHE.sha256(Path(item["path"])) == item["sha256"]
                for item in value.get("descriptors", {}).values()
            ),
            receipt.stat().st_mode & 0o222 == 0,
        )
    except (OSError, KeyError, TypeError, ValueError, CACHE.CacheError):
        return None
    return value if all(checks) else None


def native_bridge_materialization(
    repository: Path, cache_root: Path, view_root: Path, requested: str | None
) -> Path:
    """The SLEIGH view the bridge key binds; it must be the consumer's materialization."""
    if not requested:
        raise Unavailable("native-bridge needs --materialization-root (the consumer's SLEIGH materialization)")
    sleigh = resolve("sleigh-native-source", repository, cache_root, view_root, build=False)
    materialization = (sleigh["view"] / "materialization").resolve(strict=True)
    if Path(requested).resolve(strict=True) != materialization:
        raise Unavailable("the consumer's SLEIGH materialization is not the shared cache view the key binds")
    return materialization


def reused_sleigh_materialization(
    repository: Path, requested: Path, cache_root: Path | None = None, view_root: Path | None = None,
) -> dict[str, Any]:
    """Admit only an already domain-verified SLEIGH view; never repair or rehash it.

    ENTRY supplies the content digests. VIEW binds that exact ENTRY digest and
    the consumer descriptors observed when the domain verifier passed; the view
    must still match ENTRY structurally (no filesystem metadata across runs).
    A missing receipt or changed identity is an error, not permission to verify
    the unchanged dependency again or silently fall back to a weaker path.
    """
    if cache_root is None or view_root is None:
        cache_root, view_root = roots(argparse.Namespace(cache_root=None, view_root=None))
    component = "sleigh-native-source"
    key = component_key(component, repository, view_root)
    entry = cache_root / "artifacts/v1" / component / key
    directory = view_root / component / key
    view = directory / COMPONENTS[component]["view_name"]
    materialization = view / "materialization"
    if Path(requested) != materialization or materialization.resolve(strict=True) != materialization:
        raise DevCacheError("SLEIGH consumer does not name the receipt-bound shared view")
    receipt = directory / "VIEW.json"
    accepted = view_receipt_valid(receipt, entry, view, component, key)
    if accepted is None:
        raise DevCacheError("SLEIGH verification receipt is missing or stale; reuse is required")
    manifest = CACHE.load_entry_receipt(entry, component, key)
    files = {}
    for record in manifest["payload_records"]:
        relative = record.get("path", "")
        if not relative.startswith("materialization/") or record.get("kind") == "directory":
            continue
        if (record.get("kind") != "file" or not isinstance(record.get("size"), int)
                or record["size"] < 0 or not isinstance(record.get("sha256"), str)
                or CACHE.HEX64.fullmatch(record["sha256"]) is None):
            raise DevCacheError("SLEIGH entry contains an invalid materialization file identity")
        relative = relative.removeprefix("materialization/")
        if relative in files:
            raise DevCacheError("SLEIGH entry contains duplicate materialization files")
        files[relative] = (record["size"], record["sha256"])
    if "MATERIALIZATION.json" not in files or not any(name.startswith("package/") for name in files):
        raise DevCacheError("SLEIGH entry omits the materialization identity")
    identity = json.loads((materialization / "MATERIALIZATION.json").read_text(encoding="utf-8"))
    if view_receipt_valid(receipt, entry, view, component, key) != accepted:
        raise DevCacheError("SLEIGH view changed while admitting its verified identity")
    log(f"sleigh-native-source {key[:12]}: verification receipt reused")
    return {"key": key, "identity": identity, "files": files, "receipt": str(receipt),
            "manifest_sha256": files["MATERIALIZATION.json"][1]}


def resolve(
    component: str, repository: Path, cache_root: Path, view_root: Path, build: bool,
    requested_materialization: str | None = None,
) -> dict[str, Any]:
    started = time.monotonic()
    materialization = None
    if component == "native-bridge":
        materialization = native_bridge_materialization(repository, cache_root, view_root, requested_materialization)
    key = component_key(component, repository, view_root)
    entry, entry_status = ensure_entry(component, key, repository, cache_root, build, materialization)
    component_root = view_root / component
    component_root.mkdir(mode=0o700, exist_ok=True)
    directory = component_root / key
    view = directory / COMPONENTS[component]["view_name"]
    receipt = directory / "VIEW.json"
    lock_descriptor = os.open(component_root / f".{key}.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        value = view_receipt_valid(receipt, entry, view, component, key)
        if value is not None:
            status = "view-reused"
        else:
            if directory.exists() or directory.is_symlink():
                remove_tree(directory)
            directory.mkdir(mode=0o700)
            before = CACHE.entry_metadata_digest(entry)
            # Full SHA-256 of the immutable entry and of the new read-only view.
            CACHE.materialize_command(
                argparse.Namespace(entry=entry, component=component, key=key,
                                   destination=view, snapshot_output=None)
            )
            if materialization is None:
                verify_view(component, repository, view)
            else:
                verify_view(component, repository, view, materialization)
            described = descriptors(component, repository, view, directory)
            if CACHE.entry_metadata_digest(entry) != before:
                raise DevCacheError("cache entry metadata changed during view verification")
            value = {
                "component": component,
                "descriptors": described,
                "entry": str(entry),
                "entry_metadata_sha256": before,
                "entry_receipt_sha256": CACHE.sha256(entry / "ENTRY.json"),
                "entry_status": entry_status,
                "key": key,
                "schema_version": VIEW_SCHEMA_VERSION,
                "verification": "dependency_cache.py materialize (full SHA-256 of entry and view) + domain verifier",
                "verified_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "view": str(view),
                "view_metadata_sha256": CACHE.entry_metadata_digest(view),
            }
            temporary = directory / f".VIEW.json.{os.getpid()}"
            temporary.write_bytes(canonical_json(value))
            temporary.chmod(0o444)
            os.replace(temporary, receipt)
            status = "view-verified" if entry_status == "verified-hit" else entry_status
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)
    log(f"{component} {key[:12]}: {status} in {time.monotonic() - started:.1f}s ({view})")
    return {"key": key, "status": status, "view": view, "receipt": value}


def contract(component: str, resolved: dict[str, Any]) -> list[str]:
    view: Path = resolved["view"]
    lines = [f"MACSCOPE_DEV_DEPENDENCY_KEY={resolved['key']}"]
    consumer = resolved["receipt"].get("descriptors", {}).get("consumer")
    if component == "ghostty-vt":
        lines += [
            f"MACSCOPE_GHOSTTY_VT_VERIFIED_ARTIFACT_ROOT={view}/artifacts",
            f"MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR={consumer['path']}",
            f"MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR_SHA256={consumer['sha256']}",
        ]
    elif component == "native-bridge":
        lines += [f"MACSCOPE_NATIVE_DECOMPILER_CACHED_VIEW={view}"]
    elif component == "ghostty-surface":
        lines += [
            f"MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT={view.parent}",
            f"MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR={consumer['path']}",
            f"MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256={consumer['sha256']}",
        ]
    else:
        lines += [
            f"MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT={view}",
            f"MACSCOPE_SLEIGH_MATERIALIZATION_ROOT={view}/materialization",
        ]
    for line in lines:
        if any(character in line for character in '"$\n') or "//" in line.partition("=")[2]:
            raise DevCacheError(f"dependency view path is not representable: {line}")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("key", "resolve"):
        command = commands.add_parser(name)
        command.add_argument("--component", choices=sorted(COMPONENTS), required=True)
        command.add_argument("--repository-root", type=Path, default=SCRIPTS.parent)
        command.add_argument("--cache-root")
        command.add_argument("--view-root")
        if name == "resolve":
            command.add_argument("--no-build", action="store_true",
                                 help="report unavailable on a cache miss instead of building once")
            command.add_argument("--materialization-root",
                                 help="native-bridge only: the consumer's SLEIGH materialization root")
    reuse = commands.add_parser("reuse-sleigh")
    reuse.add_argument("--repository-root", type=Path, default=SCRIPTS.parent)
    reuse.add_argument("--cache-root")
    reuse.add_argument("--view-root")
    reuse.add_argument("--materialization-root", type=Path, required=True)
    reuse.add_argument("--expected-sanitizer", choices=("none",), default="none")
    reuse.add_argument("--output-json", action="store_true")
    reuse.set_defaults(component="sleigh-native-source")
    arguments = parser.parse_args()
    repository = arguments.repository_root.resolve(strict=True)
    try:
        require_git_checkout(repository)
        cache_root, view_root = roots(arguments)
        if arguments.command == "reuse-sleigh":
            accepted = reused_sleigh_materialization(repository, arguments.materialization_root, cache_root, view_root)
            if arguments.output_json:
                print(json.dumps({"identity": accepted["identity"], "manifest_sha256": accepted["manifest_sha256"]},
                                 sort_keys=True, separators=(",", ":")))
            return 0
        if arguments.command == "key":
            print(component_key(arguments.component, repository, view_root))
            return 0
        # A focused native Debug iteration uses its retained CMake products on
        # a miss. Never launch the cache producer's cold build/full CTest here.
        build_on_miss = not arguments.no_build
        if arguments.component == "native-bridge" and os.environ.get("MACSCOPE_NATIVE_DEV_BUILD_ONLY") == "1":
            build_on_miss = False
        resolved = resolve(arguments.component, repository, cache_root, view_root, build_on_miss,
                           arguments.materialization_root)
        print("\n".join(contract(arguments.component, resolved)))
        return 0
    except Unavailable as error:
        log(f"{arguments.component} unavailable ({error}); using the local build path")
        return UNAVAILABLE_STATUS
    except (DevCacheError, CACHE.CacheError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"ERROR: dev dependency cache: {arguments.component}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
