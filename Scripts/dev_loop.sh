#!/usr/bin/env bash
# Fast developer iteration loop for CoreTests on the live worktree.
#
# ITERATION ONLY. Products of this loop are never Gate F, Release, CI or
# qualification evidence: there is no sealed source export, no source-qualified
# provenance, no signing-environment re-verification beyond what the Debug
# build phases do, and no receipt. Use the canonical qualification gate for
# evidence.
#
# What it does:
#   1. Regenerates the Xcode project only when the generated-project freshness
#      contract fails (project.yml or another generator input changed, or a
#      file was added, removed or renamed under a folder source such as App or
#      CoreTests; content edits do not count), via
#      ./script/build_and_run.sh --prepare. SLEIGH, the Ghostty surface and
#      (in the Xcode phase) Ghostty VT come from the shared verified dependency
#      cache as read-only views (Scripts/qualification/dev_dependency_cache.py),
#      so a new lane or DerivedData never recompiles them.
#   2. Keeps ONE persistent DerivedData per worktree + toolchain under an
#      owner-controlled .noindex root, so every run after the first is
#      incremental.
#   3. Enables Xcode compilation caching with a shared .noindex CAS, so a cold
#      DerivedData (new worktree, new toolchain) can replay unchanged compiles.
#      Prefix mapping rewrites the worktree root to /^src and the DerivedData
#      directory to /^derived in cache keys, so a compile cached by one
#      worktree replays in every other one. CoreTests locate the checkout via
#      TEST_RUNNER_MACSCOPE_SOURCE_ROOT (Tests/CoreTests/Support/TestSourceRoot.swift),
#      because #filePath then names the virtual /^src root. The CAS is pruned by
#      Xcode to COMPILATION_CACHE_LIMIT_SIZE at the end of each build.
#   4. Takes the machine-wide heavy-gate lock only around xcodebuild, after
#      waiting for at least MACSCOPE_DEV_MIN_FREE_GB of available memory, and
#      runs xcodebuild at nice 5 so the owner's foreground apps stay responsive.
#   5. Runs build-for-testing once, then test-without-building with the given
#      -only-testing selectors.
#   Before all of this, `Scripts/station.sh sync` aligns ThirdParty/Lumen with
#   the checked-out gitlink (offline, from the local Lumen seed).
#
# usage: Scripts/dev_loop.sh [--build-only] [--native-verbose] [--no-lock] [SELECTOR ...]
#        --native-verbose resolves the exact native bridge cache entry and prints
#        its build/CTest log on a miss. Xcode then stages that same tested artifact;
#        an existing receipt is reused without repeating CTest. With no SELECTOR
#        it stops after native resolution; with selectors it continues with Xcode.
#        At least one SELECTOR is required, e.g. CoreTests/ImageLayoutTests or
#        Phase2Tests/Phase2ShellBrokerTests; pass a bundle name (CoreTests,
#        Phase2Tests) to run the whole bundle (--build-only needs none). When every
#        selector names the same bundle, only that bundle is built (its own scheme);
#        selectors from both bundles build both (scheme MacScopeApp).
#
# Environment:
#   MACSCOPE_DEV_LOOP_ROOT  owner-controlled root whose name ends in .noindex
#                           (default: MacScopeDevLoop.noindex in the work root)
#   MACSCOPE_GATE_LOCK      heavy-gate lock path (shared with the qualifier)
#   MACSCOPE_XCODE_JOBS     xcodebuild -jobs (default: logical CPUs / dev slots,
#                           at least 3)
#   MACSCOPE_DEV_SLOTS      dev loops that may build together under a shared
#                           hold on the heavy-gate lock (1-3, default 2; 1 = old
#                           exclusive behaviour). Heavy phases stay exclusive.
#   MACSCOPE_DEV_MIN_FREE_GB  wait before building while available memory
#                           (free + inactive + speculative) is below this many
#                           GB (default 8; 0 disables); gives up after
#                           MACSCOPE_DEV_MEMORY_WAIT_SECONDS (default 1800)
#   MACSCOPE_DEPENDENCY_CACHE_ROOT  shared verified dependency cache (default:
#                           the qualifier's MacScopeQualificationCache-20260920 in the work root)
#   MACSCOPE_DEPENDENCY_VIEW_ROOT   read-only verified views (default:
#                           MacScopeDevLoop.noindex/dependency-views in the work root)
#   MACSCOPE_DEV_DEPENDENCY_CACHE=0 build SLEIGH/Ghostty locally instead
#   MACSCOPE_DEV_PREFIX_MAP=0       disable compilation-cache prefix mapping
#                           (cache entries are then private to this worktree)
#   MACSCOPE_COMPILATION_CACHE_LIMIT  CAS size cap Xcode prunes to after each
#                           build (default 40G; K/M/G/T suffix)
#   MACSCOPE_LUMEN_SEED, MACSCOPE_LUMEN_SYNC=0  Lumen sync settings (Scripts/station.sh)
#   MACSCOPE_DEV_TEST_TIMEOUT_SECONDS  per-test XCTest time allowance for
#                           test-without-building (default 300; 0 disables). A hung
#                           async test then fails by name instead of holding the
#                           heavy-gate lock indefinitely.
#   MACSCOPE_DEV_QUIET=0  drop -quiet so xcodebuild prints its build timing summary
#   MACSCOPE_ALLOW_PIN_CHANGE=1  allow a branch that moves a ThirdParty/* gitlink without
#                           FIRST_PARTY_COMPONENTS.json (Scripts/check_pin_changes.py)
#   MACSCOPE_DEV_SKIP_ALLOWLIST_CHECK=1  skip the test skip-allowlist check
#                           (Scripts/qualification/check_skip_allowlist_cached.py)
#   MACSCOPE_DEV_SKIP_PROJECT_CHECK=1  skip the generated-project allowlist check
#                           (Scripts/qualification/check_generated_project.py)
#   MACSCOPE_DEV_IGNORE_EXCLUSIVE_WAITER=1  take a free slot even while an exclusive
#                           heavy phase is queued (default: wait for it; it has priority)

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/work_root.sh
source "${SCRIPT_DIR}/lib/work_root.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
XCODEPROJ="${ROOT_DIR}/MacScope/MacScope.xcodeproj"
BUILD_ONLY=0
NATIVE_VERBOSE=0
LOCK_ENABLED=1
SELECTORS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1; shift ;;
    --native-verbose) NATIVE_VERBOSE=1; shift ;;
    --no-lock) LOCK_ENABLED=0; shift ;;
    -h|--help)
      /usr/bin/sed -n '2,81p' "${BASH_SOURCE[0]}" | /usr/bin/sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *) SELECTORS+=("$1"); shift ;;
  esac
