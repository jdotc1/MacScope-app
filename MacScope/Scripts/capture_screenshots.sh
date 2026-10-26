#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEME="${MACSCOPE_SCHEME:-MacScopeApp}"
CONFIGURATION="${MACSCOPE_CONFIGURATION:-Debug}"
PROJECT_FILE="$PROJECT_DIR/MacScope.xcodeproj"
DERIVED_DATA="${MACSCOPE_DERIVED_DATA:-$PROJECT_DIR/DerivedData}"

source "${SCRIPT_DIR}/../../Scripts/xcode27_env.sh"

SKIP_BUILD=0

usage() {
  echo "usage: $0 [--skip-build] [--all-states]" >&2
  echo "GUI screenshot launch is disabled in this script." >&2
}

while (($#)); do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      ;;
    --all-states)
      # Accepted for compatibility with older validation commands. It does not
      # enable GUI launch or screenshot capture.
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  xcrun xcodebuild build \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS=arm64
fi

cat >&2 <<'EOF'
GUI screenshot capture is disabled for this script.

This script intentionally does not call open(1), osascript activation,
screencapture, or any other command that can launch or move MacScope windows
across displays. Visual validation must be performed only after explicit
display-placement approval.
EOF

exit 64
