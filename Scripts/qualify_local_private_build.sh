#!/usr/bin/env bash
# Reproducible private MacScope qualification from sealed source and pinned inputs.

set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/work_root.sh
source "${SCRIPT_DIR}/lib/work_root.sh"
# Explicit new input scope; the ordinary qualifier and Release policy remain unchanged.
for argument in "$@"; do
  if [[ "$argument" == --cache-release-admission ]]; then
    exec /usr/bin/python3 -B "$SCRIPT_DIR/qualification/cache_release_build.py" "$@"
  fi
done
TRUSTED_RESTORE_TOOL="${SCRIPT_DIR}/qualification/restore_build_source.py"
if [[ ! -f "${TRUSTED_RESTORE_TOOL}" || -L "${TRUSTED_RESTORE_TOOL}" || \
      "$(/usr/bin/stat -f '%l' "${TRUSTED_RESTORE_TOOL}")" != 1 ]]; then
  echo "ERROR: trusted build-source restore helper must be an ordinary adjacent file" >&2
  exit 1
fi
TRUSTED_RESTORE_TOOL_FD=8
if ! exec 8<"${TRUSTED_RESTORE_TOOL}"; then
  echo "ERROR: trusted build-source restore helper could not be opened" >&2
  exit 1
fi
if ! TRUSTED_RESTORE_TOOL_ADMISSION="$(
  /usr/bin/python3 -B - \
    "${TRUSTED_RESTORE_TOOL}" "${TRUSTED_RESTORE_TOOL_FD}" <<'PY'
import hashlib
import json
import os
import stat
import sys

path = sys.argv[1]
descriptor = int(sys.argv[2])
stable_fields = (
    "st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns"
)
path_metadata = os.lstat(path)
descriptor_metadata = os.fstat(descriptor)
path_binding = tuple(getattr(path_metadata, field) for field in stable_fields)
descriptor_binding = tuple(getattr(descriptor_metadata, field) for field in stable_fields)
if (
    path_binding != descriptor_binding
    or not stat.S_ISREG(path_metadata.st_mode)
    or stat.S_ISLNK(path_metadata.st_mode)
    or path_metadata.st_nlink != 1
    or path_metadata.st_size > 1024 * 1024
):
    raise SystemExit("trusted build-source restore helper binding is unsafe")
payload = bytearray()
while len(payload) <= 1024 * 1024:
    chunk = os.pread(
        descriptor,
        min(1024 * 1024, 1024 * 1024 + 1 - len(payload)),
        len(payload),
    )
    if not chunk:
        break
    payload.extend(chunk)
if (
    len(payload) != path_metadata.st_size
    or tuple(getattr(os.fstat(descriptor), field) for field in stable_fields) != path_binding
    or tuple(getattr(os.lstat(path), field) for field in stable_fields) != path_binding
):
    raise SystemExit("trusted build-source restore helper changed during admission")
print(hashlib.sha256(bytes(payload)).hexdigest())
print(json.dumps(path_binding, separators=(",", ":")))
PY
)"; then
  echo "ERROR: trusted build-source restore helper identity could not be frozen" >&2
  exit 1
fi
if [[ "${TRUSTED_RESTORE_TOOL_ADMISSION}" != *$'\n'* ]]; then
  echo "ERROR: trusted build-source restore helper identity could not be frozen" >&2
  exit 1
fi
TRUSTED_RESTORE_TOOL_SHA256="${TRUSTED_RESTORE_TOOL_ADMISSION%%$'\n'*}"
TRUSTED_RESTORE_TOOL_IDENTITY="${TRUSTED_RESTORE_TOOL_ADMISSION#*$'\n'}"
if [[ ! "${TRUSTED_RESTORE_TOOL_SHA256}" =~ ^[0-9a-f]{64}$ || \
      -z "${TRUSTED_RESTORE_TOOL_IDENTITY}" ]]; then
  echo "ERROR: trusted build-source restore helper identity could not be frozen" >&2
  exit 1
fi
run_trusted_restore_tool() {
  local status
  if /usr/bin/python3 -B - \
      "${TRUSTED_RESTORE_TOOL_FD}" \
      "${TRUSTED_RESTORE_TOOL_SHA256}" \
      "${TRUSTED_RESTORE_TOOL_IDENTITY}" \
      "${TRUSTED_RESTORE_TOOL}" "$@" <<'PY'
import hashlib
import json
import os
import stat
import sys

descriptor = int(sys.argv[1])
expected_sha256 = sys.argv[2]
expected_binding = tuple(json.loads(sys.argv[3]))
path = sys.argv[4]
arguments = sys.argv[5:]
stable_fields = (
    "st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns"
)


def binding(metadata):
    return tuple(getattr(metadata, field) for field in stable_fields)


def read_exact():
    metadata = os.fstat(descriptor)
    if (
        binding(metadata) != expected_binding
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size > 1024 * 1024
    ):
        raise RuntimeError("trusted build-source restore helper descriptor changed")
    payload = bytearray()
    while len(payload) <= 1024 * 1024:
        chunk = os.pread(
            descriptor,
            min(1024 * 1024, 1024 * 1024 + 1 - len(payload)),
            len(payload),
        )
        if not chunk:
            break
        payload.extend(chunk)
    if (
        len(payload) != metadata.st_size
        or len(payload) > 1024 * 1024
        or binding(os.fstat(descriptor)) != expected_binding
        or binding(os.lstat(path)) != expected_binding
        or hashlib.sha256(payload).hexdigest() != expected_sha256
    ):
        raise RuntimeError("trusted build-source restore helper identity changed")
    return bytes(payload)


payload = read_exact()
namespace = {
    "__name__": "macscope_trusted_build_source_restore",
    "__file__": path,
    "__package__": None,
}
exec(compile(payload, path, "exec", dont_inherit=True), namespace)
entry_point = namespace.get("main")
if not callable(entry_point):
    raise RuntimeError("trusted build-source restore helper has no entry point")
status = entry_point(arguments)
read_exact()
raise SystemExit(status)
PY
  then
    status=0
  else
    status=$?
  fi
  return "${status}"
}
DEFAULT_SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
SOURCE_ROOT="${DEFAULT_SOURCE_ROOT}"
WORK_ROOT=""
DEPENDENCY_CACHE_ROOT=""
RESUME_RUN=""
RETAINED_RELEASE_QUALIFICATION_INPUTS=""
NATIVE_RELEASE_ADMISSION=""
PATTERN_ADAPTER_ROOT="${MACSCOPE_PATTERN_ADAPTER_ROOT:-}"
PATTERN_ADAPTER_RECEIPT="${MACSCOPE_PATTERN_ADAPTER_RECEIPT:-}"
MODE="full-test"
ONLY_TESTING=()
SIGNING="development"
XCODE_OUTPUT="mirror"
INTEGRATION_REF=""
EXPECTED_INTEGRATION_COMMIT=""
MATERIALIZE_DEPENDENCIES=0
# D1: verified dependency/bootstrap receipts are always reused; there is no
# re-verification mode.
VERIFICATION_REUSE=1
VERIFICATION_CACHE_ROOT=""
COMPILATION_CACHE_ENABLED=1
COMPILATION_CACHE_ROOT=""
COMPILATION_CACHE_EXPLICIT=0
PATH_INDEPENDENT_CACHE=0
INSTALLED_UI_PRODUCTS="auto"
RELEASE_CANDIDATE="auto"
GATE_LOCK_ENABLED=1
GATE_LOCK_PATH="${MACSCOPE_GATE_LOCK:-$(macscope_work_root)/.macscope-heavy-gate.lock}"
GATE_LOCK_TIMEOUT=1800
GATE_LOCK_SHARED=0
PERSISTENT_RUN=""
PROCESS_NICE=""

usage() {
  cat <<'EOF'
usage: qualify_local_private_build.sh --work-root PATH [options]

Options:
  --source-root PATH       Clean Git worktree (admitted by HEAD/tree identity) or
                           a Git-less sealed source export.
  --dependency-cache-root PATH
                           Reusable verified dependency/toolchain cache
                           (default: <work-root>/dependencies).
  --pattern-adapter-root PATH
                           Retained staged pattern adapter directory (absolute,
                           canonical, owned; holds MacScopePatternAdapter.a,
                           module.modulemap and include/MacScopePatternAdapter.h).
                           Default: $MACSCOPE_PATTERN_ADAPTER_ROOT. Exported
                           before bootstrap so DependencyRoots.local.xcconfig
                           carries it. Nothing is rebuilt or rehashed.
  --pattern-adapter-receipt PATH
                           Accepted producer receipt for that root (required
                           whenever a root is supplied).
                           Default: $MACSCOPE_PATTERN_ADAPTER_RECEIPT.
  --resume-run PATH        Resume a run directly under <work-root>/runs while
                           retaining its sealed source and DerivedData.
  --retained-release-qualification-inputs PATH
                           Inherit unchanged dependency manifest digests from an accepted Release receipt.
  --native-release-admission PATH
                           Typed admission of the separately produced native Release archive.
  --mode MODE              prepare, smoke, focused-test, full-test, or release.
  --only-testing FILTER    Repeatable in focused-test/full-test; focused-test requires at least one.
  --signing MODE           development or isolated-ci (default: development).
  --xcode-output MODE      mirror or quiet (default: mirror). Quiet selects
                           Xcode warnings/errors-only output; logs retain all
                           generated output and stage timings remain enabled.
  --integration-ref REF    Locally resolved canonical integration ref.
                           Required; must be a fully qualified refs/remotes ref.
  --integration-commit SHA Expected canonical integration commit. Required when
                           --source-root is a Git-less sealed source export.
  --materialize-dependencies
                           Record explicit network permission for compatibility
                           with qualification receipts. Repository-owned
                           dependencies are complete and ordinary qualification
                           remains offline without using this permission.
  --verification-cache-root PATH
                           Shared store of per-blob source SHA-256 records and
                           dependency/bootstrap verification receipts
                           (default: <dependency-cache-root>/verification.noindex).
  --no-verification-reuse  Refused. Verified inputs are never re-verified
                           (owner decision D1, 2026-10-12).
  --compilation-cache-root PATH
                           Shared Xcode compilation cache (CAS) for smoke and
                           focused-test builds; the name must end in .noindex
                           (default: <dependency-cache-root>/compilation-cache.noindex).
                           full-test and release never use it.
  --no-compilation-cache   Build without Xcode compilation caching.
  --compilation-cache      Explicitly enable the compilation cache, including
                           for full-test (CI opt-in). Never for release; Gate F
                           passes no option and so never uses it.
  --path-independent-cache Map the whole run root to a stable alias
                           (<dependency-cache-root>/build-alias.noindex/run, a
                           symlink retargeted under the heavy-gate lock) so
                           content-identical inputs hit the cache across run
                           roots and source paths. #filePath then names the
                           alias, which resolves to this run while it holds the
                           lock. Requires the cache and the heavy-gate lock.
                           smoke only: focused-test and full-test ignore it
                           (test bundles need real #filePath source paths).
  --installed-ui-products auto|build|skip
                           auto (default): build the installed UI-test bundle
                           only where it is consumed, i.e. full-test, whose
                           installed-acceptance preparation (Gate F) needs it.
                           build: same as auto (full-test only).
                           skip: full-test without the installed UI-test
                           bundle and without installed-acceptance preparation.
  --release-candidate auto|build|skip
                           auto (default): full-test and release build the
                           certificate-backed Release candidate (Gate F and
                           installed acceptance consume it). build: same as
                           auto (full-test only). skip: full-test without the
                           Release build and without installed-acceptance
                           preparation; final validation covers the Debug app.
                           CI uses skip only on intermediate PR pushes.
  --gate-lock PATH         Machine-wide heavy-gate lock held only around Xcode
                           build/test/sign actions (default: $MACSCOPE_GATE_LOCK
                           or .macscope-heavy-gate.lock in the work root).
  --gate-lock-timeout SECONDS
                           Give up waiting for the heavy-gate lock after
                           SECONDS (default: 1800; 0 waits without limit).
  --no-gate-lock           Do not take the heavy-gate lock.
  --gate-lock-shared       Take one shared dev-loop slot of the heavy-gate lock
                           (flock LOCK_SH plus one of slots 0-2) instead of the
                           exclusive lock, so lanes are never starved (CI).
  --persistent-run NAME    Use runs/run.NAME as the run root and keep its
                           DerivedData and the receipt-bound native package view
                           across runs; other run metadata is replaced. NAME: [A-Za-z0-9._-]{1,64}.
  --nice N                 Lower this run's priority (nice 0-20; preserve lower inherited priority).

Modes: prepare stops after sealed source admission, dependency views and the
qualification input receipt (no bootstrap, no Xcode). smoke adds bootstrap and
a Debug build; focused-test/full-test/release add the selected Xcode actions.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root)
      SOURCE_ROOT="${2:?missing value for --source-root}"
      shift 2
      ;;
    --work-root)
      WORK_ROOT="${2:?missing value for --work-root}"
      shift 2
      ;;
    --dependency-cache-root)
      DEPENDENCY_CACHE_ROOT="${2:?missing value for --dependency-cache-root}"
      shift 2
      ;;
    --pattern-adapter-root)
      PATTERN_ADAPTER_ROOT="${2:?missing value for --pattern-adapter-root}"
      shift 2
      ;;
    --pattern-adapter-receipt)
      PATTERN_ADAPTER_RECEIPT="${2:?missing value for --pattern-adapter-receipt}"
      shift 2
      ;;
    --retained-release-qualification-inputs)
      RETAINED_RELEASE_QUALIFICATION_INPUTS="${2:?missing retained Release receipt}"
      shift 2
      ;;
    --native-release-admission)
      NATIVE_RELEASE_ADMISSION="${2:?missing native Release admission}"
      shift 2
      ;;
    --resume-run)
      RESUME_RUN="${2:?missing value for --resume-run}"
      shift 2
      ;;
    --mode)
      MODE="${2:?missing value for --mode}"
      shift 2
      ;;
    --only-testing)
      ONLY_TESTING+=("${2:?missing value for --only-testing}")
      shift 2
      ;;
    --signing)
      SIGNING="${2:?missing value for --signing}"
      shift 2
      ;;
    --xcode-output)
      XCODE_OUTPUT="${2-}"
      shift
      if [[ $# -gt 0 ]]; then shift; fi
      ;;
    --integration-ref)
      INTEGRATION_REF="${2:?missing value for --integration-ref}"
      shift 2
      ;;
    --integration-commit)
      EXPECTED_INTEGRATION_COMMIT="${2:?missing value for --integration-commit}"
      shift 2
      ;;
    --materialize-dependencies)
      MATERIALIZE_DEPENDENCIES=1
      shift
      ;;
    --verification-cache-root)
      VERIFICATION_CACHE_ROOT="${2:?missing value for --verification-cache-root}"
      shift 2
      ;;
    --no-verification-reuse)
      echo "ERROR: --no-verification-reuse is not supported: verified inputs are never re-verified (owner decision D1, 2026-10-12)" >&2
      exit 2
      ;;
    --compilation-cache-root)
      COMPILATION_CACHE_ROOT="${2:?missing value for --compilation-cache-root}"
      shift 2
      ;;
    --no-compilation-cache)
      COMPILATION_CACHE_ENABLED=0
      shift
      ;;
    --compilation-cache)
      COMPILATION_CACHE_EXPLICIT=1
      shift
      ;;
    --path-independent-cache)
      PATH_INDEPENDENT_CACHE=1
      shift
      ;;
    --installed-ui-products)
      INSTALLED_UI_PRODUCTS="${2:?missing value for --installed-ui-products}"
      shift 2
      ;;
    --release-candidate)
      RELEASE_CANDIDATE="${2:?missing value for --release-candidate}"
      shift 2
      ;;
    --gate-lock)
      GATE_LOCK_PATH="${2:?missing value for --gate-lock}"
      shift 2
      ;;
    --gate-lock-timeout)
      GATE_LOCK_TIMEOUT="${2:?missing value for --gate-lock-timeout}"
      shift 2
      ;;
    --no-gate-lock)
      GATE_LOCK_ENABLED=0
      shift
      ;;
    --gate-lock-shared)
      GATE_LOCK_SHARED=1
      shift
      ;;
    --persistent-run)
      PERSISTENT_RUN="${2:?missing value for --persistent-run}"
      shift 2
      ;;
    --nice)
      PROCESS_NICE="${2:?missing value for --nice}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${XCODE_OUTPUT}" in
  mirror|quiet) ;;
  *)
    echo "ERROR: --xcode-output must be mirror or quiet" >&2
    exit 2
    ;;
esac

# Reuse verified source/dependency receipts in every mode, including Release.
# Signing and exact source identity remain independently required.

if [[ -z "${WORK_ROOT}" ]]; then
  echo "ERROR: --work-root is required" >&2
  exit 2
fi
# The retained pattern adapter is an already-staged input owned by its producer
# receipt. When supplied it must be canonical and owned, exactly as the Release
# route requires; a supplied root that is unreachable is refused here, never
# skipped. Presence only: the archive is never rebuilt or rehashed. When no
# root is supplied the project's "Require retained pattern adapter" build phase
# still refuses to build.
if [[ -n "${PATTERN_ADAPTER_ROOT}" ]]; then
  if [[ -z "${PATTERN_ADAPTER_RECEIPT}" ]]; then
    echo "ERROR: --pattern-adapter-root requires --pattern-adapter-receipt (accepted producer receipt for ${PATTERN_ADAPTER_ROOT})" >&2
    exit 2
  fi
  if ! /usr/bin/python3 -B - "${PATTERN_ADAPTER_ROOT}" "${PATTERN_ADAPTER_RECEIPT}" <<'PYPATTERN'
import os, stat, sys
root, receipt = sys.argv[1], sys.argv[2]
def refuse(message):
    sys.stderr.write("ERROR: retained pattern adapter: " + message + "\n")
    raise SystemExit(1)
if not os.path.isabs(root) or any(token in root for token in ('"', '$', '//', '\\', '\n', '\r')):
    refuse("root must be absolute and representable in dependency configuration: " + root)
try:
    status = os.stat(root)
    canonical = os.path.realpath(root)
except OSError:
    refuse("root is missing or unreachable: " + root)
if canonical != root or not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid():
    refuse("root must be a canonical directory owned by the current user: " + root)
for name in ("MacScopePatternAdapter.a", "module.modulemap", "include/MacScopePatternAdapter.h"):
    if not os.path.isfile(os.path.join(root, name)):
        refuse("missing " + name + " under root " + root)
if not os.path.isabs(receipt) or not os.path.isfile(receipt) or os.path.islink(receipt):
    refuse("producer receipt must be an absolute ordinary file: " + receipt)
PYPATTERN
  then
    exit 2
  fi
  export MACSCOPE_PATTERN_ADAPTER_ROOT="${PATTERN_ADAPTER_ROOT}"
  export MACSCOPE_PATTERN_ADAPTER_RECEIPT="${PATTERN_ADAPTER_RECEIPT}"
