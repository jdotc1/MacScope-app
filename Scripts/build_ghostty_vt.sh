#!/usr/bin/env bash
# build_ghostty_vt.sh — Build/check MacScope's repository-owned Ghostty VT dylib.
#
# Usage:
#   ./Scripts/build_ghostty_vt.sh --work-root /absolute/external/path
#   ./Scripts/build_ghostty_vt.sh --work-root /absolute/external/path --force-rebuild
#   ./Scripts/build_ghostty_vt.sh --work-root /absolute/external/path --verify-only
#   ./Scripts/build_ghostty_vt.sh --work-root /absolute/external/path --verify-inputs-only
#
# MacScope consumes Ghostty's libghostty-vt as one native arm64 macOS dylib plus
# its C module headers. Source, the closed Zig package store, and the Zig
# toolchain are repository inputs. All generated artifacts and caches live under
# the caller-supplied --work-root outside the repository. iOS,
# Simulator, universal-static, and XCFramework products are deliberately omitted.

set -euo pipefail

VERIFY_ONLY=0
VERIFY_INPUTS_ONLY=0
FORCE_REBUILD=0
WORK_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-root)
      if [[ $# -lt 2 || -n "${WORK_ROOT}" ]]; then
        echo "ERROR: --work-root requires exactly one value" >&2
        exit 2
      fi
      WORK_ROOT="$2"
      shift 2
      continue
      ;;
    --verify-only)
      VERIFY_ONLY=1
      ;;
    --force-rebuild)
      FORCE_REBUILD=1
      ;;
    --verify-inputs-only)
      VERIFY_INPUTS_ONLY=1
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      exit 2
      ;;
  esac
  shift
done
if [[ "$((VERIFY_ONLY + VERIFY_INPUTS_ONLY + FORCE_REBUILD))" -gt 1 ]]; then
  echo "ERROR: --verify-only, --verify-inputs-only, and --force-rebuild are mutually exclusive"
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GHOSTTY_DIR="${REPO_ROOT}/ThirdParty/GhosttyVT/Source"
CONTRACT_FILE="${SCRIPT_DIR}/ghostty-vt-source.contract"
ARTIFACT_ROOT=""
BUILD_CACHE_ROOT=""
GLOBAL_CACHE_ROOT=""
DYLIB=""
STATIC_LIBRARY=""
HEADERS_ROOT=""
UMBRELLA_HEADER="${HEADERS_ROOT}/ghostty/vt.h"
MODULE_MAP="${HEADERS_ROOT}/module.modulemap"
MANIFEST=""
LIPO="/usr/bin/lipo"
OTOOL="/usr/bin/otool"
STRIP="/usr/bin/strip"
CODESIGN="/usr/bin/codesign"
AR="/usr/bin/ar"
# The final app-owned relink is the deployment authority. The pinned upstream
# build replaces macOS target queries with its own generic macOS 13 object target.
# Those objects remain compatible with MacScope's stricter dylib minimum.
MACOS_DEPLOYMENT_TARGET="27.0"
# Default to Ghostty's scalar VT build for the local MacScope artifact. With the
# current Xcode 27 SDK and pinned Zig toolchain, Ghostty's optional SIMD C++ path fails
# inside Zig's bundled libc++ (`INFINITY` is undeclared in
# __random/clamp_to_integral.h). Developers can opt back into SIMD with
# MACSCOPE_GHOSTTY_SIMD=true after that toolchain issue is resolved.
SIMD="${MACSCOPE_GHOSTTY_SIMD:-false}"
SDK_OVERLAY_HELPER="${SCRIPT_DIR}/prepare_zig_macos_sdk_overlay.py"
XCRUN="/usr/bin/xcrun"
ZIG_IDENTITY_HELPER="${SCRIPT_DIR}/dependencies/zig_toolchain_receipt.py"
PACKAGE_STORE="${GHOSTTY_DIR}/zig-pkg"
ZIG_ROOT="${REPO_ROOT}/ThirdParty/Zig/zig-0.16.0"
ZIG="${ZIG_ROOT}/zig"
ZIG_RECEIPT="${REPO_ROOT}/ThirdParty/Zig/zig-0.16.0.receipt.json"
SDK_COMPATIBILITY_ROOT_OVERRIDE=""

