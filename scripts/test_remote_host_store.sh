#!/bin/zsh
set -euo pipefail

ROOT_DIR=$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd)
QA_DIR=$(/usr/bin/mktemp -d /private/tmp/remote-host-store-qa.XXXXXX)

/usr/bin/xcrun swiftc \
  -DREMOTE_HOST_STORE_QA \
  -parse-as-library \
  "$ROOT_DIR/app/Sources/DeepSeekHarnessMac/Services/RemoteHostStore.swift" \
  "$ROOT_DIR/app/Tests/RemoteHostStoreQA/main.swift" \
  -o "$QA_DIR/RemoteHostStoreQA"

"$QA_DIR/RemoteHostStoreQA"
