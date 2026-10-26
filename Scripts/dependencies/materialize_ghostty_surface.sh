#!/usr/bin/env bash
# Explicitly materialize the reviewed GST-01 Ghostty source and its external-I/O patchset.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/Scripts/ghostty-surface-source.contract"

DESTINATION="${1:?usage: materialize_ghostty_surface.sh DESTINATION [SOURCE_REPOSITORY] [PACKAGE_STORE]}"
SOURCE_REPOSITORY="${2:-https://github.com/ghostty-org/ghostty}"
PACKAGE_STORE_SOURCE="${3:-${MACSCOPE_GHOSTTY_SURFACE_PACKAGE_STORE:-}}"
PATCH_ROOT="${REPO_ROOT}/ThirdParty/GhosttySurface/patches"
GHOSTTY_PATCHES=(
  "${PATCH_ROOT}/0001-test-gst-define-external-termio-ABI-and-backend-cont.patch"
  "${PATCH_ROOT}/0002-feat-gst-add-host-fed-external-termio-backend.patch"
  "${PATCH_ROOT}/0003-test-gst-harden-external-backend-ordering-and-lifecy.patch"
  "${PATCH_ROOT}/0004-build-gst-add-external-I-O-only-XCFramework-step.patch"
  "${PATCH_ROOT}/0005-build-gst-disable-root-networking-in-external-only.patch"
)
LIBXEV_PATCH="${PATCH_ROOT}/libxev-networking-capability.patch"

if [[ -e "${DESTINATION}" ]]; then
  echo "ERROR: destination already exists: ${DESTINATION}" >&2
  exit 2
fi
if [[ -z "${PACKAGE_STORE_SOURCE}" || ! -d "${PACKAGE_STORE_SOURCE}" ]]; then
  echo "ERROR: pass the pre-materialized Zig package store as argument 3 or MACSCOPE_GHOSTTY_SURFACE_PACKAGE_STORE" >&2
  exit 2
fi
/bin/mkdir -p "$(dirname "${DESTINATION}")"
STAGING_ROOT="$(/usr/bin/mktemp -d "$(dirname "${DESTINATION}")/.ghostty-surface.XXXXXX")"
cleanup() { /bin/rm -rf "${STAGING_ROOT}"; }
trap cleanup EXIT
SOURCE_ROOT="${STAGING_ROOT}/source"

normalize_ghostty_source_alias() {
  local source_dir="${1:?usage: normalize_ghostty_source_alias SOURCE_DIR}"
  local alias_path="" candidate target target_path temporary
  if [[ ! -d "${source_dir}" || -L "${source_dir}" ]]; then
    echo "ERROR: source root must be an ordinary directory" >&2
    return 1
  fi
  # Discover the single root-local Markdown alias. The frozen normalized
  # source identity below still admits only the exact reviewed source bytes.
  for candidate in "${source_dir}"/*.md; do
    [[ -L "${candidate}" ]] || continue
    if [[ -n "${alias_path}" ]]; then
      echo "ERROR: multiple source documentation aliases" >&2
      return 1
    fi
    alias_path="${candidate}"
  done
  if [[ -z "${alias_path}" ]]; then
    echo "ERROR: reviewed source documentation alias is missing" >&2
    return 1
  fi
  target="$(/usr/bin/readlink "${alias_path}")"
  if [[ "${target}" == */* || "${target}" != *.md ]]; then
    echo "ERROR: source alias target must be a root-local Markdown file" >&2
    return 1
  fi
  target_path="${source_dir}/${target}"
  if [[ ! -f "${target_path}" || -L "${target_path}" ]]; then
    echo "ERROR: source alias target must be an ordinary file" >&2
    return 1
  fi
  if ! temporary="$(/usr/bin/mktemp "${source_dir}/.macscope-source-normalize.XXXXXX")"; then
    return 1
  fi
  if ! /bin/cp -p "${target_path}" "${temporary}"; then
    /bin/rm -f "${temporary}"
    return 1
  fi
  if ! /bin/mv -f "${temporary}" "${alias_path}"; then
    /bin/rm -f "${temporary}"
    return 1
  fi
  NORMALIZED_ALIAS_NAME="${alias_path##*/}"
}

