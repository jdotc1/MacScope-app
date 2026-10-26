#!/usr/bin/env bash
# Build or verify the pinned GhosttyKit XCFramework used by GST-01.

set -euo pipefail
umask 077

MODE="build"
if [[ "${1:-}" == "--verify-only" ]]; then
  MODE="verify"
elif [[ -n "${1:-}" ]]; then
  echo "ERROR: usage: build_ghostty_surface.sh [--verify-only]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/Scripts/ghostty-surface-source.contract"
source "${REPO_ROOT}/Scripts/ghostty-vt-source.contract"

SOURCE_ROOT="${MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR:?set MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR to the verified patched checkout}"
ZIG_ROOT="${MACSCOPE_ZIG_ROOT:-}"
ZIG_RECEIPT="${MACSCOPE_ZIG_RECEIPT:-}"
ZIG="${MACSCOPE_ZIG:-${ZIG_ROOT}/zig}"
GIT="${MACSCOPE_GIT:-/usr/bin/git}"
LIPO="${MACSCOPE_LIPO:-/usr/bin/lipo}"
NM="${MACSCOPE_NM:-/usr/bin/nm}"
PLIST_BUDDY="${MACSCOPE_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
PYTHON="${MACSCOPE_PYTHON:-/usr/bin/python3}"
ZIG_RECEIPT_TOOL="${REPO_ROOT}/Scripts/dependencies/zig_toolchain_receipt.py"
ARTIFACT="${SOURCE_ROOT}/macos/GhosttyKit.xcframework"
SLICE="${ARTIFACT}/macos-arm64"
ARCHIVE="${SLICE}/libghostty-internal.a"
HEADER="${SLICE}/Headers/ghostty.h"
MODULE_MAP="${SLICE}/Headers/module.modulemap"
INFO_PLIST="${ARTIFACT}/Info.plist"
MANIFEST="${SOURCE_ROOT}/macos/.macscope-ghostty-surface-manifest"
PACKAGE_STORE="${SOURCE_ROOT}/zig-pkg"
EXPECTED_SYMBOLS=(
  _ghostty_surface_new_external
  _ghostty_surface_external_feed
  _ghostty_surface_external_set_process_state
  _ghostty_surface_is_external_io
)
FORBIDDEN_SYMBOL_PREFIXES=(
  _sentry_
  _crashpad_
  _breakpad_
)
NETWORK_SYMBOLS=(
  _accept
  _accept4
  _bind
  _connect
  _freeaddrinfo
  _getaddrinfo
  _getnameinfo
  _getpeername
  _getsockname
  _getsockopt
  _listen
  _recvfrom
  _recvmsg
  _recv
  _send
  _sendmsg
  _sendto
  _setsockopt
  _shutdown
  _socket
  _socketpair
)
# Zig 0.16.0 emits these five unreachable POSIX entries from its root Io vtable
# even when std.Options.networking is false. Freeze that exact inert residual;
# any new network import fails artifact validation.
EXPECTED_RESIDUAL_NETWORK_IMPORTS=(
  _bind
  _connect
  _listen
  _recvmsg
  _socket
)
BUILD_FLAGS=(
  -Demit-lib-vt=false
  -Dapp-runtime=none
  -Drenderer=metal
  -Dsentry=false
  -Di18n=false
  -Dmacscope-external-io-only=true
  -Demit-xcframework=true
  -Demit-macos-app=false
  -Demit-exe=false
  -Demit-test-exe=false
  -Demit-unicode-table-gen=false
  -Demit-bench=false
  -Demit-helpgen=false
  -Demit-docs=false
  -Demit-terminfo=false
  -Demit-termcap=false
  -Demit-themes=false
  -Demit-webdata=false
  -Dxcframework-target=native
  -Doptimize=ReleaseFast
)