# Production authority is fixed by the source export.  Test doubles are
# accepted only under a single explicit test-only gate, never by an ambient
# developer shell/Xcode environment.
if [[ "${MACSCOPE_GHOSTTY_TEST_SEAMS:-}" == "1" ]]; then
  GHOSTTY_DIR="${MACSCOPE_GHOSTTY_SOURCE_DIR:-${GHOSTTY_DIR}}"
  CONTRACT_FILE="${MACSCOPE_GHOSTTY_CONTRACT_FILE:-${CONTRACT_FILE}}"
  LIPO="${MACSCOPE_LIPO:-${LIPO}}"
  OTOOL="${MACSCOPE_OTOOL:-${OTOOL}}"
  STRIP="${MACSCOPE_STRIP:-${STRIP}}"
  CODESIGN="${MACSCOPE_CODESIGN:-${CODESIGN}}"
  AR="${MACSCOPE_AR:-${AR}}"
  SDK_OVERLAY_HELPER="${MACSCOPE_ZIG_SDK_OVERLAY_HELPER:-${SDK_OVERLAY_HELPER}}"
  XCRUN="${MACSCOPE_XCRUN:-${XCRUN}}"
  ZIG_ROOT="${MACSCOPE_ZIG_ROOT:-${ZIG_ROOT}}"
  ZIG="${MACSCOPE_ZIG:-${ZIG}}"
  ZIG_RECEIPT="${MACSCOPE_ZIG_RECEIPT:-${ZIG_RECEIPT}}"
  SDK_COMPATIBILITY_ROOT_OVERRIDE="${MACSCOPE_ZIG_SDK_COMPATIBILITY_ROOT:-}"
elif [[ -n "${MACSCOPE_GHOSTTY_SOURCE_DIR:-}${MACSCOPE_GHOSTTY_CONTRACT_FILE:-}${MACSCOPE_ZIG_ROOT:-}${MACSCOPE_ZIG:-}${MACSCOPE_ZIG_RECEIPT:-}${MACSCOPE_LIPO:-}${MACSCOPE_OTOOL:-}${MACSCOPE_STRIP:-}${MACSCOPE_CODESIGN:-}${MACSCOPE_AR:-}${MACSCOPE_XCRUN:-}${MACSCOPE_ZIG_SDK_OVERLAY_HELPER:-}${MACSCOPE_ZIG_SDK_COMPATIBILITY_ROOT:-}" ]]; then
  echo "ERROR: Ghostty build authority overrides are test-only and rejected in production."
  exit 2
fi

if [[ -z "${WORK_ROOT}" ]]; then
  echo "ERROR: --work-root is required and must name an external build root." >&2
  exit 2
