#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="${1:-${ROOT}/sleigh-native-dcp03b4}"
PYTHON="${MACSCOPE_DCP03B4_PYTHON:-python3}"
VERSION="12.1.2"
GIT_REVISION="bfd38a983b4aa53dd386365e1df5ed5499b7e2fb"
RELEASE_BASE="https://github.com/lifting-bits/sleigh/releases/download/v12.1.2"

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    PLATFORM="macos-arm64"
    ARCHIVE="macOS-sleigh-12.1.2-1.arm64.tar.gz"
    ARCHIVE_SHA256="e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a"
    ;;
  Linux:x86_64)
    PLATFORM="linux-x86_64"
    ARCHIVE="Linux-sleigh-12.1.2-1.x86_64.tar.gz"
    ARCHIVE_SHA256="7539dd630b7069b372d8fbe9be8e29ef4ca9c7ce2945c2a3009d43ab98b12ea4"
    ;;
  *)
    echo "unsupported DCP-03B4 materialization host: $(uname -s) $(uname -m)" >&2
    exit 2
    ;;
esac
ARCHIVE_URL="${RELEASE_BASE}/${ARCHIVE}"

"${PYTHON}" -B - <<'PY'
import sys
if sys.implementation.name != "cpython" or sys.version_info < (3, 11):
    raise SystemExit("DCP-03B4 materialization requires CPython 3.11 or newer")
PY

if [[ -e "${DESTINATION}" || -L "${DESTINATION}" ]]; then
  echo "destination already exists; remove it explicitly before rematerializing: ${DESTINATION}" >&2
  exit 2
fi
PARENT="$(dirname "${DESTINATION}")"
mkdir -p "${PARENT}"
WORK="$(mktemp -d "${PARENT}/.sleigh-native-dcp03b4.XXXXXX")"
DOWNLOAD="${WORK}/${ARCHIVE}"
EXTRACTED="${WORK}/extracted"
STAGED="${WORK}/materialization"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT
mkdir -m 0700 "${EXTRACTED}" "${STAGED}"

/usr/bin/curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --connect-timeout 30 \
  --max-time 1800 \
  --retry 3 \
  --output "${DOWNLOAD}" \
  "${ARCHIVE_URL}"

OBSERVED_SHA256="$("${PYTHON}" -B - "${DOWNLOAD}" <<'PY'
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
with path.open("rb") as stream:
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"
if [[ "${OBSERVED_SHA256}" != "${ARCHIVE_SHA256}" ]]; then
  echo "native SLEIGH release archive checksum mismatch" >&2
  echo "expected: ${ARCHIVE_SHA256}" >&2
  echo "observed: ${OBSERVED_SHA256}" >&2
  exit 3
fi

"${PYTHON}" -B "${ROOT}/Scripts/native-decompiler-direct/extract_sleigh_package.py" \
  --archive "${DOWNLOAD}" \
  --destination "${EXTRACTED}"

PREFIX_RELATIVE="$("${PYTHON}" -B "${ROOT}/Scripts/native-decompiler-direct/verify_sleigh_package.py" \
  discover --extraction-root "${EXTRACTED}")"
if [[ "${PREFIX_RELATIVE}" == "." ]]; then
  mv "${EXTRACTED}" "${STAGED}/package"
else
  mv "${EXTRACTED}/${PREFIX_RELATIVE}" "${STAGED}/package"
  rm -rf "${EXTRACTED}"
fi

"${PYTHON}" -B "${ROOT}/Scripts/native-decompiler-direct/verify_sleigh_package.py" \
  materialize \
  --package-root "${STAGED}/package" \
  --artifact "${DOWNLOAD}" \
  --output "${STAGED}/MATERIALIZATION.json" >/dev/null

"${PYTHON}" -B "${ROOT}/Scripts/native-decompiler-direct/verify_sleigh_package.py" \
  verify --materialization-root "${STAGED}" >/dev/null

mv "${STAGED}" "${DESTINATION}"
trap - EXIT
rm -rf "${WORK}"

cat <<EOF
Materialized lifting-bits/sleigh ${VERSION} (${GIT_REVISION}) for ${PLATFORM}.
Destination: ${DESTINATION}
Archive SHA-256: ${ARCHIVE_SHA256}
This developer package is not an ordinary MacScope build input.
EOF
