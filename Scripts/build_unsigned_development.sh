#!/usr/bin/env bash
# Unsigned local Debug build only; never signs, installs, archives or publishes.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/work_root.sh
source "$ROOT/Scripts/lib/work_root.sh"
WORK_ROOT_DIR="$(macscope_work_root)"
if [[ $# != 3 ]]; then
  echo "usage: Scripts/build_unsigned_development.sh PREPARED_CHECKOUT PREPARED_DERIVED_DATA OUTPUT_ROOT" >&2
  exit 2
fi
PREPARED_CHECKOUT="$1"
PREPARED_DERIVED_DATA="$2"
OUTPUT_ROOT="$3"
AUTHORIZED_ROOT="$(cd "$WORK_ROOT_DIR" && pwd -P)"
OUTPUT_ROOT="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$OUTPUT_ROOT")"
case "$OUTPUT_ROOT" in
  "$AUTHORIZED_ROOT"/*) ;;
  *) echo 'ERROR: canonical output must remain under the Developer workspace' >&2; exit 2 ;;
esac
if [[ -n "${CI:-}${GITHUB_ACTIONS:-}${MACSCOPE_NATIVE_RELEASE_ADMISSION:-}" || "${MACSCOPE_CONFIGURATION:-Debug}" != Debug ]]; then
  echo 'ERROR: unsigned development is Debug/local only; CI and release are prohibited' >&2
  exit 2
fi
mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd -P)"
case "$OUTPUT_ROOT/" in
  "$ROOT/"*) echo 'ERROR: build outputs must remain outside the checkout' >&2; exit 2 ;;
esac
LOCK="$WORK_ROOT_DIR/.macscope-heavy-gate.lock"
exec 7>>"$LOCK"
python3 -B "$ROOT/Scripts/qualification/heavy_gate_lock.py" acquire --lock "$LOCK" --fd 7 --pid "$$" --work-root "$ROOT" --integration-ref unsigned-development --mode unsigned-development --run-root "$OUTPUT_ROOT" --timeout 1800
trap 'python3 -B "$ROOT/Scripts/qualification/heavy_gate_lock.py" release --lock "$LOCK" --pid "$$"; exec 7>&-' EXIT
LUMEN_PIN="$(/usr/bin/git -C "$ROOT" rev-parse -q --verify 'HEAD:ThirdParty/Lumen' 2>/dev/null || true)"
LUMEN_CURRENT=""
if [[ -e "$ROOT/ThirdParty/Lumen/.git" ]]; then
  LUMEN_CURRENT="$(/usr/bin/git -C "$ROOT/ThirdParty/Lumen" rev-parse -q --verify HEAD 2>/dev/null || true)"
fi
if [[ -z "$LUMEN_PIN" || -z "$LUMEN_CURRENT" || "$LUMEN_CURRENT" != "$LUMEN_PIN" ]]; then
  echo 'ERROR: Lumen is uninitialized or does not match the repository gitlink; refusing the unsigned build.' >&2
  echo 'Sync the Lumen submodule to its gitlink with the explicit dependency setup tool, then retry.' >&2
  exit 2
fi
export PYTHONDONTWRITEBYTECODE=1
export TMPDIR="$OUTPUT_ROOT/tmp"
mkdir -p "$TMPDIR"
ADMISSION="$OUTPUT_ROOT/unsigned-development-inputs.json"
python3 -B "$ROOT/Scripts/unsigned_development.py" prepare \
  --prepared-repository "$PREPARED_CHECKOUT" --prepared-derived-data "$PREPARED_DERIVED_DATA" --admission "$ADMISSION"
source "$ROOT/Scripts/xcode27_env.sh"
/usr/bin/nice -n 5 /usr/bin/xcodebuild build \
  -project "$ROOT/MacScope/MacScope.xcodeproj" -scheme MacScopeApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$OUTPUT_ROOT/DerivedData" -jobs 4 \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  MACSCOPE_DEV_UNSIGNED=YES "MACSCOPE_DEV_UNSIGNED_ADMISSION=$ADMISSION" \
  MACSCOPE_DEBUG_SOURCE_IDENTITY=runtime-only \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY= EXPANDED_CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  COMPILER_INDEX_STORE_ENABLE=NO COMPILATION_CACHE_ENABLE_CACHING=YES \
  "COMPILATION_CACHE_CAS_PATH=$WORK_ROOT_DIR/MacScopeDevLoop.noindex/compilation-cache" \
  -showBuildTimingSummary
printf 'Unsigned development product: %s\n' "$OUTPUT_ROOT/DerivedData/Build/Products/Debug/MacScope.app"
