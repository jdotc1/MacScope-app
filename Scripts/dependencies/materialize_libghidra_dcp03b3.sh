#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="${1:-${ROOT}/libghidra-dcp03b3}"
BOOTSTRAP_PYTHON="${MACSCOPE_DCP03B3_BOOTSTRAP_PYTHON:-python3}"
VERSION="0.0.2"
GIT_REVISION="61b37fa2d99aa5cf0da450b84f2abd797fb6a27c"
SERVICE_NAME="local-decompiler"
SERVICE_VERSION="1.0.0"
RELEASE_BASE="https://github.com/0xeb/libghidra/releases/download/v0.0.2"

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    PLATFORM="macosx_15_0_arm64"
    WHEEL="libghidra-0.0.2-cp312-abi3-macosx_15_0_arm64.whl"
    WHEEL_SHA256="c96f2266c66d16302b917ce2645d5ba08ca90bac30f44d957a7e16ad40d40fee"
    ;;
  Linux:x86_64)
    PLATFORM="manylinux_2_28_x86_64"
    WHEEL="libghidra-0.0.2-cp312-abi3-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"
    WHEEL_SHA256="aeb32952ad1ba30f87d480c3ab56eb0346f199470c2584ebe67e05d03d4e6c78"
    ;;
  *)
    echo "unsupported DCP-03B3 materialization host: $(uname -s) $(uname -m)" >&2
    exit 2
    ;;
esac
WHEEL_URL="${RELEASE_BASE}/${WHEEL}"

"${BOOTSTRAP_PYTHON}" - <<'PY'
import sys
if sys.implementation.name != "cpython" or sys.version_info[:2] != (3, 13):
    raise SystemExit("DCP-03B3 materialization requires CPython 3.13 exactly")
PY

if [[ -e "${DESTINATION}" || -L "${DESTINATION}" ]]; then
  echo "destination already exists; remove it explicitly before rematerializing: ${DESTINATION}" >&2
  exit 2
fi
PARENT="$(dirname "${DESTINATION}")"
mkdir -p "${PARENT}"
WORK="$(mktemp -d "${PARENT}/.libghidra-dcp03b3.XXXXXX")"
STAGED="${WORK}/environment"
DOWNLOAD="${WORK}/${WHEEL}"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

/usr/bin/curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --retry 3 \
  --output "${DOWNLOAD}" \
  "${WHEEL_URL}"

ACTUAL_SHA256="$("${BOOTSTRAP_PYTHON}" - "${DOWNLOAD}" <<'PY'
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
with path.open("rb") as stream:
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"
if [[ "${ACTUAL_SHA256}" != "${WHEEL_SHA256}" ]]; then
  echo "libghidra wheel checksum mismatch" >&2
  echo "expected: ${WHEEL_SHA256}" >&2
  echo "observed: ${ACTUAL_SHA256}" >&2
  exit 3
fi

"${BOOTSTRAP_PYTHON}" -m venv "${STAGED}"
mkdir -m 0700 -p "${STAGED}/vendor"
"${STAGED}/bin/python3" - "${DOWNLOAD}" "${STAGED}/vendor" <<'PY'
"""Extract an approved wheel without following links or trusting archive paths."""
from __future__ import annotations

import os
import pathlib
import shutil
import stat
import sys
import zipfile

wheel = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
root = destination.resolve(strict=True)

MAX_MEMBERS = 20_000
MAX_TOTAL_UNCOMPRESSED = 1024 * 1024 * 1024
MAX_SINGLE_FILE = 512 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
MAX_PATH_BYTES = 4096
COPY_CHUNK = 1024 * 1024


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"unsafe libghidra wheel: {message}")


def normalized_parts(name: str) -> tuple[str, ...]:
    if not name or "\x00" in name or len(name.encode("utf-8")) > MAX_PATH_BYTES:
        fail("invalid member name")
    candidate = pathlib.PurePosixPath(name)
    if candidate.is_absolute() or any(part in {"", ".", ".."} for part in candidate.parts):
        fail("member path escapes extraction root")
    if "\\" in name or ":" in candidate.parts[0]:
        fail("member path uses a non-portable form")
    return candidate.parts


def ordinary_mode(info: zipfile.ZipInfo) -> int:
    mode = (info.external_attr >> 16) & 0xFFFF
    kind = stat.S_IFMT(mode)
    if kind not in {0, stat.S_IFREG, stat.S_IFDIR}:
        fail("member is not an ordinary file or directory")
    if info.is_dir() or info.filename.endswith("/"):
        return 0o755
    executable = bool(mode & 0o111)
    return 0o755 if executable else 0o644


