#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
QA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-settings-migration-qa.XXXXXX")"
QA_BINARY="$QA_ROOT/settings-migration-qa"

cleanup() {
  /bin/rm -rf "$QA_ROOT"
}
trap cleanup EXIT INT TERM

/usr/bin/xcrun swiftc \
  "$PROJECT_ROOT/app/Sources/DeepSeekHarnessMac/Services/DeepSeekModelCatalogMigration.swift" \
  "$PROJECT_ROOT/scripts/test_settings_model_migration.swift" \
  -o "$QA_BINARY"

"$QA_BINARY"