fi
if [[ "${WORK_ROOT}" != /* ]]; then
  echo "ERROR: --work-root must be an absolute path." >&2
  exit 2
fi
WORK_ROOT="$(/usr/bin/python3 -B - "${WORK_ROOT}" "${REPO_ROOT}" <<'PY'
from pathlib import Path
import sys

work = Path(sys.argv[1]).resolve()
repository = Path(sys.argv[2]).resolve()
if work in (Path("/"), Path.home().resolve()):
    raise SystemExit("ERROR: --work-root must be a dedicated external directory.")
if work == repository or repository in work.parents:
    raise SystemExit("ERROR: --work-root must be outside the repository.")
print(work)
PY
)" || exit 2
/bin/mkdir -p "${WORK_ROOT}"
ARTIFACT_ROOT="${WORK_ROOT}/artifacts"
BUILD_CACHE_ROOT="${WORK_ROOT}/cache"
GLOBAL_CACHE_ROOT="${WORK_ROOT}/global-cache"
/bin/mkdir -p "${ARTIFACT_ROOT}" "${BUILD_CACHE_ROOT}" "${GLOBAL_CACHE_ROOT}"
DYLIB="${ARTIFACT_ROOT}/lib/libghostty-vt.dylib"
STATIC_LIBRARY="${ARTIFACT_ROOT}/lib/libghostty-vt.a"
HEADERS_ROOT="${ARTIFACT_ROOT}/include"
UMBRELLA_HEADER="${HEADERS_ROOT}/ghostty/vt.h"
MODULE_MAP="${HEADERS_ROOT}/module.modulemap"
MANIFEST="${ARTIFACT_ROOT}/lib/.macscope-ghostty-vt-manifest"
PACKAGE_STORE="${GHOSTTY_DIR}/zig-pkg"

if [[ ! -f "${CONTRACT_FILE}" ]]; then
  echo "ERROR: Ghostty source contract not found: ${CONTRACT_FILE}"
  exit 1
fi
# shellcheck source=ghostty-vt-source.contract
source "${CONTRACT_FILE}"

read_zon_string() {
  local field="$1"
  /usr/bin/sed -n -E \
    "s/^[[:space:]]*\\.?${field}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\\1/p" \
    "${GHOSTTY_DIR}/build.zig.zon" | head -1
}

read_zon_atom() {
  local field="$1"
  /usr/bin/sed -n -E \
    "s/^[[:space:]]*\\.?${field}[[:space:]]*=[[:space:]]*\\.?([^,[:space:]]+).*/\\1/p" \
    "${GHOSTTY_DIR}/build.zig.zon" | head -1
}

validate_artifact_shape() {
  local load_commands
  [[ -f "${DYLIB}" && -f "${UMBRELLA_HEADER}" && -f "${MODULE_MAP}" ]] || return 1
  /usr/bin/grep -Fxq 'module GhosttyVt {' "${MODULE_MAP}" || return 1
  /usr/bin/grep -Fxq '    umbrella header "ghostty/vt.h"' "${MODULE_MAP}" || return 1
  /usr/bin/grep -Fxq '    export *' "${MODULE_MAP}" || return 1
  /usr/bin/grep -Fxq '}' "${MODULE_MAP}" || return 1
  [[ "$("${LIPO}" -archs "${DYLIB}" 2>/dev/null)" == "arm64" ]] || return 1
  load_commands="$("${OTOOL}" -l "${DYLIB}" 2>/dev/null)" || return 1
  /usr/bin/python3 -B - "${MACOS_DEPLOYMENT_TARGET}" "${load_commands}" <<'PY' || return 1
import re
import sys

expected_minimum, commands = sys.argv[1:]
blocks = re.split(r"(?m)^Load command [0-9]+\s*$", commands)
build_versions = [
    block for block in blocks
    if re.search(r"(?m)^\s*cmd LC_BUILD_VERSION\s*$", block)
]
if len(build_versions) != 1:
    raise SystemExit(1)
platforms = re.findall(r"(?m)^\s*platform\s+(\S+)\s*$", build_versions[0])
minimums = re.findall(r"(?m)^\s*minos\s+(\S+)\s*$", build_versions[0])
uuid_count = len(re.findall(r"(?m)^\s*cmd LC_UUID\s*$", commands))
raise SystemExit(0 if (
    uuid_count == 1
    and platforms in (["1"], ["MACOS"])
    and minimums == [expected_minimum]
) else 1)
PY
  "${OTOOL}" -D "${DYLIB}" 2>/dev/null \
    | /usr/bin/tail -n +2 \
    | /usr/bin/grep -Fxq '@rpath/libghostty-vt.dylib' || return 1
  "${CODESIGN}" --verify --strict "${DYLIB}" >/dev/null 2>&1
}

write_expected_manifest() {
  local destination="$1"
  local module_map_sha umbrella_header_sha dylib_sha
  module_map_sha="$(/usr/bin/shasum -a 256 "${MODULE_MAP}" | /usr/bin/awk '{print $1}')"
  umbrella_header_sha="$(/usr/bin/shasum -a 256 "${UMBRELLA_HEADER}" | /usr/bin/awk '{print $1}')"
  dylib_sha="$(/usr/bin/shasum -a 256 "${DYLIB}" | /usr/bin/awk '{print $1}')"
  {
    echo "schema=5"
    echo "link_mode=strip-debug-ar-reproducible-link-stripx-v1"
    echo "input_scope=repository-owned-source-package-store-toolchain"
    echo "source_path=ThirdParty/GhosttyVT/Source"
    echo "toolchain_path=ThirdParty/Zig/zig-0.16.0"
    echo "source_revision=${EXPECTED_GHOSTTY_SOURCE_REVISION}"
    echo "source_tree_sha256=${FOUND_SOURCE_TREE_SHA256}"
    echo "zig_version=${EXPECTED_ZIG_VERSION}"
    echo "zig_archive_sha256=${EXPECTED_ZIG_AARCH64_MACOS_SHA256}"
    echo "zig_toolchain_tree_sha256=${EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256}"
    echo "zig_toolchain_receipt_sha256=${EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256}"
    echo "zig_package_store_sha256=${FOUND_PACKAGE_STORE_SHA256}"
    echo "simd=${SIMD}"
    echo "architecture=arm64"
    echo "artifact_scope=macos-arm64-dylib"
    echo "install_name=@rpath/libghostty-vt.dylib"
    echo "umbrella_header=ghostty/vt.h"
    echo "umbrella_header_sha256=${umbrella_header_sha}"
    echo "module_map_sha256=${module_map_sha}"
    echo "dylib_sha256=${dylib_sha}"
  } >"${destination}"
}

if [[ ! -d "${GHOSTTY_DIR}" ]]; then
  echo "ERROR: Repository-owned Ghostty VT source not found: ${GHOSTTY_DIR}"
  exit 1
fi

if [[ ! -f "${ZIG_IDENTITY_HELPER}" ]]; then
  echo "ERROR: Zig identity verifier not found: ${ZIG_IDENTITY_HELPER}"
  exit 1
fi

FOUND_PACKAGE_STORE_SHA256="$(/usr/bin/python3 -B "${ZIG_IDENTITY_HELPER}" package-store \
  --root "${PACKAGE_STORE}" \
  --expected-sha256 "${EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256}")" || {
  echo "ERROR: Ghostty's closed Zig dependency package store is missing or stale: ${PACKAGE_STORE}"
  echo "       Restore the committed ThirdParty/GhosttyVT/Source/zig-pkg closure."
  exit 1
}
if [[ ! -f "${GHOSTTY_DIR}/build.zig.zon" ]]; then
  echo "ERROR: Ghostty build manifest not found: ${GHOSTTY_DIR}/build.zig.zon"
  exit 1
fi

FOUND_GHOSTTY_NAME="$(read_zon_atom name)"
FOUND_GHOSTTY_VERSION="$(read_zon_string version)"
FOUND_GHOSTTY_FINGERPRINT="$(read_zon_atom fingerprint)"
MINIMUM_ZIG_VERSION="$(read_zon_string minimum_zig_version)"
FOUND_SOURCE_TREE_SHA256="$(/usr/bin/python3 -B "${ZIG_IDENTITY_HELPER}" ghostty-source \
  --root "${GHOSTTY_DIR}" \
  --expected-sha256 "${EXPECTED_GHOSTTY_SOURCE_TREE_SHA256}")" || {
  echo "ERROR: Ghostty source is not an exact ordinary-leaf closure."
  exit 1
}
FOUND_SOURCE_ID="${FOUND_GHOSTTY_NAME}|${FOUND_GHOSTTY_VERSION}|${FOUND_GHOSTTY_FINGERPRINT}|${MINIMUM_ZIG_VERSION}|${FOUND_SOURCE_TREE_SHA256}"
EXPECTED_SOURCE_ID="${EXPECTED_GHOSTTY_NAME}|${EXPECTED_GHOSTTY_VERSION}|${EXPECTED_GHOSTTY_FINGERPRINT}|${EXPECTED_GHOSTTY_MINIMUM_ZIG_VERSION}|${EXPECTED_GHOSTTY_SOURCE_TREE_SHA256}"
if ! /usr/bin/python3 - "${FOUND_SOURCE_ID}" "${EXPECTED_SOURCE_ID}" <<'PY'
import sys
raise SystemExit(0 if sys.argv[1] == sys.argv[2] else 1)
PY
then
  echo "ERROR: Ghostty source contract mismatch: ${GHOSTTY_DIR}"
  echo "       Expected: ${EXPECTED_GHOSTTY_NAME} ${EXPECTED_GHOSTTY_VERSION} ${EXPECTED_GHOSTTY_FINGERPRINT} (Zig ${EXPECTED_GHOSTTY_MINIMUM_ZIG_VERSION})"
  echo "       Found:    ${FOUND_GHOSTTY_NAME:-missing} ${FOUND_GHOSTTY_VERSION:-missing} ${FOUND_GHOSTTY_FINGERPRINT:-missing} (Zig ${MINIMUM_ZIG_VERSION:-missing})"
  echo "       Reviewed archive SHA-256: ${EXPECTED_GHOSTTY_SOURCE_ARCHIVE_SHA256}"
  echo "       Expected source tree: ${EXPECTED_GHOSTTY_SOURCE_TREE_SHA256}"
  echo "       Found source tree:    ${FOUND_SOURCE_TREE_SHA256}"
  exit 1
fi

if [[ "${MINIMUM_ZIG_VERSION}" == "" ]]; then
  echo "ERROR: Could not read Ghostty minimum Zig version from ${GHOSTTY_DIR}/build.zig.zon."
  exit 1
fi
if ! /usr/bin/python3 - "${EXPECTED_ZIG_VERSION}" "${MINIMUM_ZIG_VERSION}" <<'PY'
import sys

def version(value: str) -> tuple[int, ...]:
    core = value.split("-")[0]
    return tuple(int(part) for part in core.split("."))

installed = version(sys.argv[1])
minimum = version(sys.argv[2])
raise SystemExit(0 if installed >= minimum else 1)
PY
then
  echo "ERROR: Ghostty requires Zig ${MINIMUM_ZIG_VERSION}+; the frozen toolchain is ${EXPECTED_ZIG_VERSION}."
  exit 1
fi

verify_zig_toolchain_identity() {
  if [[ ! -d "${ZIG_ROOT}" || ! -f "${ZIG_RECEIPT}" ]]; then
    echo "ERROR: Repository-owned Zig toolchain or receipt is missing."
    echo "       Expected: ${ZIG_ROOT}"
    echo "       Expected: ${ZIG_RECEIPT}"
    return 1
  fi
  if [[ "${ZIG}" != "${ZIG_ROOT}/zig" || ! -x "${ZIG}" ]]; then
    echo "ERROR: Repository-owned Zig executable is missing or not an ordinary executable: ${ZIG}"
    return 1
  fi
  FOUND_ZIG_RECEIPT_SHA256="$(/usr/bin/python3 -B "${ZIG_IDENTITY_HELPER}" verify \
    --root "${ZIG_ROOT}" \
    --receipt "${ZIG_RECEIPT}" \
    --expected-version "${EXPECTED_ZIG_VERSION}" \
    --expected-archive-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_SHA256}" \
    --expected-tree-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256}")" || {
    echo "ERROR: Zig toolchain receipt verification failed before the Ghostty build."
    return 1
  }
  if [[ "${FOUND_ZIG_RECEIPT_SHA256}" != "${EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256}" ]]; then
    echo "ERROR: Zig toolchain receipt identity does not match the frozen official receipt."
    return 1
  fi
  FOUND_ZIG_VERSION="$("${ZIG}" version)"
  if [[ "${FOUND_ZIG_VERSION}" != "${EXPECTED_ZIG_VERSION}" ]]; then
    echo "ERROR: Zig toolchain version drifted after receipt verification."
    return 1
  fi
}

