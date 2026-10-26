#!/bin/bash
# Build MacScope's repository-owned Ghostty surface closure into an external work root.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/Scripts/ghostty-surface-source.contract"
source "${REPO_ROOT}/Scripts/ghostty-vt-source.contract"

usage() {
  echo "usage: build_vendored_ghostty_surface.sh --work-root ABSOLUTE_PATH [--verify-only|--verify-inputs-only]" >&2
  exit 2
}

WORK_ROOT=""
VERIFY_ONLY=0
VERIFY_INPUTS_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-root)
      [[ $# -ge 2 ]] || usage
      WORK_ROOT="$2"
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY=1
      shift
      ;;
    --verify-inputs-only)
      VERIFY_INPUTS_ONLY=1
      shift
      ;;
    *) usage ;;
  esac
done

[[ $((VERIFY_ONLY + VERIFY_INPUTS_ONLY)) -le 1 ]] || usage

[[ "${WORK_ROOT}" == /* ]] || usage
[[ "${WORK_ROOT}" != "/" ]] || usage
REQUESTED_WORK_ROOT="${WORK_ROOT}"
WORK_ROOT="$(/usr/bin/python3 -B - "${REQUESTED_WORK_ROOT}" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve(strict=False))
PY
)"
case "${WORK_ROOT}" in
  "${REPO_ROOT}"|"${REPO_ROOT}"/*)
    echo "ERROR: Ghostty build output must remain outside the repository" >&2
    exit 2
    ;;
esac
if [[ -L "${REQUESTED_WORK_ROOT}" ]]; then
  echo "ERROR: Ghostty work root must not be a symbolic link" >&2
  exit 2
fi

VENDORED_SOURCE="${REPO_ROOT}/ThirdParty/GhosttySurface/Source"
VENDORED_PACKAGE_STORE="${REPO_ROOT}/ThirdParty/GhosttySurface/zig-pkg"
ZIG_ROOT="${REPO_ROOT}/ThirdParty/Zig/zig-0.16.0"
ZIG="${ZIG_ROOT}/zig"
ZIG_RECEIPT="${REPO_ROOT}/ThirdParty/Zig/zig-0.16.0.receipt.json"
IDENTITY_TOOL="${REPO_ROOT}/Scripts/dependencies/zig_toolchain_receipt.py"
BUILDER="${REPO_ROOT}/Scripts/dependencies/build_ghostty_surface.sh"
OUTPUT_ROOT="${WORK_ROOT}/GhosttySurface"
IDENTITY_FILE="${OUTPUT_ROOT}/.git/macscope-vendored-inputs"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "${VENDORED_SOURCE}" && ! -L "${VENDORED_SOURCE}" ]] \
  || fail "vendored Ghostty surface source is missing or indirect"
[[ ! -e "${VENDORED_SOURCE}/.git" ]] \
  || fail "vendored Ghostty source must be a repository-owned source snapshot"
[[ -d "${VENDORED_PACKAGE_STORE}" && ! -L "${VENDORED_PACKAGE_STORE}" ]] \
  || fail "vendored Ghostty package store is missing or indirect"
[[ -x "${ZIG}" && -f "${ZIG_RECEIPT}" ]] || fail "vendored Zig toolchain is missing"

verify_source_tree() {
  local scratch index observed
  scratch="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/macscope-ghostty-tree.XXXXXX")"
  index="${scratch}/index"
  /usr/bin/git init --bare --quiet "${scratch}/git"
  GIT_INDEX_FILE="${index}" /usr/bin/git \
    --git-dir="${scratch}/git" --work-tree="${VENDORED_SOURCE}" add -A
  observed="$(GIT_INDEX_FILE="${index}" /usr/bin/git --git-dir="${scratch}/git" write-tree)"
  /bin/rm -rf "${scratch}"
  [[ "${observed}" == "${EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE}" ]] \
    || fail "vendored Ghostty source tree does not match the frozen patched tree"
}

verify_source_tree
PACKAGE_STORE_SHA256="$(/usr/bin/python3 -B - "${VENDORED_PACKAGE_STORE}" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
all_paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
if any(path.is_symlink() for path in all_paths):
    raise SystemExit("vendored Ghostty package store contains a symbolic link")
files = [path for path in all_paths if path.is_file()
         and path.name != ".DS_Store" and not path.name.startswith("._")]
if not files:
    raise SystemExit("vendored Ghostty package store is empty")
digest = hashlib.sha256()
for path in files:
    relative = path.relative_to(root).as_posix().encode()
    payload = path.read_bytes()
    digest.update(len(relative).to_bytes(8, "big"))
    digest.update(relative)
    digest.update(len(payload).to_bytes(8, "big"))
    digest.update(payload)
print(digest.hexdigest())
PY
)"
[[ "${PACKAGE_STORE_SHA256}" == "${EXPECTED_GHOSTTY_SURFACE_PACKAGE_STORE_SHA256}" ]] \
  || fail "vendored Ghostty package store does not match the frozen patched closure"
ZIG_RECEIPT_SHA256="$(/usr/bin/python3 -B "${IDENTITY_TOOL}" verify \
  --root "${ZIG_ROOT}" \
  --receipt "${ZIG_RECEIPT}" \
  --expected-version "${EXPECTED_ZIG_VERSION}" \
  --expected-archive-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_SHA256}" \
  --expected-tree-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256}")"

EXPECTED_IDENTITY="tree=${EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE}
packages=${EXPECTED_GHOSTTY_SURFACE_PACKAGE_STORE_SHA256}
zig_receipt=${ZIG_RECEIPT_SHA256}"

if [[ "${VERIFY_INPUTS_ONLY}" -eq 1 ]]; then
  echo "GHOSTTY_SURFACE_INPUTS_VERIFIED=1"
  exit 0
fi

verify_built_artifact() {
  [[ -d "${OUTPUT_ROOT}" && ! -L "${OUTPUT_ROOT}" ]] || return 1
  [[ -f "${IDENTITY_FILE}" ]] || return 1
  [[ "$(/bin/cat "${IDENTITY_FILE}")" == "${EXPECTED_IDENTITY}" ]] || return 1
  MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR="${OUTPUT_ROOT}" \
  MACSCOPE_ZIG_ROOT="${ZIG_ROOT}" \
  MACSCOPE_ZIG="${ZIG}" \
  MACSCOPE_ZIG_RECEIPT="${ZIG_RECEIPT}" \
    "${BUILDER}" --verify-only >/dev/null
}

if verify_built_artifact; then
  echo "GHOSTTY_SURFACE_SOURCE_DIR=${OUTPUT_ROOT}"
  echo "GHOSTTY_SURFACE_ARTIFACT_ROOT=${OUTPUT_ROOT}/macos/GhosttyKit.xcframework"
  exit 0
fi

if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
  fail "repository-owned Ghostty surface build is missing or stale at ${OUTPUT_ROOT}"
fi

if [[ -e "${WORK_ROOT}" ]]; then
  [[ -d "${WORK_ROOT}" && ! -L "${WORK_ROOT}" ]] \
    || fail "Ghostty work root must be an ordinary directory"
else
  /bin/mkdir -p "${WORK_ROOT}"
fi
if [[ -e "${OUTPUT_ROOT}" || -L "${OUTPUT_ROOT}" ]]; then
  [[ -d "${OUTPUT_ROOT}" && ! -L "${OUTPUT_ROOT}" ]] \
    || fail "Ghostty surface output must be an ordinary directory"
  [[ -f "${IDENTITY_FILE}" ]] \
    || fail "refusing to replace unowned Ghostty surface output at ${OUTPUT_ROOT}"
fi

STAGING="$(/usr/bin/mktemp -d "${WORK_ROOT}/.MacScopeGhosttySurface.XXXXXX")"
BACKUP=""
cleanup() {
  if [[ -n "${BACKUP}" && -d "${BACKUP}" ]]; then
    if [[ -e "${OUTPUT_ROOT}" ]]; then
      /bin/rm -rf "${BACKUP}"
    else
      /bin/mv "${BACKUP}" "${OUTPUT_ROOT}"
    fi
  fi
  [[ -z "${STAGING}" || ! -d "${STAGING}" ]] || /bin/rm -rf "${STAGING}"
}
trap cleanup EXIT INT TERM

/bin/cp -R "${VENDORED_SOURCE}/." "${STAGING}"
/bin/mkdir -p "${STAGING}/zig-pkg"
/bin/cp -R "${VENDORED_PACKAGE_STORE}/." "${STAGING}/zig-pkg"

/usr/bin/git -C "${STAGING}" init --quiet
/usr/bin/git -C "${STAGING}" config user.name "MacScope Build"
/usr/bin/git -C "${STAGING}" config user.email "build@invalid"
/usr/bin/git -C "${STAGING}" add -A
[[ "$(/usr/bin/git -C "${STAGING}" write-tree)" == "${EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE}" ]] \
  || fail "materialized Ghostty source tree drifted"
/usr/bin/git -C "${STAGING}" commit --quiet -m "MacScope vendored Ghostty surface"

MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR="${STAGING}" \
MACSCOPE_ZIG_ROOT="${ZIG_ROOT}" \
MACSCOPE_ZIG="${ZIG}" \
MACSCOPE_ZIG_RECEIPT="${ZIG_RECEIPT}" \
  "${BUILDER}" >&2

printf '%s\n' "${EXPECTED_IDENTITY}" >"${STAGING}/.git/macscope-vendored-inputs"

if [[ -e "${OUTPUT_ROOT}" ]]; then
  BACKUP="${WORK_ROOT}/.MacScopeGhosttySurface.previous.$$"
  [[ ! -e "${BACKUP}" && ! -L "${BACKUP}" ]] \
    || fail "Ghostty surface replacement backup already exists"
  /bin/mv "${OUTPUT_ROOT}" "${BACKUP}"
  if ! /bin/mv "${STAGING}" "${OUTPUT_ROOT}"; then
    /bin/mv "${BACKUP}" "${OUTPUT_ROOT}"
    fail "could not install the new Ghostty surface output"
  fi
  STAGING=""
  /bin/rm -rf "${BACKUP}"
  BACKUP=""
else
  /bin/mv "${STAGING}" "${OUTPUT_ROOT}"
  STAGING=""
fi
trap - EXIT INT TERM

echo "GHOSTTY_SURFACE_SOURCE_DIR=${OUTPUT_ROOT}"
echo "GHOSTTY_SURFACE_ARTIFACT_ROOT=${OUTPUT_ROOT}/macos/GhosttyKit.xcframework"