fi
# The compilation cache is owner-controlled CLI state like the verification
# cache, so the same authority boundary applies: full-test (CI, Gate F) and
# release compile every product from source. prepare runs no Xcode action.
COMPILATION_CACHE_DISABLED_REASON=""
if [[ "${COMPILATION_CACHE_ENABLED}" == 0 ]]; then
  COMPILATION_CACHE_DISABLED_REASON="--no-compilation-cache"
  if [[ -n "${COMPILATION_CACHE_ROOT}" ]]; then
    echo "ERROR: --compilation-cache-root cannot be combined with --no-compilation-cache" >&2
    exit 2
  fi
fi
if [[ "${COMPILATION_CACHE_EXPLICIT}" == 1 && "${COMPILATION_CACHE_ENABLED}" == 0 ]]; then
  echo "ERROR: --compilation-cache cannot be combined with --no-compilation-cache" >&2
  exit 2
fi
if [[ "${MODE}" == release ]]; then
  if [[ -n "${COMPILATION_CACHE_ROOT}" || "${COMPILATION_CACHE_EXPLICIT}" == 1 ]]; then
    echo "ERROR: release always compiles from source; compilation cache options are not accepted" >&2
    exit 2
  fi
  COMPILATION_CACHE_ENABLED=0
  COMPILATION_CACHE_DISABLED_REASON="release compiles every product from source"
fi
case "${MODE}" in
  prepare)
    COMPILATION_CACHE_ENABLED=0
    COMPILATION_CACHE_DISABLED_REASON="prepare runs no Xcode action"
    ;;
esac
# full-test default (Gate F, which passes no option): compile from source. CI
# may opt in explicitly with --compilation-cache.
if [[ "${MODE}" == full-test && "${COMPILATION_CACHE_EXPLICIT}" != 1 ]]; then
  if [[ -n "${COMPILATION_CACHE_ROOT}" ]]; then
    echo "ERROR: full-test uses --compilation-cache-root only with --compilation-cache" >&2
    exit 2
  fi
  COMPILATION_CACHE_ENABLED=0
  COMPILATION_CACHE_DISABLED_REASON="full-test compiles every product from source unless --compilation-cache"
fi
if [[ "${PATH_INDEPENDENT_CACHE}" == 1 && \
      ( "${COMPILATION_CACHE_ENABLED}" != 1 || "${GATE_LOCK_ENABLED}" != 1 ) ]]; then
  echo "ERROR: --path-independent-cache requires an enabled compilation cache and the heavy-gate lock" >&2
  exit 2
fi
# The alias cannot be confined to cache keys: Xcode's compilation cache applies
# SWIFT_/CLANG_OTHER_PREFIX_MAPPINGS as scanner prefix maps, so the mapped path
# is what the frontend compiles and what #filePath/#file embed (a cached object
# is only path-independent if its embedded paths are). Test bundles read the
# source tree through #filePath and reject symlinked paths, so test actions
# keep the default mapping, under which first-party sources keep real paths.
PATH_INDEPENDENT_CACHE_EXCLUDED_REASON=""
if [[ "${PATH_INDEPENDENT_CACHE}" == 1 ]]; then
  case "${MODE}" in
    focused-test|full-test)
      PATH_INDEPENDENT_CACHE=0
      PATH_INDEPENDENT_CACHE_EXCLUDED_REASON="${MODE} compiles test bundles that read real source paths through #filePath"
      echo "==> path-independent compilation cache not applied: ${PATH_INDEPENDENT_CACHE_EXCLUDED_REASON}" >&2
      ;;
  esac
fi
case "${INSTALLED_UI_PRODUCTS}:${MODE}" in
  auto:*|build:full-test|skip:full-test) ;;
  build:*|skip:*)
    echo "ERROR: --installed-ui-products ${INSTALLED_UI_PRODUCTS} is not valid for ${MODE}" >&2
    exit 2
    ;;
  *)
    echo "ERROR: --installed-ui-products must be auto, build or skip" >&2
    exit 2
    ;;
esac
# smoke/focused-test/prepare never build Release, so CI's one expression may pass
# build or skip there as a no-op; release itself cannot skip its candidate.
case "${RELEASE_CANDIDATE}:${MODE}" in
  auto:*|build:*|skip:full-test|skip:smoke|skip:focused-test|skip:prepare) ;;
  skip:*)
    echo "ERROR: --release-candidate ${RELEASE_CANDIDATE} is not valid for ${MODE}" >&2
    exit 2
    ;;
  *)
    echo "ERROR: --release-candidate must be auto, build or skip" >&2
    exit 2
    ;;
esac

if [[ -z "${INTEGRATION_REF}" ]]; then
  echo "ERROR: --integration-ref is required; no remote branch is authoritative by default" >&2
  exit 2
fi
if [[ ! "${INTEGRATION_REF}" =~ ^refs/remotes/([A-Za-z0-9][A-Za-z0-9._-]{0,127})/(.+)$ ]]; then
  echo "ERROR: --integration-ref must be a fully qualified refs/remotes/<remote>/<branch>" >&2
  exit 2