verify_zig_toolchain_identity || exit 1
if [[ "${VERIFY_INPUTS_ONLY}" -eq 1 ]]; then
  echo "==> Ghostty VT repository inputs verified"
  exit 0
fi

EXPECTED_MANIFEST="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/macscope-ghostty-manifest.XXXXXX")"
cleanup_manifest() {
  /bin/rm -f "${EXPECTED_MANIFEST}"
  if [[ -n "${REPRODUCIBLE_DYLIB:-}" ]]; then
    /bin/rm -f "${REPRODUCIBLE_DYLIB}"
  fi
  if [[ -n "${REPRODUCIBLE_EXPORTS:-}" ]]; then
    /bin/rm -f "${REPRODUCIBLE_EXPORTS}"
  fi
  if [[ -n "${REPRODUCIBLE_STRIPPED_DYLIB:-}" ]]; then
    /bin/rm -f "${REPRODUCIBLE_STRIPPED_DYLIB}"
  fi
  for temporary in \
    "${EXTRACTED_ZCU_OBJECT:-}" \
    "${EXTRACTED_COMPILER_RT_OBJECT:-}" \
    "${NORMALIZED_ZCU_OBJECT:-}" \
    "${NORMALIZED_COMPILER_RT_OBJECT:-}" \
    "${NORMALIZED_STATIC_LIBRARY:-}"
  do
    if [[ -n "${temporary}" ]]; then
      /bin/rm -f "${temporary}"
    fi
  done
  if [[ -n "${REPRODUCIBLE_STRIPPED_ROOT:-}" && -d "${REPRODUCIBLE_STRIPPED_ROOT}" ]]; then
    /bin/rmdir "${REPRODUCIBLE_STRIPPED_ROOT}" 2>/dev/null || true
  fi
  if [[ -n "${NORMALIZED_ARCHIVE_ROOT:-}" && -d "${NORMALIZED_ARCHIVE_ROOT}" ]]; then
    /bin/rmdir "${NORMALIZED_ARCHIVE_ROOT}" 2>/dev/null || true
  fi
  if [[ -n "${EXTRACTED_ARCHIVE_ROOT:-}" && -d "${EXTRACTED_ARCHIVE_ROOT}" ]]; then
    /bin/rmdir "${EXTRACTED_ARCHIVE_ROOT}" 2>/dev/null || true
  fi
  if [[ -n "${REPRODUCIBLE_ROOT:-}" && -d "${REPRODUCIBLE_ROOT}" ]]; then
    /bin/rmdir "${REPRODUCIBLE_ROOT}" 2>/dev/null || true
  fi
}
trap cleanup_manifest EXIT INT TERM
if validate_artifact_shape; then
  write_expected_manifest "${EXPECTED_MANIFEST}"
