#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
QA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-appshot-qa.XXXXXX")"
QA_BINARY="$QA_ROOT/appshot-qa"

cleanup() {
  /bin/rm -rf "$QA_ROOT"
}
trap cleanup EXIT INT TERM

/usr/bin/xcrun swiftc \
  -D DEBUG \
  -parse-as-library \
  "$PROJECT_ROOT/app/Sources/DeepSeekHarnessMac/Services/HarnessPrivacy.swift" \
  "$PROJECT_ROOT/app/Sources/DeepSeekHarnessMac/Services/AppshotStore.swift" \
  "$PROJECT_ROOT/app/Sources/DeepSeekHarnessMac/Services/GlobalHotKeyController.swift" \
  "$PROJECT_ROOT/scripts/test_appshot_qa.swift" \
  -o "$QA_BINARY"

APPSHOT_QA_ROOT="$QA_ROOT/artifacts" "$QA_BINARY"

if [[ "${APPSHOT_QA_KEEP_FIXTURE:-0}" == "1" ]]; then
  KEPT_ROOT="${TMPDIR:-/tmp}/deepseek-appshot-qa-kept"
  /bin/rm -rf "$KEPT_ROOT"
  /bin/mv "$QA_ROOT" "$KEPT_ROOT"
  trap - EXIT INT TERM
  print "APPSHOT_QA_FIXTURE_ROOT=$KEPT_ROOT"
fi