fi
INTEGRATION_REMOTE="${BASH_REMATCH[1]}"
INTEGRATION_BRANCH="${BASH_REMATCH[2]}"
if (( ${#INTEGRATION_REF} > 256 )) || \
   [[ "${INTEGRATION_REMOTE}" == *. || \
      "${INTEGRATION_REMOTE}" == *.[Ll][Oo][Cc][Kk] || \
      "${INTEGRATION_BRANCH}" == HEAD ]]; then
  echo "ERROR: --integration-ref must name a safe explicit remote branch" >&2
  exit 2
fi
IFS='/' read -r -a INTEGRATION_BRANCH_PARTS <<<"${INTEGRATION_BRANCH}"
for INTEGRATION_BRANCH_PART in "${INTEGRATION_BRANCH_PARTS[@]}"; do
  if [[ -z "${INTEGRATION_BRANCH_PART}" || \
        "${INTEGRATION_BRANCH_PART}" == . || \
        "${INTEGRATION_BRANCH_PART}" == .. || \
        "${INTEGRATION_BRANCH_PART}" == .* || \
        "${INTEGRATION_BRANCH_PART}" == *. || \
        "${INTEGRATION_BRANCH_PART}" == *.[Ll][Oo][Cc][Kk] ]]; then
    echo "ERROR: --integration-ref contains an unsafe branch component" >&2
    exit 2
  fi
done
INTEGRATION_REPOSITORY_LABEL="${INTEGRATION_REMOTE}:MacScope"
if ! /usr/bin/git check-ref-format "${INTEGRATION_REF}" >/dev/null 2>&1; then
  echo "ERROR: --integration-ref must be a canonical Git ref name" >&2
  exit 2
fi
if [[ "${INTEGRATION_REF}" =~ ^refs/remotes/[^/]+/HEAD$ ]]; then
  echo "ERROR: --integration-ref must name an explicit remote branch, not remote HEAD" >&2
  exit 2
fi
if [[ -n "${EXPECTED_INTEGRATION_COMMIT}" && \
      ! "${EXPECTED_INTEGRATION_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: --integration-commit must be a lowercase 40-hex Git commit ID" >&2
  exit 2
fi
if [[ -n "${PERSISTENT_RUN}" ]]; then
  if [[ ! "${PERSISTENT_RUN}" =~ ^[A-Za-z0-9._-]{1,64}$ || "${PERSISTENT_RUN}" == . || \
        "${PERSISTENT_RUN}" == .. || -n "${RESUME_RUN}" ]]; then
    echo "ERROR: --persistent-run needs a plain name and cannot be combined with --resume-run" >&2
    exit 2
  fi
fi
if [[ -n "${PROCESS_NICE}" ]]; then
  if [[ ! "${PROCESS_NICE}" =~ ^([0-9]|1[0-9]|20)$ ]]; then
    echo "ERROR: --nice must be an integer from 0 to 20" >&2
    exit 2
  fi
  INHERITED_NICE="$(/bin/ps -o nice= -p "$$" | /usr/bin/tr -d ' ')"
  if [[ ! "${INHERITED_NICE}" =~ ^-?[0-9]+$ ]]; then
    echo "ERROR: cannot determine inherited process priority" >&2
    exit 1
  fi
  EFFECTIVE_NICE="${INHERITED_NICE}"
  if (( PROCESS_NICE > INHERITED_NICE )); then
    /usr/bin/renice "${PROCESS_NICE}" -p "$$" >/dev/null
    EFFECTIVE_NICE="$(/bin/ps -o nice= -p "$$" | /usr/bin/tr -d ' ')"
  fi
  echo "qualification priority: requested=${PROCESS_NICE} inherited=${INHERITED_NICE} effective=${EFFECTIVE_NICE}" >&2
fi
if [[ ! "${GATE_LOCK_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --gate-lock-timeout must be a nonnegative integer number of seconds" >&2
  exit 2
fi
if [[ -z "${GATE_LOCK_PATH}" || "${GATE_LOCK_PATH}" != /* ]]; then
  echo "ERROR: --gate-lock must be an absolute path" >&2
  exit 2
fi
if [[ -n "${RESUME_RUN}" && "${MATERIALIZE_DEPENDENCIES}" == 1 ]]; then
  echo "ERROR: --materialize-dependencies cannot be used while resuming a sealed run" >&2
  exit 2
fi
case "${MODE}" in
  prepare|smoke|focused-test|full-test|release) ;;
  *) echo "ERROR: unsupported qualification mode: ${MODE}" >&2; exit 2 ;;
esac
if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}${NATIVE_RELEASE_ADMISSION}" ]]; then
  if [[ "${MODE}" != release || -n "${RESUME_RUN}" ||
        "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" != /* ||
        "${NATIVE_RELEASE_ADMISSION}" != /* ]]; then
    echo "ERROR: retained Release inputs and native admission require a fresh Release run and both absolute paths" >&2
    exit 2
  fi
fi
case "${SIGNING}" in
  development|isolated-ci) ;;
  *) echo "ERROR: unsupported signing mode: ${SIGNING}" >&2; exit 2 ;;
esac
if [[ "${MODE}" == "focused-test" && ${#ONLY_TESTING[@]} == 0 ]]; then
  echo "ERROR: --only-testing is required for focused-test" >&2
  exit 2
fi
if [[ "${MODE}" != "focused-test" && "${MODE}" != "full-test" && ${#ONLY_TESTING[@]} != 0 ]]; then
  echo "ERROR: --only-testing is valid only for focused-test/full-test" >&2
  exit 2
fi
TEST_SELECTION_ARGUMENTS=()
for selector in ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"}; do
  TEST_SELECTION_ARGUMENTS+=("-only-testing:${selector}")
done
if [[ "${MODE}" == full-test && ${#TEST_SELECTION_ARGUMENTS[@]} == 0 ]]; then
  # Every hosted test bundle (D12 layer 3 split CoreTests into CoreTests + Phase2Tests).
  TEST_SELECTION_ARGUMENTS=(-only-testing:CoreTests -only-testing:Phase2Tests)
fi
XCODE_JOBS="${MACSCOPE_XCODE_JOBS:-}"
if [[ -z "${XCODE_JOBS}" ]]; then
  XCODE_JOBS="$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || /usr/bin/getconf _NPROCESSORS_ONLN)"
fi
if [[ ! "${XCODE_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: MACSCOPE_XCODE_JOBS must be a positive integer" >&2
  exit 2
fi

SOURCE_ROOT="$(/usr/bin/python3 -B - "${SOURCE_ROOT}" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve(strict=True))
PY
)"
/bin/mkdir -p "${WORK_ROOT}"
WORK_ROOT="$(/usr/bin/python3 -B - "${WORK_ROOT}" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve(strict=True))
PY
)"
if [[ -z "${DEPENDENCY_CACHE_ROOT}" ]]; then
  DEPENDENCY_CACHE_ROOT="${WORK_ROOT}/dependencies"
fi
/bin/mkdir -p "${DEPENDENCY_CACHE_ROOT}"
DEPENDENCY_CACHE_ROOT="$(/usr/bin/python3 -B - "${DEPENDENCY_CACHE_ROOT}" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve(strict=True))
PY
)"

if [[ "${VERIFICATION_REUSE}" == 1 ]]; then
  if [[ -z "${VERIFICATION_CACHE_ROOT}" ]]; then
    # .noindex keeps Spotlight out of the shared receipt store.
    VERIFICATION_CACHE_ROOT="${DEPENDENCY_CACHE_ROOT}/verification.noindex"
  fi
  /bin/mkdir -p "${VERIFICATION_CACHE_ROOT}"
  VERIFICATION_CACHE_ROOT="$(/usr/bin/python3 -B - "${VERIFICATION_CACHE_ROOT}" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve(strict=True))
PY
)"
fi
SOURCE_RECORD_CACHE_ROOT="${VERIFICATION_CACHE_ROOT}/source-records"

if [[ "${COMPILATION_CACHE_ENABLED}" == 1 ]]; then
  if [[ -z "${COMPILATION_CACHE_ROOT}" ]]; then
    COMPILATION_CACHE_ROOT="${DEPENDENCY_CACHE_ROOT}/compilation-cache.noindex"
  fi
  # Same owner-controlled admission as the verification cache: absolute,
  # canonical (no symlink), an ordinary directory owned by this user and not
  # group/world writable. The .noindex suffix keeps Spotlight out of the CAS.
  if ! COMPILATION_CACHE_ROOT="$(/usr/bin/python3 -B - "${COMPILATION_CACHE_ROOT}" <<'PY'
import os
from pathlib import Path
import stat
import sys
root = Path(sys.argv[1])
if not root.is_absolute() or not root.name.endswith(".noindex") or len(root.name) <= len(".noindex"):
    raise SystemExit("compilation cache root must be an absolute path whose name ends in .noindex")
if not root.exists() and not root.is_symlink():
    root.mkdir(mode=0o700)
metadata = root.lstat()
if (root.resolve(strict=True) != root or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022):
    raise SystemExit("compilation cache root must be ordinary, canonical, owner-controlled and not group/world writable")
print(root)
PY
  )"; then
    echo "ERROR: compilation cache root was not admitted" >&2
    exit 2
  fi
  if [[ "${PATH_INDEPENDENT_CACHE}" == 1 ]]; then
    COMPILATION_CACHE_ALIAS_ROOT="${DEPENDENCY_CACHE_ROOT}/build-alias.noindex"
    if ! COMPILATION_CACHE_ALIAS_ROOT="$(/usr/bin/python3 -B - "${COMPILATION_CACHE_ALIAS_ROOT}" <<'PY'
import os
from pathlib import Path
import stat
import sys
root = Path(sys.argv[1])
if not root.exists() and not root.is_symlink():
    root.mkdir(mode=0o700)
metadata = root.lstat()
if (root.resolve(strict=True) != root or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022):
    raise SystemExit("build alias root must be ordinary, canonical, owner-controlled and not group/world writable")
print(root)
PY
    )"; then
      echo "ERROR: build alias root was not admitted" >&2
      exit 2
    fi
  fi
fi

if ! /usr/bin/python3 -B - "${SOURCE_ROOT}" "${WORK_ROOT}" "${DEPENDENCY_CACHE_ROOT}" \
    "${VERIFICATION_CACHE_ROOT:-${DEPENDENCY_CACHE_ROOT}}" \
    "${COMPILATION_CACHE_ROOT:-${DEPENDENCY_CACHE_ROOT}}" <<'PY'
from pathlib import Path
import sys
source, work, cache, verification, compilation = map(Path, sys.argv[1:])


def overlaps(first: Path, second: Path) -> bool:
    try:
        first.relative_to(second)
    except ValueError:
        pass
    else:
        return True
    try:
        second.relative_to(first)
    except ValueError:
        return False
    return True


if (overlaps(source, work) or overlaps(source, cache) or overlaps(source, verification)
        or overlaps(source, compilation)):
    raise SystemExit(1)
for run_owned in (work / "runs", work / "source-export"):
    if overlaps(cache, run_owned) or overlaps(verification, run_owned) or overlaps(compilation, run_owned):
        raise SystemExit(1)
PY
then
  echo "ERROR: qualification work/cache roots and source root must not overlap" >&2
  exit 2
fi

# Source admission runs before any run-source helper (including stage timing)
# may execute, so measure it with the system-wide monotonic clock and append
# the observations once the run's timing receipt exists.
stage_clock() {
  /usr/bin/python3 -B -c 'import datetime, time
print(time.clock_gettime_ns(time.CLOCK_MONOTONIC), datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"))'
}
read -r SOURCE_EXPORT_STARTED_NS SOURCE_EXPORT_STARTED_AT < <(stage_clock)
SOURCE_EXPORT_STAGE="source.git-identity"
# Owner decision D1 (2026-10-12): Git is the source identity. A clean worktree
# whose HEAD and HEAD^{tree} are the integration commit is staged once as an
# APFS clone of its tracked files (Scripts/source_export_provenance.py
# git-stage); nothing re-verifies source bytes afterwards. SOURCE_FILES.json and
# SOURCE_PROVENANCE.json keep their schema for every downstream consumer; file
# SHA-256 values are computed once per Git blob ID and reused by key.
RUNS_ROOT="${WORK_ROOT}/runs"
/bin/mkdir -p "${RUNS_ROOT}"
IS_RESUME=0
if [[ -n "${RESUME_RUN}" ]]; then
  IS_RESUME=1
  RUN_ROOT="$(/usr/bin/python3 -B - "${RESUME_RUN}" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve(strict=True))
PY
)"
  if ! /usr/bin/python3 -B - "${RUNS_ROOT}" "${RUN_ROOT}" <<'PY'
from pathlib import Path
import sys
runs, run = map(Path, sys.argv[1:])
try:
    relative = run.relative_to(runs.resolve(strict=True))
except ValueError:
    raise SystemExit(1)
if len(relative.parts) != 1 or not relative.name.startswith("run."):
    raise SystemExit(1)
PY
  then
    echo "ERROR: --resume-run must name one run directly under ${RUNS_ROOT}" >&2
    exit 2
  fi
  BUILD_SOURCE_ROOT="${RUN_ROOT}/source"
  # A resumed run keeps the source it staged; its recorded identity is checked
  # against the Git source below.
  SOURCE_EXPORT_IDENTITY_JSON="$(/bin/cat "${BUILD_SOURCE_ROOT}/SOURCE_PROVENANCE.json")"
  SOURCE_EXPORT_STAGE="source.git-identity.resume"
else
  if [[ -n "${PERSISTENT_RUN}" ]]; then
    # Keep compiled products and the native package view whose controlled-copy
    # receipt lives outside this run. Deleting that view leaves a valid receipt
    # pointing at missing bytes. Other dependency views are cache-recreated.
    RUN_ROOT="${RUNS_ROOT}/run.${PERSISTENT_RUN}"
    if [[ -L "${RUN_ROOT}" ]]; then
      echo "ERROR: persistent run root must not be a symbolic link: ${RUN_ROOT}" >&2
      exit 1
    fi
    if [[ -d "${RUN_ROOT}" ]]; then
      # A persistent run can itself hold the golden/provenance evidence used
      # by its native admission. Preserve it before replacing current outputs.
      if [[ -n "${NATIVE_RELEASE_ADMISSION}" ]]; then
        NATIVE_RELEASE_ADMISSION="$(/usr/bin/python3 -B \
          "${SCRIPT_DIR}/qualification/persistent_release_evidence.py" \
          --run-root "${RUN_ROOT}" --admission "${NATIVE_RELEASE_ADMISSION}" \
          --lock "${GATE_LOCK_PATH}")"
      fi
      PERSISTENT_KEEP="${RUNS_ROOT}/.keep.${PERSISTENT_RUN}.$$"
      /bin/mkdir -m 700 "${PERSISTENT_KEEP}"
      if [[ -L "${RUN_ROOT}/dependencies" ]]; then
        echo "ERROR: persistent dependencies must not be indirect" >&2
        exit 1
      fi
      PERSISTENT_RETAINED_PATHS=(DerivedData accepted-evidence)
      if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
        PERSISTENT_RETAINED_PATHS+=(dependencies/sleigh-native-source)
      fi
      for retained_path in "${PERSISTENT_RETAINED_PATHS[@]}"; do
        if [[ -e "${RUN_ROOT}/${retained_path}" || -L "${RUN_ROOT}/${retained_path}" ]]; then
          if [[ ! -d "${RUN_ROOT}/${retained_path}" || -L "${RUN_ROOT}/${retained_path}" ]]; then
            echo "ERROR: persistent retained path must be an ordinary directory: ${retained_path}" >&2
            exit 1
          fi
          /bin/mkdir -p "${PERSISTENT_KEEP}/$(dirname "${retained_path}")"
          /bin/mv "${RUN_ROOT}/${retained_path}" "${PERSISTENT_KEEP}/${retained_path}"
        fi
      done
      /bin/chmod -R u+w "${RUN_ROOT}" 2>/dev/null || true
      /bin/rm -rf "${RUN_ROOT:?}"
      /bin/mkdir -m 700 "${RUN_ROOT}"
      for retained_path in "${PERSISTENT_RETAINED_PATHS[@]}"; do
        if [[ -d "${PERSISTENT_KEEP}/${retained_path}" ]]; then
          /bin/mkdir -p "${RUN_ROOT}/$(dirname "${retained_path}")"
          /bin/mv "${PERSISTENT_KEEP}/${retained_path}" "${RUN_ROOT}/${retained_path}"
        fi
      done
      /bin/rmdir "${PERSISTENT_KEEP}/dependencies" "${PERSISTENT_KEEP}" 2>/dev/null || true
    else
      /bin/mkdir -m 700 "${RUN_ROOT}"
    fi
  else
    RUN_ROOT="$(/usr/bin/mktemp -d "${RUNS_ROOT}/run.XXXXXX")"
  fi
  BUILD_SOURCE_ROOT="${RUN_ROOT}/source"
  if [[ -f "${SOURCE_ROOT}/SOURCE_PROVENANCE.json" && ! -e "${SOURCE_ROOT}/.git" ]]; then
    # Git-less sealed export (Gate F): its recorded commit must equal the
    # --integration-commit authority checked below; it is cloned, not re-verified.
    if [[ ! -f "${SOURCE_ROOT}/SOURCE_FILES.json" ]]; then
      echo "ERROR: source export records are incomplete" >&2
      exit 1
    fi
    /bin/cp -c -pR "${SOURCE_ROOT}" "${BUILD_SOURCE_ROOT}"
    SOURCE_EXPORT_IDENTITY_JSON="$(/bin/cat "${BUILD_SOURCE_ROOT}/SOURCE_PROVENANCE.json")"
    SOURCE_EXPORT_STAGE="source.sealed-export.clone"
  else
    SOURCE_STAGE_ARGUMENTS=()
    if [[ -n "${EXPECTED_INTEGRATION_COMMIT}" ]]; then
      SOURCE_STAGE_ARGUMENTS=(--expected-commit "${EXPECTED_INTEGRATION_COMMIT}")
    fi
    SOURCE_EXPORT_IDENTITY_JSON="$(/usr/bin/python3 -B "${SCRIPT_DIR}/source_export_provenance.py" \
      git-stage \
      --repository-root "${SOURCE_ROOT}" \
      --destination "${BUILD_SOURCE_ROOT}" \
      --integration-ref "${INTEGRATION_REF}" \
      --record-cache "${SOURCE_RECORD_CACHE_ROOT}" \
      ${SOURCE_STAGE_ARGUMENTS[@]+"${SOURCE_STAGE_ARGUMENTS[@]}"})"
  fi
fi
BUILD_SOURCE_IDENTITY_JSON="${SOURCE_EXPORT_IDENTITY_JSON}"

# Freeze the exact source candidate once, regardless of whether the caller gave
# us a Git worktree, a reusable sealed export, or a Git-less sealed export. A
# reused export must retain the requested integration ref, and a locally
# resolvable ref must still resolve to the sealed commit without network access.
SOURCE_IDENTITY_OUTPUT="$(/usr/bin/python3 -B - \
  "${SOURCE_EXPORT_IDENTITY_JSON}" \
  "${SOURCE_ROOT}" \
  "${INTEGRATION_REF}" \
  "${EXPECTED_INTEGRATION_COMMIT}" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

provenance_json, source_root_value, requested_ref, expected_commit_value = sys.argv[1:]
expected_commit = expected_commit_value or None
record = json.loads(provenance_json)
commit = record.get("canonical_integration_commit")
head = record.get("git_head_commit")
tree = record.get("git_head_tree")
if (
    record.get("canonical_integration_ref") != requested_ref
    or not isinstance(commit, str)
    or re.fullmatch(r"[0-9a-f]{40}", commit) is None
    or head != commit
    or not isinstance(tree, str)
    or re.fullmatch(r"[0-9a-f]{40}", tree) is None
):
    raise SystemExit("sealed source export is not the exact requested integration candidate")
if expected_commit is not None and commit != expected_commit:
    raise SystemExit(
        "sealed source export does not match the expected integration commit authority"
    )

source_root = Path(source_root_value)
probe = subprocess.run(
    ["/usr/bin/git", "rev-parse", "--show-toplevel"],
    cwd=source_root,
    check=False,
    capture_output=True,
    text=True,
)
if (
    probe.returncode == 0
    and Path(probe.stdout.strip()).resolve(strict=True) == source_root
):
    status = subprocess.run(
        [
            "/usr/bin/git",
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
        ],
        cwd=source_root,
        check=False,
        capture_output=True,
    )
    if status.returncode != 0:
        raise SystemExit("could not verify clean Git source worktree")
    if status.stdout:
        raise SystemExit("Git source worktree is not clean")
    resolved = subprocess.run(
        ["/usr/bin/git", "rev-parse", f"{requested_ref}^{{commit}}"],
        cwd=source_root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    observed_head = subprocess.run(
        ["/usr/bin/git", "rev-parse", "HEAD"],
        cwd=source_root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if resolved != commit or observed_head != commit:
        raise SystemExit("local integration ref no longer resolves to the sealed source candidate")
elif expected_commit is None:
    raise SystemExit(
        "Git-less sealed source qualification requires --integration-commit authority"
    )
print(commit)
print(tree)
PY
)"
if [[ "${SOURCE_IDENTITY_OUTPUT}" != *$'\n'* ]]; then
  echo "ERROR: sealed source identity omitted its commit/tree contract" >&2
  exit 1
fi
INTEGRATION_COMMIT="${SOURCE_IDENTITY_OUTPUT%%$'\n'*}"
INTEGRATION_TREE="${SOURCE_IDENTITY_OUTPUT#*$'\n'}"
if [[ -z "${INTEGRATION_COMMIT}" || -z "${INTEGRATION_TREE}" || \
      "${INTEGRATION_TREE}" == *$'\n'* ]]; then
  echo "ERROR: sealed source identity returned a malformed commit/tree contract" >&2
  exit 1
fi
read -r SOURCE_EXPORT_ENDED_NS _ < <(stage_clock)

DEPENDENCY_NETWORK_ALLOWED=false
DEPENDENCY_NETWORK_USED=false
if [[ "${MATERIALIZE_DEPENDENCIES}" == 1 ]]; then
  DEPENDENCY_NETWORK_ALLOWED=true
fi
if [[ "${IS_RESUME}" == 1 ]]; then
  RECEIPT="${RUN_ROOT}/QUALIFICATION_INPUTS.json"
  if [[ ! -f "${RECEIPT}" ]]; then
    echo "ERROR: resumed run has no qualification receipt: ${RECEIPT}" >&2
    exit 1
  fi
  RESUME_NETWORK_STATE="$(/usr/bin/python3 -B - \
    "${SOURCE_EXPORT_IDENTITY_JSON}" \
    "${RECEIPT}" \
    "${MODE}" \
    "${BUILD_SOURCE_ROOT}" \
    "${DEPENDENCY_CACHE_ROOT}" <<'PY'
import json
from pathlib import Path
import sys
source_provenance, receipt_path, mode, build_source, cache_root = sys.argv[1:]
expected = json.loads(source_provenance)
receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
expected_fields = {
    "build_source_root",
    "dependency_cache_root",
    "dependency_network_allowed",
    "dependency_network_used",
    "ghostty_artifact_manifest_sha256",
    "ghostty_source_dir",
    "ghostty_surface_artifact_root",
    "ghostty_surface_manifest_sha256",
    "ghostty_surface_source_dir",
    "mode",
    "schema_version",
    "sleigh_materialization_manifest_sha256",
    "sleigh_materialization_root",
    "source_identity",
    "zig_executable",
}
checks = {
    "receipt schema": receipt.get("schema_version") == 4,
    "receipt field set": set(receipt) == expected_fields,
    "source identity": receipt.get("source_identity") == expected,
    "mode": receipt.get("mode") == mode,
    "build source root": receipt.get("build_source_root") == str(Path(build_source).resolve(strict=True)),
    "dependency cache root": receipt.get("dependency_cache_root") == str(Path(cache_root).resolve(strict=True)),
    "network allowed type": isinstance(receipt.get("dependency_network_allowed"), bool),
    "network remained unused": receipt.get("dependency_network_used") is False,
}
failed = [name for name, accepted in checks.items() if not accepted]
if failed:
    raise SystemExit("resumed qualification input mismatch: " + ", ".join(failed))
print("true" if receipt["dependency_network_allowed"] else "false")
PY
)"
  if [[ "${RESUME_NETWORK_STATE}" != true && "${RESUME_NETWORK_STATE}" != false ]]; then
    echo "ERROR: resumed qualification receipt returned invalid network authority" >&2
    exit 1
  fi
  DEPENDENCY_NETWORK_ALLOWED="${RESUME_NETWORK_STATE}"
fi
RECEIPT="${RUN_ROOT}/QUALIFICATION_INPUTS.json"

# Installed acceptance admits only an offline full-test qualification. Its
# preparation-receipt producer deliberately binds a clean Git repository (not
# the disposable Git-less build export), so prove that authority before any
# dependency work or Xcode execution. The source-export checks above already
# bound this repository to the exact sealed commit/tree and integration ref.
PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY=0
if [[ "${MODE}" == full-test && "${DEPENDENCY_NETWORK_ALLOWED}" == false ]]; then
  PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY=1
  PREPARATION_SOURCE_BRANCH="$(/usr/bin/git -C "${SOURCE_ROOT}" branch --show-current 2>/dev/null || true)"
  if [[ -z "${PREPARATION_SOURCE_BRANCH}" ]]; then
    echo "ERROR: installed acceptance preparation requires an exact clean, attached Git source worktree" >&2
    exit 1
  fi
  if [[ "$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)" != "${SOURCE_ROOT}" || \
        "$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse HEAD 2>/dev/null || true)" != "${INTEGRATION_COMMIT}" || \
        "$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse 'HEAD^{tree}' 2>/dev/null || true)" != "${INTEGRATION_TREE}" ]]; then
    echo "ERROR: installed acceptance preparation source authority differs from the sealed candidate" >&2
    exit 1
  fi
fi
# --installed-ui-products skip: no installed UI-test bundle, so no installed
# acceptance preparation either (never used by Gate F, which passes no option).
if [[ "${INSTALLED_UI_PRODUCTS}" == skip ]]; then
  PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY=0
fi
# --release-candidate skip: no Release candidate, so nothing for installed
# acceptance to bind (never used by Gate F, which passes no option).
if [[ "${RELEASE_CANDIDATE}" == skip ]]; then
  PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY=0
fi

# Derive every path from the admitted run before any dependency verifier or
# producer can observe it. Resume rejects path splicing before touching those
# dependencies; fresh and resumed modes then share one exact path contract.
DEPENDENCY_WORK_ROOT="${RUN_ROOT}/dependencies"
DERIVED_DATA_ROOT="${RUN_ROOT}/DerivedData"
GHOSTTY_VT_WORK_ROOT="${DEPENDENCY_WORK_ROOT}/ghostty-vt"
GHOSTTY_SURFACE_WORK_ROOT="${DEPENDENCY_WORK_ROOT}/ghostty-surface"
SLEIGH_SOURCE_BUILD_WORK_ROOT="${DEPENDENCY_WORK_ROOT}/sleigh-native-source"
GHOSTTY_QUALIFICATION_ROOT="${DEPENDENCY_WORK_ROOT}/ghostty-vt-qualification"
GHOSTTY_QUALIFICATION_LIBRARY_ROOT="${GHOSTTY_QUALIFICATION_ROOT}/zig-out/lib"
GHOSTTY_SOURCE_DIR="${GHOSTTY_QUALIFICATION_ROOT}"
GHOSTTY_SURFACE_SOURCE_DIR="${GHOSTTY_SURFACE_WORK_ROOT}/GhosttySurface"
GHOSTTY_SURFACE_ARTIFACT_ROOT="${GHOSTTY_SURFACE_SOURCE_DIR}/macos/GhosttyKit.xcframework"
GHOSTTY_SURFACE_MANIFEST="${GHOSTTY_SURFACE_SOURCE_DIR}/macos/.macscope-ghostty-surface-manifest"
SLEIGH_SOURCE_BUILD_ROOT="${SLEIGH_SOURCE_BUILD_WORK_ROOT}/SleighNativeSource"
SLEIGH_ROOT="${SLEIGH_SOURCE_BUILD_ROOT}/materialization"
ZIG="${BUILD_SOURCE_ROOT}/ThirdParty/Zig/zig-0.16.0/zig"
PRIVATE_MACHOKIT_ROOT="${RUN_ROOT}/private-machokit-input"
CANDIDATE_ARTIFACT_ROOT="${RUN_ROOT}/candidate-artifacts"
NATIVE_PREPARATION_RECEIPT="${CANDIDATE_ARTIFACT_ROOT}/NativeLivePreparation.receipt.json"
INSTALLED_UI_PREPARATION_RECEIPT="${CANDIDATE_ARTIFACT_ROOT}/InstalledUIPreparation.receipt.json"
STAGE_TIMING_RECEIPT="${RUN_ROOT}/STAGE_TIMINGS.json"
DEPENDENCY_CACHE_EVENT_RECEIPT="${RUN_ROOT}/DEPENDENCY_CACHE_EVENTS.json"
DEPENDENCY_CACHE_TOOL=(
  /usr/bin/python3 -B
  "${BUILD_SOURCE_ROOT}/Scripts/qualification/dependency_cache.py"
)
STAGE_TIMING_TOOL=(
  /usr/bin/python3 -B
  "${BUILD_SOURCE_ROOT}/Scripts/qualification/stage_timing.py"
)
BOOTSTRAP_REUSE_TOOL=(
  /usr/bin/python3 -B
  "${BUILD_SOURCE_ROOT}/Scripts/qualification/bootstrap_reuse.py"
)
BUILD_SOURCE_RESTORE_ARGUMENTS=(
  --build-source-root "${BUILD_SOURCE_ROOT}"
  --machokit-root "${PRIVATE_MACHOKIT_ROOT}"
  --dependency-cache-root "${DEPENDENCY_CACHE_ROOT}"
)
if [[ -n "${PATTERN_ADAPTER_ROOT}" ]]; then
  BUILD_SOURCE_RESTORE_ARGUMENTS+=(--pattern-adapter-root "${PATTERN_ADAPTER_ROOT}")
fi
for QUALIFICATION_HELPER in \
  "${BUILD_SOURCE_ROOT}/Scripts/qualification/dependency_cache.py" \
  "${BUILD_SOURCE_ROOT}/Scripts/qualification/stage_timing.py" \
  "${BUILD_SOURCE_ROOT}/Scripts/qualification/restore_build_source.py" \
  "${BUILD_SOURCE_ROOT}/Scripts/qualification/heavy_gate_lock.py" \
  "${BUILD_SOURCE_ROOT}/Scripts/qualification/bootstrap_reuse.py"
do
  if [[ ! -f "${QUALIFICATION_HELPER}" || -L "${QUALIFICATION_HELPER}" ]]; then
    echo "ERROR: qualification helper is missing or indirect: ${QUALIFICATION_HELPER}" >&2
    exit 1
  fi
done
if [[ "${IS_RESUME}" == 1 ]]; then
  /usr/bin/python3 -B - \
    "${RECEIPT}" \
    "${BUILD_SOURCE_ROOT}" \
    "${DEPENDENCY_CACHE_ROOT}" \
    "${GHOSTTY_SOURCE_DIR}" \
    "${GHOSTTY_SURFACE_SOURCE_DIR}" \
    "${GHOSTTY_SURFACE_ARTIFACT_ROOT}" \
    "${SLEIGH_ROOT}" \
    "${ZIG}" \
    "${DEPENDENCY_NETWORK_ALLOWED}" <<'PY'
import json
from pathlib import Path
import sys

(
    receipt_path,
    build_source,
    cache_root,
    ghostty_root,
    surface_source,
    surface_artifact,
    sleigh_root,
    zig,
    network_allowed,
) = sys.argv[1:]
receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
checks = {
    "Ghostty VT root": receipt.get("ghostty_source_dir") == ghostty_root,
    "Ghostty surface source root": receipt.get("ghostty_surface_source_dir")
        == surface_source,
    "Ghostty surface artifact root": receipt.get("ghostty_surface_artifact_root")
        == surface_artifact,
    "SLEIGH root": receipt.get("sleigh_materialization_root") == sleigh_root,
    "Zig executable": receipt.get("zig_executable") == zig,
    "build source root": receipt.get("build_source_root") == build_source,
    "dependency cache root": receipt.get("dependency_cache_root") == cache_root,
    "network authority": receipt.get("dependency_network_allowed")
        is (network_allowed == "true"),
    "network remained unused": receipt.get("dependency_network_used") is False,
}
failed = [name for name, accepted in checks.items() if not accepted]
if failed:
    raise SystemExit("resumed qualification input mismatch: " + ", ".join(failed))
PY
fi
if [[ "${IS_RESUME}" != 1 ]]; then
  /bin/mkdir -p "${DEPENDENCY_WORK_ROOT}" "${DERIVED_DATA_ROOT}"
fi

# A resumable run may have stopped after bootstrap generated its ignored local
# package link, dependency xcconfig, and Xcode project. Remove only that exact,
# validated run-owned scaffold before asking the closed-tree verifier to admit
# the source again. A wrong link target or unsafe project entry fails closed.
if [[ "${IS_RESUME}" == 1 ]]; then
  run_trusted_restore_tool --operation restore \
    "${BUILD_SOURCE_RESTORE_ARGUMENTS[@]}"
fi

QUALIFICATION_VALIDATOR=(
  /usr/bin/python3 -B
  "${BUILD_SOURCE_ROOT}/Scripts/reconstruction/validate_qualification_product_identity.py"
)
QUALIFICATION_AUTHORITY_ARGUMENTS=(
  --receipt "${RECEIPT}"
  --run-root "${RUN_ROOT}"
  --derived-data-root "${DERIVED_DATA_ROOT}"
  --build-source-root "${BUILD_SOURCE_ROOT}"
  --dependency-cache-root "${DEPENDENCY_CACHE_ROOT}"
  --expected-mode "${MODE}"
  --expected-integration-ref "${INTEGRATION_REF}"
  --expected-integration-commit "${INTEGRATION_COMMIT}"
  --expected-integration-tree "${INTEGRATION_TREE}"
)
if [[ "${DEPENDENCY_NETWORK_ALLOWED}" == true ]]; then
  QUALIFICATION_AUTHORITY_ARGUMENTS+=(--dependency-network-authorized)
fi
read -r SOURCE_STAGE_STARTED_NS SOURCE_STAGE_STARTED_AT < <(stage_clock)
SOURCE_STAGE_NAME="source.identity-check"
if [[ "${BUILD_SOURCE_IDENTITY_JSON}" != "${SOURCE_EXPORT_IDENTITY_JSON}" ]]; then
  echo "ERROR: private build source does not match the admitted source identity" >&2
  exit 1
fi
read -r SOURCE_STAGE_ENDED_NS _ < <(stage_clock)

# No run-source Python helper executes until the cloned source has been
# restored by the adjacent hash-frozen helper and strictly re-admitted above.
"${STAGE_TIMING_TOOL[@]}" init \
  --receipt "${STAGE_TIMING_RECEIPT}" \
  --source-commit "${INTEGRATION_COMMIT}" \
  --source-tree "${INTEGRATION_TREE}" \
  --mode "${MODE}" \
  --run-root "${RUN_ROOT}"
"${STAGE_TIMING_TOOL[@]}" record \
  --receipt "${STAGE_TIMING_RECEIPT}" \
  --stage "${SOURCE_EXPORT_STAGE}" \
  --started-at "${SOURCE_EXPORT_STARTED_AT}" \
  --started-monotonic-ns "${SOURCE_EXPORT_STARTED_NS}" \
  --ended-monotonic-ns "${SOURCE_EXPORT_ENDED_NS}" \
  --exit-code 0
"${STAGE_TIMING_TOOL[@]}" record \
  --receipt "${STAGE_TIMING_RECEIPT}" \
  --stage "${SOURCE_STAGE_NAME}" \
  --started-at "${SOURCE_STAGE_STARTED_AT}" \
  --started-monotonic-ns "${SOURCE_STAGE_STARTED_NS}" \
  --ended-monotonic-ns "${SOURCE_STAGE_ENDED_NS}" \
  --exit-code 0

timed_stage() {
  local stage="$1"
  shift
  "${STAGE_TIMING_TOOL[@]}" run \
    --receipt "${STAGE_TIMING_RECEIPT}" \
    --stage "${stage}" \
    -- "$@"
}

timed_xcode_stage() {
  local stage="$1"
  local log_path="$2"
  shift 2
  "${STAGE_TIMING_TOOL[@]}" run \
    --receipt "${STAGE_TIMING_RECEIPT}" \
    --stage "${stage}" \
    --combined-log "${log_path}" \
    -- "$@"
}

# CoreTests is parallelizable at scheme level, but Xcode cannot disable
# parallelism per class. Classes in the sealed serial list are skipped in the
# parallel pass and run in their own serial pass; the two result bundles are
# merged into the canonical bundle. The list is read from BUILD_SOURCE_ROOT so
# it is bound to the same sealed provenance as every other input.
XCRESULTTOOL=(/usr/bin/xcrun xcresulttool)
CORE_TEST_WORKERS="${MACSCOPE_CORE_TEST_WORKERS:-4}"
if [[ ! "${CORE_TEST_WORKERS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: MACSCOPE_CORE_TEST_WORKERS must be a positive integer" >&2
  exit 2
fi

load_serial_core_tests() {
  local list="${BUILD_SOURCE_ROOT}/Scripts/qualification/serial_core_tests.txt"
  local line
  SERIAL_CORE_TESTS=()
  if [[ -L "${list}" || ! -f "${list}" ]]; then
    echo "ERROR: sealed serial CoreTests list is missing or not a regular file: ${list}" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "${line}" ]] || continue
    if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "ERROR: invalid serial CoreTests class name: ${line}" >&2
      exit 1
    fi
    SERIAL_CORE_TESTS+=("${line}")
  done < "${list}"
}

# Prints 1 when the focused selector names a serial class (or one of its cases).
selector_is_serial_core_test() {
  local selector="$1"
  local serial
  for serial in ${SERIAL_CORE_TESTS[@]+"${SERIAL_CORE_TESTS[@]}"}; do
    if [[ "${selector}" == "CoreTests/${serial}" || "${selector}" == "CoreTests/${serial}/"* ]]; then
      return 0
    fi
  done
  return 1
}

# run_core_tests_partition FINAL_BUNDLE PARALLEL_STAGE PARALLEL_LOG PARALLEL_ACTION
#   SERIAL_STAGE SERIAL_LOG SERIAL_ACTION [COMMAND_PREFIX...] -- [XCODEBUILD_OPTIONS...]
# Pass A runs CoreTests in parallel minus the serial classes; pass B runs only
# the serial classes with parallelism off. Pass B runs even when pass A fails.
# Both bundles merge into FINAL_BUNDLE; any failed pass fails the stage.
# Hosted test bundles the parallel pass covers (serial classes all live in CoreTests).
PARTITION_BUNDLES=(CoreTests Phase2Tests)
run_core_tests_partition() {
  local final_bundle="$1" parallel_stage="$2" parallel_log="$3" parallel_action="$4"
  local serial_stage="$5" serial_log="$6" serial_action="$7"
  shift 7
  local prefix=() options=() skip=() only=() serial bundles=() partition_bundle
  for partition_bundle in "${PARTITION_BUNDLES[@]}"; do
    bundles+=("-only-testing:${partition_bundle}")
  done
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    prefix+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  options=("$@")
  for serial in ${SERIAL_CORE_TESTS[@]+"${SERIAL_CORE_TESTS[@]}"}; do
    skip+=("-skip-testing:CoreTests/${serial}")
    only+=("-only-testing:CoreTests/${serial}")
  done
  local parallel_bundle="${final_bundle%.xcresult}.parallel.xcresult"
  local serial_bundle="${final_bundle%.xcresult}.serial.xcresult"
  local bundle
  for bundle in "${final_bundle}" "${parallel_bundle}" "${serial_bundle}"; do
    if [[ -e "${bundle}" || -L "${bundle}" ]]; then
      echo "ERROR: result bundle already exists; refusing to overwrite evidence: ${bundle}" >&2
      exit 1
    fi
  done
  echo "==> CoreTests partition: parallel (${CORE_TEST_WORKERS} workers, skipping: ${SERIAL_CORE_TESTS[*]:-none}) + serial (${SERIAL_CORE_TESTS[*]:-none})" >&2
  local parallel_status=0 serial_status=0
  if timed_xcode_stage "${parallel_stage}" "${parallel_log}" \
    ${prefix[@]+"${prefix[@]}"} "${XCODEBUILD[@]}" \
      ${options[@]+"${options[@]}"} \
      -resultBundlePath "${parallel_bundle}" \
      -parallel-testing-enabled YES -parallel-testing-worker-count "${CORE_TEST_WORKERS}" \
      "${bundles[@]}" ${skip[@]+"${skip[@]}"} "${parallel_action}"; then
    parallel_status=0
  else
    parallel_status=$?
  fi
  if [[ ${#only[@]} -gt 0 ]]; then
    if timed_xcode_stage "${serial_stage}" "${serial_log}" \
      ${prefix[@]+"${prefix[@]}"} "${XCODEBUILD[@]}" \
        ${options[@]+"${options[@]}"} \
        -resultBundlePath "${serial_bundle}" \
        -parallel-testing-enabled NO "${only[@]}" "${serial_action}"; then
      serial_status=0
    else
      serial_status=$?
    fi
  fi
  if [[ -e "${parallel_bundle}" && -e "${serial_bundle}" ]]; then
    "${XCRESULTTOOL[@]}" merge "${parallel_bundle}" "${serial_bundle}" \
      --output-path "${final_bundle}"
  elif [[ -e "${parallel_bundle}" ]]; then
    /bin/mv "${parallel_bundle}" "${final_bundle}"
  elif [[ -e "${serial_bundle}" ]]; then
    /bin/mv "${serial_bundle}" "${final_bundle}"
  fi
  if [[ "${parallel_status}" != 0 ]]; then
    echo "ERROR: parallel CoreTests pass failed (exit ${parallel_status})" >&2
    exit "${parallel_status}"
  fi
  if [[ "${serial_status}" != 0 ]]; then
    echo "ERROR: serial CoreTests pass failed (exit ${serial_status})" >&2
    exit "${serial_status}"
  fi
}
if [[ "${IS_RESUME}" == 1 ]]; then
  "${QUALIFICATION_VALIDATOR[@]}" validate-inputs \
    "${QUALIFICATION_AUTHORITY_ARGUMENTS[@]}" >/dev/null
fi

/usr/bin/find "${BUILD_SOURCE_ROOT}/ThirdParty/Zig/zig-0.16.0" -type d -exec /bin/chmod 755 {} +

# Cache keys use the already verified canonical source-file manifest rather
# than checkout metadata. Each component selects only its governed closure, so
# an app-only source change can reuse the same dependency bytes. External
# toolchain and SDK files are hashed once and flow into every relevant key.
if [[ -n "${MACSCOPE_QUALIFICATION_CACHE_TEST_PLATFORM_IDENTITY:-}" || \
      -n "${MACSCOPE_QUALIFICATION_CACHE_TEST_NATIVE_TOOLS_IDENTITY:-}" ]]; then
  echo "ERROR: qualification cache identity overrides are not supported" >&2
  exit 2
else
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    CACHE_DEVELOPER_DIR="${DEVELOPER_DIR}"
  else
    CACHE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
  fi
  CACHE_DEVELOPER_DIR="$(/usr/bin/python3 -B - "${CACHE_DEVELOPER_DIR}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).resolve(strict=True)
if not path.is_dir():
    raise SystemExit("selected Xcode developer authority is not a directory")
print(path)
PY
)"
  CACHE_XCODE_CONTENTS_ROOT="$(/usr/bin/dirname "${CACHE_DEVELOPER_DIR}")"
  CACHE_XCODE_VERSION_PLIST="${CACHE_XCODE_CONTENTS_ROOT}/version.plist"
  CACHE_SDK_SETTINGS="${CACHE_DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist"
  CACHE_CLANG="${CACHE_DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
  CACHE_CMAKE="$(command -v cmake || true)"
  CACHE_NINJA="$(command -v ninja || true)"
  if [[ -z "${CACHE_CMAKE}" || -z "${CACHE_NINJA}" ]]; then
    echo "ERROR: CMake and Ninja identities are required for the native dependency cache" >&2
    exit 1
  fi
  if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
    export MACSCOPE_RETAINED_TOOLCHAIN_ADMISSION="${RUN_ROOT}/RETAINED_TOOLCHAIN_ADMISSION.json"
    IFS=$'\t' read -r CACHE_PLATFORM_IDENTITY GHOSTTY_VT_CACHE_KEY GHOSTTY_SURFACE_CACHE_KEY <<< "$(
      /usr/bin/python3 -B - "${BUILD_SOURCE_ROOT}" "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" "${CACHE_DEVELOPER_DIR}" "${CACHE_CMAKE}" "${CACHE_NINJA}" "${MACSCOPE_RETAINED_TOOLCHAIN_ADMISSION}" "${NATIVE_RELEASE_ADMISSION}" <<'PYTOOLS'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'Scripts/qualification'))
from retained_toolchain_admission import prepare
value = prepare(Path(sys.argv[2]), Path(sys.argv[1]), Path(sys.argv[3]), Path(sys.argv[4]), Path(sys.argv[5]), Path(sys.argv[6]), native_admission=Path(sys.argv[7]))
print('\t'.join([value['platform_identity'], *[value['component_keys'][key] for key in ('ghostty-vt', 'ghostty-surface')]]))
PYTOOLS
    )"
    [[ -n "${CACHE_PLATFORM_IDENTITY}" && -n "${GHOSTTY_SURFACE_CACHE_KEY}" ]] || exit 1
  else
  CACHE_PLATFORM_IDENTITY="$("${DEPENDENCY_CACHE_TOOL[@]}" external-identity \
    --external-file "xcode-version=${CACHE_XCODE_VERSION_PLIST}" \
    --external-file "macos-sdk-settings=${CACHE_SDK_SETTINGS}" \
    --external-file "clang=${CACHE_CLANG}" \
    --external-file "system-version=/System/Library/CoreServices/SystemVersion.plist" \
    --external-file "xcrun=/usr/bin/xcrun" \
    --external-file "ar=/usr/bin/ar" \
    --external-file "strip=/usr/bin/strip" \
    --external-file "lipo=/usr/bin/lipo" \
    --external-file "codesign=/usr/bin/codesign" \
    --external-file "otool=/usr/bin/otool" \
    --external-file "nm=/usr/bin/nm" \
    --external-file "git=/usr/bin/git" \
    --external-file "python=/usr/bin/python3" \
    --external-file "plist-buddy=/usr/libexec/PlistBuddy")"
  CACHE_SLEIGH_TOOL_IDENTITY="$("${DEPENDENCY_CACHE_TOOL[@]}" external-identity \
    --external-file "cmake=${CACHE_CMAKE}" \
    --external-file "ninja=${CACHE_NINJA}" \
    --external-file "rsync=/usr/bin/rsync" \
    --external-file "git=/usr/bin/git" \
    --external-file "python=/usr/bin/python3")"
  fi
fi

if [[ -z "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
GHOSTTY_VT_CACHE_KEY="$("${DEPENDENCY_CACHE_TOOL[@]}" key \
  --source-files "${BUILD_SOURCE_ROOT}/SOURCE_FILES.json" \
  --component ghostty-vt \
  --prefix ThirdParty/GhosttyVT \
  --prefix ThirdParty/Zig \
  --prefix Scripts/build_ghostty_vt.sh \
  --prefix Scripts/ghostty-vt-source.contract \
  --prefix Scripts/prepare_zig_macos_sdk_overlay.py \
  --prefix Scripts/dependencies/zig_toolchain_receipt.py \
  --value "architecture=arm64" \
  --value "payload-layout=vt-artifacts-no-transient-v1" \
  --value "simd=${MACSCOPE_GHOSTTY_SIMD:-false}" \
  --value "platform-toolchain=${CACHE_PLATFORM_IDENTITY}")"
GHOSTTY_SURFACE_CACHE_KEY="$("${DEPENDENCY_CACHE_TOOL[@]}" key \
  --source-files "${BUILD_SOURCE_ROOT}/SOURCE_FILES.json" \
  --component ghostty-surface \
  --prefix ThirdParty/GhosttySurface \
  --prefix ThirdParty/Zig \
  --prefix Scripts/dependencies/build_vendored_ghostty_surface.sh \
  --prefix Scripts/dependencies/build_ghostty_surface.sh \
  --prefix Scripts/dependencies/zig_toolchain_receipt.py \
  --prefix Scripts/ghostty-surface-source.contract \
  --prefix Scripts/ghostty-vt-source.contract \
  --value "architecture=arm64" \
  --value "configuration=ReleaseFast" \
  --value "payload-layout=surface-source-package-artifact-no-zig-state-v1" \
  --value "platform-toolchain=${CACHE_PLATFORM_IDENTITY}")"
SLEIGH_CACHE_KEY="$("${DEPENDENCY_CACHE_TOOL[@]}" key \
  --source-files "${BUILD_SOURCE_ROOT}/SOURCE_FILES.json" \
  --component sleigh-native-source \
  --prefix ThirdParty/SleighNative \
  --prefix Scripts/dependencies/build_vendored_sleigh_native_source.sh \
  --prefix Scripts/dependencies/verify_vendored_sleigh_source.py \
  --prefix Scripts/native-decompiler-direct/sleigh_package.py \
  --prefix Scripts/native-decompiler-direct/verify_sleigh_package.py \
  --value "architecture=arm64" \
  --value "configuration=Release" \
  --value "deployment-target=27.0" \
  --value "jobs=${MACSCOPE_NATIVE_SOURCE_JOBS:-8}" \
  --value "payload-layout=sleigh-materialization-and-source-receipt-v1" \
  --value "platform-toolchain=${CACHE_PLATFORM_IDENTITY}" \
  --value "native-tools=${CACHE_SLEIGH_TOOL_IDENTITY}")"
fi

CACHE_ARTIFACT_ROOT="${DEPENDENCY_CACHE_ROOT}/artifacts/v1"
CACHE_LOCK_ROOT="${DEPENDENCY_CACHE_ROOT}/locks/v1"
CACHE_TEMP_ROOT="${DEPENDENCY_CACHE_ROOT}/temporary/v1"
/bin/mkdir -p "${CACHE_ARTIFACT_ROOT}" "${CACHE_LOCK_ROOT}" "${CACHE_TEMP_ROOT}"
ACTIVE_CACHE_LOCK=""
ACTIVE_CACHE_TEMP=""
HEAVY_GATE_LOCK_HELD=0
HEAVY_GATE_LOCK_FD=7
release_heavy_gate_lock() {
  if [[ "${HEAVY_GATE_LOCK_HELD}" == 1 ]]; then
    HEAVY_GATE_LOCK_HELD=0
    /usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/qualification/heavy_gate_lock.py" \
      release --lock "${GATE_LOCK_PATH}" --pid "$$" || true
    # Closing the qualifier's descriptor releases the flock. A crash closes it
    # too, so the kernel never leaves the lock stale.
    exec 7>&-
    if [[ "${GATE_LOCK_SHARED:-0}" == 1 ]]; then
      exec 4>&- 5>&- 6>&-
    fi
  fi
}

# Heavy native phases (Xcode build/test and their signing)
# are serialized through one flock. Export,
# verification, dependency views, bootstrap and prepare mode never take it.
acquire_heavy_gate_lock() {
  local started_ns
  local started_at
  local ended_ns
  local status=0
  if [[ "${GATE_LOCK_ENABLED}" != 1 ]]; then
    echo "==> heavy-gate lock disabled (--no-gate-lock)" >&2
    return 0
  fi
  /bin/mkdir -p "$(/usr/bin/dirname "${GATE_LOCK_PATH}")"
  if [[ -L "${GATE_LOCK_PATH}" ]]; then
    echo "ERROR: heavy-gate lock must not be a symbolic link: ${GATE_LOCK_PATH}" >&2
    exit 1
  fi
  exec 7>>"${GATE_LOCK_PATH}"
  local shared_arguments=()
  if [[ "${GATE_LOCK_SHARED:-0}" == 1 ]]; then
    # One of the dev loop's slots (Scripts/dev_loop.sh, MACSCOPE_DEV_SLOTS<=3).
    local slot
    for slot in 0 1 2; do
      if [[ -L "${GATE_LOCK_PATH}.slot-${slot}" ]]; then
        echo "ERROR: heavy-gate slot must not be a symbolic link: ${GATE_LOCK_PATH}.slot-${slot}" >&2
        exit 1
      fi
    done
    exec 4>>"${GATE_LOCK_PATH}.slot-0" 5>>"${GATE_LOCK_PATH}.slot-1" 6>>"${GATE_LOCK_PATH}.slot-2"
    shared_arguments=(--shared --slot-fds 4,5,6)
  fi
  read -r started_ns started_at < <(stage_clock)
  /usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/qualification/heavy_gate_lock.py" \
    acquire --fd "${HEAVY_GATE_LOCK_FD}" --lock "${GATE_LOCK_PATH}" \
    --timeout "${GATE_LOCK_TIMEOUT}" --pid "$$" --work-root "${WORK_ROOT}" \
    --integration-ref "${INTEGRATION_REF}" --mode "${MODE}" --run-root "${RUN_ROOT}" \
    ${shared_arguments[@]+"${shared_arguments[@]}"} \
    || status=$?
  read -r ended_ns _ < <(stage_clock)
  "${STAGE_TIMING_TOOL[@]}" record \
    --receipt "${STAGE_TIMING_RECEIPT}" \
    --stage gate.heavy-lock.wait \
    --started-at "${started_at}" \
    --started-monotonic-ns "${started_ns}" \
    --ended-monotonic-ns "${ended_ns}" \
    --exit-code "${status}"
  if [[ "${status}" != 0 ]]; then
    exec 7>&-
    echo "ERROR: heavy-gate lock was not acquired: ${GATE_LOCK_PATH}" >&2
    exit 1
  fi
  HEAVY_GATE_LOCK_HELD=1
}

cleanup_cache_operation() {
  release_heavy_gate_lock
  if [[ -n "${ACTIVE_CACHE_TEMP}" && -d "${ACTIVE_CACHE_TEMP}" && ! -L "${ACTIVE_CACHE_TEMP}" ]]; then
    /bin/chmod -R u+w "${ACTIVE_CACHE_TEMP}" 2>/dev/null || true
    /bin/rm -rf "${ACTIVE_CACHE_TEMP:?}"
  fi
  if [[ -n "${ACTIVE_CACHE_LOCK}" && -d "${ACTIVE_CACHE_LOCK}" ]]; then
    /bin/rm -f "${ACTIVE_CACHE_LOCK}/owner"
    /bin/rmdir "${ACTIVE_CACHE_LOCK}" 2>/dev/null || true
  fi
}
# Bash may defer a signal trap until the foreground stage returns. Exit rather
# than cleaning up and resuming: EXIT keeps the lock held until that stage ends
# and releases it exactly once before termination, never before a later stage.
trap cleanup_cache_operation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

release_cache_lock() {
  cleanup_cache_operation
  ACTIVE_CACHE_TEMP=""
  ACTIVE_CACHE_LOCK=""
}

acquire_cache_lock() {
  local component="$1"
  local key="$2"
  local entry="$3"
  local lock_parent="${CACHE_LOCK_ROOT}/${component}"
  local lock="${lock_parent}/${key}.lock"
  local timeout="${MACSCOPE_DEPENDENCY_CACHE_LOCK_TIMEOUT_SECONDS:-900}"
  local waited=0
  if [[ ! "${timeout}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MACSCOPE_DEPENDENCY_CACHE_LOCK_TIMEOUT_SECONDS must be a positive integer" >&2
    return 2
  fi
  /bin/mkdir -p "${lock_parent}"
  while ! /bin/mkdir "${lock}" 2>/dev/null; do
    if [[ -e "${entry}" || -L "${entry}" ]]; then
      return 2
    fi
    # Fail closed instead of inferring staleness from a PID. PID reuse,
    # permission failures, and a producer dying before writing owner metadata
    # make automatic reclamation unsafe without a stronger process identity.
    if (( waited >= timeout )); then
      echo "ERROR: timed out waiting for dependency cache lock: ${lock}" >&2
      return 1
    fi
    /bin/sleep 1
    waited=$((waited + 1))
  done
  ACTIVE_CACHE_LOCK="${lock}"
  printf 'pid=%s\ncomponent=%s\nkey=%s\n' "$$" "${component}" "${key}" >"${lock}/owner"
  return 0
}

verify_ghostty_vt_view() {
  local payload="$1"
  timed_stage dependency.ghostty-vt.verify \
    "${BUILD_SOURCE_ROOT}/Scripts/build_ghostty_vt.sh" \
    --work-root "${payload}" --verify-only \
    >"${RUN_ROOT}/ghostty-vt-verify.log" 2>&1
}

build_ghostty_vt_payload() {
  local temporary="$1"
  local payload="${temporary}/payload"
  /bin/mkdir -p "${payload}"
  timed_stage dependency.ghostty-vt.build \
    "${BUILD_SOURCE_ROOT}/Scripts/build_ghostty_vt.sh" \
    --work-root "${payload}" \
    >"${RUN_ROOT}/ghostty-vt-build.log" 2>&1
  verify_ghostty_vt_view "${payload}"
  for transient in cache global-cache sdk-compatibility; do
    if [[ -e "${payload}/${transient}" && ! -L "${payload}/${transient}" ]]; then
      /bin/chmod -R u+w "${payload}/${transient}" 2>/dev/null || true
      /bin/rm -rf "${payload:?}/${transient}"
    fi
  done
  /bin/mkdir -p "${payload}/cache" "${payload}/global-cache"
  BUILT_CACHE_PAYLOAD="${payload}"
}

verify_ghostty_surface_view() {
  local payload="$1"
  local work_root
  local output
  work_root="$(/usr/bin/dirname "${payload}")"
  output="$(timed_stage dependency.ghostty-surface.verify \
    /usr/bin/env \
    MACSCOPE_GIT=/usr/bin/git \
    MACSCOPE_LIPO=/usr/bin/lipo \
    MACSCOPE_NM=/usr/bin/nm \
    MACSCOPE_PLIST_BUDDY=/usr/libexec/PlistBuddy \
    MACSCOPE_PYTHON=/usr/bin/python3 \
    "${BUILD_SOURCE_ROOT}/Scripts/dependencies/build_vendored_ghostty_surface.sh" \
    --work-root "${work_root}" --verify-only \
    2>>"${RUN_ROOT}/ghostty-surface-build.log")"
  local expected="GHOSTTY_SURFACE_SOURCE_DIR=${payload}
GHOSTTY_SURFACE_ARTIFACT_ROOT=${payload}/macos/GhosttyKit.xcframework"
  if [[ "${output}" != "${expected}" ]]; then
    echo "ERROR: Ghostty surface cache verifier returned an unexpected output contract" >&2
    return 1
  fi
}

build_ghostty_surface_payload() {
  local temporary="$1"
  local work_root="${temporary}/work"
  local payload="${work_root}/GhosttySurface"
  local output
  /bin/mkdir -p "${work_root}"
  output="$(timed_stage dependency.ghostty-surface.build \
    /usr/bin/env \
    MACSCOPE_GIT=/usr/bin/git \
    MACSCOPE_LIPO=/usr/bin/lipo \
    MACSCOPE_NM=/usr/bin/nm \
    MACSCOPE_PLIST_BUDDY=/usr/libexec/PlistBuddy \
    MACSCOPE_PYTHON=/usr/bin/python3 \
    "${BUILD_SOURCE_ROOT}/Scripts/dependencies/build_vendored_ghostty_surface.sh" \
    --work-root "${work_root}" \
    2>"${RUN_ROOT}/ghostty-surface-build.log")"
  local expected="GHOSTTY_SURFACE_SOURCE_DIR=${payload}
GHOSTTY_SURFACE_ARTIFACT_ROOT=${payload}/macos/GhosttyKit.xcframework"
  if [[ "${output}" != "${expected}" ]]; then
    echo "ERROR: Ghostty surface producer returned an unexpected output contract" >&2
    return 1
  fi
  verify_ghostty_surface_view "${payload}"
  for transient in .zig-cache zig-out; do
    if [[ -e "${payload}/${transient}" && ! -L "${payload}/${transient}" ]]; then
      /bin/chmod -R u+w "${payload}/${transient}" 2>/dev/null || true
      /bin/rm -rf "${payload:?}/${transient}"
    fi
  done
  BUILT_CACHE_PAYLOAD="${payload}"
}

verify_sleigh_view() {
  local payload="$1"
  local work_root
  local output
  work_root="$(/usr/bin/dirname "${payload}")"
  output="$(timed_stage dependency.sleigh-native-source.verify \
    "${BUILD_SOURCE_ROOT}/Scripts/dependencies/build_vendored_sleigh_native_source.sh" \
    --work-root "${work_root}" \
    2>>"${RUN_ROOT}/sleigh-source-build.log")"
  local expected="MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=${payload}
MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=${payload}/materialization"
  if [[ "${output}" != "${expected}" ]]; then
    echo "ERROR: native SLEIGH/Ghidra cache verifier returned an unexpected output contract" >&2
    return 1
  fi
}

build_sleigh_payload() {
  local temporary="$1"
  local work_root="${temporary}/work"
  local payload="${work_root}/SleighNativeSource"
  local output
  /bin/mkdir -p "${work_root}"
  output="$(timed_stage dependency.sleigh-native-source.build \
    "${BUILD_SOURCE_ROOT}/Scripts/dependencies/build_vendored_sleigh_native_source.sh" \
    --work-root "${work_root}" \
    2>"${RUN_ROOT}/sleigh-source-build.log")"
  local expected="MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=${payload}
MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=${payload}/materialization"
  if [[ "${output}" != "${expected}" ]]; then
    echo "ERROR: native SLEIGH/Ghidra producer returned an unexpected output contract" >&2
    return 1
  fi
  verify_sleigh_view "${payload}"
  for transient in source build; do
    if [[ -d "${payload}/${transient}" && ! -L "${payload}/${transient}" ]]; then
      /bin/chmod -R u+w "${payload}/${transient}" 2>/dev/null || true
      /bin/rm -rf "${payload:?}/${transient}"
    fi
  done
  BUILT_CACHE_PAYLOAD="${payload}"
}

ensure_cached_component() {
  local component="$1"
  local key="$2"
  local destination="$3"
  local build_callback="$4"
  local verify_callback="$5"
  local entry="${CACHE_ARTIFACT_ROOT}/${component}/${key}"
  local cache_status="verified-hit"
  local lock_status=0
  local temporary
  /bin/mkdir -p "${CACHE_ARTIFACT_ROOT}/${component}" "${CACHE_TEMP_ROOT}/${component}"
  if [[ ! -e "${entry}" && ! -L "${entry}" ]]; then
    if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
      echo "ERROR: retained Release dependency entry is absent; new verification/build is not authorized: ${component}" >&2
      return 1
    fi
    if acquire_cache_lock "${component}" "${key}" "${entry}"; then
      lock_status=0
    else
      lock_status=$?
    fi
    if [[ "${lock_status}" == 2 ]]; then
      cache_status="verified-after-wait"
    elif [[ "${lock_status}" != 0 ]]; then
      return "${lock_status}"
    elif [[ -e "${entry}" || -L "${entry}" ]]; then
      cache_status="verified-after-wait"
      release_cache_lock
    else
      temporary="$(/usr/bin/mktemp -d "${CACHE_TEMP_ROOT}/${component}/${key}.XXXXXX")"
      ACTIVE_CACHE_TEMP="${temporary}"
      BUILT_CACHE_PAYLOAD=""
      "${build_callback}" "${temporary}"
      if [[ -z "${BUILT_CACHE_PAYLOAD}" ]]; then
        echo "ERROR: ${component} cache builder did not expose a payload" >&2
        return 1
      fi
      timed_stage "cache.${component}.publish" \
        "${DEPENDENCY_CACHE_TOOL[@]}" publish \
        --entry "${entry}" \
        --component "${component}" \
        --key "${key}" \
        --payload "${BUILT_CACHE_PAYLOAD}"
      cache_status="published-miss"
      /bin/rmdir "${temporary}/work" 2>/dev/null || true
      /bin/rmdir "${temporary}" 2>/dev/null || true
      ACTIVE_CACHE_TEMP=""
      release_cache_lock
    fi
  fi
  if [[ -e "${destination}" || -L "${destination}" ]]; then
    echo "ERROR: fresh run-owned dependency view already exists: ${destination}" >&2
    return 1
  fi
  local verification_arguments=(
    --entry "${entry}"
    --component "${component}"
    --key "${key}"
    --verification-root "${VERIFICATION_CACHE_ROOT:-}"
    # D1: the cache key binds the component's source closure (including its
    # domain verifier scripts) and the platform/toolchain identity, so a view
    # verified once is trusted by key on every later commit.
    --binding "platform-toolchain=${CACHE_PLATFORM_IDENTITY}"
    --binding "domain-verifier=${verify_callback}"
  )
  local snapshot_arguments=()
  local reuse_output
  local reuse_status
  if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
    verification_arguments+=(--retained-toolchain-admission "${MACSCOPE_RETAINED_TOOLCHAIN_ADMISSION}")
    if ! reuse_output="$(timed_stage "dependency.${component}.reuse" \
        /usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/qualification/retained_dependency_cache.py" reuse-verified \
        "${verification_arguments[@]}" --destination "${destination}")"; then
      echo "ERROR: retained dependency consumption refused; no content-verification fallback: ${reuse_output}" >&2
      return 1
    fi
    echo "==> reusing retained dependency ${component} (${reuse_output})" >&2
    "${DEPENDENCY_CACHE_TOOL[@]}" record-event \
      --receipt "${DEPENDENCY_CACHE_EVENT_RECEIPT}" \
      --source-commit "${INTEGRATION_COMMIT}" --source-tree "${INTEGRATION_TREE}" \
      --cache-root "${DEPENDENCY_CACHE_ROOT}" --component "${component}" \
      --key "${key}" --status receipt-reused-hit --entry "${entry}" \
      --run-view "${destination}" || return 1
    return 0
  fi
  verification_arguments+=(--binding "native-tools=${CACHE_SLEIGH_TOOL_IDENTITY}")
  if [[ "${VERIFICATION_REUSE}" == 1 ]]; then
    if reuse_output="$("${DEPENDENCY_CACHE_TOOL[@]}" reuse-check \
        "${verification_arguments[@]}")"; then
      if reuse_output="$(timed_stage "dependency.${component}.reuse" \
          "${DEPENDENCY_CACHE_TOOL[@]}" reuse-verified \
          "${verification_arguments[@]}" --destination "${destination}")"; then
        echo "==> reusing verified dependency ${component} ${key} (receipt ${reuse_output})" >&2
        "${DEPENDENCY_CACHE_TOOL[@]}" record-event \
          --receipt "${DEPENDENCY_CACHE_EVENT_RECEIPT}" \
          --source-commit "${INTEGRATION_COMMIT}" \
          --source-tree "${INTEGRATION_TREE}" \
          --cache-root "${DEPENDENCY_CACHE_ROOT}" \
          --component "${component}" \
          --key "${key}" \
          --status receipt-reused-hit \
          --entry "${entry}" \
          --run-view "${destination}" || return 1
        return 0
      else
        reuse_status=$?
      fi
    else
      reuse_status=$?
    fi
    if [[ "${reuse_status}" != 3 ]]; then
      echo "ERROR: ${component} verification receipt lookup failed" >&2
      return 1
    fi
    if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
      echo "ERROR: retained Release dependency receipt cannot be reused; refusing repeated verification: ${component}: ${reuse_output}" >&2
      return 1
    fi
    echo "==> full verification: dependency ${component}: ${reuse_output}" >&2
    snapshot_arguments=(--snapshot-output "${RUN_ROOT}/dependency-${component}-entry-snapshot.json")
  fi
  timed_stage "cache.${component}.materialize" \
    "${DEPENDENCY_CACHE_TOOL[@]}" materialize \
    --entry "${entry}" \
    --component "${component}" \
    --key "${key}" \
    --destination "${destination}" \
    ${snapshot_arguments[@]+"${snapshot_arguments[@]}"} || return 1
  # This function runs under `if !`, where errexit is suspended: a failed
  # domain verifier must stop here and can never publish a reuse receipt.
  "${verify_callback}" "${destination}" || return 1
  if [[ "${VERIFICATION_REUSE}" == 1 ]]; then
    reuse_output="$("${DEPENDENCY_CACHE_TOOL[@]}" record-verification \
      "${verification_arguments[@]}" \
      --snapshot "${RUN_ROOT}/dependency-${component}-entry-snapshot.json" \
      --run-view "${destination}" \
      --verification "dependency_cache.py materialize (full SHA-256 of entry and run view) + ${verify_callback}")" || return 1
    echo "==> published dependency verification receipt ${reuse_output} for ${component} ${key}" >&2
  fi
  "${DEPENDENCY_CACHE_TOOL[@]}" record-event \
    --receipt "${DEPENDENCY_CACHE_EVENT_RECEIPT}" \
    --source-commit "${INTEGRATION_COMMIT}" \
    --source-tree "${INTEGRATION_TREE}" \
    --cache-root "${DEPENDENCY_CACHE_ROOT}" \
    --component "${component}" \
    --key "${key}" \
    --status "${cache_status}" \
    --entry "${entry}" \
    --run-view "${destination}"
}

# The generated run tree is disposable; the pristine source export remains
# closed and reusable. Repository-owned source, package stores, and tools stay
# inside the sealed export while every generated artifact lives beside it under
# this run's external dependency work root.
# MachOKit remains a governed direct-source package. A new run defaults to the
# sealed repository component, while the existing explicit diagnostic override
# is verified and privately copied before use. Resume never consults a mutable
# input again; it verifies only the run's already sealed private copy.
if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
  MACHOKIT_INHERITED_TREE="$(/usr/bin/python3 -B - "${BUILD_SOURCE_ROOT}" "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" "${PRIVATE_MACHOKIT_ROOT}" <<'PYMACHO'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'Scripts/qualification'))
from qualification_manifest_inheritance import copy_admitted_machokit
print(copy_admitted_machokit(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])))
PYMACHO
)"
else
  if [[ "${IS_RESUME}" != 1 ]]; then
    if [ "${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT+set}" = set ]; then
      MACHOKIT_INPUT_ROOT="${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT}"
      /usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/machokit_source_identity.py" \
        verify --materialization-root "${MACHOKIT_INPUT_ROOT}" --quiet
    else
      MACHOKIT_INPUT_ROOT="${BUILD_SOURCE_ROOT}/ThirdParty/MachOKit/materialization"
    fi
    /usr/bin/ditto "${MACHOKIT_INPUT_ROOT}" "${PRIVATE_MACHOKIT_ROOT}"
    /usr/bin/find "${PRIVATE_MACHOKIT_ROOT}" -type f -exec /bin/chmod a-w {} +
    /usr/bin/find "${PRIVATE_MACHOKIT_ROOT}" -depth -type d -exec /bin/chmod a-w {} +
  fi
  /usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/machokit_source_identity.py" \
    verify --materialization-root "${PRIVATE_MACHOKIT_ROOT}" --quiet
fi

# Fresh runs consume immutable content-addressed entries through run-owned
# views. Resume never consults the shared cache: it independently verifies the
# exact run-owned bytes already bound by the qualification input receipt.
if [[ "${IS_RESUME}" == 1 ]]; then
  verify_ghostty_vt_view "${GHOSTTY_VT_WORK_ROOT}" || {
    /bin/cat "${RUN_ROOT}/ghostty-vt-verify.log" >&2
    echo "ERROR: resumed Ghostty VT artifact is missing or invalid" >&2
    exit 1
  }
  verify_ghostty_surface_view "${GHOSTTY_SURFACE_SOURCE_DIR}" || {
    /bin/cat "${RUN_ROOT}/ghostty-surface-build.log" >&2
    echo "ERROR: resumed Ghostty surface artifact is missing or invalid" >&2
    exit 1
  }
  verify_sleigh_view "${SLEIGH_SOURCE_BUILD_ROOT}" || {
    /bin/cat "${RUN_ROOT}/sleigh-source-build.log" >&2
    echo "ERROR: resumed native SLEIGH/Ghidra artifact is missing or invalid" >&2
    exit 1
  }
elif ! ensure_cached_component \
  ghostty-vt "${GHOSTTY_VT_CACHE_KEY}" "${GHOSTTY_VT_WORK_ROOT}" \
  build_ghostty_vt_payload verify_ghostty_vt_view
then
  /bin/cat "${RUN_ROOT}/ghostty-vt-build.log" >&2 2>/dev/null || true
  echo "ERROR: verified Ghostty VT dependency cache preparation failed" >&2
  exit 1
elif ! ensure_cached_component \
  ghostty-surface "${GHOSTTY_SURFACE_CACHE_KEY}" "${GHOSTTY_SURFACE_SOURCE_DIR}" \
  build_ghostty_surface_payload verify_ghostty_surface_view
then
  /bin/cat "${RUN_ROOT}/ghostty-surface-build.log" >&2 2>/dev/null || true
  echo "ERROR: verified Ghostty surface dependency cache preparation failed" >&2
  exit 1
fi
if [[ -n "${NATIVE_RELEASE_ADMISSION}" ]]; then
  /usr/bin/python3 -B - "${BUILD_SOURCE_ROOT}" "${NATIVE_RELEASE_ADMISSION}" "${SLEIGH_ROOT}" "${RUN_ROOT}/NATIVE_DEPENDENCY_ADMISSION.json" <<'PYNATIVEDEPENDENCY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'Scripts/qualification'))
from qualification_manifest_inheritance import copy_native_dependency
copy_native_dependency(*map(Path, sys.argv[1:]))
PYNATIVEDEPENDENCY
elif [[ "${IS_RESUME}" != 1 ]] && ! ensure_cached_component \
  sleigh-native-source "${SLEIGH_CACHE_KEY}" "${SLEIGH_SOURCE_BUILD_ROOT}" \
  build_sleigh_payload verify_sleigh_view
then
  /bin/cat "${RUN_ROOT}/sleigh-source-build.log" >&2 2>/dev/null || true
  echo "ERROR: verified native SLEIGH/Ghidra dependency cache preparation failed" >&2
  exit 1
fi

# Bootstrap can consume this exact immutable view without repeating the full
# source/package/toolchain traversal just completed by verify_ghostty_surface_view.
GHOSTTY_SURFACE_ADMISSION_DESCRIPTOR="${RUN_ROOT}/ghostty-surface-admission.json"
GHOSTTY_SURFACE_ADMISSION_SHA256="$(/usr/bin/python3 -B \
  "${BUILD_SOURCE_ROOT}/Scripts/dependencies/verified_ghostty_surface_admission.py" \
  --describe --source-root "${GHOSTTY_SURFACE_SOURCE_DIR}" \
  --descriptor "${GHOSTTY_SURFACE_ADMISSION_DESCRIPTOR}")"

# Receipt schema v4 and its reconstruction consumer retain the historical
# ``ghostty_source_dir/zig-out/lib`` artifact seam. Publish an ordinary-file,
# run-owned compatibility view from the verified VT output without making that
# legacy layout a build input. Resume compares both files byte-for-byte and
# never repairs a changed sealed run.
# Bind the whole consumed header closure after the existing source/artifact verifier.
GHOSTTY_VT_STAGING_DESCRIPTOR="${RUN_ROOT}/ghostty-vt-staging.json"
GHOSTTY_VT_STAGING_SHA256="$(/usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/dependencies/stage_verified_ghostty_vt.py" \
  --describe --artifact-root "${GHOSTTY_VT_WORK_ROOT}/artifacts" \
  --descriptor "${GHOSTTY_VT_STAGING_DESCRIPTOR}")"
GHOSTTY_BUILT_LIBRARY_ROOT="${GHOSTTY_VT_WORK_ROOT}/artifacts/lib"
GHOSTTY_BUILT_DYLIB="${GHOSTTY_BUILT_LIBRARY_ROOT}/libghostty-vt.dylib"
GHOSTTY_BUILT_MANIFEST="${GHOSTTY_BUILT_LIBRARY_ROOT}/.macscope-ghostty-vt-manifest"
GHOSTTY_QUALIFICATION_DYLIB="${GHOSTTY_QUALIFICATION_LIBRARY_ROOT}/libghostty-vt.dylib"
GHOSTTY_QUALIFICATION_MANIFEST="${GHOSTTY_QUALIFICATION_LIBRARY_ROOT}/.macscope-ghostty-vt-manifest"
if [[ "${IS_RESUME}" == 1 ]]; then
  if ! /usr/bin/cmp -s "${GHOSTTY_BUILT_DYLIB}" "${GHOSTTY_QUALIFICATION_DYLIB}" || \
     ! /usr/bin/cmp -s "${GHOSTTY_BUILT_MANIFEST}" "${GHOSTTY_QUALIFICATION_MANIFEST}"
  then
    echo "ERROR: resumed Ghostty qualification artifact view is missing or changed" >&2
    exit 1
  fi
else
  /bin/mkdir -p "${GHOSTTY_QUALIFICATION_LIBRARY_ROOT}"
  /usr/bin/ditto "${GHOSTTY_BUILT_DYLIB}" "${GHOSTTY_QUALIFICATION_DYLIB}"
  /usr/bin/ditto "${GHOSTTY_BUILT_MANIFEST}" "${GHOSTTY_QUALIFICATION_MANIFEST}"
fi

GHOSTTY_ARTIFACT_MANIFEST="${GHOSTTY_QUALIFICATION_MANIFEST}"
SLEIGH_MATERIALIZATION_MANIFEST="${SLEIGH_ROOT}/MATERIALIZATION.json"
if [[ ! -f "${GHOSTTY_ARTIFACT_MANIFEST}" ]]; then
  echo "ERROR: verified Ghostty artifact manifest is missing: ${GHOSTTY_ARTIFACT_MANIFEST}" >&2
  exit 1
fi
if [[ ! -f "${SLEIGH_MATERIALIZATION_MANIFEST}" ]]; then
  echo "ERROR: verified SLEIGH materialization manifest is missing: ${SLEIGH_MATERIALIZATION_MANIFEST}" >&2
  exit 1
fi
if [[ ! -f "${GHOSTTY_SURFACE_MANIFEST}" ]]; then
  echo "ERROR: verified Ghostty surface manifest is missing: ${GHOSTTY_SURFACE_MANIFEST}" >&2
  exit 1
fi

if [[ "${IS_RESUME}" == 1 ]]; then
  /usr/bin/python3 -B - \
    "${RECEIPT}" \
    "${GHOSTTY_ARTIFACT_MANIFEST}" \
    "${GHOSTTY_SURFACE_MANIFEST}" \
    "${SLEIGH_MATERIALIZATION_MANIFEST}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
receipt_path, ghostty_manifest, ghostty_surface_manifest, sleigh_manifest = map(
    Path, sys.argv[1:]
)
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
expected_fields = {
    "build_source_root",
    "dependency_cache_root",
    "dependency_network_allowed",
    "dependency_network_used",
    "ghostty_artifact_manifest_sha256",
    "ghostty_source_dir",
    "ghostty_surface_artifact_root",
    "ghostty_surface_manifest_sha256",
    "ghostty_surface_source_dir",
    "mode",
    "schema_version",
    "sleigh_materialization_manifest_sha256",
    "sleigh_materialization_root",
    "source_identity",
    "zig_executable",
}
checks = {
    "receipt schema": receipt.get("schema_version") == 4,
    "receipt field set": set(receipt) == expected_fields,
    "Ghostty artifact manifest": receipt.get("ghostty_artifact_manifest_sha256")
        == hashlib.sha256(ghostty_manifest.read_bytes()).hexdigest(),
    "Ghostty surface manifest": receipt.get("ghostty_surface_manifest_sha256")
        == hashlib.sha256(ghostty_surface_manifest.read_bytes()).hexdigest(),
    "SLEIGH materialization manifest": receipt.get("sleigh_materialization_manifest_sha256")
        == hashlib.sha256(sleigh_manifest.read_bytes()).hexdigest(),
}
failed = [name for name, accepted in checks.items() if not accepted]
if failed:
    raise SystemExit("resumed qualification dependency mismatch: " + ", ".join(failed))
PY
else
  /usr/bin/python3 -B - \
    "${BUILD_SOURCE_IDENTITY_JSON}" \
    "${MODE}" \
    "${BUILD_SOURCE_ROOT}" \
    "${GHOSTTY_SOURCE_DIR}" \
    "${GHOSTTY_SURFACE_SOURCE_DIR}" \
    "${GHOSTTY_SURFACE_ARTIFACT_ROOT}" \
    "${ZIG}" \
    "${SLEIGH_ROOT}" \
    "${DEPENDENCY_CACHE_ROOT}" \
    "${DEPENDENCY_NETWORK_ALLOWED}" \
    "${DEPENDENCY_NETWORK_USED}" \
    "${GHOSTTY_ARTIFACT_MANIFEST}" \
    "${GHOSTTY_SURFACE_MANIFEST}" \
    "${SLEIGH_MATERIALIZATION_MANIFEST}" \
    "${RECEIPT}" \
    "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" \
    "${DEPENDENCY_CACHE_EVENT_RECEIPT}" \
    "${NATIVE_RELEASE_ADMISSION}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
(
    provenance_json,
    mode,
    source,
    ghostty,
    ghostty_surface,
    ghostty_surface_artifact,
    zig,
    sleigh,
    cache,
    network_allowed,
    network_used,
    ghostty_manifest,
    ghostty_surface_manifest,
    sleigh_manifest,
    destination,
    retained_release,
    dependency_events,
    native_admission,
) = sys.argv[1:]
source_identity = json.loads(provenance_json)
payload = {
    "build_source_root": str(Path(source).resolve(strict=True)),
    "dependency_cache_root": str(Path(cache).resolve(strict=True)),
    "dependency_network_allowed": network_allowed == "true",
    "dependency_network_used": network_used == "true",

    "ghostty_source_dir": str(Path(ghostty).resolve(strict=True)),
    "ghostty_surface_artifact_root": str(
        Path(ghostty_surface_artifact).resolve(strict=True)
    ),

    "ghostty_surface_source_dir": str(Path(ghostty_surface).resolve(strict=True)),
    "mode": mode,
    "schema_version": 4,

    "sleigh_materialization_root": str(Path(sleigh).resolve(strict=True)),
    "source_identity": source_identity,
    "zig_executable": str(Path(zig).resolve(strict=True)),
}
if retained_release:
    sys.path.insert(0, str(Path(source) / 'Scripts/qualification'))
    from qualification_manifest_inheritance import admit_manifests, revalidate
    inherited, lease = admit_manifests(Path(retained_release), payload, Path(dependency_events), native_admission=native_admission)
    payload.update(inherited)
    revalidate(lease)
else:
    for field, manifest in zip(("ghostty_artifact_manifest_sha256",
            "ghostty_surface_manifest_sha256", "sleigh_materialization_manifest_sha256"),
            (ghostty_manifest, ghostty_surface_manifest, sleigh_manifest)):
        payload[field] = hashlib.sha256(Path(manifest).read_bytes()).hexdigest()
encoded = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode()
path = Path(destination)
path.write_bytes(encoded)
path.chmod(0o600)
PY
fi
if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
  export MACSCOPE_QUALIFICATION_INPUTS_RECEIPT="${RECEIPT}"
  export MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS="${RETAINED_RELEASE_QUALIFICATION_INPUTS}"
  export MACSCOPE_NATIVE_RELEASE_ADMISSION="${NATIVE_RELEASE_ADMISSION}"
fi
"${QUALIFICATION_VALIDATOR[@]}" validate-inputs \
  "${QUALIFICATION_AUTHORITY_ARGUMENTS[@]}"

emit_qualification_outputs() {
  echo "MACSCOPE_QUALIFICATION_RUN_ROOT=${RUN_ROOT}"
  echo "MACSCOPE_QUALIFICATION_DERIVED_DATA_ROOT=${DERIVED_DATA_ROOT}"
  echo "MACSCOPE_QUALIFICATION_SOURCE_ROOT=${BUILD_SOURCE_ROOT}"
  echo "MACSCOPE_QUALIFICATION_SOURCE_COMMIT=${INTEGRATION_COMMIT}"
  echo "MACSCOPE_QUALIFICATION_SOURCE_TREE=${INTEGRATION_TREE}"
  echo "MACSCOPE_QUALIFICATION_DEPENDENCY_CACHE_ROOT=${DEPENDENCY_CACHE_ROOT}"
  echo "MACSCOPE_GHOSTTY_SOURCE_DIR=${GHOSTTY_SOURCE_DIR}"
  echo "MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR=${GHOSTTY_SURFACE_ADMISSION_DESCRIPTOR}"
  echo "MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256=${GHOSTTY_SURFACE_ADMISSION_SHA256}"
  echo "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT=${GHOSTTY_SURFACE_WORK_ROOT}"
  echo "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR=${GHOSTTY_SURFACE_SOURCE_DIR}"
  echo "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT=${GHOSTTY_SURFACE_ARTIFACT_ROOT}"
  echo "MACSCOPE_GHOSTTY_SURFACE_MANIFEST=${GHOSTTY_SURFACE_MANIFEST}"
  echo "MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT=${SLEIGH_SOURCE_BUILD_WORK_ROOT}"
  echo "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=${SLEIGH_SOURCE_BUILD_ROOT}"
  echo "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=${SLEIGH_ROOT}"
  echo "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=${PRIVATE_MACHOKIT_ROOT}"
  echo "MACSCOPE_XCODE_JOBS=${XCODE_JOBS}"
  echo "MACSCOPE_QUALIFICATION_STAGE_TIMINGS=${STAGE_TIMING_RECEIPT}"
  echo "MACSCOPE_QUALIFICATION_DEPENDENCY_CACHE_EVENTS=${DEPENDENCY_CACHE_EVENT_RECEIPT}"
  if [[ "${PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY}" == 1 ]]; then
    echo "MACSCOPE_CANDIDATE_ARTIFACT_ROOT=${CANDIDATE_ARTIFACT_ROOT}"
    echo "MACSCOPE_NATIVE_LIVE_PREPARATION_RECEIPT=${NATIVE_PREPARATION_RECEIPT}"
    echo "MACSCOPE_INSTALLED_UI_PREPARATION_RECEIPT=${INSTALLED_UI_PREPARATION_RECEIPT}"
  fi
  # The receipt is the final success token. Keep it last so interruption or a
  # failed selected gate cannot expose a receipt path as a completed result.
  echo "MACSCOPE_QUALIFICATION_RECEIPT=${RECEIPT}"
}

if [[ "${MODE}" == "prepare" ]]; then
  emit_qualification_outputs
  exit 0
fi

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  QUALIFICATION_DEVELOPER_DIR="${DEVELOPER_DIR}"
else
  QUALIFICATION_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
fi
QUALIFICATION_DEVELOPER_DIR="$(/usr/bin/python3 -B - "${QUALIFICATION_DEVELOPER_DIR}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).resolve(strict=True)
if not path.is_dir():
    raise SystemExit("selected Xcode developer authority is not a directory")
print(path)
PY
)"
export DEVELOPER_DIR="${QUALIFICATION_DEVELOPER_DIR}"

export MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR="${GHOSTTY_SURFACE_ADMISSION_DESCRIPTOR}"
export MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256="${GHOSTTY_SURFACE_ADMISSION_SHA256}"
export MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT="${GHOSTTY_SURFACE_WORK_ROOT}"
export MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR="${GHOSTTY_SURFACE_SOURCE_DIR}"
export MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT="${GHOSTTY_SURFACE_ARTIFACT_ROOT}"
export MACSCOPE_GHOSTTY_SURFACE_MANIFEST="${GHOSTTY_SURFACE_MANIFEST}"
export MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT="${SLEIGH_SOURCE_BUILD_WORK_ROOT}"
export MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT="${SLEIGH_SOURCE_BUILD_ROOT}"
export MACSCOPE_SLEIGH_MATERIALIZATION_ROOT="${SLEIGH_ROOT}"
export MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT="${PRIVATE_MACHOKIT_ROOT}"
# Bootstrap, its reuse key and cleanup must use the admitted cache, including
# --dependency-cache-root overrides and stable --persistent-run layouts.
export MACSCOPE_DEPENDENCY_CACHE_ROOT="${DEPENDENCY_CACHE_ROOT}"
# Bootstrap's governance checks, generation and post-generation checks are a
# pure function of the source tree, the scripts/tools it runs, the verified
# dependency views and the toolchain. On an exact key match, replay the
# byte-verified outputs of an earlier full bootstrap instead (see
# Scripts/qualification/bootstrap_reuse.py); any mismatch runs it in full.
BOOTSTRAP_REUSED=0
if [[ "${VERIFICATION_REUSE}" == 1 ]]; then
  BOOTSTRAP_KEY_INPUTS="${RUN_ROOT}/bootstrap-reuse-key.json"
  /bin/rm -f "${BOOTSTRAP_KEY_INPUTS}"
  BOOTSTRAP_XCODEGEN="${MACSCOPE_XCODEGEN:-${BUILD_SOURCE_ROOT}/ThirdParty/XcodeGen/bin/xcodegen}"
  BOOTSTRAP_KEY_ARGUMENTS=(
    --run-root "${RUN_ROOT}"
    --source-root "${BUILD_SOURCE_ROOT}"
    --binding "source-tree=${INTEGRATION_TREE}"
    --binding "platform-toolchain=${CACHE_PLATFORM_IDENTITY}"
    --binding "developer-dir=${QUALIFICATION_DEVELOPER_DIR}"
    --binding "ghostty-vt-key=${GHOSTTY_VT_CACHE_KEY}"
    --binding "ghostty-surface-key=${GHOSTTY_SURFACE_CACHE_KEY}"
    --normalized-file "ghostty-surface-admission=${GHOSTTY_SURFACE_ADMISSION_DESCRIPTOR}"
    --normalized-file "ghostty-vt-staging=${GHOSTTY_VT_STAGING_DESCRIPTOR}"
    --binding "parser-engine-cache-root=${DEPENDENCY_CACHE_ROOT}"
    --binding "dependency-roots=${GHOSTTY_SURFACE_WORK_ROOT}:${GHOSTTY_SURFACE_SOURCE_DIR}:${GHOSTTY_SURFACE_ARTIFACT_ROOT}:${BUILD_SOURCE_ROOT}/ThirdParty/SleighNative:${SLEIGH_SOURCE_BUILD_ROOT}:${SLEIGH_ROOT}:${PRIVATE_MACHOKIT_ROOT}"
    --hash-file "xcodegen=${BOOTSTRAP_XCODEGEN}"
    --tool-version "xcodegen=${BOOTSTRAP_XCODEGEN}"
    --environment-prefix MACSCOPE_
    --environment-exclude MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256
    --which xcodebuild
    --output "${BOOTSTRAP_KEY_INPUTS}"
  )
  if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
    BOOTSTRAP_KEY_ARGUMENTS+=(--binding "machokit-materialization=${MACHOKIT_INHERITED_TREE}")
    while IFS= read -r native_binding; do
      BOOTSTRAP_KEY_ARGUMENTS+=(--binding "${native_binding}")
    done < <(/usr/bin/python3 -B - "${RUN_ROOT}/NATIVE_DEPENDENCY_ADMISSION.json" <<'PYNATIVEKEY'
import json, sys
document = json.load(open(sys.argv[1]))
print('sleigh-native-admission-manifest=' + document['identity']['materializationManifestSHA256'])
print('sleigh-native-admission-tree=' + document['identity']['materializationTreeSHA256'])
PYNATIVEKEY
)
    while IFS= read -r inherited_binding; do
      BOOTSTRAP_KEY_ARGUMENTS+=(--binding "${inherited_binding}")
    done < <(/usr/bin/python3 -B - "${RECEIPT}" <<'PYKEY'
import json, sys
receipt = json.load(open(sys.argv[1]))
for name, field in (("sleigh-materialization", "sleigh_materialization_manifest_sha256"),
                    ("ghostty-surface-manifest", "ghostty_surface_manifest_sha256"),
                    ("ghostty-vt-manifest", "ghostty_artifact_manifest_sha256")):
    print(name + "=" + receipt[field])
PYKEY
)
  else
    BOOTSTRAP_KEY_ARGUMENTS+=(
      --binding "sleigh-native-source-key=${SLEIGH_CACHE_KEY}"
      --hash-file "machokit-materialization=${PRIVATE_MACHOKIT_ROOT}/MATERIALIZATION.json"
      --hash-file "sleigh-materialization=${SLEIGH_MATERIALIZATION_MANIFEST}"
      --hash-file "ghostty-surface-manifest=${GHOSTTY_SURFACE_MANIFEST}"
      --hash-file "ghostty-vt-manifest=${GHOSTTY_ARTIFACT_MANIFEST}"
    )
  fi
  for BOOTSTRAP_INPUT in \
    Scripts/bootstrap.sh \
    Scripts/xcode27_env.sh \
    Scripts/dependencies/validate_policy_consistency.py \
    Scripts/dependencies/validate_third_party_components.py \
    Scripts/dependencies/validate_offline_build_surface.py \
    Scripts/dependencies/materialize_xcodegen.py \
    Scripts/check_local_signing_policy.py \
    Scripts/dependencies/verified_ghostty_surface_admission.py \
    Scripts/dependencies/stage_verified_ghostty_surface.py \
    Scripts/native-decompiler-direct/verify_sleigh_package.py \
    Scripts/machokit_source_identity.py \
    Scripts/generate_xcode_json_project.py \
    Scripts/xcode_project_json.py \
    Scripts/qualification/bootstrap_reuse.py \
    Scripts/qualification/restore_build_source.py
  do
    BOOTSTRAP_SCRIPT_LABEL="${BOOTSTRAP_INPUT#Scripts/}"
    BOOTSTRAP_SCRIPT_LABEL="${BOOTSTRAP_SCRIPT_LABEL//\//-}"
    BOOTSTRAP_KEY_ARGUMENTS+=(--hash-file "script-${BOOTSTRAP_SCRIPT_LABEL}=${BUILD_SOURCE_ROOT}/${BOOTSTRAP_INPUT}")
  done
  BOOTSTRAP_REUSE_KEY="$("${BOOTSTRAP_REUSE_TOOL[@]}" key "${BOOTSTRAP_KEY_ARGUMENTS[@]}")"
  BOOTSTRAP_REUSE_ARGUMENTS=(
    --verification-root "${VERIFICATION_CACHE_ROOT}"
    --key "${BOOTSTRAP_REUSE_KEY}"
    --key-inputs "${BOOTSTRAP_KEY_INPUTS}"
  )
  BOOTSTRAP_REUSE_STATUS=0
  BOOTSTRAP_REUSE_OUTPUT="$("${BOOTSTRAP_REUSE_TOOL[@]}" reuse-check \
    "${BOOTSTRAP_REUSE_ARGUMENTS[@]}")" || BOOTSTRAP_REUSE_STATUS=$?
  if [[ "${BOOTSTRAP_REUSE_STATUS}" == 0 ]]; then
    BOOTSTRAP_REUSE_OUTPUT="$(timed_stage project.bootstrap.reuse \
      "${BOOTSTRAP_REUSE_TOOL[@]}" reuse "${BOOTSTRAP_REUSE_ARGUMENTS[@]}" \
      --run-root "${RUN_ROOT}" --source-root "${BUILD_SOURCE_ROOT}")" || \
      BOOTSTRAP_REUSE_STATUS=$?
  fi
  if [[ "${BOOTSTRAP_REUSE_STATUS}" == 0 ]]; then
    BOOTSTRAP_REUSED=1
    echo "==> reusing verified bootstrap ${BOOTSTRAP_REUSE_KEY} (receipt ${BOOTSTRAP_REUSE_OUTPUT})" >&2
  elif [[ "${BOOTSTRAP_REUSE_STATUS}" == 3 ]]; then
    echo "==> full bootstrap: ${BOOTSTRAP_REUSE_OUTPUT}" >&2
  else
    echo "ERROR: bootstrap verification receipt lookup failed" >&2
    exit 1
  fi
fi
if [[ "${BOOTSTRAP_REUSED}" != 1 ]]; then
  timed_stage project.bootstrap \
    /bin/bash -c 'cd "$1" && exec ./Scripts/bootstrap.sh' \
    macscope-bootstrap "${BUILD_SOURCE_ROOT}"
  if [[ "${VERIFICATION_REUSE}" == 1 ]]; then
    if BOOTSTRAP_REUSE_OUTPUT="$("${BOOTSTRAP_REUSE_TOOL[@]}" record \
        "${BOOTSTRAP_REUSE_ARGUMENTS[@]}" \
        --run-root "${RUN_ROOT}" --source-root "${BUILD_SOURCE_ROOT}" \
        --verification "Scripts/bootstrap.sh (full governance, generation and post-generation checks)")"; then
      echo "==> published bootstrap verification receipt ${BOOTSTRAP_REUSE_OUTPUT} for ${BOOTSTRAP_REUSE_KEY}" >&2
    else
      # Publication is an optimization; the run's own bootstrap already passed.
      echo "==> bootstrap verification receipt not published: ${BOOTSTRAP_REUSE_OUTPUT}" >&2
    fi
  fi
fi

# Freeze the exact project bytes after bootstrap's deterministic generation and
# lightweight checks, before any qualification build/test action can consume
# them. Keep the digest in this process so cleanup cannot erase mutation proof.
GENERATED_PROJECT_IDENTITY="$(run_trusted_restore_tool --operation identity \
  "${BUILD_SOURCE_RESTORE_ARGUMENTS[@]}")"
if [[ ! "${GENERATED_PROJECT_IDENTITY}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: generated Xcode project returned a malformed byte identity" >&2
  exit 1
fi

acquire_heavy_gate_lock

XCODEBUILD=(
  /usr/bin/xcodebuild
  -project "${BUILD_SOURCE_ROOT}/MacScope/MacScope.xcodeproj"
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "${DERIVED_DATA_ROOT}"
  -parallelizeTargets
  -jobs "${XCODE_JOBS}"
  -showBuildTimingSummary
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
  # Qualification inputs already bind Debug to the sealed source transaction.
  # Use the existing runtime-only producer path rather than hashing that source
  # again in each Debug build. Release ignores this Debug-only selector and
  # retains complete source/dependency qualification.
  MACSCOPE_DEBUG_SOURCE_IDENTITY=runtime-only
  "MACSCOPE_GHOSTTY_VT_VERIFIED_ARTIFACT_ROOT=${GHOSTTY_VT_WORK_ROOT}/artifacts"
  "MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR=${GHOSTTY_VT_STAGING_DESCRIPTOR}"
  "MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR_SHA256=${GHOSTTY_VT_STAGING_SHA256}"
  "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT=${GHOSTTY_SURFACE_WORK_ROOT}"
  "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR=${GHOSTTY_SURFACE_SOURCE_DIR}"
  "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT=${GHOSTTY_SURFACE_ARTIFACT_ROOT}"
  "MACSCOPE_GHOSTTY_SURFACE_MANIFEST=${GHOSTTY_SURFACE_MANIFEST}"
  "MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT=${SLEIGH_SOURCE_BUILD_WORK_ROOT}"
  "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=${SLEIGH_SOURCE_BUILD_ROOT}"
  "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=${SLEIGH_ROOT}"
  "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=${PRIVATE_MACHOKIT_ROOT}"
  COMPILER_INDEX_STORE_ENABLE=NO
)
if [[ -n "${RETAINED_RELEASE_QUALIFICATION_INPUTS}" ]]; then
  XCODEBUILD+=(
    "MACSCOPE_QUALIFICATION_INPUTS_RECEIPT=${RECEIPT}"
    "MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS=${RETAINED_RELEASE_QUALIFICATION_INPUTS}"
    "MACSCOPE_NATIVE_RELEASE_ADMISSION=${NATIVE_RELEASE_ADMISSION}"
  )
  NATIVE_RELEASE_PROJECT_PATHS="$(/usr/bin/python3 -B - "${NATIVE_RELEASE_ADMISSION}" "${BUILD_SOURCE_ROOT}" <<'PYNATIVE'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[2]) / 'Scripts/qualification'))
import native_release_admission as native
admission = native.read(Path(sys.argv[1]), True)
print('\n'.join(native.project_paths(admission)))
PYNATIVE
)"
  NATIVE_RELEASE_BUILD_ROOT="${NATIVE_RELEASE_PROJECT_PATHS%%$'\n'*}"
  NATIVE_RELEASE_FILELIST_ROOT="${NATIVE_RELEASE_PROJECT_PATHS#*$'\n'}"
  XCODEBUILD+=("MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT=${NATIVE_RELEASE_BUILD_ROOT}")
  for native_phase in BRIDGE PACKAGE GOLDEN; do
    native_name="$(echo "${native_phase}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    XCODEBUILD+=(
      "MACSCOPE_NATIVE_${native_phase}_INPUT_FILE_LIST=${NATIVE_RELEASE_FILELIST_ROOT}/${native_name}-inputs.xcfilelist"
      "MACSCOPE_NATIVE_${native_phase}_OUTPUT_FILE_LIST=${NATIVE_RELEASE_FILELIST_ROOT}/${native_name}-outputs.xcfilelist"
    )
  done
fi
if [[ "${XCODE_OUTPUT}" == quiet ]]; then
  XCODEBUILD+=(-quiet)
fi
if [[ "${SIGNING}" == "isolated-ci" ]]; then
  XCODEBUILD+=(
    AD_HOC_CODE_SIGNING_ALLOWED=YES
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=-
    ENABLE_HARDENED_RUNTIME=YES
    DEVELOPMENT_TEAM=
    MACSCOPE_ISOLATED_CI_ADHOC_SIGNING=YES
  )
fi
# Xcode content-addressed compilation caching (smoke/focused-test only). The
# CAS outlives the run's fresh DerivedData. Only run-owned paths that compiled
# code never reads back are prefix-mapped (DerivedData, third-party sources,
# dependency views), so their cache keys no longer contain the random run root.
# First-party MacScope sources keep their real paths: SWIFT_ENABLE_PROJECT_PREFIX_MAPPING
# would rewrite #filePath, which CoreTests use to read the source tree.
if [[ "${COMPILATION_CACHE_ENABLED:-0}" == 1 ]]; then
  XCODEBUILD+=(
    COMPILATION_CACHE_ENABLE_CACHING=YES
    "COMPILATION_CACHE_CAS_PATH=${COMPILATION_CACHE_ROOT}"
    SWIFT_ENABLE_PREFIX_MAPPING=YES
    CLANG_ENABLE_PREFIX_MAPPING=YES
  )
  if [[ "${PATH_INDEPENDENT_CACHE:-0}" == 1 ]]; then
    # Retarget the stable alias at this run while the heavy-gate lock is held
    # (acquired above), atomically via rename. Every run maps its whole run
    # root to the same alias, so cache keys no longer contain the run path,
    # and #filePath/debug paths name the alias, which resolves to this run.
    COMPILATION_CACHE_ALIAS="${COMPILATION_CACHE_ALIAS_ROOT}/run"
    /bin/ln -sfn "${RUN_ROOT}" "${COMPILATION_CACHE_ALIAS}.$$"
    /bin/mv -h -f "${COMPILATION_CACHE_ALIAS}.$$" "${COMPILATION_CACHE_ALIAS}"
    if [[ "$(cd "${COMPILATION_CACHE_ALIAS}" && pwd -P)" != "${RUN_ROOT}" ]]; then
      echo "ERROR: build alias does not resolve to this run" >&2
      exit 1
    fi
    COMPILATION_CACHE_PREFIX_MAPPINGS=("${RUN_ROOT}=${COMPILATION_CACHE_ALIAS}")
    echo "==> path-independent compilation cache: ${RUN_ROOT} -> ${COMPILATION_CACHE_ALIAS}" >&2
  else
    COMPILATION_CACHE_PREFIX_MAPPINGS=(
      "${DERIVED_DATA_ROOT}=/^derived"
      "${BUILD_SOURCE_ROOT}/ThirdParty=/^thirdparty"
      "${BUILD_SOURCE_ROOT}/MacScope/LocalPackages=/^localpackages"
      "${PRIVATE_MACHOKIT_ROOT}=/^machokit"
      "${DEPENDENCY_WORK_ROOT}=/^dependencies"
    )
  fi
  # Xcode splits these list settings on whitespace; every mapped path lives
  # under the run root.
  if [[ "${RUN_ROOT}${COMPILATION_CACHE_ALIAS_ROOT:-}" =~ [[:space:]] ]]; then
    echo "==> compilation cache: run root contains whitespace; prefix mapping disabled" >&2
  else
    XCODEBUILD+=(
      "SWIFT_OTHER_PREFIX_MAPPINGS=${COMPILATION_CACHE_PREFIX_MAPPINGS[*]}"
      "CLANG_OTHER_PREFIX_MAPPINGS=${COMPILATION_CACHE_PREFIX_MAPPINGS[*]}"
    )
  fi
  echo "==> compilation cache: ${COMPILATION_CACHE_ROOT}" >&2
else
  echo "==> compilation cache disabled: ${COMPILATION_CACHE_DISABLED_REASON:-not enabled}" >&2
fi
# smoke/focused-test Debug provenance takes selected-input digests from the
# sealed manifest this qualifier verified before Xcode (and fully re-verifies
# after the last Xcode action) instead of re-hashing ~1.7 GB in a serial build
# phase. full-test (Gate F, CI) and release keep full re-hashing.
case "${MODE:-}" in
  smoke|focused-test)
    XCODEBUILD+=(MACSCOPE_PROVENANCE_SEALED_DIGESTS=trust-verified-export)
    ;;
esac
if [[ -n "${RUN_ROOT:-}" && -d "${RUN_ROOT:-}" ]]; then
  /usr/bin/python3 -B - "${RUN_ROOT}/COMPILATION_CACHE.json" \
    "${COMPILATION_CACHE_ENABLED:-0}" "${COMPILATION_CACHE_ROOT:-}" \
    "${COMPILATION_CACHE_DISABLED_REASON:-}" "${INSTALLED_UI_PRODUCTS:-auto}" \
    "${PATH_INDEPENDENT_CACHE:-0}" "${PATH_INDEPENDENT_CACHE_EXCLUDED_REASON:-}" \
    "${XCODEBUILD[@]}" <<'PY'
import json
from pathlib import Path
import sys
(destination, enabled, root, reason, installed_ui,
 path_independent, path_independent_excluded, *argv) = sys.argv[1:]
settings = [value for value in argv if value.split("=", 1)[0] in {
    "COMPILATION_CACHE_ENABLE_CACHING", "COMPILATION_CACHE_CAS_PATH",
    "SWIFT_ENABLE_PREFIX_MAPPING", "CLANG_ENABLE_PREFIX_MAPPING",
    "SWIFT_OTHER_PREFIX_MAPPINGS", "CLANG_OTHER_PREFIX_MAPPINGS"}]
document = {"schema_version": 1, "enabled": enabled == "1", "cas_path": root or None,
            "disabled_reason": reason or None, "installed_ui_products": installed_ui,
            "path_independent": enabled == "1" and path_independent == "1",
            "path_independent_excluded_reason": path_independent_excluded or None,
            "xcodebuild_settings": settings}
path = Path(destination)
path.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n")
path.chmod(0o600)
PY
fi

record_test_selection() {
  {
    printf '%s\n' "Qualification test execution selection (build mode: ${MODE})"
    printf '%s\n' "${TEST_SELECTION_ARGUMENTS[@]}"
    if [[ ${#ONLY_TESTING[@]} != 0 ]]; then
      printf '%s\n' "Bounded affected-case coverage only; unselected cases are not rerun or newly qualified."
    fi
    printf '%s\n' "Installed/GUI acceptance is separate; nonwindow exclusions remain in NONWINDOW_TEST_SCOPE.json."
  } > "${RUN_ROOT}/TEST_SELECTION.txt"
  /bin/cat "${RUN_ROOT}/TEST_SELECTION.txt"
}

case "${MODE}" in
  smoke)
    timed_xcode_stage xcode.debug-build "${RUN_ROOT}/xcode-debug-build.log" \
      "${XCODEBUILD[@]}" -scheme MacScopeApp -configuration Debug build
    ;;
  focused-test)
    record_test_selection
    RESULT_BUNDLE="${RUN_ROOT}/FocusedTestResults.xcresult"
    if [[ -e "${RESULT_BUNDLE}" || -L "${RESULT_BUNDLE}" ]]; then
      echo "ERROR: focused result bundle already exists; refusing to overwrite evidence" >&2
      exit 1
    fi
    load_serial_core_tests
    # --only-testing is repeatable (#261). A sole CoreTests selector runs the
    # parallel/serial partition; otherwise one pass over exactly the selectors,
    # with parallelism off when any selector names a serial class.
    FOCUSED_SERIAL=0
    for selector in ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"}; do
      if selector_is_serial_core_test "${selector}"; then
        FOCUSED_SERIAL=1
      fi
    done
    if [[ ${#ONLY_TESTING[@]} == 1 && ( "${ONLY_TESTING[0]}" == CoreTests || "${ONLY_TESTING[0]}" == Phase2Tests ) ]]; then
      PARTITION_BUNDLES=("${ONLY_TESTING[0]}")
      run_core_tests_partition "${RESULT_BUNDLE}" \
        xcode.focused-test "${RUN_ROOT}/xcode-focused-test.log" test \
        xcode.focused-test-serial "${RUN_ROOT}/xcode-focused-test-serial.log" test-without-building \
        -- -scheme MacScopeApp -configuration Debug
    elif [[ "${FOCUSED_SERIAL}" == 1 ]]; then
      timed_xcode_stage xcode.focused-test-serial "${RUN_ROOT}/xcode-focused-test-serial.log" \
        "${XCODEBUILD[@]}" -scheme MacScopeApp -configuration Debug \
          -resultBundlePath "${RESULT_BUNDLE}" -parallel-testing-enabled NO \
          "${TEST_SELECTION_ARGUMENTS[@]}" test
    else
      timed_xcode_stage xcode.focused-test "${RUN_ROOT}/xcode-focused-test.log" \
        "${XCODEBUILD[@]}" -scheme MacScopeApp -configuration Debug \
          -resultBundlePath "${RESULT_BUNDLE}" \
          -parallel-testing-enabled YES -parallel-testing-worker-count "${CORE_TEST_WORKERS}" \
          "${TEST_SELECTION_ARGUMENTS[@]}" test
    fi
    echo "MACSCOPE_TEST_RESULTS=${RESULT_BUNDLE}"
    ;;
  full-test)
    record_test_selection
    RESULT_BUNDLE="${RUN_ROOT}/TestResults.xcresult"
    COVERAGE_JSON="${RUN_ROOT}/COVERAGE.json"
    COVERAGE_PROFILE_ROOT="${RUN_ROOT}/CoverageProfiles"
    if [[ -e "${RESULT_BUNDLE}" || -L "${RESULT_BUNDLE}" ]]; then
      RESULT_INDEX=1
      while [[ -e "${RUN_ROOT}/TestResults.resume-${RESULT_INDEX}.xcresult" || \
               -L "${RUN_ROOT}/TestResults.resume-${RESULT_INDEX}.xcresult" ]]; do
        RESULT_INDEX=$((RESULT_INDEX + 1))
      done
      RESULT_BUNDLE="${RUN_ROOT}/TestResults.resume-${RESULT_INDEX}.xcresult"
      COVERAGE_JSON="${RUN_ROOT}/COVERAGE.resume-${RESULT_INDEX}.json"
      COVERAGE_PROFILE_ROOT="${RUN_ROOT}/CoverageProfiles.resume-${RESULT_INDEX}"
    fi
    /bin/mkdir -p "${COVERAGE_PROFILE_ROOT}"
    # This is the sole additional product build needed for installed
    # acceptance. It shares the qualifier's DerivedData with the CoreTests
    # gate, so Xcode reuses the already-built app and dependency products. A
    # resumed sealed run reuses a complete existing UI product set and rejects
    # a partial one instead of launching a redundant or repairing build.
    INSTALLED_PRODUCTS_ROOT="${DERIVED_DATA_ROOT}/Build/Products"
    QUALIFICATION_SDK_VERSION="$(DEVELOPER_DIR="${QUALIFICATION_DEVELOPER_DIR}" /usr/bin/xcrun --sdk macosx --show-sdk-version)"
    # --installed-ui-products skip: CoreTests + host app (+ embedded XPC
    # services) only; no installed-acceptance preparation is published.
    if [[ "${INSTALLED_UI_PRODUCTS}" != skip ]]; then
      INSTALLED_XCTESTRUN="$(/usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/reconstruction/qualification_xctestrun.py" \
        --products-root "${INSTALLED_PRODUCTS_ROOT}" --scheme MacScopeInstalledAppUITests \
        --sdk-version "${QUALIFICATION_SDK_VERSION}" --allow-missing)"
      INSTALLED_RUNNER="${INSTALLED_PRODUCTS_ROOT}/Debug/MacScopeInstalledAppUITests-Runner.app"
      INSTALLED_TEST_BUNDLE="${INSTALLED_RUNNER}/Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
      INSTALLED_APP="${INSTALLED_PRODUCTS_ROOT}/Debug/MacScope.app"
      INSTALLED_PRODUCT_COUNT=0
      for INSTALLED_PRODUCT in \
        "${INSTALLED_XCTESTRUN}" \
        "${INSTALLED_RUNNER}" \
        "${INSTALLED_TEST_BUNDLE}" \
        "${INSTALLED_APP}"
      do
        if [[ -e "${INSTALLED_PRODUCT}" || -L "${INSTALLED_PRODUCT}" ]]; then
          INSTALLED_PRODUCT_COUNT=$((INSTALLED_PRODUCT_COUNT + 1))
        fi
      done
      if [[ "${INSTALLED_PRODUCT_COUNT}" == 0 ]]; then
        timed_xcode_stage xcode.installed-ui-build-for-testing \
          "${RUN_ROOT}/xcode-installed-ui-build-for-testing.log" \
          "${XCODEBUILD[@]}" -scheme MacScopeInstalledAppUITests \
            -configuration Debug -enableCodeCoverage YES build-for-testing
      elif [[ "${INSTALLED_PRODUCT_COUNT}" != 4 ]]; then
        echo "ERROR: installed UI qualification products are partial; refusing a repairing build" >&2
        exit 1
      fi
    fi
    timed_xcode_stage xcode.core-tests-build-for-testing \
      "${RUN_ROOT}/xcode-core-tests-build-for-testing.log" \
      "${XCODEBUILD[@]}" -scheme MacScopeApp -configuration Debug \
        -enableCodeCoverage YES \
        -only-testing:CoreTests -only-testing:Phase2Tests build-for-testing
    NONWINDOW_TEST_ARGUMENTS=()
    if [[ "${MACSCOPE_NONWINDOW_CORE_TESTS:-0}" == 1 ]]; then
      /usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/qualification/nonwindow_core_tests.py" \
        --source-root "${BUILD_SOURCE_ROOT}" \
        --receipt "${RUN_ROOT}/NONWINDOW_TEST_SCOPE.json" > "${RUN_ROOT}/nonwindow-test-arguments.txt"
      while IFS= read -r selection_argument; do
        NONWINDOW_TEST_ARGUMENTS+=("${selection_argument}")
      done < "${RUN_ROOT}/nonwindow-test-arguments.txt"
      echo "CoreTests window suites are excluded and UNCOVERED; see NONWINDOW_TEST_SCOPE.json"
    fi
    load_serial_core_tests
    CORE_TESTS_PREFIX=(/usr/bin/env "LLVM_PROFILE_FILE=${COVERAGE_PROFILE_ROOT}/%p-%m.profraw")
    CORE_TESTS_OPTIONS=(-scheme MacScopeApp -configuration Debug -enableCodeCoverage YES
      ${NONWINDOW_TEST_ARGUMENTS[@]+"${NONWINDOW_TEST_ARGUMENTS[@]}"})
    if [[ ${#ONLY_TESTING[@]} == 0 ]]; then
      run_core_tests_partition "${RESULT_BUNDLE}" \
        xcode.core-tests "${RUN_ROOT}/xcode-core-tests.log" test-without-building \
        xcode.core-tests-serial "${RUN_ROOT}/xcode-core-tests-serial.log" test-without-building \
        "${CORE_TESTS_PREFIX[@]}" \
        -- "${CORE_TESTS_OPTIONS[@]}"
    else
      # Bounded affected-case selection (#261 --only-testing in full-test):
      # one pass over exactly the named selectors.
      timed_xcode_stage xcode.core-tests "${RUN_ROOT}/xcode-core-tests.log" \
        "${CORE_TESTS_PREFIX[@]}" \
        "${XCODEBUILD[@]}" "${CORE_TESTS_OPTIONS[@]}" \
          -resultBundlePath "${RESULT_BUNDLE}" \
          "${TEST_SELECTION_ARGUMENTS[@]}" test-without-building
    fi
    COVERAGE_TEMPORARY="${COVERAGE_JSON}.tmp"
    /usr/bin/xcrun xccov view --report --json \
      "${RESULT_BUNDLE}" > "${COVERAGE_TEMPORARY}"
    /bin/mv "${COVERAGE_TEMPORARY}" "${COVERAGE_JSON}"
    # Installed acceptance consumes one certificate-backed Release candidate.
    # Keep Debug test products for their xctestrun/runner authority, but bind
    # both preparation receipts to the exact Release app built from this run.
    # --release-candidate skip (intermediate PR CI only) records the omission
    # instead; such a run is never Release, Gate F or installed evidence.
    if [[ "${RELEASE_CANDIDATE}" == skip ]]; then
      echo "==> Release candidate skipped (--release-candidate skip): no Release build, Release provenance or installed-acceptance preparation" >&2
      printf '{"release_candidate":"skipped","schema_version":1}\n' > "${RUN_ROOT}/RELEASE_CANDIDATE.json"
      /bin/chmod 600 "${RUN_ROOT}/RELEASE_CANDIDATE.json"
    else
      timed_xcode_stage xcode.release-build "${RUN_ROOT}/xcode-release-build.log" \
        "${XCODEBUILD[@]}" -scheme MacScopeApp -configuration Release \
          CLANG_COVERAGE_MAPPING=NO build
    fi
    echo "MACSCOPE_TEST_RESULTS=${RESULT_BUNDLE}"
    echo "MACSCOPE_COVERAGE_JSON=${COVERAGE_JSON}"
    ;;
  release)
    timed_xcode_stage xcode.release-build "${RUN_ROOT}/xcode-release-build.log" \
      "${XCODEBUILD[@]}" -scheme MacScopeApp -configuration Release \
        CLANG_COVERAGE_MAPPING=NO build
    ;;
esac
if [[ -n "${COMPILATION_CACHE_ALIAS:-}" && -L "${COMPILATION_CACHE_ALIAS}" ]]; then
  /bin/rm -f "${COMPILATION_CACHE_ALIAS}"
fi
release_heavy_gate_lock

# Bootstrap and Xcode require three ignored source-adjacent artifacts, but the
# admitted source contract is a closed Git tree. Restore that closed tree after
# the last Xcode action. Reuse the existing admitted identity; the final
# validator binds the receipt and manifests without re-reading source leaves.
/usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/qualification/generated_project_evidence.py" \
  --run-root "${RUN_ROOT}" \
  --expected-project-identity "${GENERATED_PROJECT_IDENTITY}"
run_trusted_restore_tool --operation restore \
  --expected-project-identity "${GENERATED_PROJECT_IDENTITY}" \
  "${BUILD_SOURCE_RESTORE_ARGUMENTS[@]}"
echo "==> reusing admitted source identity after scoped scaffold restoration; no source-byte re-verification" >&2

publish_installed_acceptance_preparation() {
  local preparation_producer
  local products_root
  local native_xctestrun
  local installed_xctestrun
  local candidate_app
  local native_test_bundle
  local ui_runner
  local ui_test_bundle

  preparation_producer="${BUILD_SOURCE_ROOT}/Scripts/reconstruction/native_live_preparation_receipt.py"
  products_root="${DERIVED_DATA_ROOT}/Build/Products"
  native_xctestrun="$(/usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/reconstruction/qualification_xctestrun.py" \
    --products-root "${products_root}" --scheme MacScopeApp --sdk-version "${QUALIFICATION_SDK_VERSION}")"
  installed_xctestrun="$(/usr/bin/python3 -B "${BUILD_SOURCE_ROOT}/Scripts/reconstruction/qualification_xctestrun.py" \
    --products-root "${products_root}" --scheme MacScopeInstalledAppUITests --sdk-version "${QUALIFICATION_SDK_VERSION}")"
  candidate_app="${products_root}/Release/MacScope.app"
  native_test_bundle="${products_root}/Debug/MacScope.app/Contents/PlugIns/CoreTests.xctest"
  ui_runner="${products_root}/Debug/MacScopeInstalledAppUITests-Runner.app"
  ui_test_bundle="${ui_runner}/Contents/PlugIns/MacScopeInstalledAppUITests.xctest"

  if [[ ! -f "${preparation_producer}" || -L "${preparation_producer}" ]]; then
    echo "ERROR: installed acceptance preparation producer is missing or indirect" >&2
    return 1
  fi
  if [[ -e "${CANDIDATE_ARTIFACT_ROOT}" || -L "${CANDIDATE_ARTIFACT_ROOT}" ]]; then
    if [[ ! -d "${CANDIDATE_ARTIFACT_ROOT}" || -L "${CANDIDATE_ARTIFACT_ROOT}" || \
          "$(cd "${CANDIDATE_ARTIFACT_ROOT}" && pwd -P)" != "${CANDIDATE_ARTIFACT_ROOT}" ]]; then
      echo "ERROR: candidate artifact root is not one canonical physical directory" >&2
      return 1
    fi
  else
    /bin/mkdir -m 700 "${CANDIDATE_ARTIFACT_ROOT}"
  fi
  NATIVE_RECEIPT_PRESENT=0
  INSTALLED_RECEIPT_PRESENT=0
  if [[ -e "${NATIVE_PREPARATION_RECEIPT}" || -L "${NATIVE_PREPARATION_RECEIPT}" ]]; then
    NATIVE_RECEIPT_PRESENT=1
  fi
  if [[ -e "${INSTALLED_UI_PREPARATION_RECEIPT}" || -L "${INSTALLED_UI_PREPARATION_RECEIPT}" ]]; then
    INSTALLED_RECEIPT_PRESENT=1
  fi
  if [[ "${NATIVE_RECEIPT_PRESENT}" != "${INSTALLED_RECEIPT_PRESENT}" ]]; then
    echo "ERROR: installed acceptance preparation receipt set is partial" >&2
    return 1
  fi
  if [[ "${NATIVE_RECEIPT_PRESENT}" == 0 ]]; then
    DEVELOPER_DIR="${QUALIFICATION_DEVELOPER_DIR}" /usr/bin/python3 -B \
      "${preparation_producer}" create \
      --repository-root "${SOURCE_ROOT}" \
      --repository-label "${INTEGRATION_REPOSITORY_LABEL}" \
      --xctestrun "${native_xctestrun}" \
      --candidate-app "${candidate_app}" \
      --test-bundle "${native_test_bundle}" \
      --output "${NATIVE_PREPARATION_RECEIPT}"
    DEVELOPER_DIR="${QUALIFICATION_DEVELOPER_DIR}" /usr/bin/python3 -B \
      "${preparation_producer}" create \
      --repository-root "${SOURCE_ROOT}" \
      --repository-label "${INTEGRATION_REPOSITORY_LABEL}" \
      --xctestrun "${installed_xctestrun}" \
      --candidate-app "${candidate_app}" \
      --preparation-mode installed-ui-matrix \
      --test-bundle "${ui_test_bundle}" \
      --ui-runner "${ui_runner}" \
      --output "${INSTALLED_UI_PREPARATION_RECEIPT}"
  fi

  # Re-read both create-only products through the same producer and compare
  # them with freshly derived exact documents. This closes schema, source,
  # toolchain, build, artifact-path, and artifact-byte authority before the
  # qualifier exposes its success token.
  DEVELOPER_DIR="${QUALIFICATION_DEVELOPER_DIR}" /usr/bin/python3 -B - \
    "${preparation_producer}" \
    "${SOURCE_ROOT}" \
    "${native_xctestrun}" \
    "${installed_xctestrun}" \
    "${candidate_app}" \
    "${native_test_bundle}" \
    "${ui_test_bundle}" \
    "${ui_runner}" \
    "${NATIVE_PREPARATION_RECEIPT}" \
    "${INSTALLED_UI_PREPARATION_RECEIPT}" \
    "${INTEGRATION_REPOSITORY_LABEL}" \
    "${INTEGRATION_COMMIT}" \
    "${INTEGRATION_TREE}" <<'PY'
import importlib.util
from pathlib import Path
import stat
import sys

(
    producer_path,
    source_root,
    native_xctestrun,
    installed_xctestrun,
    candidate_app,
    native_test_bundle,
    ui_test_bundle,
    ui_runner,
    native_receipt,
    installed_receipt,
    expected_repository_label,
    expected_commit,
    expected_tree,
) = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "macscope_qualification_preparation_receipt", producer_path
)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load the installed acceptance preparation producer")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
for receipt_path in (Path(native_receipt), Path(installed_receipt)):
    metadata = receipt_path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
        or receipt_path.resolve(strict=True) != receipt_path
    ):
        raise SystemExit("installed acceptance preparation receipt is not a canonical single-link file")
toolchain = module._toolchain_identity()
native_expected = module.create_document(
    Path(source_root),
    expected_repository_label,
    Path(native_xctestrun),
    Path(candidate_app),
    toolchain=toolchain,
    test_bundle=Path(native_test_bundle),
)
installed_expected = module.create_document(
    Path(source_root),
    expected_repository_label,
    Path(installed_xctestrun),
    Path(candidate_app),
    toolchain=toolchain,
    preparation_mode=module.INSTALLED_UI_PREPARATION_MODE,
    test_bundle=Path(ui_test_bundle),
    ui_runner=Path(ui_runner),
)
native_observed = module.load_receipt(Path(native_receipt))
installed_observed = module.load_receipt(Path(installed_receipt))
if native_observed != native_expected or installed_observed != installed_expected:
    raise SystemExit("installed acceptance preparation receipt differs from exact authority")
for document in (native_observed, installed_observed):
    if (
        document.get("schema_version") != 2
        or document.get("receipt_kind") != "native-live-xpc-preparation"
        or document.get("source", {}).get("commit") != expected_commit
        or document.get("source", {}).get("tree") != expected_tree
    ):
        raise SystemExit("installed acceptance preparation receipt source or schema differs")
PY
}

if [[ "${PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY}" == 1 ]]; then
  publish_installed_acceptance_preparation
fi

QUALIFICATION_CONFIGURATION=Debug
if [[ "${MODE}" == release || \
      ( "${MODE}" == full-test && "${RELEASE_CANDIDATE}" != skip ) ]]; then
  QUALIFICATION_CONFIGURATION=Release
fi
QUALIFICATION_APP_BUNDLE="${DERIVED_DATA_ROOT}/Build/Products/${QUALIFICATION_CONFIGURATION}/MacScope.app"
echo "==> final validation reuses the admitted source/manifest receipt; no new source freshness claim" >&2
timed_stage qualification.final-validation \
  "${QUALIFICATION_VALIDATOR[@]}" validate-build \
    "${QUALIFICATION_AUTHORITY_ARGUMENTS[@]}" \
    --expected-configuration "${QUALIFICATION_CONFIGURATION}" \
    --app-bundle "${QUALIFICATION_APP_BUNDLE}"
emit_qualification_outputs
