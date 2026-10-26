#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON_EXECUTABLE="${MACSCOPE_DCP03_PYTHON:-${ROOT}/pypcode-dcp03/bin/python3}"

exec /usr/bin/env python3 "${ROOT}/Scripts/decompiler-proof/run_dcp03_proof.py" \
  --python "${PYTHON_EXECUTABLE}" \
  "$@"
