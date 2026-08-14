#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 "$ROOT_DIR/scripts/test_ssh_bridge.py"