with zipfile.ZipFile(wheel) as archive:
    members = archive.infolist()
    if not members or len(members) > MAX_MEMBERS:
        fail("member count exceeds the fixed bound")

    seen: set[tuple[str, ...]] = set()
    total = 0
    planned: list[tuple[zipfile.ZipInfo, tuple[str, ...], int]] = []
    for info in members:
        if info.flag_bits & 0x1:
            fail("encrypted members are not allowed")
        parts = normalized_parts(info.filename.rstrip("/"))
        if parts in seen:
            fail("duplicate member path")
        seen.add(parts)
        if info.file_size < 0 or info.compress_size < 0 or info.file_size > MAX_SINGLE_FILE:
            fail("member size exceeds the fixed bound")
        total += info.file_size
        if total > MAX_TOTAL_UNCOMPRESSED:
            fail("uncompressed archive size exceeds the fixed bound")
        if info.file_size and (info.compress_size == 0 or info.file_size > info.compress_size * MAX_COMPRESSION_RATIO):
            fail("member compression ratio exceeds the fixed bound")
        planned.append((info, parts, ordinary_mode(info)))

    for info, parts, mode in planned:
        target = root.joinpath(*parts)
        try:
            target.relative_to(root)
        except ValueError:
            fail("member path escapes extraction root")
        if info.is_dir() or info.filename.endswith("/"):
            target.mkdir(mode=mode, parents=True, exist_ok=True)
            if target.is_symlink():
                fail("archive directory resolved through a symlink")
            continue

        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        current = root
        for part in parts[:-1]:
            current = current / part
            metadata = current.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                fail("archive parent is not an ordinary directory")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        try:
            descriptor = os.open(target, flags, mode)
        except OSError as error:
            fail(f"member could not be created safely: {error.__class__.__name__}")
        copied = 0
        try:
            with os.fdopen(descriptor, "wb") as output, archive.open(info, "r") as source:
                descriptor = -1
                while True:
                    chunk = source.read(COPY_CHUNK)
                    if not chunk:
                        break
                    copied += len(chunk)
                    if copied > info.file_size:
                        fail("member expanded beyond its declared size")
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        if copied != info.file_size:
            fail("member size differs from its archive declaration")
        os.chmod(target, mode, follow_symlinks=False)
PY

EXTENSION_RELATIVE="$("${STAGED}/bin/python3" - "${STAGED}" <<'PY'
import pathlib, stat, sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
package = root / "vendor" / "libghidra"
candidates = []
for path in package.glob("_libghidra*"):
    metadata = path.lstat()
    if stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode) and path.suffix in {".so", ".dylib", ".pyd"}:
        candidates.append(path)
if len(candidates) != 1:
    raise SystemExit(f"expected one ordinary libghidra native extension, found {len(candidates)}")
print(candidates[0].resolve(strict=True).relative_to(root).as_posix())
PY
)"
EXTENSION_SHA256="$("${STAGED}/bin/python3" - "${STAGED}/${EXTENSION_RELATIVE}" <<'PY'
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
with path.open("rb") as stream:
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"

"${STAGED}/bin/python3" - \
  "${STAGED}/MATERIALIZATION.json" \
  "${WHEEL}" "${WHEEL_SHA256}" "${PLATFORM}" "${WHEEL_URL}" \
  "${EXTENSION_RELATIVE}" "${EXTENSION_SHA256}" <<PY
import json, pathlib, sys
path, wheel, wheel_sha, platform, wheel_url, extension_path, extension_sha = sys.argv[1:]
value = {
    "schemaVersion": 1,
    "componentId": "libghidra-dcp03b3-pilot",
    "version": "${VERSION}",
    "gitRevision": "${GIT_REVISION}",
    "wheel": wheel,
    "wheelSha256": wheel_sha,
    "wheelPlatform": platform,
    "wheelURL": wheel_url,
    "extensionRelativePath": extension_path,
    "extensionSha256": extension_sha,
}
pathlib.Path(path).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

"${STAGED}/bin/python3" - \
  "${STAGED}/${EXTENSION_RELATIVE}" \
  "${SERVICE_NAME}" "${SERVICE_VERSION}" <<'PY'
import importlib.util, pathlib, sys
extension = pathlib.Path(sys.argv[1])
expected_service_name = sys.argv[2]
expected_service_version = sys.argv[3]
spec = importlib.util.spec_from_file_location("_libghidra", extension)
if spec is None or spec.loader is None:
    raise SystemExit("could not construct libghidra extension spec")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
client = module.create_local_client(
    ghidra_root="",
    state_path="",
    default_arch="AARCH64:LE:64:v8A",
    pool_size=1,
)
status = client.get_status()
if (
    set(status) != {"ok", "service_name", "service_version", "host_mode", "program_revision", "warnings"}
    or status.get("ok") is not True
    or status.get("service_name") != expected_service_name
    or status.get("service_version") != expected_service_version
    or status.get("host_mode") != "local"
):
    raise SystemExit("unexpected libghidra local-service identity")
if not isinstance(status.get("warnings"), list) or status["warnings"]:
    raise SystemExit("unexpected libghidra warning contract")
capabilities = client.get_capabilities()
for item in capabilities:
    if not isinstance(item, dict) or set(item) != {"id", "status", "note"}:
        raise SystemExit("unexpected libghidra capability contract")
observed = {
    item.get("id"): item.get("status")
    for item in capabilities
    if isinstance(item, dict)
}
for capability in ("health", "session", "decompiler", "functions", "listing"):
    if observed.get(capability) != "supported":
        raise SystemExit(f"required libghidra capability is unavailable: {capability}")
PY

chmod -R u=rwX,go=rX "${STAGED}"
chmod 0644 "${STAGED}/MATERIALIZATION.json"
mv "${STAGED}" "${DESTINATION}"
printf 'materialized libghidra DCP-03B3 pilot at %s\n' "${DESTINATION}"
printf 'wheel sha256: %s\n' "${WHEEL_SHA256}"
printf 'extension sha256: %s\n' "${EXTENSION_SHA256}"