fi

if [[ "${FORCE_REBUILD}" -eq 0 ]] && validate_artifact_shape && \
   [[ -f "${MANIFEST}" ]] && /usr/bin/cmp -s "${EXPECTED_MANIFEST}" "${MANIFEST}"; then
  echo "==> Ghostty VT native macOS dylib available"
  echo "    Dylib:    ${DYLIB}"
  echo "    Headers:  ${HEADERS_ROOT}"
  echo "    Zig:      ${EXPECTED_ZIG_VERSION} (closed receipt ${EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256})"
  echo "    Packages: ${FOUND_PACKAGE_STORE_SHA256}"
  echo "    Ghostty:  ${FOUND_GHOSTTY_VERSION} (${FOUND_GHOSTTY_FINGERPRINT})"
  echo "    Source:   ThirdParty/GhosttyVT/Source"
  echo "    Artifact: ${ARTIFACT_ROOT}"
  exit 0
fi

if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
  echo "ERROR: Ghostty VT artifacts are missing, malformed, or stale."
  echo "       Expected: ${DYLIB}"
  echo "       Expected: ${UMBRELLA_HEADER}"
  echo "       Expected: ${MODULE_MAP}"
  echo "       Expected matching manifest: ${MANIFEST}"
  echo "       Run ./Scripts/build_ghostty_vt.sh --work-root ${WORK_ROOT} to build it."
  exit 1
