#!/bin/zsh
# Re-record DSSnapshot subjects offline without building the app.
# Prefer an explicit output directory for reviewing candidate images before accepting goldens.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/MacScope/Tests/Fixtures/DSSnapshots"
BUILD_ONLY=0
while (( $# )); do
  case "$1" in
    --output-directory)
      (( $# >= 2 )) || { print -u2 "missing output directory"; exit 2; }
      OUT="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --help)
      print "usage: $0 [--output-directory DIRECTORY] [--build-only]"
      exit 0 ;;
    *) print -u2 "unknown argument: $1"; exit 2 ;;
  esac
done
export MACSCOPE_DESIGN_BUILD_ONLY="$BUILD_ONLY"
exec "$REPO/Scripts/design/run_lumen_tool.sh" snapshots "$REPO" "$OUT"
