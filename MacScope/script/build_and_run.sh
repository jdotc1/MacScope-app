#!/usr/bin/env bash
set -euo pipefail
umask 077

MODE="${1:-run}"

usage() {
  cat >&2 <<'EOF'
usage: MacScope/script/build_and_run.sh [MODE]

Build-capable modes:
  run                 stop only the previously receipted process, build, launch,
                      and wait for first-window readiness (default)
  build, --build      build and record the exact executable; do not launch
  debug, --debug      build, then debug that exact executable with LLDB

No-build modes:
  verify, --verify    prove source, executable, PID/start/path, and first window
  logs, --logs        stream unified logs scoped to the receipted PID
  telemetry, --telemetry
                      stream PID-scoped MacScope subsystem/category telemetry
  stop, --stop        terminate only the receipted exact PID/start/path process

Launch helper cache:
  The external helper is compiled only when its source bytes or selected
  Xcode/Swift compiler identity changes; ordinary launches reuse that cache.
EOF
}

if [[ "$#" -gt 1 ]]; then
  usage
  exit 2
fi

case "${MODE}" in
  -h|--help|help)
    usage
    exit 0
    ;;
  run|build|--build|debug|--debug|logs|--logs|telemetry|--telemetry|verify|--verify|stop|--stop)
    ;;
  *)
    usage
    exit 2
    ;;
esac

APP_NAME="MacScope"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"
REPOSITORY_ROOT_REAL="$(cd "${REPOSITORY_ROOT}" && pwd -P)"

# Keep this driver's build database stable for warm rebuilds, but isolate it
# from Xcode, focused tests, and every other linked worktree. Sharing one
# DerivedData root across worktrees causes build.db signature churn and can
# produce needless relinks and re-signing when agents alternate builds.
if [[ -n "${MACSCOPE_DERIVED_DATA:-}" ]]; then
  DERIVED_DATA="${MACSCOPE_DERIVED_DATA}"
else
  WORKTREE_ID="$(
    /usr/bin/python3 -B -c \
      'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' \
      "${REPOSITORY_ROOT_REAL}"
  )"
  DERIVED_DATA="${HOME:-/private/tmp}/Library/Developer/Xcode/DerivedData/MacScopeRun-${WORKTREE_ID}"
fi