fi

echo "==> Building Ghostty VT native macOS dylib"
echo "    Ghostty: ${GHOSTTY_DIR}"
echo "    Version: ${FOUND_GHOSTTY_VERSION} (${FOUND_GHOSTTY_FINGERPRINT})"
echo "    Zig:     ${ZIG} (${FOUND_ZIG_VERSION})"
echo "    SIMD:    ${SIMD}"
echo "    Work:    ${WORK_ROOT}"
if [[ -e "${GHOSTTY_DIR}/zig-out" || -e "${GHOSTTY_DIR}/.zig-cache" ]]; then
  echo "ERROR: Repository-owned Ghostty source contains generated build state." >&2
  echo "       Remove Source/zig-out and Source/.zig-cache; generated state belongs under ${WORK_ROOT}." >&2
  exit 1
fi
SDK_ROOT="$("${XCRUN}" --sdk macosx --show-sdk-path)"
SDK_COMPATIBILITY_ROOT="${SDK_COMPATIBILITY_ROOT_OVERRIDE:-${WORK_ROOT}/sdk-compatibility}"
SDK_COMPATIBILITY_JSON="$(/usr/bin/python3 -B "${SDK_OVERLAY_HELPER}" prepare \
  --sdk-root "${SDK_ROOT}" \
  --output-root "${SDK_COMPATIBILITY_ROOT}" \
  --xcrun "${XCRUN}")"
SDK_XCRUN_SHIM="$(/usr/bin/python3 -B -c \
  'import json,sys; value=json.loads(sys.argv[1])["xcrun_shim_dir"]; print(value or "")' \
  "${SDK_COMPATIBILITY_JSON}")"
ZIG_PATH="${PATH}"
if [[ -n "${SDK_XCRUN_SHIM}" ]]; then
  ZIG_PATH="${SDK_XCRUN_SHIM}:${ZIG_PATH}"
  echo "    SDK:     Xcode arm64e compatibility overlay (${SDK_COMPATIBILITY_ROOT})"
fi
(
  cd "${GHOSTTY_DIR}"
  # The pinned Zig Darwin linker/cache graph is not concurrency-safe against the
  # Xcode 27 arm64e compatibility view. Keep this pinned build deterministic.
  PATH="${ZIG_PATH}" ZIG_GLOBAL_CACHE_DIR="${GLOBAL_CACHE_ROOT}" "${ZIG}" build -j1 \
    --system "${PACKAGE_STORE}" \
    --cache-dir "${BUILD_CACHE_ROOT}" \
    --prefix "${ARTIFACT_ROOT}" \
    -Demit-lib-vt \
    -Demit-xcframework=false \
    "-Dsimd=${SIMD}"
)

if [[ -e "${GHOSTTY_DIR}/zig-out" || -e "${GHOSTTY_DIR}/.zig-cache" ]]; then
  echo "ERROR: Ghostty build wrote generated state into the repository-owned source tree." >&2
  exit 1
fi

AFTER_ZIG_RECEIPT_SHA256="$(/usr/bin/python3 -B "${ZIG_IDENTITY_HELPER}" verify \
  --root "${ZIG_ROOT}" \
  --receipt "${ZIG_RECEIPT}" \
  --expected-version "${EXPECTED_ZIG_VERSION}" \
  --expected-archive-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_SHA256}" \
  --expected-tree-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256}")" || {
  echo "ERROR: Zig toolchain changed during the Ghostty build."
  exit 1
}
if [[ "${AFTER_ZIG_RECEIPT_SHA256}" != "${EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256}" ]]; then
  echo "ERROR: Zig toolchain receipt identity changed during the Ghostty build."
  exit 1
