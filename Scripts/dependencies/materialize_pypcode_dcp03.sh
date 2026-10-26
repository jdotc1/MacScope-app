#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="${1:-${ROOT}/pypcode-dcp03}"
BOOTSTRAP_PYTHON="${MACSCOPE_DCP03_BOOTSTRAP_PYTHON:-python3}"
VERSION="4.0.0"
GIT_REVISION="2787546a83b42a62dde3a1905deea8b0906e85b5"
SOURCE_SHA256="1a83fa81769a2c1cfe8024ad627977edb99ed7ecb76dbc12722416fb7a54ec34"

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    PLATFORM="macosx_11_0_arm64"
    WHEEL="pypcode-4.0.0-cp313-cp313-macosx_11_0_arm64.whl"
    WHEEL_SHA256="dd7c79b6e0547e09b5e35d30a3548e8604f829a376dabf0b44c722e57a6acb1f"
    EXPECTED_SLA_SHA256="5ac26c9f5e13554d2347c82632fd901c5d830054782a3cdc5078787e2bdda1ae"
    ;;
  Linux:x86_64)
    PLATFORM="manylinux_2_28_x86_64"
    WHEEL="pypcode-4.0.0-cp313-cp313-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"
    WHEEL_SHA256="214aeed946e33293d398b22af57cab92ceff733f684bc2c25d74efac21115e93"
    EXPECTED_SLA_SHA256="3bc07d211cf32be3b46b3dba1df6c43017bf63a9fb8c2b7ed9291e93e7ddab0f"
    ;;
  *)
    echo "unsupported DCP-03 materialization host: $(uname -s) $(uname -m)" >&2
    exit 2
    ;;
esac

"${BOOTSTRAP_PYTHON}" - <<'PY'
import platform
import sys
if sys.implementation.name != "cpython" or sys.version_info[:2] != (3, 13):
    raise SystemExit("DCP-03 materialization requires CPython 3.13 exactly")
PY

if [[ -e "${DESTINATION}" || -L "${DESTINATION}" ]]; then
  echo "destination already exists; remove it explicitly before rematerializing: ${DESTINATION}" >&2
  exit 2
fi

PARENT="$(dirname "${DESTINATION}")"
mkdir -p "${PARENT}"
WORK="$(mktemp -d "${PARENT}/.pypcode-dcp03.XXXXXX")"
STAGED="${WORK}/environment"
DOWNLOADS="${WORK}/downloads"
cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT
mkdir -p "${DOWNLOADS}"

"${BOOTSTRAP_PYTHON}" -m pip download \
  --disable-pip-version-check \
  --no-deps \
  --only-binary=:all: \
  --implementation cp \
  --python-version 313 \
  --abi cp313 \
  --platform "${PLATFORM}" \
  --dest "${DOWNLOADS}" \
  "pypcode==${VERSION}"

WHEEL_PATH="${DOWNLOADS}/${WHEEL}"
if [[ ! -f "${WHEEL_PATH}" ]]; then
  echo "pip did not materialize the exact expected wheel: ${WHEEL}" >&2
  find "${DOWNLOADS}" -maxdepth 1 -type f -print >&2
  exit 3
fi

ACTUAL_SHA256="$("${BOOTSTRAP_PYTHON}" - "${WHEEL_PATH}" <<'PY'
import hashlib
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
with path.open("rb") as stream:
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"
if [[ "${ACTUAL_SHA256}" != "${WHEEL_SHA256}" ]]; then
  echo "pypcode wheel checksum mismatch" >&2
  echo "expected: ${WHEEL_SHA256}" >&2
  echo "observed: ${ACTUAL_SHA256}" >&2
  exit 4
fi

"${BOOTSTRAP_PYTHON}" -m venv "${STAGED}"
"${STAGED}/bin/python3" -m pip install \
  --disable-pip-version-check \
  --no-index \
  --no-deps \
  "${WHEEL_PATH}"

"${STAGED}/bin/python3" - "${VERSION}" "${EXPECTED_SLA_SHA256}" <<'PY'
import hashlib
import pathlib
import sys
import pypcode

expected_version, expected_sla = sys.argv[1:]
if pypcode.__version__ != expected_version:
    raise SystemExit(f"installed pypcode version mismatch: {pypcode.__version__}")
language = pypcode.ArchLanguage.from_id("AARCH64:LE:64:AppleSilicon")
if language is None:
    raise SystemExit("Apple-Silicon AArch64 SLEIGH language is unavailable")
sha = hashlib.sha256(pathlib.Path(language.slafile_path).read_bytes()).hexdigest()
if sha != expected_sla:
    raise SystemExit(f"AArch64 SLEIGH resource mismatch: {sha}")
context = pypcode.Context(language)
translation = context.translate(bytes.fromhex("c0035fd6"), base_address=0x1000, max_bytes=4, max_instructions=1)
if not any(operation.opcode.name == "RETURN" for operation in translation.ops):
    raise SystemExit("native SLEIGH self-test did not lift RET")
PY

"${STAGED}/bin/python3" - "${STAGED}/MATERIALIZATION.json" <<PY
import json
import pathlib
import sys
value = {
    "schemaVersion": 1,
    "componentId": "pypcode-dcp03-proof",
    "version": "${VERSION}",
    "gitRevision": "${GIT_REVISION}",
    "sourceArchiveSha256": "${SOURCE_SHA256}",
    "wheel": "${WHEEL}",
    "wheelSha256": "${WHEEL_SHA256}",
    "platform": "${PLATFORM}",
    "languageId": "AARCH64:LE:64:AppleSilicon",
    "sleighResourceSha256": "${EXPECTED_SLA_SHA256}"
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

mv "${STAGED}" "${DESTINATION}"
printf 'materialized pypcode DCP-03 proof environment at %s\n' "${DESTINATION}"
printf 'wheel sha256: %s\n' "${WHEEL_SHA256}"
