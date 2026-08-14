#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
WORKSPACE="${SCRIPT_DIR:h}"

if command -v uv >/dev/null 2>&1; then
  exec uv run --with reportlab --with pillow python "${SCRIPT_DIR}/test_artifact_bridge.py" --workspace "${WORKSPACE}" "$@"
fi

python3 - <<'PY'
import reportlab
from PIL import Image
PY
exec python3 "${SCRIPT_DIR}/test_artifact_bridge.py" --workspace "${WORKSPACE}" "$@"