digest_source() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
excluded = {".git", ".zig-cache", "zig-out", "zig-pkg", ".DS_Store"}
files = sorted(
    (
        path for path in root.rglob("*")
        if path.is_file()
        and not any(part in excluded for part in path.relative_to(root).parts)
        and not path.name.startswith("._")
    ),
    key=lambda path: path.relative_to(root).as_posix(),
)
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
}

digest_package_store() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
all_paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
if any(path.is_symlink() for path in all_paths):
    raise SystemExit("package store contains a symbolic link")
files = [path for path in all_paths if path.is_file()
         and path.name != ".DS_Store" and not path.name.startswith("._")]
if not files:
    raise SystemExit("package store is empty")
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
}

verify_patch() {
  local path="$1"
  local expected="$2"
  echo "${expected}  ${path}" | /usr/bin/shasum -a 256 -c - >/dev/null
}

verify_patch "${PATCH_ROOT}/0001-test-gst-define-external-termio-ABI-and-backend-cont.patch" \
  "${EXPECTED_GHOSTTY_SURFACE_PATCH_1_SHA256}"
verify_patch "${PATCH_ROOT}/0002-feat-gst-add-host-fed-external-termio-backend.patch" \
  "${EXPECTED_GHOSTTY_SURFACE_PATCH_2_SHA256}"
verify_patch "${PATCH_ROOT}/0003-test-gst-harden-external-backend-ordering-and-lifecy.patch" \
  "${EXPECTED_GHOSTTY_SURFACE_PATCH_3_SHA256}"
verify_patch "${PATCH_ROOT}/0004-build-gst-add-external-I-O-only-XCFramework-step.patch" \
  "${EXPECTED_GHOSTTY_SURFACE_PATCH_4_SHA256}"
verify_patch "${PATCH_ROOT}/0005-build-gst-disable-root-networking-in-external-only.patch" \
  "${EXPECTED_GHOSTTY_SURFACE_PATCH_5_SHA256}"
verify_patch "${LIBXEV_PATCH}" "${EXPECTED_GHOSTTY_SURFACE_LIBXEV_PATCH_SHA256}"

/usr/bin/git clone --quiet --no-checkout "${SOURCE_REPOSITORY}" "${SOURCE_ROOT}"
/usr/bin/git -C "${SOURCE_ROOT}" checkout --quiet --detach \
  "${EXPECTED_GHOSTTY_SURFACE_REVISION}"

BASE_TREE="$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse HEAD^{tree})"
BASE_SHA256="$(digest_source "${SOURCE_ROOT}")"
if [[ "${BASE_TREE}" != "${EXPECTED_GHOSTTY_SURFACE_BASE_TREE}" \
   || "${BASE_SHA256}" != "${EXPECTED_GHOSTTY_SURFACE_BASE_SHA256}" ]]; then
  echo "ERROR: Ghostty surface baseline identity mismatch" >&2
  exit 1
fi

/usr/bin/git -C "${SOURCE_ROOT}" am --quiet "${GHOSTTY_PATCHES[@]}"
RAW_PATCHED_COMMIT="$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse HEAD)"
RAW_PATCHED_TREE="$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse HEAD^{tree})"
if [[ "${RAW_PATCHED_TREE}" != "${EXPECTED_GHOSTTY_SURFACE_RAW_PATCHED_TREE}" ]]; then
  echo "ERROR: Ghostty surface raw patched identity mismatch" >&2
  exit 1
fi
if ! /usr/bin/git -C "${SOURCE_ROOT}" diff --quiet --ignore-submodules -- \
  || ! /usr/bin/git -C "${SOURCE_ROOT}" diff --cached --quiet --ignore-submodules --; then
  echo "ERROR: Ghostty surface raw patched checkout is not clean" >&2
  exit 1
fi

normalize_ghostty_source_alias "${SOURCE_ROOT}"
/usr/bin/git -C "${SOURCE_ROOT}" add -- "${NORMALIZED_ALIAS_NAME}"
NORMALIZED_PATHS="$(/usr/bin/git -C "${SOURCE_ROOT}" diff --cached --name-only --)"
if [[ "${NORMALIZED_PATHS}" != "${NORMALIZED_ALIAS_NAME}" ]]; then
  echo "ERROR: Ghostty surface normalization changed an unexpected path" >&2
  exit 1