fi

AFTER_PACKAGE_STORE_SHA256="$(/usr/bin/python3 -B "${ZIG_IDENTITY_HELPER}" package-store \
  --root "${PACKAGE_STORE}" \
  --expected-sha256 "${EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256}")" || {
  echo "ERROR: Ghostty package store changed during the Ghostty build."
  exit 1
}
AFTER_SOURCE_TREE_SHA256="$(/usr/bin/python3 -B "${ZIG_IDENTITY_HELPER}" ghostty-source \
  --root "${GHOSTTY_DIR}" \
  --expected-sha256 "${EXPECTED_GHOSTTY_SOURCE_TREE_SHA256}")" || {
  echo "ERROR: Ghostty source changed during the Ghostty build."
  exit 1
}
if [[ "${AFTER_PACKAGE_STORE_SHA256}" != "${FOUND_PACKAGE_STORE_SHA256}" || \
      "${AFTER_SOURCE_TREE_SHA256}" != "${FOUND_SOURCE_TREE_SHA256}" ]]; then
  echo "ERROR: Ghostty input identity changed during the Ghostty build."
  exit 1
fi

if [[ ! -f "${DYLIB}" || ! -f "${STATIC_LIBRARY}" || -L "${STATIC_LIBRARY}" || ! -f "${UMBRELLA_HEADER}" ]]; then
  echo "ERROR: Ghostty build completed without producing required VT artifacts."
  echo "       Expected: ${DYLIB}"
  echo "       Expected: ${STATIC_LIBRARY}"
  echo "       Expected: ${UMBRELLA_HEADER}"
  exit 1
fi
# Ghostty's native link incorporates absolute object/source paths into local
# symbol metadata. Normalize the exact reviewed archive-member closure by
# stripping debug/path metadata, rebuild that archive deterministically, relink
# it with Apple's reproducible algorithm, then strip non-exported symbols from
# the final dylib. This preserves a deterministic LC_UUID (required by Xcode 27)
# while making the shipped dylib independent of the sealed qualification root.
REAL_DYLIB="$(/usr/bin/python3 -B -c \
  'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' \
  "${DYLIB}")"
CANONICAL_LIB_DIR="$(/usr/bin/python3 -B -c \
  'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' \
  "${ARTIFACT_ROOT}/lib")"
if [[ "$(/usr/bin/dirname "${REAL_DYLIB}")" != "${CANONICAL_LIB_DIR}" || \
      "$(/usr/bin/basename "${REAL_DYLIB}")" != "libghostty-vt.0.1.0.dylib" ]]; then
  echo "ERROR: Ghostty VT dylib symlink must resolve to the governed versioned artifact inside artifacts/lib."
  exit 1
fi
REPRODUCIBLE_ROOT="$(/usr/bin/mktemp -d "${ARTIFACT_ROOT}/lib/.macscope-reproducible-link.XXXXXX")"
REPRODUCIBLE_DYLIB="${REPRODUCIBLE_ROOT}/libghostty-vt.0.1.0.dylib"
REPRODUCIBLE_EXPORTS="${REPRODUCIBLE_ROOT}/exports"
REPRODUCIBLE_STRIPPED_ROOT="${REPRODUCIBLE_ROOT}/stripped"
/bin/mkdir "${REPRODUCIBLE_STRIPPED_ROOT}"
REPRODUCIBLE_STRIPPED_DYLIB="${REPRODUCIBLE_STRIPPED_ROOT}/libghostty-vt.0.1.0.stripx.dylib"
EXTRACTED_ARCHIVE_ROOT="${REPRODUCIBLE_ROOT}/extracted"
NORMALIZED_ARCHIVE_ROOT="${REPRODUCIBLE_ROOT}/normalized"
/bin/mkdir "${EXTRACTED_ARCHIVE_ROOT}" "${NORMALIZED_ARCHIVE_ROOT}"
ARCHIVE_MEMBERS="$("${AR}" -t "${STATIC_LIBRARY}")"
if ! /usr/bin/python3 -B - "${ARCHIVE_MEMBERS}" <<'PY'
import sys

members = sys.argv[1].splitlines()
symbol_tables = {"__.SYMDEF", "__.SYMDEF SORTED"}
ordinary = [member for member in members if member not in symbol_tables]
expected = ["libghostty-vt-static_zcu.o", "compiler_rt.o"]
raise SystemExit(0 if ordinary == expected and len(members) in (2, 3) else 1)
PY
then
  echo "ERROR: Ghostty VT static archive member closure is not the reviewed two-object contract."
  exit 1
