#!/bin/bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  build_vendored_sleigh_native_source.sh --verify-only
  build_vendored_sleigh_native_source.sh --work-root /absolute/external/root [--sanitizer address|undefined]
EOF
  exit 2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/../.." && pwd -P)"
source_root="${repo_root}/ThirdParty/SleighNative/Source"
governed_package="${repo_root}/ThirdParty/SleighNative/package"
verifier="${script_dir}/verify_vendored_sleigh_source.py"
resource_root="${repo_root}/ThirdParty/SleighNative/AARCH64"
strict_package_module_root="${repo_root}/Scripts/native-decompiler-direct"
strict_verifier="${strict_package_module_root}/verify_sleigh_package.py"
governed_specfiles_config="${governed_package}/lib/cmake/sleigh/specfiles.cmake"

mode="build"
work_root=""
sanitizer="none"
while (($#)); do
  case "$1" in
    --verify-only)
      mode="verify"
      shift
      ;;
    --work-root)
      (($# >= 2)) || usage
      work_root="$2"
      shift 2
      ;;
    --sanitizer)
      (($# >= 2)) || usage
      sanitizer="$2"
      [[ "${sanitizer}" == address || "${sanitizer}" == undefined ]] || usage
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -x "${verifier}" || -f "${verifier}" ]] || fail "source verifier is missing"
[[ -f "${strict_verifier}" && ! -L "${strict_verifier}" ]] || fail "strict package verifier is missing"
[[ -f "${governed_specfiles_config}" && ! -L "${governed_specfiles_config}" ]] || \
  fail "governed specfiles package configuration is missing"
/usr/bin/python3 -B "${verifier}" source "${source_root}" >/dev/null

if [[ "${mode}" == "verify" ]]; then
  [[ -z "${work_root}" ]] || fail "--verify-only does not accept --work-root"
  [[ "${sanitizer}" == none ]] || fail "--verify-only does not accept --sanitizer"
  exit 0
fi

[[ -n "${work_root}" ]] || usage
[[ "${work_root}" == /* ]] || fail "--work-root must be absolute"

work_root="$(/usr/bin/python3 -B - "${work_root}" "${repo_root}" <<'PY'
from pathlib import Path
import sys

requested = Path(sys.argv[1])
repository = Path(sys.argv[2]).resolve(strict=True)
resolved = requested.resolve(strict=False)
if resolved in (Path("/"), Path.home().resolve()):
    raise SystemExit("ERROR: --work-root must be a dedicated external directory")
if resolved == repository or repository in resolved.parents:
    raise SystemExit("ERROR: --work-root must be outside the repository")
print(resolved)
PY
)" || exit 1
/bin/mkdir -p "${work_root}"
[[ -d "${work_root}" && ! -L "${work_root}" ]] || fail "--work-root must be an ordinary directory"

profile_suffix=""
[[ "${sanitizer}" == none ]] || profile_suffix="-${sanitizer}"
published_root="${work_root}/SleighNativeSource${profile_suffix}"
published_materialization="${published_root}/materialization"
published_receipt="${published_root}/SOURCE_BUILD_MATERIALIZATION.json"
lock_directory="${work_root}/.macscope-sleigh-native-source${profile_suffix}.lock"
if ! /bin/mkdir "${lock_directory}" 2>/dev/null; then
  fail "native source producer is already active or its lock requires inspection: ${lock_directory}"
fi
cleanup_lock() {
  /bin/rmdir "${lock_directory}" 2>/dev/null || true
}
trap cleanup_lock EXIT

# Resolve the same selected Xcode compiler and SDK for new builds and cache
# reuse. A sanitizer package built by another toolchain is never silently used.
compiler="$(/usr/bin/xcrun --find clang++)"
sdk_root=""
if [[ "${sanitizer}" != none ]]; then
  sdk_root="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
fi

emit_contract() {
  printf 'MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=%s\n' "${published_root}"
  printf 'MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=%s\n' "${published_materialization}"
}

verify_published_root() {
  [[ -d "${published_root}" && ! -L "${published_root}" ]] || \
    fail "published native source build root is not an ordinary directory"
  [[ -f "${published_receipt}" && ! -L "${published_receipt}" ]] || \
    fail "published native source build receipt is missing or unsafe"
  local profile_verification=()
  if [[ "${sanitizer}" != none ]]; then
    profile_verification=(--compile-commands "${published_root}/build/compile_commands.json"
      --compiler "${compiler}" --sdk-root "${sdk_root}")
  fi
  /usr/bin/python3 -B "${strict_verifier}" verify \
    --materialization-root "${published_materialization}" \
    --expected-sanitizer "${sanitizer}" ${profile_verification[@]+"${profile_verification[@]}"} >/dev/null || \
    fail "published native source strict materialization is invalid"
  local observed_receipt
  if ! observed_receipt="$(/usr/bin/python3 -B "${verifier}" package \
    "${published_materialization}/package" \
    --governed-package "${governed_package}" \
    --governed-resources "${resource_root}")"
  then
    fail "published native source package qualification failed"
  fi
  local recorded_receipt
  recorded_receipt="$(<"${published_receipt}")"
  [[ "${recorded_receipt}" == "${observed_receipt}" ]] || \
    fail "published native source build receipt does not match the package"
}

if [[ -e "${published_root}" || -L "${published_root}" ]]; then
  verify_published_root
  emit_contract
  exit 0
fi

cmake_bin="$(command -v cmake || true)"
ninja_bin="$(command -v ninja || true)"
[[ -n "${cmake_bin}" && -x "${cmake_bin}" ]] || fail "cmake is required"
[[ -n "${ninja_bin}" && -x "${ninja_bin}" ]] || fail "ninja is required"

work_dir="$(/usr/bin/mktemp -d "${work_root}/.SleighNativeSource${profile_suffix}.build.XXXXXX")"
/bin/mkdir -p "${work_dir}/source"
/usr/bin/rsync -a "${source_root}/sleigh/" "${work_dir}/source/sleigh/"
/usr/bin/rsync -a "${source_root}/ghidra/" "${work_dir}/source/ghidra/"

ghidra_work="${work_dir}/source/ghidra"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
/usr/bin/git -C "${ghidra_work}" init -q
/usr/bin/git -C "${ghidra_work}" config user.name "MacScope dependency builder"
/usr/bin/git -C "${ghidra_work}" config user.email "local-build@invalid"
/usr/bin/git -C "${ghidra_work}" config core.longpaths true
/usr/bin/git -C "${ghidra_work}" add --all
GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
  /usr/bin/git -C "${ghidra_work}" commit -q -m "Frozen upstream source baseline"

patch_root="${work_dir}/source/sleigh/src/patches/stable"
while IFS= read -r patch_path; do
  GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git -C "${ghidra_work}" am \
      --ignore-space-change --ignore-whitespace --no-gpg-sign "${patch_path}" >&2
done < <(/usr/bin/find "${patch_root}" -maxdepth 1 -type f -name '*.patch' -print | /usr/bin/sort)

build_dir="${work_dir}/build"
materialization_dir="${work_dir}/materialization"
package_dir="${materialization_dir}/package"
jobs="${MACSCOPE_NATIVE_SOURCE_JOBS:-8}"
[[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || fail "MACSCOPE_NATIVE_SOURCE_JOBS must be a positive integer"
export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH=946684800
export LC_ALL=C
export TZ=UTC

profile_cmake=()
profile_receipt=()
if [[ "${sanitizer}" != none ]]; then
  sanitizer_flags="-fsanitize=${sanitizer}"
  if [[ "${sanitizer}" == address ]]; then
    sanitizer_flags+=" -fno-omit-frame-pointer"
  else
    sanitizer_flags+=" -fno-sanitize-recover=all"
  fi
  profile_cmake=(-DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    "-DCMAKE_OSX_SYSROOT=${sdk_root}"
    "-DCMAKE_CXX_FLAGS=${sanitizer_flags}"
    "-DCMAKE_CXX_FLAGS_RELEASE=-O1 -g -DNDEBUG"
    "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=${sanitizer}")
  profile_receipt=(--sanitizer "${sanitizer}"
    --compile-commands "${build_dir}/compile_commands.json" --sdk-root "${sdk_root}")
fi

"${cmake_bin}" -S "${work_dir}/source/sleigh" -B "${build_dir}" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="${ninja_bin}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER="${compiler}" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
  -DCMAKE_INSTALL_PREFIX="${package_dir}" \
  -DBUILD_SHARED_LIBS=OFF \
  -Dsleigh_DEVELOPER_MODE=OFF \
  -Dsleigh_BUILD_TOOLS=OFF \
  -Dsleigh_BUILD_SLEIGHSPECS=OFF \
  -Dsleigh_BUILD_SUPPORT=OFF \
  -Dsleigh_BUILD_EXTRATOOLS=OFF \
  -Dsleigh_BUILD_EXAMPLE=OFF \
  -DFETCHCONTENT_SOURCE_DIR_GHIDRASOURCE="${ghidra_work}" \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DFETCHCONTENT_UPDATES_DISCONNECTED=ON \
  -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER \
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=FALSE \
  -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=FALSE ${profile_cmake[@]+"${profile_cmake[@]}"} >&2

"${cmake_bin}" --build "${build_dir}" --parallel "${jobs}" --target sleigh_sla sleigh_decomp >&2
"${cmake_bin}" --install "${build_dir}" --prefix "${package_dir}" >&2

language_dir="${package_dir}/share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages"
/bin/mkdir -p "${language_dir}"
/usr/bin/rsync -a "${resource_root}/" "${language_dir}/"
cmake_package_dir="${package_dir}/lib/cmake/sleigh"
/bin/mkdir -p "${cmake_package_dir}"
/bin/cp "${governed_specfiles_config}" "${cmake_package_dir}/specfiles.cmake"

receipt="${work_dir}/SOURCE_BUILD_MATERIALIZATION.json"
/usr/bin/python3 -B "${verifier}" package "${package_dir}" \
  --governed-package "${governed_package}" \
    --governed-resources "${resource_root}" >"${receipt}"
/usr/bin/python3 -B "${strict_verifier}" materialize-source \
  --package-root "${package_dir}" \
  --source-manifest "${source_root}/MATERIALIZATION.json" \
  --compiler "${compiler}" \
  --cmake "${cmake_bin}" \
  --ninja "${ninja_bin}" \
  --output "${materialization_dir}/MATERIALIZATION.json" ${profile_receipt[@]+"${profile_receipt[@]}"} >/dev/null
/usr/bin/python3 -B "${strict_verifier}" verify \
  --materialization-root "${materialization_dir}" --expected-sanitizer "${sanitizer}" >/dev/null

[[ ! -e "${published_root}" && ! -L "${published_root}" ]] || \
  fail "published native source build appeared while the producer lock was held"
/bin/mv "${work_dir}" "${published_root}"
verify_published_root
emit_contract