fi

PATCHED_TREE="$(/usr/bin/git -C "${SOURCE_ROOT}" write-tree)"
PATCHED_SHA256="$(digest_source "${SOURCE_ROOT}")"
if [[ "${PATCHED_TREE}" != "${EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE}" \
   || "${PATCHED_SHA256}" != "${EXPECTED_GHOSTTY_SURFACE_PATCHED_SHA256}" ]]; then
  echo "ERROR: Ghostty surface normalized patched identity mismatch" >&2
  exit 1
fi

NORMALIZED_COMMIT="$(
  GIT_AUTHOR_NAME="MacScope Materializer" \
  GIT_AUTHOR_EMAIL="materializer@invalid" \
  GIT_COMMITTER_NAME="MacScope Materializer" \
  GIT_COMMITTER_EMAIL="materializer@invalid" \
    /usr/bin/git -C "${SOURCE_ROOT}" commit-tree "${PATCHED_TREE}" \
      -p "${RAW_PATCHED_COMMIT}" <<'EOF'
Normalize source documentation alias for MacScope vendoring
EOF
)"
/usr/bin/git -C "${SOURCE_ROOT}" update-ref HEAD \
  "${NORMALIZED_COMMIT}" "${RAW_PATCHED_COMMIT}"
if [[ "$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse HEAD^{tree})" != "${PATCHED_TREE}" ]] \
  || ! /usr/bin/git -C "${SOURCE_ROOT}" diff --quiet --ignore-submodules -- \
  || ! /usr/bin/git -C "${SOURCE_ROOT}" diff --cached --quiet --ignore-submodules --; then
  echo "ERROR: Ghostty surface normalized checkout was not committed cleanly" >&2
  exit 1
fi

PACKAGE_STORE_SHA256="$(digest_package_store "${PACKAGE_STORE_SOURCE}")"
if [[ "${PACKAGE_STORE_SHA256}" != "${EXPECTED_GHOSTTY_SURFACE_RAW_PACKAGE_STORE_SHA256}" ]]; then
  echo "ERROR: Ghostty surface raw Zig package-store identity mismatch" >&2
  exit 1
fi
/bin/mkdir "${SOURCE_ROOT}/zig-pkg"
/bin/cp -R "${PACKAGE_STORE_SOURCE}/." "${SOURCE_ROOT}/zig-pkg/"
/usr/bin/find "${SOURCE_ROOT}/zig-pkg" -type f \( -name .DS_Store -o -name '._*' \) -delete
LIBXEV_ROOT="${SOURCE_ROOT}/zig-pkg/${EXPECTED_GHOSTTY_SURFACE_LIBXEV_PACKAGE_ID}"
if [[ ! -d "${LIBXEV_ROOT}" ]]; then
  echo "ERROR: pinned libxev package is missing from the copied package store" >&2
  exit 1
fi
if ! /usr/bin/patch --batch --fuzz=0 -p1 -d "${LIBXEV_ROOT}" -i "${LIBXEV_PATCH}" >/dev/null; then
  echo "ERROR: pinned libxev network-capability patch did not apply exactly" >&2
  exit 1
fi
PATCHED_PACKAGE_STORE_SHA256="$(digest_package_store "${SOURCE_ROOT}/zig-pkg")"
if [[ "${PATCHED_PACKAGE_STORE_SHA256}" != "${EXPECTED_GHOSTTY_SURFACE_PACKAGE_STORE_SHA256}" ]]; then
  echo "ERROR: patched Zig package store failed closed-tree verification" >&2
  exit 1
fi

/bin/mv "${SOURCE_ROOT}" "${DESTINATION}"
echo "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR=${DESTINATION}"
echo "GHOSTTY_SURFACE_TREE=${PATCHED_TREE}"
echo "GHOSTTY_SURFACE_RAW_PACKAGE_STORE_SHA256=${PACKAGE_STORE_SHA256}"
echo "GHOSTTY_SURFACE_PACKAGE_STORE_SHA256=${PATCHED_PACKAGE_STORE_SHA256}"
echo "GHOSTTY_EXTERNAL_IO_ABI_VERSION=${EXPECTED_GHOSTTY_EXTERNAL_IO_ABI_VERSION}"
