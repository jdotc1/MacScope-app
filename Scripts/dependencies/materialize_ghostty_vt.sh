#!/usr/bin/env bash
# Provision the exact Ghostty and Zig inputs frozen for MacScope CI.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_SCRIPTS_DIR}/ghostty-vt-source.contract"

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

main() {
  local destination="${1:?usage: materialize_ghostty_vt.sh DESTINATION}"
  local package_store_seed="${MACSCOPE_GHOSTTY_ZIG_PACKAGE_STORE_SOURCE:?MACSCOPE_GHOSTTY_ZIG_PACKAGE_STORE_SOURCE is required and must name the verified Ghostty zig-pkg seed}"
  local source_dir="${destination}/ghostty-${EXPECTED_GHOSTTY_SOURCE_REVISION}"
  local zig_root="${destination}/zig-${EXPECTED_ZIG_VERSION}"
  local zig_receipt="${destination}/zig-${EXPECTED_ZIG_VERSION}.receipt.json"
  local zig_identity_helper="${SCRIPT_DIR}/zig_toolchain_receipt.py"
  local package_store="${source_dir}/zig-pkg"
  local archive="${destination}/ghostty.zip"
  local isolated_global_cache

  # Fail closed on the operator-supplied seed before creating a destination,
  # downloading an archive, or invoking any other materializer. This keeps an
  # invalid-but-present seed from producing a partial export that could later
  # be mistaken for a qualified closure.
  /usr/bin/python3 -B "${zig_identity_helper}" package-store \
    --root "${package_store_seed}" \
    --expected-sha256 "${EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256}" >/dev/null

  /bin/mkdir -p "${destination}"
  /usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://github.com/ghostty-org/ghostty/archive/${EXPECTED_GHOSTTY_SOURCE_REVISION}.zip" \
    -o "${archive}"
  echo "${EXPECTED_GHOSTTY_GITHUB_ARCHIVE_SHA256}  ${archive}" | /usr/bin/shasum -a 256 -c -
  /bin/rm -rf "${source_dir}"
  /usr/bin/ditto -x -k "${archive}" "${destination}"
  normalize_ghostty_source_alias "${source_dir}"

  # The package seed was validated before any destination or network side
  # effect. Consume only the descriptor-rooted private snapshot, then verify
  # the copied closure again. Never ask Zig to discover or fetch a wider graph.
  /bin/rm -rf "${package_store}"
  /usr/bin/python3 -B "${zig_identity_helper}" snapshot \
    --kind package-store \
    --source "${package_store_seed}" \
    --destination "${package_store}" \
    --expected-sha256 "${EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256}" >/dev/null
  /usr/bin/python3 -B "${zig_identity_helper}" package-store \
    --root "${package_store}" \
    --expected-sha256 "${EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256}" >/dev/null

  # This is the last non-Zig operation on the extracted source: immediately
  # before any Zig executable can run, prove the normalized ordinary-leaf
  # source closure against the frozen contract.
  /usr/bin/python3 -B "${zig_identity_helper}" ghostty-source \
    --root "${source_dir}" \
    --expected-sha256 "${EXPECTED_GHOSTTY_SOURCE_TREE_SHA256}" >/dev/null

  "${SCRIPT_DIR}/materialize_zig_toolchain.sh" "${destination}"

  /usr/bin/python3 -B "${zig_identity_helper}" create \
    --root "${zig_root}" \
    --receipt "${zig_receipt}" \
    --expected-version "${EXPECTED_ZIG_VERSION}" \
    --expected-archive-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_SHA256}" \
    --expected-tree-sha256 "${EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256}"

  # The seed snapshot, not a shared user cache, is the only package authority.
  # Keep Zig's writable cache private to this materialization and discard it;
  # no shared global cache or network-backed dependency discovery is permitted.
  isolated_global_cache="$(/usr/bin/mktemp -d "${destination}/.macscope-zig-global-cache.XXXXXX")"
  if ! (
    cd "${source_dir}"
    ZIG_GLOBAL_CACHE_DIR="${isolated_global_cache}" "${zig_root}/zig" build -j1 \
      --system "${package_store}" \
      --cache-dir "${source_dir}/.zig-cache" \
      -Demit-lib-vt -Demit-xcframework=false -Dsimd=false
  ); then
    /bin/rm -rf "${isolated_global_cache}"
    echo "ERROR: bounded Ghostty VT build failed." >&2
    return 1
  fi
  /bin/rm -rf "${isolated_global_cache}"
  /usr/bin/python3 -B "${zig_identity_helper}" package-store \
    --root "${package_store}" \
    --expected-sha256 "${EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256}"
  /usr/bin/python3 -B "${zig_identity_helper}" ghostty-source \
    --root "${source_dir}" \
    --expected-sha256 "${EXPECTED_GHOSTTY_SOURCE_TREE_SHA256}" >/dev/null

  MACSCOPE_GHOSTTY_SOURCE_DIR="${source_dir}" \
  MACSCOPE_ZIG_ROOT="${zig_root}" \
  MACSCOPE_ZIG="${zig_root}/zig" \
  MACSCOPE_ZIG_RECEIPT="${zig_receipt}" \
    "${ROOT_SCRIPTS_DIR}/build_ghostty_vt.sh"

  echo "MACSCOPE_GHOSTTY_SOURCE_DIR=${source_dir}"
  echo "MACSCOPE_ZIG=${zig_root}/zig"
  echo "MACSCOPE_ZIG_ROOT=${zig_root}"
  echo "MACSCOPE_ZIG_RECEIPT=${zig_receipt}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
