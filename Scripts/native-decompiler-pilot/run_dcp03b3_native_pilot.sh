#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON="${MACSCOPE_DCP03B3_PYTHON:-${ROOT}/libghidra-dcp03b3/bin/python3}"
MATERIALIZATION="${MACSCOPE_DCP03B3_MATERIALIZATION:-${ROOT}/libghidra-dcp03b3/MATERIALIZATION.json}"
exec /usr/bin/env python3 "${ROOT}/Scripts/native-decompiler-pilot/run_dcp03b3_native_pilot.py" \
  --python "${PYTHON}" \
  --materialization "${MATERIALIZATION}" \
  "$@"
