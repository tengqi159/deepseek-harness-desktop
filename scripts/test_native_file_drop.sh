#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
QA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-native-drop-qa.XXXXXX")"
QA_BINARY="$QA_ROOT/native-drop-qa"

cleanup() {
  /bin/rm -rf "$QA_ROOT"
}
trap cleanup EXIT INT TERM

/usr/bin/xcrun swiftc \
  -D DEBUG \
  -parse-as-library \
  "$PROJECT_ROOT/app/Sources/DeepSeekHarnessMac/Services/ArtifactStore.swift" \
  "$PROJECT_ROOT/scripts/test_native_file_drop.swift" \
  -o "$QA_BINARY"

DSH_ARTIFACT_STORE_ROOT="$QA_ROOT/artifacts" "$QA_BINARY"
/usr/bin/env node "$PROJECT_ROOT/scripts/test_native_attachments_plugin.mjs"
