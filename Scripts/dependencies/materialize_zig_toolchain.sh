#!/usr/bin/env bash
# Materialize the exact Zig toolchain required by the pinned Ghostty VT build.
#
# This is an explicit network-backed dependency command. Ordinary bootstrap,
# build, and test paths must never invoke it.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../ghostty-vt-source.contract
source "${ROOT_SCRIPTS_DIR}/ghostty-vt-source.contract"

DESTINATION="${1:?usage: materialize_zig_toolchain.sh DESTINATION}"
ZIG_ROOT="${DESTINATION}/zig-${EXPECTED_ZIG_VERSION}"
ZIG_ARCHIVE="${DESTINATION}/zig-aarch64-macos-${EXPECTED_ZIG_VERSION}.tar.xz"
ZIG_RECEIPT="${DESTINATION}/zig-${EXPECTED_ZIG_VERSION}.receipt.json"
EXTRACTED_ROOT="${DESTINATION}/zig-aarch64-macos-${EXPECTED_ZIG_VERSION}"
ZIG_RECEIPT_TOOL="${SCRIPT_DIR}/zig_toolchain_receipt.py"

/bin/mkdir -p "${DESTINATION}"
/usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
  "https://ziglang.org/download/${EXPECTED_ZIG_VERSION}/zig-aarch64-macos-${EXPECTED_ZIG_VERSION}.tar.xz" \
  -o "${ZIG_ARCHIVE}"
echo "${EXPECTED_ZIG_AARCH64_MACOS_SHA256}  ${ZIG_ARCHIVE}" \
  | /usr/bin/shasum -a 256 -c -

/bin/rm -rf "${ZIG_ROOT}" "${EXTRACTED_ROOT}"
/bin/rm -f "${ZIG_RECEIPT}"
/usr/bin/tar -xJf "${ZIG_ARCHIVE}" -C "${DESTINATION}"
if [[ ! -x "${EXTRACTED_ROOT}/zig" ]]; then
  echo "ERROR: Zig archive did not contain the expected executable: ${EXTRACTED_ROOT}/zig" >&2
  exit 1
fi
/bin/mv "${EXTRACTED_ROOT}" "${ZIG_ROOT}"
# Git cannot preserve the official archive's empty directories. Normalize them
# out before computing the repository-stable closed-tree identity; the verified
# archive checksum remains the authority for the original distribution bytes.
/usr/bin/find "${ZIG_ROOT}" -depth -type d -empty -delete

FOUND_VERSION="$("${ZIG_ROOT}/zig" version)"
if [[ "${FOUND_VERSION}" != "${EXPECTED_ZIG_VERSION}" ]]; then
  echo "ERROR: Materialized Zig version mismatch: expected ${EXPECTED_ZIG_VERSION}, found ${FOUND_VERSION}" >&2
  exit 1
fi

ZIG_RECEIPT_SHA256="$(
  /usr/bin/python3 "${ZIG_RECEIPT_TOOL}" create \
    --root "${ZIG_ROOT}" \
    --receipt "${ZIG_RECEIPT}" \
    --expected-version "${EXPECTED_ZIG_VERSION}" \
    --expected-archive-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_SHA256}" \
    --expected-tree-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256}"
)"
if [[ "${ZIG_RECEIPT_SHA256}" != "${EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256}" ]]; then
  echo "ERROR: Materialized Zig receipt does not match the canonical receipt identity" >&2
  exit 1
fi

echo "MACSCOPE_ZIG_ROOT=${ZIG_ROOT}"
echo "MACSCOPE_ZIG=${ZIG_ROOT}/zig"
echo "MACSCOPE_ZIG_RECEIPT=${ZIG_RECEIPT}"
echo "MACSCOPE_ZIG_RECEIPT_SHA256=${ZIG_RECEIPT_SHA256}"
