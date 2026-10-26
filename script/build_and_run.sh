#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACSCOPE_DIR="${ROOT_DIR}/MacScope"
PROJECT_YML="${MACSCOPE_DIR}/project.yml"
XCODEPROJ="${MACSCOPE_DIR}/MacScope.xcodeproj"
SCHEME="${MACSCOPE_SCHEME:-MacScopeApp}"
CONFIGURATION="${MACSCOPE_CONFIGURATION:-Debug}"
MODE="${1:-run}"

usage() {
  cat >&2 <<'EOF'
usage: ./script/build_and_run.sh [MODE] [TEST]

Routine fast paths:
  --test [TEST]        incrementally build and run TEST (default: CoreTests)
  --rerun-test [TEST]  rerun an already-built TEST without any build work
  --prepare            bootstrap only when the generated project is stale/missing

App modes:
  run                 bootstrap only if stale, then exact build + launch
  build, --build      bootstrap only if stale, then exact build without launch
  debug, --debug      bootstrap only if stale, then debug the exact executable
  logs, --logs        no build; stream logs for the receipted exact PID
  telemetry, --telemetry
                      no build; stream PID-scoped subsystem/category telemetry
  verify, --verify    no build; verify the current exact generation
  stop, --stop        no build; stop only the receipted exact process
EOF
}

# >>> dependency-root-freshness
# Compare bootstrap's explicit nonempty root inputs, not its discovered defaults.
# This reads configuration text only; dependency admission/receipts are unchanged.
dependency_roots_are_current() {
  /usr/bin/python3 -B - "${MACSCOPE_DIR}/DependencyRoots.local.xcconfig" <<'PYROOTS'
import os
from pathlib import Path
import sys

configuration = Path(sys.argv[1])
# Published names that bootstrap consumes directly. Ghostty's source/artifact/
# framework fields derive from its work root; they are not independent env inputs.
inputs = {
    "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT": "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT",
    "MACSCOPE_SLEIGH_COMPONENT_ROOT": "MACSCOPE_SLEIGH_COMPONENT_ROOT",
    "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT": "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT",
    "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT": "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT",
    "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT": "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT",
    "MACSCOPE_DEPENDENCY_CACHE_ROOT": "MACSCOPE_PARSER_ENGINE_CACHE_ROOT",
    "MACSCOPE_PATTERN_ADAPTER_ROOT": "MACSCOPE_PATTERN_ADAPTER_ROOT",
}
# bootstrap uses ${NAME:-...}: an empty or absent variable does not select a root.
requested = {name: os.environ[name] for name in inputs if os.environ.get(name)}
if not requested:
    raise SystemExit(0)
try:
    lines = configuration.read_text(encoding="utf-8").splitlines()
except OSError as error:
    print(f"ERROR: cannot read dependency-root configuration {configuration}: {error}", file=sys.stderr)
    raise SystemExit(1)
recorded = {}
for line in lines:
    if line.lstrip().startswith("//"):
        continue
    key, separator, value = line.partition("=")
    if separator:
        recorded.setdefault(key.strip(), []).append(value.strip())
stale = False
for name, value in requested.items():
    setting = inputs[name]
    # Bootstrap publishes literal unquoted paths; never evaluate xcconfig macros,
    # unescape shell syntax, canonicalize roots, or inspect dependency contents.
    values = recorded.get(setting, [])
    if values != [value]:
        state = "empty or missing" if not values or values == [""] else repr(values)
        print(f"ERROR: generated dependency root {setting} is {state} in {configuration}; "
              f"{name} explicitly requests {value!r}. Generated project is stale.", file=sys.stderr)
        stale = True
raise SystemExit(1 if stale else 0)
PYROOTS
}
# <<< dependency-root-freshness

generated_project_is_fresh() {
  [[ ! -e "${XCODEPROJ}/.unsigned-development" && ! -e "${XCODEPROJ}/.cache-release" ]] || return 1
  [[ -d "${XCODEPROJ}" && -f "${MACSCOPE_DIR}/DependencyRoots.local.xcconfig" ]] || return 1
  dependency_roots_are_current || return 1
  /usr/bin/python3 -B - "${ROOT_DIR}" "${PROJECT_YML}" <<'PY'
import importlib.util
from pathlib import Path
import sys

repository, project_yml = map(Path, sys.argv[1:])
policy_path = repository / "Scripts" / "check_local_signing_policy.py"
spec = importlib.util.spec_from_file_location("macscope_signing_policy", policy_path)
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
raise SystemExit(bool(module.validate_generated_project_freshness(project_yml)))
PY
}

