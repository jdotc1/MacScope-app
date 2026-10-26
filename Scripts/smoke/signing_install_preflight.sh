#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: signing_install_preflight.sh --app-bundle PATH [--source-app-bundle PATH]
       [--configuration Release]

Validate an already-built, certificate-signed MacScope.app without changing it.
The check is offline and never installs, launches, or modifies the artifact.
EOF
}

APP_BUNDLE=""
SOURCE_APP_BUNDLE=""
CONFIGURATION="Release"
DESTINATION="/Applications/MacScope.app"
while (($#)); do
  case "$1" in
    --app-bundle) APP_BUNDLE="${2:?missing value for --app-bundle}"; shift 2 ;;
    --source-app-bundle) SOURCE_APP_BUNDLE="${2:?missing value for --source-app-bundle}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:?missing value for --configuration}"; shift 2 ;;
    --destination) DESTINATION="${2:?missing value for --destination}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$APP_BUNDLE" ]]; then echo "ERROR: --app-bundle is required" >&2; exit 2; fi
if [[ -n "$SOURCE_APP_BUNDLE" && "$SOURCE_APP_BUNDLE" != /* ]]; then
  echo "ERROR: --source-app-bundle must be an absolute path" >&2; exit 2
fi
if [[ "$CONFIGURATION" != Release ]]; then
  echo "ERROR: install preflight accepts only the sealed Release configuration" >&2; exit 2
fi
if [[ "$APP_BUNDLE" != /* ]]; then
  echo "ERROR: --app-bundle must be an absolute path" >&2; exit 2
fi
if [[ ! -d "$APP_BUNDLE" || -L "$APP_BUNDLE" || "${APP_BUNDLE##*/}" != MacScope.app ]]; then
  echo "ERROR: app bundle must be a non-symlink directory named MacScope.app: $APP_BUNDLE" >&2; exit 1
fi
if [[ -n "$SOURCE_APP_BUNDLE" && ( ! -d "$SOURCE_APP_BUNDLE" || -L "$SOURCE_APP_BUNDLE" || "${SOURCE_APP_BUNDLE##*/}" != MacScope.app ) ]]; then
  echo "ERROR: source app bundle must be a non-symlink directory named MacScope.app: $SOURCE_APP_BUNDLE" >&2; exit 1
fi
if [[ -n "$SOURCE_APP_BUNDLE" && "$SOURCE_APP_BUNDLE" == "$APP_BUNDLE" ]]; then
  echo "ERROR: source and installed app bundles must differ" >&2; exit 1
fi

ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PREFLIGHT_TEST_SEAMS="${MACSCOPE_PREFLIGHT_TEST_SEAMS:-}"
if [[ -n "$PREFLIGHT_TEST_SEAMS" && "$PREFLIGHT_TEST_SEAMS" != 1 ]]; then
  echo "ERROR: MACSCOPE_PREFLIGHT_TEST_SEAMS must be unset or exactly 1" >&2
  exit 2
fi
if [[ "$PREFLIGHT_TEST_SEAMS" == 1 ]]; then
  PLUTIL="${MACSCOPE_PREFLIGHT_PLUTIL:-/usr/bin/plutil}"
  CODESIGN="${MACSCOPE_PREFLIGHT_CODESIGN:-/usr/bin/codesign}"
  LIPO="${MACSCOPE_PREFLIGHT_LIPO:-/usr/bin/lipo}"
  OTOOL="${MACSCOPE_PREFLIGHT_OTOOL:-/usr/bin/otool}"
  PYTHON="${MACSCOPE_PREFLIGHT_PYTHON:-/usr/bin/python3}"
  POLICY="${MACSCOPE_PREFLIGHT_POLICY_CHECKER:-$ROOT_DIR/Scripts/check_local_signing_policy.py}"
else
  if [[ -n "${MACSCOPE_PREFLIGHT_PLUTIL:-}" ||
        -n "${MACSCOPE_PREFLIGHT_CODESIGN:-}" ||
        -n "${MACSCOPE_PREFLIGHT_LIPO:-}" ||
        -n "${MACSCOPE_PREFLIGHT_OTOOL:-}" ||
        -n "${MACSCOPE_PREFLIGHT_PYTHON:-}" ||
        -n "${MACSCOPE_PREFLIGHT_POLICY_CHECKER:-}" ]]; then
    echo "ERROR: preflight tool overrides are test-only and require MACSCOPE_PREFLIGHT_TEST_SEAMS=1" >&2
    exit 2
  fi
  PLUTIL="/usr/bin/plutil"
  CODESIGN="/usr/bin/codesign"
  LIPO="/usr/bin/lipo"
  OTOOL="/usr/bin/otool"
  PYTHON="/usr/bin/python3"
  POLICY="$ROOT_DIR/Scripts/check_local_signing_policy.py"
fi

fail() { echo "ERROR: $*" >&2; exit 1; }
readonly MAX_TOOL_BYTES=65536
readonly TOOL_TIMEOUT_SECONDS=60

bounded_tool() {
  "$PYTHON" -B - "$TOOL_TIMEOUT_SECONDS" "$MAX_TOOL_BYTES" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
maximum = int(sys.argv[2])
command = sys.argv[3:]
try:
    result = subprocess.run(command, capture_output=True, timeout=timeout, check=False)
except (OSError, subprocess.SubprocessError) as error:
    print(f"bounded tool execution failed: {error}", file=sys.stderr)
    raise SystemExit(125)
if len(result.stdout) > maximum or len(result.stderr) > maximum:
    print("bounded tool output exceeded 65536 bytes", file=sys.stderr)
    raise SystemExit(125)
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
raise SystemExit(result.returncode if 0 <= result.returncode <= 125 else 125)
PY
}

require_file() {
  "$PYTHON" -B - "$1" <<'PY' || fail "missing canonical single-link regular file: $1"
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    metadata = path.lstat()
    canonical = path.resolve(strict=True)
except OSError:
    raise SystemExit(1)
if (
    not path.is_absolute()
    or canonical != path
    or not stat.S_ISREG(metadata.st_mode)
    or stat.S_ISLNK(metadata.st_mode)
    or metadata.st_nlink != 1
):
    raise SystemExit(1)
PY
}

require_dir() {
  "$PYTHON" -B - "$1" <<'PY' || fail "missing canonical non-symlink directory: $1"
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    metadata = path.lstat()
    canonical = path.resolve(strict=True)
except OSError:
    raise SystemExit(1)
if (
    not path.is_absolute()
    or canonical != path
    or not stat.S_ISDIR(metadata.st_mode)
    or stat.S_ISLNK(metadata.st_mode)
):
    raise SystemExit(1)
PY
}
require_exact_children() {
  local directory="$1" label="$2" child name expected matched
  shift 2
  local -a children
  shopt -s nullglob dotglob
  children=("$directory"/*)
  shopt -u nullglob dotglob
  [[ "${#children[@]}" -eq "$#" ]] || fail "$label has an unexpected entry count"
  for child in "${children[@]}"; do
    name="${child##*/}"
    matched=0
    for expected in "$@"; do
      if [[ "$name" == "$expected" ]]; then matched=1; break; fi
    done
    [[ "$matched" -eq 1 ]] || fail "$label contains unexpected entry: $name"
  done
}

require_dir "$APP_BUNDLE"
if [[ -n "$SOURCE_APP_BUNDLE" ]]; then
  require_dir "$SOURCE_APP_BUNDLE"
  "$PYTHON" -B - "$SOURCE_APP_BUNDLE" "$APP_BUNDLE" <<'PY' || fail "source and installed app bundles must be physically distinct"
from pathlib import Path
import sys

source, installed = (Path(value) for value in sys.argv[1:])
source_metadata = source.lstat()
installed_metadata = installed.lstat()
if (
    source.resolve(strict=True) == installed.resolve(strict=True)
    or (source_metadata.st_dev, source_metadata.st_ino)
    == (installed_metadata.st_dev, installed_metadata.st_ino)
):
    raise SystemExit(1)
PY
fi

"$PYTHON" -B - "$DESTINATION" <<'PY' || fail "installation destination must be an absolute canonical path below a canonical parent"
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_absolute() or path.name == "":
    raise SystemExit(1)
try:
    parent = path.parent.resolve(strict=True)
    parent_metadata = path.parent.lstat()
except OSError:
    raise SystemExit(1)
if (
    parent != path.parent
    or not stat.S_ISDIR(parent_metadata.st_mode)
    or stat.S_ISLNK(parent_metadata.st_mode)
):
    raise SystemExit(1)
PY

CONTENTS="$APP_BUNDLE/Contents"
MAIN="$CONTENTS/MacOS/MacScope"
require_dir "$CONTENTS"
require_file "$CONTENTS/Info.plist"
require_file "$MAIN"
require_dir "$CONTENTS/XPCServices"
require_dir "$CONTENTS/Frameworks"
require_dir "$CONTENTS/Resources"
require_file "$CONTENTS/MacOS/ShellBrokerLaunchAgent"
require_file "$CONTENTS/MacOS/SourceExecutionRunner"
require_file "$CONTENTS/Resources/MacScopeBuildProvenance.json"
require_dir "$CONTENTS/_CodeSignature"
require_file "$CONTENTS/_CodeSignature/CodeResources"
require_exact_children "$CONTENTS/MacOS" "MacScope.app Contents/MacOS" \
  MacScope ShellBrokerLaunchAgent SourceExecutionRunner

for service in AnalysisWorkerXPCService AIAgentWorkerXPCService NativeDecompilerXPCService ShellBrokerXPCService; do
  bundle="$CONTENTS/XPCServices/${service}.xpc"
  require_dir "$bundle"
  require_dir "$bundle/Contents"
  require_file "$bundle/Contents/Info.plist"
  require_dir "$bundle/Contents/MacOS"
  require_file "$bundle/Contents/MacOS/$service"
  require_dir "$bundle/Contents/_CodeSignature"
  require_file "$bundle/Contents/_CodeSignature/CodeResources"
  require_exact_children "$bundle/Contents/MacOS" "$service Contents/MacOS" "$service"
done
require_exact_children "$CONTENTS/XPCServices" "MacScope.app XPCServices" \
  AnalysisWorkerXPCService.xpc \
  AIAgentWorkerXPCService.xpc \
  NativeDecompilerXPCService.xpc \
  ShellBrokerXPCService.xpc
require_exact_children "$CONTENTS/Frameworks" "MacScope.app Contents/Frameworks" \
  libghostty-vt.dylib
require_file "$CONTENTS/Frameworks/libghostty-vt.dylib"

[[ "$(bounded_tool "$PLUTIL" -extract CFBundleIdentifier raw "$CONTENTS/Info.plist" 2>/dev/null)" == "org.macscope.app" ]] || fail "app CFBundleIdentifier is not org.macscope.app"
[[ "$(bounded_tool "$PLUTIL" -extract CFBundlePackageType raw "$CONTENTS/Info.plist" 2>/dev/null)" == "APPL" ]] || fail "app CFBundlePackageType is not APPL"
[[ "$(bounded_tool "$PLUTIL" -extract CFBundleExecutable raw "$CONTENTS/Info.plist" 2>/dev/null)" == "MacScope" ]] || fail "app CFBundleExecutable is not MacScope"

for service_identity in \
  "AnalysisWorkerXPCService:org.macscope.app.AnalysisWorker" \
  "AIAgentWorkerXPCService:org.macscope.app.AIAgentWorker" \
  "NativeDecompilerXPCService:org.macscope.app.NativeDecompiler" \
  "ShellBrokerXPCService:org.macscope.app.ShellBroker"; do
  service="${service_identity%%:*}"
  expected_identifier="${service_identity#*:}"
  plist="$CONTENTS/XPCServices/${service}.xpc/Contents/Info.plist"
  [[ "$(bounded_tool "$PLUTIL" -extract CFBundleIdentifier raw "$plist" 2>/dev/null)" == "$expected_identifier" ]] || fail "$service CFBundleIdentifier is not $expected_identifier"
  [[ "$(bounded_tool "$PLUTIL" -extract CFBundlePackageType raw "$plist" 2>/dev/null)" == "XPC!" ]] || fail "$service CFBundlePackageType is not XPC!"
  [[ "$(bounded_tool "$PLUTIL" -extract CFBundleExecutable raw "$plist" 2>/dev/null)" == "$service" ]] || fail "$service CFBundleExecutable is not $service"
done

"$PYTHON" -B - "$CONTENTS/Resources/MacScopeBuildProvenance.json" <<'PY' || fail "sealed Release provenance is malformed or ineligible"
import json
import re
import sys
from pathlib import Path

try:
    value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
if (
    not isinstance(value, dict)
    or value.get("schema_version") != 1
    or value.get("qualification_eligible") is not True
    or value.get("configuration") != "Release"
    or value.get("repository_clean") is not True
    or re.fullmatch(r"[0-9a-f]{40}", str(value.get("git_head_commit", ""))) is None
    or re.fullmatch(r"[0-9a-f]{40}", str(value.get("git_head_tree", ""))) is None
    or re.fullmatch(r"[0-9a-f]{64}", str(value.get("selected_build_inputs_sha256", ""))) is None
):
    raise SystemExit(1)
PY

verify_code() { bounded_tool "$CODESIGN" --verify --deep --strict --verbose=2 "$1" >/dev/null 2>&1 || fail "strict/deep code-sign verification failed: $1"; }
inspect_macho() {
  local label="$1" path="$2"; local archs minos
  archs="$(bounded_tool "$LIPO" -archs "$path" 2>/dev/null)" || fail "$label architecture inspection failed"
  [[ "$archs" == "arm64" ]] || fail "$label must be thin arm64; observed: $archs"
  minos="$(bounded_tool "$OTOOL" -l "$path" 2>/dev/null | /usr/bin/awk '/^[[:space:]]*minos / {print $2; exit}')"
  [[ "$minos" == "27.0" ]] || fail "$label minimum macOS version must be 27.0; observed: ${minos:-missing}"
}

verify_code "$APP_BUNDLE"
inspect_macho "MacScope.app executable" "$MAIN"
for service in AnalysisWorkerXPCService AIAgentWorkerXPCService NativeDecompilerXPCService ShellBrokerXPCService; do
  bundle="$CONTENTS/XPCServices/${service}.xpc"
  verify_code "$bundle"
  inspect_macho "$service" "$bundle/Contents/MacOS/$service"
done
verify_code "$CONTENTS/MacOS/SourceExecutionRunner"
inspect_macho "SourceExecutionRunner" "$CONTENTS/MacOS/SourceExecutionRunner"
verify_code "$CONTENTS/MacOS/ShellBrokerLaunchAgent"
inspect_macho "ShellBrokerLaunchAgent" "$CONTENTS/MacOS/ShellBrokerLaunchAgent"
verify_code "$CONTENTS/Frameworks/libghostty-vt.dylib"
inspect_macho "libghostty-vt.dylib" "$CONTENTS/Frameworks/libghostty-vt.dylib"

if [[ -n "$SOURCE_APP_BUNDLE" ]]; then
  bounded_tool "$PYTHON" "$POLICY" --source-app-bundle "$SOURCE_APP_BUNDLE" --app-bundle "$APP_BUNDLE" --configuration "$CONFIGURATION" >/dev/null || fail "repository signing-policy checker rejected source/installed comparison"
else
  bounded_tool "$PYTHON" "$POLICY" --app-bundle "$APP_BUNDLE" --configuration "$CONFIGURATION" >/dev/null || fail "repository signing-policy checker rejected artifact"
fi

if [[ -z "$SOURCE_APP_BUNDLE" && "$DESTINATION" == /* && ( -e "$DESTINATION" || -L "$DESTINATION" ) ]]; then
  fail "installation destination already exists; refusing overwrite: $DESTINATION"
fi
if [[ -z "$SOURCE_APP_BUNDLE" ]]; then
  [[ "$DESTINATION" != "$APP_BUNDLE" ]] || fail "installation destination must differ from source bundle"
  [[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || fail "installation destination is not available: $DESTINATION"
fi

if [[ -n "$SOURCE_APP_BUNDLE" ]]; then
  echo "PASS: source and installed MacScope.app bundles match under the repository checker"
else
  echo "PASS: $APP_BUNDLE is ready for a later non-overwriting installation at $DESTINATION"
fi