done
if [[ ${#SELECTORS[@]} -eq 0 ]]; then
  # D12: an empty list used to fall back to the whole CoreTests bundle, so a lane
  # that lost its selector list silently ran the full suite. Require intent.
  if [[ "${NATIVE_VERBOSE}" == 1 && "${BUILD_ONLY}" == 0 ]]; then
    NATIVE_ONLY=1
    SELECTORS=(CoreTests)
  elif [[ "${BUILD_ONLY}" == 1 ]]; then
    SELECTORS=(CoreTests)
  else
    echo "ERROR: give at least one CoreTests/<Suite> selector, or CoreTests to run the whole bundle" >&2
    exit 2
  fi
fi
# Test bundles (D12 layer 3); each has a scheme of the same name that builds the app
# plus only that bundle, so a focused run never compiles the other bundle.
TEST_BUNDLES=(CoreTests Phase2Tests)
SCHEME=""
for selector in "${SELECTORS[@]}"; do
  if [[ ! "${selector}" =~ ^(CoreTests|Phase2Tests)(/[A-Za-z0-9_]+(/[A-Za-z0-9_]+(\(\))?)?)?$ ]]; then
    echo "ERROR: selector must be <Bundle>[/Suite[/case]] with Bundle one of ${TEST_BUNDLES[*]}: ${selector}" >&2
    exit 2
  fi
  bundle="${selector%%/*}"
  if [[ -z "${SCHEME}" ]]; then
    SCHEME="${bundle}"
  elif [[ "${SCHEME}" != "${bundle}" ]]; then
    SCHEME=MacScopeApp
  fi
done
if [[ "${MACSCOPE_DEV_PRINT_SCHEME:-0}" == 1 ]]; then
  echo "${SCHEME}"  # test hook: report the scheme these selectors build, do nothing else
  exit 0
fi

# Drop repository-local git variables inherited from a caller such as
# `git bisect run` or a git hook: GIT_DIR makes every `git -C ThirdParty/Lumen`
# below answer for the superproject, so the Lumen sync misreads the checkout
# and the bootstrap then fails the clean-worktree check.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

# A station that switched branches keeps its old ThirdParty/Lumen checkout;
# align it with this commit's gitlink first (two rev-parses when aligned, one
# line of output, never fatal; MACSCOPE_LUMEN_SYNC=0 skips it).
"${SCRIPT_DIR}/station.sh" sync "${ROOT_DIR}" >&2 || true

# Refuse a branch whose diff against main moves a ThirdParty/* gitlink without
# FIRST_PARTY_COMPONENTS.json (a stale submodule staged wholesale; #359).
# Deliberate pin bumps change both; MACSCOPE_ALLOW_PIN_CHANGE=1 overrides.
/usr/bin/python3 -B "${SCRIPT_DIR}/check_pin_changes.py" --repo "${ROOT_DIR}" || exit $?

source "${SCRIPT_DIR}/xcode27_env.sh"

clock() { /usr/bin/python3 -c 'import time; print(time.time())'; }
elapsed() { /usr/bin/python3 -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.1f}")' "$1" "$2"; }
LOOP_STARTED="$(clock)"

DEV_LOOP_ROOT="${MACSCOPE_DEV_LOOP_ROOT:-$(macscope_work_root)/MacScopeDevLoop.noindex}"
TOOLCHAIN_IDENTITY="$(
  { /usr/bin/xcodebuild -version; echo "${DEVELOPER_DIR}"; } | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-12
)"
WORKTREE_IDENTITY="$(printf '%s' "${ROOT_DIR}" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-12)"
# Owner-controlled admission (same rules as the qualifier's shared caches).
read -r DEV_LOOP_ROOT DERIVED_DATA CAS_ROOT < <(
  /usr/bin/python3 -B - "${DEV_LOOP_ROOT}" "${ROOT_DIR}" \
      "$(basename "${ROOT_DIR}")-${WORKTREE_IDENTITY}-xcode-${TOOLCHAIN_IDENTITY}" <<'PY'
import os
from pathlib import Path
import stat
import sys

root, repository, name = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
if not root.is_absolute() or not root.name.endswith(".noindex") or len(root.name) <= len(".noindex"):
    raise SystemExit("ERROR: MACSCOPE_DEV_LOOP_ROOT must be absolute and end in .noindex")
if any(character.isspace() for character in str(root) + name):
    raise SystemExit("ERROR: dev-loop paths must not contain whitespace")
if root == repository or repository in root.parents or root in repository.parents:
    raise SystemExit("ERROR: dev-loop root must be outside the repository")


def admit(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        path.mkdir(mode=0o700)
    metadata = path.lstat()
    if (path.resolve(strict=True) != path or not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022):
        raise SystemExit(f"ERROR: {path} must be an ordinary, canonical, owner-controlled directory")


root.parent.mkdir(parents=True, exist_ok=True)
admit(root)
admit(root / "DerivedData")
admit(root / "compilation-cache")
print(root, root / "DerivedData" / name, root / "compilation-cache")
PY
)
if [[ -z "${DERIVED_DATA:-}" || -z "${CAS_ROOT:-}" ]]; then
  echo "ERROR: dev-loop root was not admitted" >&2
  exit 2
fi
/bin/mkdir -p -m 700 "${DERIVED_DATA}"

# Opt-in/skipped test methods need a skip-allowlist entry (#379, #393 went red on main).
# Cached by test-file fingerprint: ~0.1 s unless a test file or the allowlist changed.
if [[ "${MACSCOPE_DEV_SKIP_ALLOWLIST_CHECK:-0}" != 1 ]]; then
  /usr/bin/python3 -B "${SCRIPT_DIR}/qualification/check_skip_allowlist_cached.py" \
    "${ROOT_DIR}" "${DERIVED_DATA}/MacScopeDevChecks/skip-allowlist.stamp" || exit $?
fi


DEV_SLOTS="${MACSCOPE_DEV_SLOTS:-2}"
if [[ ! "${DEV_SLOTS}" =~ ^[123]$ ]]; then
  echo "ERROR: MACSCOPE_DEV_SLOTS must be 1, 2 or 3" >&2
  exit 2
fi
XCODE_JOBS="${MACSCOPE_XCODE_JOBS:-$(( $(/usr/sbin/sysctl -n hw.logicalcpu) / DEV_SLOTS ))}"
if [[ -z "${MACSCOPE_XCODE_JOBS:-}" && "${XCODE_JOBS}" -lt 3 ]]; then
  XCODE_JOBS=3
fi
TEST_TIMEOUT_SECONDS="${MACSCOPE_DEV_TEST_TIMEOUT_SECONDS:-300}"
if [[ ! "${TEST_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: MACSCOPE_DEV_TEST_TIMEOUT_SECONDS must be a non-negative integer" >&2
  exit 2
fi
MIN_FREE_GB="${MACSCOPE_DEV_MIN_FREE_GB:-8}"
MEMORY_WAIT_SECONDS="${MACSCOPE_DEV_MEMORY_WAIT_SECONDS:-1800}"
if [[ ! "${MIN_FREE_GB}" =~ ^[0-9]+$ || ! "${MEMORY_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: MACSCOPE_DEV_MIN_FREE_GB and MACSCOPE_DEV_MEMORY_WAIT_SECONDS must be integers" >&2
  exit 2
fi
available_memory_gb() {
  /usr/bin/vm_stat | /usr/bin/awk '
    /page size of/ { size = $8 }
    /^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); pages += $NF }
    END { printf "%d\n", pages * size / 1073741824 }'
}
wait_for_memory() {
  local waited=0 available
  [[ "${MIN_FREE_GB}" == 0 ]] && return 0
  while available="$(available_memory_gb)"; (( available < MIN_FREE_GB )); do
    if (( waited >= MEMORY_WAIT_SECONDS )); then
      echo "ERROR: available memory stayed below ${MIN_FREE_GB} GB for ${waited}s (now ${available} GB); not building" >&2
      exit 75
    fi
    if (( waited % 60 == 0 )); then
      echo "==> waiting for memory: ${available} GB available, need ${MIN_FREE_GB} GB" >&2
    fi
    /bin/sleep 15
    waited=$((waited + 15))
  done
}
CAS_LIMIT="${MACSCOPE_COMPILATION_CACHE_LIMIT:-40G}"
if [[ ! "${CAS_LIMIT}" =~ ^[0-9]+[KMGT]?$ ]]; then
  echo "ERROR: MACSCOPE_COMPILATION_CACHE_LIMIT must be a byte count with optional K/M/G/T suffix" >&2
  exit 2
fi
# Prefix mapping: the worktree root and its DerivedData are the only
# per-worktree paths in a compile (SDK, toolchain and Xcode are mapped by the
# *_ENABLE_PREFIX_MAPPING switches; dependency views are already shared). The
# two roots never nest (the dev-loop root is admitted outside the repository).
PREFIX_MAP_SETTINGS=()
if [[ "${MACSCOPE_DEV_PREFIX_MAP:-1}" != 0 ]]; then
  if [[ "${ROOT_DIR}${DERIVED_DATA}" =~ [[:space:]] ]]; then
    echo "ERROR: prefix mapping needs whitespace-free worktree and DerivedData paths" >&2
    exit 2
  fi
  PREFIX_MAPS="${ROOT_DIR}=/^src ${DERIVED_DATA}=/^derived"
  PREFIX_MAP_SETTINGS=(
    SWIFT_ENABLE_PREFIX_MAPPING=YES
    CLANG_ENABLE_PREFIX_MAPPING=YES
    SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=NO
    CLANG_ENABLE_PROJECT_PREFIX_MAPPING=NO
    "SWIFT_OTHER_PREFIX_MAPPINGS=${PREFIX_MAPS}"
    "CLANG_OTHER_PREFIX_MAPPINGS=${PREFIX_MAPS}"
  )
fi
XCODEBUILD=(
  /usr/bin/nice -n 5
  /usr/bin/xcodebuild
  -project "${XCODEPROJ}"
  -scheme "${SCHEME}"
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "${DERIVED_DATA}"
  -parallelizeTargets
  -jobs "${XCODE_JOBS}"
  -showBuildTimingSummary
  COMPILER_INDEX_STORE_ENABLE=NO
  # Routine Debug provenance: binds the signed runtime without walking and
  # hashing the source closure (that is the qualifier's source-qualified mode).
  MACSCOPE_DEBUG_SOURCE_IDENTITY=runtime-only
  # Content-addressed compilation cache shared by every worktree.
  COMPILATION_CACHE_ENABLE_CACHING=YES
  "COMPILATION_CACHE_CAS_PATH=${CAS_ROOT}"
  "COMPILATION_CACHE_LIMIT_SIZE=${CAS_LIMIT}"
  ${PREFIX_MAP_SETTINGS[@]+"${PREFIX_MAP_SETTINGS[@]}"}
)
# -quiet also hides the build timing summary; MACSCOPE_DEV_QUIET=0 keeps it (build-cost
# investigations: where an incremental build's seconds go, by task category).
if [[ "${MACSCOPE_DEV_QUIET:-1}" != 0 ]]; then
  XCODEBUILD+=(-quiet)
fi
# CoreTests resolve fixtures from the live checkout, not the (mapped) #filePath.
export TEST_RUNNER_MACSCOPE_SOURCE_ROOT="${ROOT_DIR}"
ONLY_TESTING=()
for selector in "${SELECTORS[@]}"; do
  ONLY_TESTING+=("-only-testing:${selector}")
done

LOCK_PATH="${MACSCOPE_GATE_LOCK:-$(macscope_work_root)/.macscope-heavy-gate.lock}"
release_lock() {
  if [[ "${LOCK_ENABLED}" == 1 && "${LOCK_HELD:-0}" == 1 ]]; then
    /usr/bin/python3 -B "${SCRIPT_DIR}/qualification/heavy_gate_lock.py" release \
      --lock "${LOCK_PATH}" --pid "$$" || true
    exec 7>&- 8>&- 9>&- 10>&-
    LOCK_HELD=0
  fi
}
# >>> exit-finalization (Scripts/tests/test_dev_loop_exit_finalization.py runs this block)
# A run that published a staged native package receipt registers its root so the
# next run (plain or --native-verbose) admits that staged copy as prior evidence.
# That is required evidence, not cleanup: a failure fails an otherwise successful
# run (exit 3) and keeps an already-failing run's status; the lock is released.
finish_native_receipts() {
  if [[ -n "${NATIVE_RECEIPT_ROOT:-}" ]]; then
    /usr/bin/python3 -B "${SCRIPT_DIR}/qualification/dev_native_receipts.py" finish \
      --derived-data "${DERIVED_DATA}" --root "${NATIVE_RECEIPT_ROOT}"
  fi
}
on_exit() {
  local status=$?
  if ! finish_native_receipts; then
    echo "ERROR: native receipt finalization failed for ${NATIVE_RECEIPT_ROOT}; the next build" \
      "may refuse this run's staged package (NativeIdentity.current was not advanced)" >&2
    if [[ "${status}" == 0 ]]; then
      status=3
    fi
  fi
  release_lock
  exit "${status}"
}
# <<< exit-finalization
trap on_exit EXIT
wait_for_memory
if [[ "${LOCK_ENABLED}" == 1 ]]; then
  if [[ -L "${LOCK_PATH}" ]]; then
    echo "ERROR: heavy-gate lock must not be a symbolic link: ${LOCK_PATH}" >&2
    exit 1
  fi
  /bin/mkdir -p "$(/usr/bin/dirname "${LOCK_PATH}")"
  exec 7>>"${LOCK_PATH}"
  SHARED_ARGS=()
  if (( DEV_SLOTS > 1 )); then
    SLOT_FDS=()
    for (( slot = 0; slot < DEV_SLOTS; slot++ )); do
      if [[ -L "${LOCK_PATH}.slot-${slot}" ]]; then
        echo "ERROR: heavy-gate slot must not be a symbolic link: ${LOCK_PATH}.slot-${slot}" >&2
        exit 1
      fi
      # Slot descriptors 8, 9, 10.
      eval "exec $((8 + slot))>>\"\${LOCK_PATH}.slot-${slot}\""
      SLOT_FDS+=("$((8 + slot))")
    done
    SHARED_ARGS=(--shared --slot-fds "$(IFS=,; echo "${SLOT_FDS[*]}")")
    # Writer priority: a queued exclusive phase (qualifier, Tier 2) runs before new dev
    # loops take slots; the helper logs the back-off. Escape hatch for emergencies.
    if [[ "${MACSCOPE_DEV_IGNORE_EXCLUSIVE_WAITER:-0}" == 1 ]]; then
      SHARED_ARGS+=(--ignore-exclusive-waiter)
    fi
  fi
  /usr/bin/python3 -B "${SCRIPT_DIR}/qualification/heavy_gate_lock.py" acquire \
    --fd 7 --lock "${LOCK_PATH}" --pid "$$" --work-root "${ROOT_DIR}" \
    --integration-ref "dev-loop" --mode "dev-loop" --run-root "${DERIVED_DATA}" \
    ${SHARED_ARGS[@]+"${SHARED_ARGS[@]}"}
  LOCK_HELD=1
fi
LOCKED="$(clock)"

# 1. Project generation only when its inputs changed. This runs bootstrap,
# dependency staging and XcodeGen, which can take minutes of CPU on a cold
# lane, so it runs under the heavy-gate lock like the build (R10.3).
"${ROOT_DIR}/script/build_and_run.sh" --prepare
# The qualifier binds the generated project to an exact file allowlist; a new shared scheme
# missing from it breaks every qualifier run (#378 -> #386). Fail here instead.
if [[ "${MACSCOPE_DEV_SKIP_PROJECT_CHECK:-0}" != 1 ]]; then
  /usr/bin/python3 -B "${SCRIPT_DIR}/qualification/check_generated_project.py" "${XCODEPROJ}" || exit $?
fi
PREPARED="$(clock)"

# Native receipt mode: --native-verbose enters it; once a DerivedData has a
# registered NativeIdentity.current, every later run keeps it, with a fresh
# per-run source-identity root and the registered root as prior staged evidence.
# A caller-supplied receipt root is used as is.
if [[ -z "${MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT:-}" ]]; then
  NATIVE_RECEIPT_REGISTER=()
  if [[ "${NATIVE_VERBOSE}" == 1 ]]; then
    NATIVE_RECEIPT_REGISTER=(--register)
  fi
  NATIVE_RECEIPT_EXPORTS="$(/usr/bin/python3 -B "${SCRIPT_DIR}/qualification/dev_native_receipts.py" begin \
    --derived-data "${DERIVED_DATA}" ${NATIVE_RECEIPT_REGISTER[@]+"${NATIVE_RECEIPT_REGISTER[@]}"})" || exit $?
  eval "${NATIVE_RECEIPT_EXPORTS}"
  if [[ -n "${MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT:-}" ]]; then
    NATIVE_RECEIPT_ROOT="${MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT}"
    echo "==> native receipts: ${NATIVE_RECEIPT_ROOT} (prior: ${MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT:-none})" >&2
  fi
fi

if [[ "${NATIVE_VERBOSE}" == 1 ]]; then
  # One native producer owns CTest and publication. Do not compile/test a second
  # local artifact before Xcode resolves the very same source-keyed cache entry.
  SLEIGH_ROOT="$(/usr/bin/sed -n 's/^MACSCOPE_SLEIGH_MATERIALIZATION_ROOT = //p' \
    "${ROOT_DIR}/MacScope/DependencyRoots.local.xcconfig" 2>/dev/null | /usr/bin/tail -1)"
  if [[ -z "${SLEIGH_ROOT}" || ! -d "${SLEIGH_ROOT}" ]]; then
    echo "ERROR: --native-verbose needs MACSCOPE_SLEIGH_MATERIALIZATION_ROOT from bootstrap" >&2
    exit 1
  fi
  export MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE=shared-view
  echo "==> native bridge single producer; source receipts: ${MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT}" >&2
  NATIVE_STATUS=0
  /usr/bin/nice -n 5 /usr/bin/python3 -B "${SCRIPT_DIR}/qualification/dev_dependency_cache.py" \
    resolve --component native-bridge --repository-root "${ROOT_DIR}" \
    --materialization-root "${SLEIGH_ROOT}" || NATIVE_STATUS=$?
  echo "==> native bridge resolution exit ${NATIVE_STATUS}" >&2
  if [[ "${NATIVE_STATUS}" != 0 || "${NATIVE_ONLY:-0}" == 1 ]]; then
    exit "${NATIVE_STATUS}"
  fi
fi

echo "==> dev loop (iteration only, not evidence): ${DERIVED_DATA}" >&2
BUILD_STATUS=0
"${XCODEBUILD[@]}" "${ONLY_TESTING[@]}" build-for-testing || BUILD_STATUS=$?
BUILT="$(clock)"
TEST_STATUS=0
if [[ "${BUILD_STATUS}" == 0 && "${BUILD_ONLY}" == 0 ]]; then
  TEST_TIMEOUT_ARGS=()
  if [[ "${TEST_TIMEOUT_SECONDS}" != 0 ]]; then
    TEST_TIMEOUT_ARGS=(-test-timeouts-enabled YES
      -default-test-execution-time-allowance "${TEST_TIMEOUT_SECONDS}"
      -maximum-test-execution-time-allowance "${TEST_TIMEOUT_SECONDS}")
  fi
  # Parallel test clones share UserDefaults.standard through cfprefsd, so tests that set
  # the MacScopeSSALifter default leak it into sibling processes. MACSCOPE_DEV_PARALLEL_TESTING=0
  # runs the selectors serially in one process.
  PARALLEL_ARGS=()
  if [[ "${MACSCOPE_DEV_PARALLEL_TESTING:-1}" == 0 ]]; then
    PARALLEL_ARGS=(-parallel-testing-enabled NO)
  fi
  "${XCODEBUILD[@]}" "${ONLY_TESTING[@]}" ${TEST_TIMEOUT_ARGS[@]+"${TEST_TIMEOUT_ARGS[@]}"} \
    ${PARALLEL_ARGS[@]+"${PARALLEL_ARGS[@]}"} test-without-building || TEST_STATUS=$?
fi
TESTED="$(clock)"
release_lock

echo "==> dev loop timings: lock wait $(elapsed "${LOOP_STARTED}" "${LOCKED}")s," \
  "prepare $(elapsed "${LOCKED}" "${PREPARED}")s," \
  "build-for-testing $(elapsed "${PREPARED}" "${BUILT}")s," \
  "test $(elapsed "${BUILT}" "${TESTED}")s," \
  "total $(elapsed "${LOOP_STARTED}" "${TESTED}")s" >&2
if [[ "${BUILD_STATUS}" != 0 ]]; then
  exit "${BUILD_STATUS}"
fi
exit "${TEST_STATUS}"
