#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
QA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-webview-drop-qa.XXXXXX")"
QA_BINARY="$QA_ROOT/webview-drop-qa"

cleanup() {
  /bin/rm -rf "$QA_ROOT"
}
trap cleanup EXIT INT TERM

/usr/bin/xcrun swiftc \
  -D DEBUG \
  -parse-as-library \
  "$PROJECT_ROOT/app/Sources/DeepSeekHarnessMac/Services/ArtifactStore.swift" \
  "$PROJECT_ROOT/app/Sources/DeepSeekHarnessMac/Views/HarnessWebView.swift" \
  "$PROJECT_ROOT/scripts/test_webview_file_drop.swift" \
  -o "$QA_BINARY"

WEBVIEW_DROP_QA_ROOT="$QA_ROOT/fixtures" "$QA_BINARY"
/usr/bin/env node "$PROJECT_ROOT/scripts/test_native_attachments_plugin.mjs"