ensure_generated_project() {
  # MacScope/LocalPackages points at the external read-only MachOKit view. If
  # that view is gone (an older $TMPDIR default wiped by a restart), the project
  # still looks fresh but package resolution fails, so re-run bootstrap once.
  local local_packages="${MACSCOPE_DIR}/LocalPackages"
  if [[ -L "${local_packages}" && ! -e "${local_packages}" ]]; then
    echo "==> MacScope/LocalPackages target is missing ($(/usr/bin/readlink "${local_packages}")); re-materializing MachOKit via bootstrap ..."
    "${ROOT_DIR}/Scripts/bootstrap.sh"
    dependency_roots_are_current || {
      echo "ERROR: bootstrap did not publish the requested dependency roots; refusing to build." >&2
      return 1
    }
    return
  fi
  if generated_project_is_fresh; then
    echo "==> Reusing verified generated project (freshness contract passed)"
    return
  fi
  echo "==> Generated project is absent or stale; running bootstrap once ..."
  "${ROOT_DIR}/Scripts/bootstrap.sh"
  dependency_roots_are_current || {
    echo "ERROR: bootstrap did not publish the requested dependency roots; refusing to build." >&2
    return 1
  }
}

canonical_test_derived_data() {
  /usr/bin/python3 -B - "${1}" "${ROOT_DIR}" "${HOME:-/private/tmp}" <<'PY'
import os
from pathlib import Path
import sys

requested, repository_value, home_value = sys.argv[1:]
candidate = Path(requested)
if not candidate.is_absolute():
    raise SystemExit("ERROR: MACSCOPE_TEST_DERIVED_DATA must be an absolute path outside the repository.")
resolved = Path(os.path.realpath(candidate))
repository = Path(repository_value).resolve(strict=True)
home = Path(home_value).resolve(strict=True)
if resolved in (Path("/"), repository, home) or repository in resolved.parents:
    raise SystemExit(f"ERROR: test DerivedData must name a dedicated path outside the repository: {resolved}")
resolved.mkdir(parents=True, exist_ok=True)
print(resolved.resolve(strict=True))
PY
}

test_derived_data() {
  if [[ -n "${MACSCOPE_TEST_DERIVED_DATA:-}" ]]; then
    canonical_test_derived_data "${MACSCOPE_TEST_DERIVED_DATA}"
    return
  fi
  local worktree_id
  worktree_id="$(
    /usr/bin/python3 -B -c \
      'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' \
      "$(cd "${ROOT_DIR}" && pwd -P)"
  )"
  canonical_test_derived_data \
    "${HOME:-/private/tmp}/Library/Developer/Xcode/DerivedData/MacScopeFocusedTests-${worktree_id}"
}

run_test() {
  local action="$1"
  local selector="$2"
  local derived_data
  derived_data="$(test_derived_data)"
  source "${ROOT_DIR}/Scripts/xcode27_env.sh"
  echo "==> ${action}: -only-testing:${selector}"
  echo "    DerivedData: ${derived_data}"
  xcrun xcodebuild "${action}" \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${derived_data}" \
    -only-testing:"${selector}" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    -showBuildTimingSummary
}

case "${MODE}" in
  -h|--help|help)
    usage
    exit 0
    ;;
  --prepare|prepare)
    [[ "$#" -eq 1 ]] || { usage; exit 2; }
    ensure_generated_project
    ;;
  --test|test)
    [[ "$#" -le 2 ]] || { usage; exit 2; }
    ensure_generated_project
    run_test test "${2:-CoreTests}"
    ;;
  --rerun-test|rerun-test)
    [[ "$#" -le 2 ]] || { usage; exit 2; }
    ensure_generated_project
    run_test test-without-building "${2:-CoreTests}"
    ;;
  run|build|--build|debug|--debug)
    [[ "$#" -le 1 ]] || { usage; exit 2; }
    ensure_generated_project
    cd "${MACSCOPE_DIR}"
    exec ./script/build_and_run.sh "$@"
    ;;
  logs|--logs|telemetry|--telemetry|verify|--verify|stop|--stop)
    [[ "$#" -le 1 ]] || { usage; exit 2; }
    cd "${MACSCOPE_DIR}"
    exec ./script/build_and_run.sh "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