fi
(
  cd "${EXTRACTED_ARCHIVE_ROOT}"
  "${AR}" -x "${STATIC_LIBRARY}"
)
EXTRACTED_ZCU_OBJECT="${EXTRACTED_ARCHIVE_ROOT}/libghostty-vt-static_zcu.o"
EXTRACTED_COMPILER_RT_OBJECT="${EXTRACTED_ARCHIVE_ROOT}/compiler_rt.o"
NORMALIZED_ZCU_OBJECT="${NORMALIZED_ARCHIVE_ROOT}/libghostty-vt-static_zcu.o"
NORMALIZED_COMPILER_RT_OBJECT="${NORMALIZED_ARCHIVE_ROOT}/compiler_rt.o"
NORMALIZED_STATIC_LIBRARY="${NORMALIZED_ARCHIVE_ROOT}/libghostty-vt.normalized.a"
if [[ ! -f "${EXTRACTED_ZCU_OBJECT}" || -L "${EXTRACTED_ZCU_OBJECT}" || \
      ! -f "${EXTRACTED_COMPILER_RT_OBJECT}" || -L "${EXTRACTED_COMPILER_RT_OBJECT}" ]]; then
  echo "ERROR: Ghostty VT static archive did not extract the reviewed ordinary object leaves."
  exit 1
fi
/bin/chmod u+r "${EXTRACTED_ZCU_OBJECT}" "${EXTRACTED_COMPILER_RT_OBJECT}"
"${STRIP}" -S -no_code_signature_warning \
  -o "${NORMALIZED_ZCU_OBJECT}" \
  "${EXTRACTED_ZCU_OBJECT}"
"${STRIP}" -S -no_code_signature_warning \
  -o "${NORMALIZED_COMPILER_RT_OBJECT}" \
  "${EXTRACTED_COMPILER_RT_OBJECT}"
(
  cd "${NORMALIZED_ARCHIVE_ROOT}"
  ZERO_AR_DATE=1 "${AR}" rcs \
    "${NORMALIZED_STATIC_LIBRARY}" \
    "${NORMALIZED_ZCU_OBJECT}" \
    "${NORMALIZED_COMPILER_RT_OBJECT}"
)
echo '_ghostty_*' >"${REPRODUCIBLE_EXPORTS}"
"${XCRUN}" --sdk macosx clang \
  -fuse-ld=ld \
  -target "arm64-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
  -dynamiclib \
  -Wl,-all_load \
  -Wl,-dead_strip \
  -Wl,-headerpad_max_install_names \
  -Wl,-reproducible \
  "-Wl,-exported_symbols_list,${REPRODUCIBLE_EXPORTS}" \
  "${NORMALIZED_STATIC_LIBRARY}" \
  -install_name '@rpath/libghostty-vt.dylib' \
  -current_version 0.1.0 \
  -compatibility_version 1.0.0 \
  -o "${REPRODUCIBLE_DYLIB}"
"${STRIP}" -x -no_code_signature_warning \
  -o "${REPRODUCIBLE_STRIPPED_DYLIB}" \
  "${REPRODUCIBLE_DYLIB}"
/bin/mv -f "${REPRODUCIBLE_STRIPPED_DYLIB}" "${REAL_DYLIB}"
/bin/mkdir -p "${HEADERS_ROOT}"
MODULE_MAP_TEMPORARY="$(/usr/bin/mktemp "${HEADERS_ROOT}/module.modulemap.tmp.XXXXXX")"
{
  echo 'module GhosttyVt {'
  echo '    umbrella header "ghostty/vt.h"'
  echo '    export *'
  echo '}'
} >"${MODULE_MAP_TEMPORARY}"
/bin/mv -f "${MODULE_MAP_TEMPORARY}" "${MODULE_MAP}"
if ! validate_artifact_shape; then
  echo "ERROR: Ghostty VT dylib must be arm64, require macOS ${MACOS_DEPLOYMENT_TARGET}, and use install name @rpath/libghostty-vt.dylib."
  exit 1
fi
write_expected_manifest "${EXPECTED_MANIFEST}"
/bin/mv -f "${EXPECTED_MANIFEST}" "${MANIFEST}"
cleanup_manifest
trap - EXIT INT TERM

echo "==> Ghostty VT native macOS dylib built"
echo "    Dylib:    ${DYLIB}"
echo "    Headers:  ${HEADERS_ROOT}"
echo "    Manifest: ${MANIFEST}"
