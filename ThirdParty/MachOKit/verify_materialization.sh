#!/bin/sh
set -eu

COMPONENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$COMPONENT_DIR/../.." && pwd)
MATERIALIZATION_ROOT="$COMPONENT_DIR/materialization"

exec python3 "$REPOSITORY_ROOT/Scripts/machokit_source_identity.py" verify \
  --materialization-root "$MATERIALIZATION_ROOT" "$@"