fail() { echo "ERROR: $*" >&2; exit 1; }
sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
digest_package_store() {
  "${PYTHON}" - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
all_paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
paths = [path for path in all_paths if path.name != ".DS_Store" and not path.name.startswith("._")]
if any(path.is_symlink() for path in all_paths):
    raise SystemExit("package store contains a symbolic link")
files = [path for path in paths if path.is_file()]
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
build_profile_sha256() {
  printf '%s\0' "${BUILD_FLAGS[@]}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}
verified_zig_receipt_sha256() {
  "${PYTHON}" "${ZIG_RECEIPT_TOOL}" verify \
    --root "${ZIG_ROOT}" \
    --receipt "${ZIG_RECEIPT}" \
    --expected-version "${EXPECTED_ZIG_VERSION}" \
    --expected-archive-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_SHA256}" \
    --expected-tree-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256}"
}

verify_source_checkout() {
  [[ "$("${GIT}" -C "${SOURCE_ROOT}" rev-parse 'HEAD^{tree}')" == "${EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE}" ]] \
    || fail "patched Ghostty Git tree does not match the reviewed source"
  "${GIT}" -C "${SOURCE_ROOT}" diff --quiet --ignore-submodules -- \
    || fail "patched Ghostty tracked source has local modifications"
  "${GIT}" -C "${SOURCE_ROOT}" diff --cached --quiet --ignore-submodules -- \
    || fail "patched Ghostty source has staged modifications"
  local unexpected
  unexpected="$("${GIT}" -C "${SOURCE_ROOT}" ls-files --others --exclude-standard \
    | /usr/bin/grep -Ev '^macos/\.macscope-ghostty-surface-manifest$' || true)"
  [[ -z "${unexpected}" ]] || fail "patched Ghostty source has unexpected untracked inputs: ${unexpected}"
}

[[ -d "${SOURCE_ROOT}" ]] || fail "patched Ghostty source is missing: ${SOURCE_ROOT}"
[[ -d "${PACKAGE_STORE}" ]] || fail "materialized Zig package store is missing: ${PACKAGE_STORE}"
[[ "$(digest_package_store "${PACKAGE_STORE}")" == "${EXPECTED_GHOSTTY_SURFACE_PACKAGE_STORE_SHA256}" ]] \
  || fail "materialized Zig package store does not match the reviewed closed tree"
[[ -n "${ZIG_ROOT}" ]] || fail "MACSCOPE_ZIG_ROOT is required for the official Zig toolchain"
[[ -n "${ZIG_RECEIPT}" ]] || fail "MACSCOPE_ZIG_RECEIPT is required for the official Zig toolchain"
[[ -d "${ZIG_ROOT}" ]] || fail "pinned Zig toolchain root is missing: ${ZIG_ROOT}"
[[ -f "${ZIG_RECEIPT}" ]] || fail "pinned Zig toolchain receipt is missing: ${ZIG_RECEIPT}"
[[ "${ZIG}" == "${ZIG_ROOT}/zig" ]] || fail "MACSCOPE_ZIG must name the executable inside MACSCOPE_ZIG_ROOT"
[[ -x "${ZIG}" ]] || fail "pinned Zig executable is missing: ${ZIG}"
if ! ZIG_RECEIPT_SHA256="$(verified_zig_receipt_sha256)"; then
  fail "pinned Zig toolchain receipt verification failed"
fi
[[ "${ZIG_RECEIPT_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
  || fail "pinned Zig toolchain verifier returned an invalid receipt identity"
[[ "$(sha256 "${ZIG_RECEIPT}")" == "${ZIG_RECEIPT_SHA256}" ]] \
  || fail "pinned Zig toolchain receipt changed after verification"
verify_source_checkout

validate_artifact() {
  [[ -f "${INFO_PLIST}" && -f "${ARCHIVE}" && -f "${HEADER}" && -f "${MODULE_MAP}" ]] || return 1
  [[ "$("${LIPO}" -archs "${ARCHIVE}" 2>/dev/null)" == "arm64" ]] || return 1
  [[ "$("${PLIST_BUDDY}" -c 'Print :AvailableLibraries:0:LibraryIdentifier' "${INFO_PLIST}" 2>/dev/null)" == "macos-arm64" ]] || return 1
  local symbols symbol forbidden undefined network_lines observed_network observed_owner expected_network
  symbols="$("${NM}" -gU "${ARCHIVE}" 2>/dev/null)" || return 1
  for symbol in "${EXPECTED_SYMBOLS[@]}"; do
    /usr/bin/grep -Eq "[[:space:]]${symbol}$" <<<"${symbols}" || return 1
  done
  for forbidden in "${FORBIDDEN_SYMBOL_PREFIXES[@]}"; do
    if /usr/bin/grep -Eq "[[:space:]]${forbidden}" <<<"${symbols}"; then
      return 1
    fi
  done
  undefined="$("${NM}" -A -u "${ARCHIVE}" 2>/dev/null)" || return 1
  network_lines="$(
    for symbol in "${NETWORK_SYMBOLS[@]}"; do
      /usr/bin/grep -E "[[:space:]]${symbol}$" <<<"${undefined}" || true
    done
  )"
  observed_network="$(/usr/bin/awk '{print $NF}' <<<"${network_lines}" | /usr/bin/sort -u)"
  expected_network="$(printf '%s\n' "${EXPECTED_RESIDUAL_NETWORK_IMPORTS[@]}" | /usr/bin/sort -u)"
  [[ "${observed_network}" == "${expected_network}" ]] || return 1
  while IFS= read -r observed_owner; do
    [[ -z "${observed_owner}" || "${observed_owner}" == *':libghostty_zcu.o:'* ]] || return 1
  done <<<"${network_lines}"
  /usr/bin/grep -Fq 'GHOSTTY_EXTERNAL_IO_ABI_VERSION 1' "${HEADER}" || return 1
  return 0
}

expected_manifest() {
  printf '%s\n' \
    'schema=3' \
    "source_revision=${EXPECTED_GHOSTTY_SURFACE_REVISION}" \
    "source_tree=${EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE}" \
    "source_sha256=${EXPECTED_GHOSTTY_SURFACE_PATCHED_SHA256}" \
    "zig_version=${EXPECTED_ZIG_VERSION}" \
    "zig_archive_sha256=${EXPECTED_ZIG_AARCH64_MACOS_SHA256}" \
    "zig_toolchain_tree_sha256=${EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256}" \
    "zig_toolchain_receipt_sha256=${ZIG_RECEIPT_SHA256}" \
    'external_io_abi_version=1' \
    'networking=disabled' \
    'residual_network_imports=_bind,_connect,_listen,_recvmsg,_socket' \
    "libxev_package_id=${EXPECTED_GHOSTTY_SURFACE_LIBXEV_PACKAGE_ID}" \
    "libxev_patch_sha256=${EXPECTED_GHOSTTY_SURFACE_LIBXEV_PATCH_SHA256}" \
    "raw_package_store_sha256=${EXPECTED_GHOSTTY_SURFACE_RAW_PACKAGE_STORE_SHA256}" \
    "package_store_sha256=${EXPECTED_GHOSTTY_SURFACE_PACKAGE_STORE_SHA256}" \
    'architecture=arm64' \
    'library_identifier=macos-arm64' \
    "build_profile_sha256=$(build_profile_sha256)" \
    "info_plist_sha256=$(sha256 "${INFO_PLIST}")" \
    "archive_sha256=$(sha256 "${ARCHIVE}")" \
    "header_sha256=$(sha256 "${HEADER}")" \
    "module_map_sha256=$(sha256 "${MODULE_MAP}")"
}

verify_complete() {
  validate_artifact || return 1
  [[ -f "${MANIFEST}" ]] || return 1
  [[ "$(sha256 "${ZIG_RECEIPT}")" == "${ZIG_RECEIPT_SHA256}" ]] || return 1
  local expected
  expected="$(expected_manifest)" || return 1
  [[ "$(<"${MANIFEST}")" == "${expected}" ]]
}

if verify_complete; then
  echo "GhosttyKit verification passed"
  echo "GHOSTTY_SURFACE_XCFRAMEWORK=${ARTIFACT}"
  echo "GHOSTTY_SURFACE_MANIFEST=${MANIFEST}"
  exit 0
fi

if [[ "${MODE}" == "verify" ]]; then
  fail "GhosttyKit artifact is missing, malformed, stale, or lacks a matching manifest"
fi

echo "==> Building pinned GhosttyKit XCFramework"
(
  cd "${SOURCE_ROOT}"
  "${ZIG}" build macscope-xcframework -j1 \
    "${BUILD_FLAGS[@]}" \
    --system "${PACKAGE_STORE}" \
    --summary all
)

if ! POST_BUILD_ZIG_RECEIPT_SHA256="$(verified_zig_receipt_sha256)"; then
  fail "pinned Zig toolchain changed during the Ghostty build"
fi
[[ "${POST_BUILD_ZIG_RECEIPT_SHA256}" == "${ZIG_RECEIPT_SHA256}" ]] \
  || fail "pinned Zig toolchain receipt identity changed during the Ghostty build"
validate_artifact || fail "Ghostty build did not produce the required arm64 ABI artifact"
TEMP_MANIFEST="$(/usr/bin/mktemp "${SOURCE_ROOT}/macos/.macscope-ghostty-surface-manifest.XXXXXX")"
trap '/bin/rm -f "${TEMP_MANIFEST}"' EXIT INT TERM
expected_manifest >"${TEMP_MANIFEST}"
/bin/mv -f "${TEMP_MANIFEST}" "${MANIFEST}"
trap - EXIT INT TERM
verify_complete || fail "new GhosttyKit artifact failed deterministic verification"
echo "GhosttyKit build and verification passed"
echo "GHOSTTY_SURFACE_XCFRAMEWORK=${ARTIFACT}"
echo "GHOSTTY_SURFACE_MANIFEST=${MANIFEST}"
