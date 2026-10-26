#!/bin/zsh
# Regenerate docs/design/tokens/* offline, without building the app.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
if (( $# > 1 )); then
  print -u2 "usage: $0 [output-directory]"
  exit 2
fi
exec "$REPO/Scripts/design/run_lumen_tool.sh" export "$REPO" "${1:-$REPO/docs/design/tokens}"