if [[ "${DERIVED_DATA}" != /* ]]; then
  echo "ERROR: MACSCOPE_DERIVED_DATA must be an absolute path outside the repository." >&2
  exit 1
fi

case "${DERIVED_DATA}/" in
  "${REPOSITORY_ROOT}/"* | "${REPOSITORY_ROOT_REAL}/"*)
    echo "ERROR: run DerivedData must remain outside the repository: ${DERIVED_DATA}" >&2
    exit 1
    ;;
esac

# Resolve existing symlinks before creating the destination so an apparently
# external override cannot traverse a symlink back into the worktree.
DERIVED_DATA="$(
  /usr/bin/python3 -B -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "${DERIVED_DATA}"
)"
HOME_REAL="$(
  /usr/bin/python3 -B -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "${HOME:-/private/tmp}"
)"
case "${DERIVED_DATA}" in
  / | "${HOME_REAL}" | "${REPOSITORY_ROOT_REAL}")
    echo "ERROR: run DerivedData must name a dedicated external directory: ${DERIVED_DATA}" >&2
    exit 1
    ;;
esac
case "${DERIVED_DATA}/" in
  "${REPOSITORY_ROOT_REAL}/"*)
    echo "ERROR: run DerivedData must remain outside the repository: ${DERIVED_DATA}" >&2
    exit 1
    ;;
esac
mkdir -p "${DERIVED_DATA}"
DERIVED_DATA="$(cd "${DERIVED_DATA}" && pwd -P)"

PROJECT_FILE="$ROOT_DIR/MacScope.xcodeproj"
SCHEME="${MACSCOPE_SCHEME:-MacScopeApp}"
CONFIGURATION="${MACSCOPE_CONFIGURATION:-Debug}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
DEPENDENCY_ROOTS="$ROOT_DIR/DependencyRoots.local.xcconfig"
RUNLOOP_HELPER="$REPOSITORY_ROOT/Scripts/runloop_exact_app.py"
RECEIPT_DIRECTORY="$DERIVED_DATA/MacScopeRunLoop"
BUILD_RECEIPT="$RECEIPT_DIRECTORY/build-receipt.json"
PROCESS_RECEIPT="$RECEIPT_DIRECTORY/process-receipt.json"

[[ -f "${RUNLOOP_HELPER}" && ! -L "${RUNLOOP_HELPER}" ]] || {
  echo "ERROR: exact runloop helper is missing or indirect: ${RUNLOOP_HELPER}" >&2
  exit 1
}

build_app() {
  local dependency_identity project_identity source_identity
  dependency_identity="$(
    /usr/bin/python3 -B "${RUNLOOP_HELPER}" verify-dependencies \
      --repository "${REPOSITORY_ROOT_REAL}" \
      --config "${DEPENDENCY_ROOTS}"
  )"
  source_identity="$(
    /usr/bin/python3 -B "${RUNLOOP_HELPER}" source-identity \
      --repository "${REPOSITORY_ROOT_REAL}"
  )"
  project_identity="$(
    /usr/bin/python3 -B "${RUNLOOP_HELPER}" generated-project-identity \
      --repository "${REPOSITORY_ROOT_REAL}"
  )"
  source "${ROOT_DIR}/../Scripts/xcode27_env.sh"
  xcrun xcodebuild build \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -showBuildTimingSummary
  /usr/bin/python3 "$ROOT_DIR/../Scripts/check_local_signing_policy.py" --app-bundle "$APP_BUNDLE" --configuration "$CONFIGURATION"
  /usr/bin/python3 -B "${RUNLOOP_HELPER}" record-build \
    --repository "${REPOSITORY_ROOT_REAL}" \
    --app-bundle "${APP_BUNDLE}" \
    --executable "${APP_EXECUTABLE}" \
    --configuration "${CONFIGURATION}" \
    --expected-source-identity "${source_identity}" \
    --expected-project-identity "${project_identity}" \
    --expected-dependency-identity "${dependency_identity}" \
    --build-receipt "${BUILD_RECEIPT}" >/dev/null
}

cd "$ROOT_DIR"

case "$MODE" in
  run)
    /usr/bin/python3 -B "${RUNLOOP_HELPER}" stop \
      --process-receipt "${PROCESS_RECEIPT}"
    build_app
    /usr/bin/python3 -B "${RUNLOOP_HELPER}" launch \
      --build-receipt "${BUILD_RECEIPT}" \
      --process-receipt "${PROCESS_RECEIPT}" \
      --timeout "${MACSCOPE_RUNLOOP_LAUNCH_TIMEOUT:-20}"
    ;;
  build|--build)
    build_app
    ;;
  debug|--debug)
    debug_executable=""
    /usr/bin/python3 -B "${RUNLOOP_HELPER}" stop \
      --process-receipt "${PROCESS_RECEIPT}"
    build_app
    debug_executable="$(
      /usr/bin/python3 -B "${RUNLOOP_HELPER}" verify-build \
        --build-receipt "${BUILD_RECEIPT}"
    )"
    xcrun lldb -- "${debug_executable}"
    ;;
  logs|--logs)
    exec /usr/bin/python3 -B "${RUNLOOP_HELPER}" logs \
      --build-receipt "${BUILD_RECEIPT}" \
      --process-receipt "${PROCESS_RECEIPT}"
    ;;
  telemetry|--telemetry)
    exec /usr/bin/python3 -B "${RUNLOOP_HELPER}" telemetry \
      --build-receipt "${BUILD_RECEIPT}" \
      --process-receipt "${PROCESS_RECEIPT}"
    ;;
  verify|--verify)
    /usr/bin/python3 -B "${RUNLOOP_HELPER}" verify \
      --build-receipt "${BUILD_RECEIPT}" \
      --process-receipt "${PROCESS_RECEIPT}"
    ;;
  stop|--stop)
    /usr/bin/python3 -B "${RUNLOOP_HELPER}" stop \
      --process-receipt "${PROCESS_RECEIPT}" \
      --timeout "${MACSCOPE_RUNLOOP_STOP_TIMEOUT:-8}"
    ;;
esac
