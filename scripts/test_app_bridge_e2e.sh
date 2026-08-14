#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
PACKAGE_DIR="${PROJECT_ROOT}/app"

swift build --package-path "${PACKAGE_DIR}" --product DeepSeekAppBridge
swift build --package-path "${PACKAGE_DIR}" --product DeepSeekBridgeFixture
swift build --package-path "${PACKAGE_DIR}" -c release --product DeepSeekAppBridge

BIN_DIR="$(swift build --package-path "${PACKAGE_DIR}" --show-bin-path)"
RELEASE_BIN_DIR="$(swift build --package-path "${PACKAGE_DIR}" -c release --show-bin-path)"
exec /usr/bin/python3 "${SCRIPT_DIR}/test_app_bridge_e2e.py" \
    --bridge "${BIN_DIR}/DeepSeekAppBridge" \
    --release-bridge "${RELEASE_BIN_DIR}/DeepSeekAppBridge" \
    --fixture "${BIN_DIR}/DeepSeekBridgeFixture" \
    "$@"
